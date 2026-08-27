#!/usr/bin/env bash
#
# TcpQuality 单线程测速精简版
#
# 保留功能：
#   1) 单线程测速（TOS 固定 IP，电信/联通/移动 × 北京/上海/广东）
#   2) ASN / IP 检测（自动探测本机公网 IPv4/IPv6，并解析 ASN）
#
set -e

# cron 环境下 PATH 可能过短（仅 /usr/bin:/bin），补充完整 PATH 保证 curl/sed/mktemp 等可用
case ":$PATH:" in
  *:/usr/local/sbin:*) ;;
  *) export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH" ;;
esac

# ===================== 颜色 =====================
RED='\033[0;31m';    GREEN='\033[0;32m';    YELLOW='\033[0;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';     MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  BOLD='\033[1m';        DIM='\033[2m'
UNDERLINE='\033[4m'
NC='\033[0m'
BG_RED='\033[41m';   BG_GREEN='\033[42m';   BG_YELLOW='\033[43m'

# ===================== 全局变量 =====================
USE_SUDO=""
IPV4_PUBLIC=""
IPV6_PUBLIC=""

GET_NODES_URL="${GET_NODES_URL:-https://tcpquality.ibsgss.uk/getNodes}"
HAS_CLI_ARGS=0
UL_FLAG=0
DL_FLAG=0

# ---------- 用户选择（CLI 参数 / 交互式向导） ----------
# 运营商：电信 联通 移动；空 = 全部
SELECTED_ISPS=""
# 城市：北京 上海 广东；空 = 全部
SELECTED_CITIES=""
# 测速方向：both=下载+上传  dl=仅回程(上传)  ul=仅去程(下载)
SPEEDTEST_DIRECTION="both"

# ---------- 配置 / Telegram 推送 / 定时测速 ----------
CONF_FILE="${CONF_FILE:-$HOME/.tcpquality.conf}"
TG_ENABLED=0
TG_BOT_TOKEN=""
TG_CHAT_ID=""
CRON_ENABLED=0
CRON_TIMES="12:00,22:00"
# 定时测速预设（CRON_ISPS/CRON_CITIES 与 SELECTED_* 同格式，空=全部）
CRON_DIRECTION="both"
CRON_ISPS=""
CRON_CITIES=""
SCHEDULED=0

REPORT_API=${TCPQUALITY_REPORT_API:-https://tcpquality.ibsgss.uk/generate}
ROUTE_ASN_API=${TCPQUALITY_ROUTE_ASN_API:-${REPORT_API%/generate}/route/asn?format=tsv}
RANK_SESSION_API=${TCPQUALITY_RANK_SESSION_API:-${REPORT_API%/generate}/rank/session}
RANK_SESSION_ID=""
RANK_SESSION_TOKEN=""
RANK_SESSION_STARTED_AT=""
RANK_SESSION_EXPIRES_AT=""
RANK_SESSION_IP4=""

RESULT_DIR=$(mktemp -d)
cleanup_result_dir() {
  printf '%b' "${NC:-\033[0m}"
  rm -rf "$RESULT_DIR"
}
trap cleanup_result_dir EXIT

# ===================== 权限与依赖 =====================
init_privilege() {
  USE_SUDO=""
  if [ "$(uname)" != "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
    if command -v sudo &>/dev/null; then
      USE_SUDO="sudo"
    fi
  fi
}

show_dependency_install_notice() {
  echo -ne "\r${YELLOW}[!] 检测到未安装的依赖，正在安装...${NC}"
}

clear_dependency_install_notice() {
  printf '\r\033[2K'
}

install_with_package_manager() {
  local dep="$1"
  local apt_pkg="$2"
  local dnf_pkg="$3"
  local yum_pkg="$4"
  local apk_pkg="$5"
  local pacman_pkg="$6"
  local brew_pkg="$7"

  if [ "$(uname)" != "Darwin" ] && [ "$(id -u)" -ne 0 ] && [ -z "$USE_SUDO" ]; then
    echo -e "${RED}[X] 运行权限不足，请切换到 root 用户后运行${NC}"
    exit 1
  fi

  if command -v apt-get &>/dev/null; then
    $USE_SUDO apt-get update -qq >/dev/null 2>&1 || true
    $USE_SUDO apt-get install -y -qq "$apt_pkg" >/dev/null 2>&1 || return 1
  elif command -v dnf &>/dev/null; then
    $USE_SUDO dnf install -y -q "$dnf_pkg" >/dev/null 2>&1 || {
      $USE_SUDO dnf install -y -q epel-release >/dev/null 2>&1 || true
      $USE_SUDO dnf install -y -q "$dnf_pkg" >/dev/null 2>&1 || return 1
    }
  elif command -v yum &>/dev/null; then
    $USE_SUDO yum install -y -q "$yum_pkg" >/dev/null 2>&1 || {
      $USE_SUDO yum install -y -q epel-release >/dev/null 2>&1 || true
      $USE_SUDO yum install -y -q "$yum_pkg" >/dev/null 2>&1 || return 1
    }
  elif command -v apk &>/dev/null; then
    $USE_SUDO apk add --no-cache "$apk_pkg" >/dev/null 2>&1 || return 1
  elif command -v pacman &>/dev/null; then
    $USE_SUDO pacman -Sy --noconfirm "$pacman_pkg" >/dev/null 2>&1 || return 1
  elif command -v brew &>/dev/null; then
    brew install "$brew_pkg" >/dev/null 2>&1 || return 1
  else
    echo -e "${RED}[X] 无法自动安装 $dep，请手动安装后重试${NC}"
    exit 1
  fi
}

check_command() {
  local cmd="$1" desc="$2" apt_pkg="$3" dnf_pkg="$4" yum_pkg="$5" apk_pkg="$6" pacman_pkg="$7" brew_pkg="$8"
  if command -v "$cmd" &>/dev/null; then
    return 0
  fi
  show_dependency_install_notice
  if install_with_package_manager "$desc" "$apt_pkg" "$dnf_pkg" "$yum_pkg" "$apk_pkg" "$pacman_pkg" "$brew_pkg" && command -v "$cmd" &>/dev/null; then
    clear_dependency_install_notice
  else
    clear_dependency_install_notice
    echo -e "${RED}[X] $desc 安装失败${NC}"
    exit 1
  fi
}

check_curl() {
  check_command curl curl curl curl curl curl curl curl
}

require_raw_socket_privilege() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[X] 运行权限不足，请切换到 root 用户后运行${NC}"
    exit 1
  fi
}

# ===================== UI 工具 =====================
bar() {
  local done=$1 total=$2 width=40
  [ "$total" -gt 0 ] 2>/dev/null || total=1
  [ "$done" -gt "$total" ] 2>/dev/null && done="$total"
  local pct=$(( done * 100 / total ))
  local fill=$(( done * width / total ))
  local empty=$(( width - fill ))
  printf "["
  printf "%${fill}s" | tr ' ' '#'
  printf "%${empty}s" | tr ' ' '-'
  printf "] %d/%d (%d%%)" "$done" "$total" "$pct"
}

# ===================== ASN / IP 检测（保留功能） =====================
is_public_ipv4() {
  local ip="$1"
  awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      if ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224) exit 1
      if ($1 == 100 && $2 >= 64 && $2 <= 127) exit 1
      if ($1 == 169 && $2 == 254) exit 1
      if ($1 == 172 && $2 >= 16 && $2 <= 31) exit 1
      if ($1 == 192 && $2 == 168) exit 1
      if ($1 == 192 && $2 == 0 && $3 == 0) exit 1
      if ($1 == 192 && $2 == 0 && $3 == 2) exit 1
      if ($1 == 198 && ($2 == 18 || $2 == 19)) exit 1
      if ($1 == 198 && $2 == 51 && $3 == 100) exit 1
      if ($1 == 203 && $2 == 0 && $3 == 113) exit 1
      exit 0
    }
  ' <<< "$ip"
}

is_valid_ipv6() {
  local ip="$1"
  [[ "$ip" =~ : ]] || return 1
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  case "$ip" in
    ""|::1|fe80:*|fc00:*|fd00:*|2001:db8:*|::ffff:*|2002:*) return 1 ;;
  esac
  return 0
}

get_public_ipv4() {
  local api response
  local apis=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.me/ip"
    "https://ifconfig.co/ip"
    "https://ident.me"
    "https://ip.sb"
  )
  for api in "${apis[@]}"; do
    response=$(curl -fsS4L --max-time 8 "$api" 2>/dev/null | awk 'NR==1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    if [[ "$response" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && is_public_ipv4 "$response"; then
      IPV4_PUBLIC="$response"
      return 0
    fi
  done
  IPV4_PUBLIC=""
  return 1
}

get_public_ipv6() {
  local api response
  local apis=(
    "https://api6.ipify.org"
    "https://ipv6.icanhazip.com"
    "https://ifconfig.co/ip"
    "https://ident.me"
  )
  for api in "${apis[@]}"; do
    response=$(curl -6 -fsSL --connect-timeout 5 --max-time 8 "$api" 2>/dev/null | awk 'NR==1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    if is_valid_ipv6 "$response"; then
      IPV6_PUBLIC="$response"
      return 0
    fi
  done
  IPV6_PUBLIC=""
  return 1
}

detect_ip_stack() {
  get_public_ipv4 || true
  get_public_ipv6 || true
}

ensure_public_ips_for_rank() {
  if [ -z "${IPV4_PUBLIC:-}" ]; then
    get_public_ipv4 || true
  fi
  if [ -z "${IPV6_PUBLIC:-}" ]; then
    get_public_ipv6 || true
  fi
}

query_cymru_asn() {
  local ip_file="$1" out_file="$2" req_file
  req_file=$(mktemp)
  {
    echo "begin"
    echo "verbose"
    sort -u "$ip_file"
    echo "end"
  } > "$req_file"

  if command -v timeout &>/dev/null; then
    timeout 35 bash -c 'exec 3<>/dev/tcp/whois.cymru.com/43; cat "$1" >&3; cat <&3' _ "$req_file" > "$out_file" 2>/dev/null || true
  else
    bash -c 'exec 3<>/dev/tcp/whois.cymru.com/43; cat "$1" >&3; cat <&3' _ "$req_file" > "$out_file" 2>/dev/null || true
  fi
  rm -f "$req_file"
}

build_asn_map() {
  local cymru_file="$1" map_file="$2"
  awk -F'|' '
    NR == 1 { next }
    {
      asn = $1
      ip = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", asn)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", ip)
      owner = $7
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", owner)
      count = split(asn, values, /[[:space:]]+/)
      asn = values[count]
      if (asn ~ /^[0-9]+$/ && ip ~ /^[0-9A-Fa-f:.]+$/) print tolower(ip) "|" asn "|" owner
    }
  ' "$cymru_file" > "$map_file"
}

# 公网 IP 打码：仅作用于展示，ASN 查询与 rank session 仍使用完整 IP。
# IPv4 保留前两段，后两段打码：59.110.43.16 -> 59.110.*.*
# IPv6 保留前 3 组，其余打码：2408:4001:abcd:ef01:... -> 2408:4001:abcd:*
mask_public_ipv4() {
  printf '%s' "$1" | sed -E 's/^([0-9]{1,3})\.([0-9]{1,3})\..*/\1.\2.*.*/'
}
mask_public_ipv6() {
  printf '%s' "$1" | sed -E 's/^(([0-9a-fA-F]{1,4}:){3}).*/\1*/'
}
mask_public_ip() {
  local ip="$1"
  if [[ "$ip" == *:* ]]; then
    mask_public_ipv6 "$ip"
  else
    mask_public_ipv4 "$ip"
  fi
}

# 展示本机公网 IP 及对应 ASN（仅提示，不阻塞主流程）。
# 每个公网 IP 只输出一行：打码 IP + ASN（如有），避免 IP 重复出现。
show_ip_asn_info() {
  local ip_file cymru_file map_file ip asn owner label
  [ -n "$IPV4_PUBLIC" ] || [ -n "$IPV6_PUBLIC" ] || return 0
  echo -e "${BOLD}${CYAN}本机公网 IP / ASN${NC}"
  ip_file=$(mktemp)
  cymru_file=$(mktemp)
  map_file=$(mktemp)
  : > "$ip_file"
  [ -n "$IPV4_PUBLIC" ] && printf '%s\n' "$IPV4_PUBLIC" >> "$ip_file"
  [ -n "$IPV6_PUBLIC" ] && printf '%s\n' "$IPV6_PUBLIC" >> "$ip_file"
  if [ -s "$ip_file" ]; then
    # 静默 ASN 查询：子 shell 抑制可能的作业终止通知；
    # 后台 + 限时 10 秒等待，cymru 不可达时快速跳过（不阻塞、不泄漏报错）
    ( query_cymru_asn "$ip_file" "$cymru_file" ) >/dev/null 2>&1 &
    asn_pid=$!
    asn_wait=0
    while [ "$asn_wait" -lt 10 ] && kill -0 "$asn_pid" 2>/dev/null; do
      sleep 1
      asn_wait=$((asn_wait + 1))
    done
    if kill -0 "$asn_pid" 2>/dev/null; then
      kill "$asn_pid" 2>/dev/null || true
    fi
    wait "$asn_pid" 2>/dev/null || true
    build_asn_map "$cymru_file" "$map_file"
  fi
  for ip in "$IPV4_PUBLIC" "$IPV6_PUBLIC"; do
    [ -n "$ip" ] || continue
    if [[ "$ip" == *:* ]]; then label="IPv6"; else label="IPv4"; fi
    asn=""; owner=""
    while IFS='|' read -r aip aasn aowner; do
      if [ "$aip" = "${ip,,}" ]; then
        asn="$aasn"
        owner="${aowner//|/ }"
        break
      fi
    done < "$map_file"
    if [ -n "$asn" ]; then
      echo -e "  ${label}: ${GREEN}$(mask_public_ip "$ip")${NC}  ${DIM}ASN${NC}${asn}  ${owner}"
    else
      echo -e "  ${label}: ${GREEN}$(mask_public_ip "$ip")${NC}"
    fi
  done
  rm -f "$ip_file" "$cymru_file" "$map_file"
}

# ===================== 国内单线程测速（保留功能） =====================
SPEEDTEST_IFACE=""
SPEEDTEST_TOS_REGION="${TOS_REGION:-cn-beijing}"
SPEEDTEST_TOS_NETWORK="${TOS_NETWORK:-public}"
SPEEDTEST_TOS_SIZE="${TOS_PROBE_SIZE:-500MB}"
SPEEDTEST_TOS_TIMEOUT="${TOS_TIMEOUT:-10}"
SPEEDTEST_TOS_CT_IP="${TOS_CT_IP:-42.81.80.86}"
SPEEDTEST_TOS_CU_IP="${TOS_CU_IP:-221.194.175.109}"
SPEEDTEST_TOS_CM_IP="${TOS_CM_IP:-120.255.0.180}"
SPEEDTEST_TOS_REMOTE_LOADED=0
SPEEDTEST_TOS_CT_CITY="北京"
SPEEDTEST_TOS_CU_CITY="北京"
SPEEDTEST_TOS_CM_CITY="北京"
SPEEDTEST_TOS_CT_CANDIDATES="${TOS_CT_IP:-42.81.80.86}|北京|cn-beijing"
SPEEDTEST_TOS_CU_CANDIDATES="${TOS_CU_IP:-221.194.175.109}|北京|cn-beijing"
SPEEDTEST_TOS_CM_CANDIDATES="${TOS_CM_IP:-120.255.0.180}|北京|cn-beijing"
SPEEDTEST_TELECOM_ID=""
SPEEDTEST_TELECOM_CITY=""
SPEEDTEST_UNICOM_ID=""
SPEEDTEST_UNICOM_CITY=""
SPEEDTEST_MOBILE_ID=""
SPEEDTEST_MOBILE_CITY=""
SPEEDTEST_ROWS=()
SPEEDTEST_RANK_ELIGIBLE=1
SPEEDTEST_RANK_DISABLED_REASON=""
SPEEDTEST_COUNTER_CHAIN=""
SPEEDTEST_COUNTER_HOOK=""
SPEEDTEST_COUNTER_TOOL=""
SPEEDTEST_TCP_INFO_ENABLED="${TCPQUALITY_TCP_INFO:-1}"
SPEEDTEST_TCP_INFO_MONITOR_PID=""
SPEEDTEST_TCP_INFO_ACTIVE_MODE="none"
SPEEDTEST_TCP_INFO_ACTIVE_PRELOAD=""
SPEEDTEST_TCP_INFO_FAILURE_REASON=""
SPEEDTEST_RETRANS_TRACE_ENABLED="${TCPQUALITY_RETRANS_TRACE:-1}"
SPEEDTEST_RETRANS_TRACE_PID=""
SPEEDTEST_RETRANS_TRACE_FILE=""
SPEEDTEST_RETRANS_TRACE_ERR=""
SPEEDTEST_RETRANS_TRACE_READY=0
SPEEDTEST_RETRANS_TRACE_KEY=""
SPEEDTEST_RETRANS_TRACE_DISABLED=0
SPEEDTEST_TCP_INFO_PRELOAD="${TCPQUALITY_TCP_INFO_PRELOAD:-/usr/local/lib/libtcpquality-tcpinfo.so}"
SPEEDTEST_RETRANS_TRACE_SCRIPT="${TCPQUALITY_RETRANS_TRACE_SCRIPT:-/usr/local/libexec/tcpquality-retrans-seq.bt}"
SPEEDTEST_RETRANS_TRACE_FALLBACK_SCRIPT="${TCPQUALITY_RETRANS_TRACE_FALLBACK_SCRIPT:-/usr/local/libexec/tcpquality-retrans-skb.bt}"
SPEEDTEST_BPFTRACE_BTF="${TCPQUALITY_BPFTRACE_BTF:-/sys/kernel/btf/vmlinux}"
speedtest_candidates() {
  case "$1" in
    电信)
      printf '%s\n' "$SPEEDTEST_TOS_CT_CANDIDATES"
      ;;
    联通)
      printf '%s\n' "$SPEEDTEST_TOS_CU_CANDIDATES"
      ;;
    移动)
      printf '%s\n' "$SPEEDTEST_TOS_CM_CANDIDATES"
      ;;
  esac
}

speedtest_group_count() {
  speedtest_group_specs | awk 'NF{count++} END{print count + 0}'
}

request_rank_session() {
  local response_file session_id token started_at expires_at session_ip4
  RANK_SESSION_ID=""
  RANK_SESSION_TOKEN=""
  RANK_SESSION_STARTED_AT=""
  RANK_SESSION_EXPIRES_AT=""
  RANK_SESSION_IP4=""
  command -v curl &>/dev/null || return 1

  response_file=$(mktemp)
  if ! curl -4 -fsS --connect-timeout 5 --max-time 15 \
    -H "X-TcpQuality-Public-IPv4: ${IPV4_PUBLIC:-}" \
    -H "X-TcpQuality-Public-IPv6: ${IPV6_PUBLIC:-}" \
    -o "$response_file" "$RANK_SESSION_API" >/dev/null 2>&1; then
    rm -f "$response_file"
    return 1
  fi

  session_id=$(sed -nE 's/.*"sessionId":"([^"]+)".*/\1/p' "$response_file" | head -1)
  token=$(sed -nE 's/.*"token":"([^"]+)".*/\1/p' "$response_file" | head -1)
  started_at=$(sed -nE 's/.*"startedAt":"([^"]+)".*/\1/p' "$response_file" | head -1)
  expires_at=$(sed -nE 's/.*"expiresAt":"([^"]+)".*/\1/p' "$response_file" | head -1)
  session_ip4=$(sed -nE 's/.*"sessionIp4":"([^"]+)".*/\1/p' "$response_file" | head -1)
  rm -f "$response_file"
  [ -n "$session_id" ] && [ -n "$token" ] || return 1
  RANK_SESSION_ID="$session_id"
  RANK_SESSION_TOKEN="$token"
  RANK_SESSION_STARTED_AT="$started_at"
  RANK_SESSION_EXPIRES_AT="$expires_at"
  RANK_SESSION_IP4="$session_ip4"
  return 0
}

speedtest_region_title() {
  case "$1" in
    cn-shanghai) printf '上海' ;;
    cn-guangzhou) printf '广东' ;;
    *) printf '北京' ;;
  esac
}

speedtest_pick_candidate() {
  local carrier="$1" region="$2"
  speedtest_candidates "$carrier" | awk -F'|' -v region="$region" '
    $1 != "" && $3 == region { print; exit }
  '
}

load_remote_speedtest_nodes() {
  local tmp url sep line type family prov isp host ip port target backup_host backup_ip backup_port backup_target region
  local loaded_ct=0 loaded_cu=0 loaded_cm=0
  local ct_candidates="" cu_candidates="" cm_candidates=""
  [ "$SPEEDTEST_TOS_REMOTE_LOADED" -eq 1 ] && return 0
  command -v curl &>/dev/null || return 1

  tmp=$(mktemp)
  sep="?"
  [[ "$GET_NODES_URL" == *"?"* ]] && sep="&"
  url="${GET_NODES_URL}${sep}format=tsv&scope=tos"
  if ! curl -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  while IFS= read -r line; do
    line=${line//$'\t'/'|'}
    IFS='|' read -r type family prov isp host ip port target backup_host backup_ip backup_port backup_target <<< "$line"
    [ "$type" = "type" ] && continue
    [ "$family" = "4" ] || continue
    [ -n "$ip" ] || continue
    case "$type" in
      tos|tosutil|speedtest) ;;
      *) continue ;;
    esac
    region="cn-beijing"
    case "$target" in
      *cn-shanghai*) region="cn-shanghai" ;;
      *cn-guangzhou*) region="cn-guangzhou" ;;
      *cn-beijing*) region="cn-beijing" ;;
    esac
    case "$isp" in
      电信|CT|ChinaTelecom|chinatelecom)
        SPEEDTEST_TOS_CT_IP="$ip"
        SPEEDTEST_TOS_CT_CITY="${prov:-北京}"
        ct_candidates+="${ct_candidates:+$'\n'}$ip|${prov:-北京}|$region"
        loaded_ct=1
        ;;
      联通|CU|ChinaUnicom|chinaunicom)
        SPEEDTEST_TOS_CU_IP="$ip"
        SPEEDTEST_TOS_CU_CITY="${prov:-北京}"
        cu_candidates+="${cu_candidates:+$'\n'}$ip|${prov:-北京}|$region"
        loaded_cu=1
        ;;
      移动|CM|ChinaMobile|chinamobile)
        SPEEDTEST_TOS_CM_IP="$ip"
        SPEEDTEST_TOS_CM_CITY="${prov:-北京}"
        cm_candidates+="${cm_candidates:+$'\n'}$ip|${prov:-北京}|$region"
        loaded_cm=1
        ;;
    esac
  done < "$tmp"
  rm -f "$tmp"

  if [ "$loaded_ct" -eq 1 ] || [ "$loaded_cu" -eq 1 ] || [ "$loaded_cm" -eq 1 ]; then
    [ -n "$ct_candidates" ] && SPEEDTEST_TOS_CT_CANDIDATES="$ct_candidates"
    [ -n "$cu_candidates" ] && SPEEDTEST_TOS_CU_CANDIDATES="$cu_candidates"
    [ -n "$cm_candidates" ] && SPEEDTEST_TOS_CM_CANDIDATES="$cm_candidates"
    SPEEDTEST_TOS_REMOTE_LOADED=1
    return 0
  fi
  return 1
}

speedtest_selected_city() {
  case "$1" in
    电信) printf '%s' "$SPEEDTEST_TELECOM_CITY" ;;
    联通) printf '%s' "$SPEEDTEST_UNICOM_CITY" ;;
    移动) printf '%s' "$SPEEDTEST_MOBILE_CITY" ;;
  esac
}

speedtest_set_selected() {
  local carrier="$1" server_id="$2" city="$3"
  case "$carrier" in
    电信) SPEEDTEST_TELECOM_ID="$server_id"; SPEEDTEST_TELECOM_CITY="$city" ;;
    联通) SPEEDTEST_UNICOM_ID="$server_id"; SPEEDTEST_UNICOM_CITY="$city" ;;
    移动) SPEEDTEST_MOBILE_ID="$server_id"; SPEEDTEST_MOBILE_CITY="$city" ;;
  esac
}

speedtest_cleanup() {
  speedtest_tcp_info_monitor_stop
  speedtest_retrans_trace_stop
  speedtest_counter_stop_current
}

speedtest_dependencies_ready() {
  local cmd
  for cmd in ip nstat awk curl; do
    command -v "$cmd" &>/dev/null || return 1
  done
}

install_speedtest_dependencies() {
  show_dependency_install_notice
  if command -v apt-get &>/dev/null; then
    $USE_SUDO apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive $USE_SUDO apt-get install -y -qq \
      iproute2 gawk curl ca-certificates >/dev/null 2>&1
  elif command -v dnf &>/dev/null; then
    $USE_SUDO dnf install -y -q iproute gawk curl ca-certificates >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    $USE_SUDO yum install -y -q iproute gawk curl ca-certificates >/dev/null 2>&1
  elif command -v apk &>/dev/null; then
    $USE_SUDO apk add --no-cache iproute2 awk curl ca-certificates >/dev/null 2>&1
  else
    return 1
  fi
  if speedtest_dependencies_ready; then
    clear_dependency_install_notice
    return 0
  fi
  clear_dependency_install_notice
  return 1
}

install_speedtest_counter_dependency() {
  command -v iptables &>/dev/null && command -v ip6tables &>/dev/null && return 0
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive $USE_SUDO apt-get install -y -qq iptables >/dev/null 2>&1
  elif command -v dnf &>/dev/null; then
    $USE_SUDO dnf install -y -q iptables >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    $USE_SUDO yum install -y -q iptables >/dev/null 2>&1
  elif command -v apk &>/dev/null; then
    $USE_SUDO apk add --no-cache iptables >/dev/null 2>&1
  else
    return 1
  fi
  command -v iptables &>/dev/null && command -v ip6tables &>/dev/null
}

speedtest_retrans_count() {
  nstat -az 2>/dev/null | awk '$1=="TcpRetransSegs"{print $2; found=1} END{if(!found) print 0}'
}

speedtest_retrans_percent() {
  local retrans="$1" packets="$2"
  awk -v retrans="$retrans" -v packets="$packets" 'BEGIN {
    if (retrans !~ /^[0-9]+$/ || packets !~ /^[0-9]+$/ || packets <= 0) {
      print "-"
      exit
    }
    ratio = retrans / packets * 100
    if (ratio < 0) ratio = 0
    if (ratio > 100) ratio = 100
    printf "%.2f%%", ratio
  }'
}

speedtest_unique_retrans_percent() {
  local retrans="$1" data_segs_out="$2" total_retrans="$3" denominator
  denominator=$(awk -v data="$data_segs_out" -v retrans="$total_retrans" 'BEGIN {
    if (data !~ /^[0-9]+$/ || retrans !~ /^[0-9]+$/ || data <= 0) {
      print 0
      exit
    }
    denominator = data - retrans
    if (denominator <= 0) denominator = data
    print denominator
  }')
  speedtest_retrans_percent "$retrans" "$denominator"
}

speedtest_curl_partial_timeout_valid() {
  local exit_code="$1" elapsed="$2" timeout="$3" bytes="$4"
  [ "$exit_code" -eq 28 ] || return 1
  [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ] || return 1
  awk -v elapsed="$elapsed" -v timeout="$timeout" 'BEGIN {
    if (elapsed !~ /^[0-9]+([.][0-9]+)?$/ ||
        timeout !~ /^[0-9]+([.][0-9]+)?$/) {
      exit 1
    }
    exit !((elapsed + 0) >= (timeout + 0) - 0.1)
  }'
}

speedtest_curl_average_rate() {
  local bytes="$1" elapsed="$2"
  awk -v bytes="$bytes" -v elapsed="$elapsed" 'BEGIN {
    if (bytes !~ /^[0-9]+$/ || elapsed !~ /^[0-9]+([.][0-9]+)?$/ ||
        bytes <= 0 || elapsed <= 0) {
      print 0
      exit
    }
    printf "%.0f", bytes / elapsed
  }'
}

speedtest_result_valid() {
  local value="$1"
  [ "$value" != "failed" ] && [ -n "$value" ]
}

speedtest_parse_rate_mbps() {
  awk '
    tolower($0) ~ /average/ && tolower($0) ~ /rate:/ {
      line = $0
      sub(/^.*[Rr][Aa][Tt][Ee]:[[:space:]]*/, "", line)
      compact = line
      gsub(/[[:space:]]+/, "", compact)
      if (match(compact, /[0-9]+([.][0-9]+)?[GgMmKk]?[Bb]\/[Ss]/)) {
        token = substr(compact, RSTART, RLENGTH)
        value = token
        unit = token
        gsub(/[^0-9.]/, "", value)
        gsub(/[0-9.[:space:]]/, "", unit)
      } else {
        value = $(NF)
        unit = $(NF)
        gsub(/[^0-9.]/, "", value)
      }
      unit = toupper(unit)
      if (unit ~ /GB\/S/) value = value * 8000
      else if (unit ~ /MB\/S/) value = value * 8
      else if (unit ~ /KB\/S/) value = value * 8 / 1000
      else if (unit ~ /B\/S/) value = value * 8 / 1000000
      else next
      printf "%.1f", value
      found = 1
    }
    END { if (!found) printf "failed" }
  '
}

speedtest_net_bytes() {
  local probe_type="$1" stat="rx_bytes"
  [ "$probe_type" = "upload" ] && stat="tx_bytes"
  cat "/sys/class/net/$SPEEDTEST_IFACE/statistics/$stat" 2>/dev/null || printf -- '-'
}

# 测速消耗流量：主接口 rx+tx 总字节（无接口时回退汇总 /proc/net/dev）
speedtest_traffic_bytes() {
  local iface="${SPEEDTEST_IFACE:-}" rx tx
  if [ -z "$iface" ]; then
    iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  fi
  if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
    rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
    tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
    echo $((rx + tx))
  else
    awk -F'[: ]+' 'NR>2 {rx+=$2; tx+=$10} END {print rx+tx}' /proc/net/dev 2>/dev/null || echo 0
  fi
}

# 字节数格式化为可读文本（B/KB/MB/GB）
speedtest_traffic_text() {
  local bytes="${1:-0}"
  [ "$bytes" -ge 1073741824 ] 2>/dev/null && awk "BEGIN{printf \"%.2f GB\", $bytes/1073741824}" && return
  [ "$bytes" -ge 1048576 ] 2>/dev/null && awk "BEGIN{printf \"%.2f MB\", $bytes/1048576}" && return
  [ "$bytes" -ge 1024 ] 2>/dev/null && awk "BEGIN{printf \"%.2f KB\", $bytes/1024}" && return
  printf '%s B' "$bytes"
}

speedtest_counter_stop_current() {
  local tool="${SPEEDTEST_COUNTER_TOOL:-iptables}"
  if [ -n "${SPEEDTEST_COUNTER_CHAIN:-}" ] && [ -n "${SPEEDTEST_COUNTER_HOOK:-}" ]; then
    $USE_SUDO "$tool" -D "$SPEEDTEST_COUNTER_HOOK" -j "$SPEEDTEST_COUNTER_CHAIN" >/dev/null 2>&1 || true
    $USE_SUDO "$tool" -F "$SPEEDTEST_COUNTER_CHAIN" >/dev/null 2>&1 || true
    $USE_SUDO "$tool" -X "$SPEEDTEST_COUNTER_CHAIN" >/dev/null 2>&1 || true
  fi
  SPEEDTEST_COUNTER_CHAIN=""
  SPEEDTEST_COUNTER_HOOK=""
  SPEEDTEST_COUNTER_TOOL=""
}

speedtest_tcp_info_ss_snapshot() {
  local server_ip="$1" family_flag="${2:--4}" ss_output
  command -v ss >/dev/null 2>&1 || return 1
  ss_output=$(ss -tinp -n "$family_flag" state established 2>/dev/null || true)
  [ -n "$ss_output" ] || return 1
  printf '%s\n' "$ss_output" | awk -v target="$server_ip" '
    BEGIN { target_is_v6 = (index(target, ":") > 0) }
    function field_value(line, name, i, token, fields, count) {
      count = split(line, fields, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (fields[i] ~ ("^" name ":[0-9]+$")) {
          token = fields[i]
          sub("^" name ":", "", token)
          return token + 0
        }
      }
      return 0
    }
    function retrans_value(line, i, token, fields, count) {
      count = split(line, fields, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (fields[i] ~ /^retrans:[0-9]+\/[0-9]+$/) {
          token = fields[i]
          sub(/^retrans:[0-9]+\//, "", token)
          return token + 0
        }
      }
      # ss may omit retrans:0/0 when this connection has not retransmitted.
      return 0
    }
    $1 == "ESTAB" {
      if (target_is_v6) {
        waiting = (index($0, "[" target "]:443") > 0)
      } else {
        waiting = (index($0, target ":443") > 0)
      }
      next
    }
    # `ss ... state established` omits the state column on some iproute2
    # versions, leaving Recv-Q/Send-Q as fields 1/2. Handle that form too.
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (target_is_v6) {
        waiting = (index($0, "[" target "]:443") > 0)
      } else {
        waiting = (index($0, target ":443") > 0)
      }
      next
    }
    waiting && ($0 ~ /(^|[[:space:]])data_segs_out:[0-9]+([[:space:]]|$)/ ||
                $0 ~ /(^|[[:space:]])segs_out:[0-9]+([[:space:]]|$)/) {
      printf "%d|%d|%d|%d\n", retrans_value($0), \
        field_value($0, "data_segs_out"), \
        field_value($0, "segs_out"), \
        field_value($0, "bytes_retrans")
      exit
    }
  '
}

speedtest_tcp_info_preload_path() {
  local preload="${SPEEDTEST_TCP_INFO_PRELOAD:-}"
  SPEEDTEST_TCP_INFO_FAILURE_REASON=""
  if [ "${SPEEDTEST_TCP_INFO_ENABLED:-1}" != "1" ]; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="disabled"
    return 1
  fi
  if [ -z "$preload" ]; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="preload_path_empty"
    return 1
  fi
  if [ ! -r "$preload" ]; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="preload_missing:$preload"
    return 1
  fi
  printf '%s\n' "$preload"
}

speedtest_tcp_info_monitor_loop() {
  local server_ip="$1" output_file="$2" family_flag="${3:--4}" snapshot temp_file
  trap - EXIT INT TERM
  temp_file="${output_file}.tmp"
  set +e
  while :; do
    snapshot=$(speedtest_tcp_info_ss_snapshot "$server_ip" "$family_flag" 2>/dev/null || true)
    if [ -n "$snapshot" ]; then
      printf '%s\n' "$snapshot" > "$temp_file" && mv -f "$temp_file" "$output_file"
    fi
    sleep 0.05
  done
}

speedtest_tcp_info_monitor_start() {
  local server_ip="$1" output_file="$2" family_flag="${3:--4}" preload force_ss="${4:-0}"
  SPEEDTEST_TCP_INFO_MONITOR_PID=""
  SPEEDTEST_TCP_INFO_ACTIVE_MODE="none"
  SPEEDTEST_TCP_INFO_ACTIVE_PRELOAD=""
  SPEEDTEST_TCP_INFO_FAILURE_REASON=""
  if [ "${SPEEDTEST_TCP_INFO_ENABLED:-1}" != "1" ]; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="disabled"
    return 1
  fi
  rm -f "$output_file" "${output_file}.tmp"

  if [ "$force_ss" != "1" ]; then
    preload=$(speedtest_tcp_info_preload_path 2>/dev/null || true)
    if [ -n "$preload" ]; then
      SPEEDTEST_TCP_INFO_ACTIVE_MODE="getsockopt"
      SPEEDTEST_TCP_INFO_ACTIVE_PRELOAD="$preload"
      return 0
    fi
  fi

  if ! command -v ss >/dev/null 2>&1; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="ss_unavailable"
    return 1
  fi
  SPEEDTEST_TCP_INFO_ACTIVE_MODE="ss"
  speedtest_tcp_info_monitor_loop "$server_ip" "$output_file" "$family_flag" &
  SPEEDTEST_TCP_INFO_MONITOR_PID=$!
  return 0
}

speedtest_tcp_info_monitor_stop() {
  local pid="${SPEEDTEST_TCP_INFO_MONITOR_PID:-}"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  SPEEDTEST_TCP_INFO_MONITOR_PID=""
}

speedtest_retrans_trace_program() {
  local script_path="$1"
  [ -r "$script_path" ] || return 1
  cat "$script_path"
}

speedtest_retrans_trace_launch() {
  local output_file="$1" program="$2" use_btf="$3"
  rm -f "$SPEEDTEST_RETRANS_TRACE_FILE" "$SPEEDTEST_RETRANS_TRACE_ERR"
  if [ "$use_btf" -eq 1 ] && [ -r "$SPEEDTEST_BPFTRACE_BTF" ]; then
    BPFTRACE_BTF="$SPEEDTEST_BPFTRACE_BTF" bpftrace -q -e "$program" \
      > "$SPEEDTEST_RETRANS_TRACE_FILE" 2> "$SPEEDTEST_RETRANS_TRACE_ERR" &
  else
    bpftrace -q -e "$program" \
      > "$SPEEDTEST_RETRANS_TRACE_FILE" 2> "$SPEEDTEST_RETRANS_TRACE_ERR" &
  fi
  SPEEDTEST_RETRANS_TRACE_PID=$!
  # Allow bpftrace to load the program before curl starts.  A failed attach
  # exits immediately and is treated as unavailable below.
  sleep 0.1
  if ! kill -0 "$SPEEDTEST_RETRANS_TRACE_PID" 2>/dev/null; then
    wait "$SPEEDTEST_RETRANS_TRACE_PID" 2>/dev/null || true
    SPEEDTEST_RETRANS_TRACE_PID=""
    return 1
  fi
  if [ -s "$SPEEDTEST_RETRANS_TRACE_ERR" ]; then
    kill -KILL "$SPEEDTEST_RETRANS_TRACE_PID" 2>/dev/null || true
    wait "$SPEEDTEST_RETRANS_TRACE_PID" 2>/dev/null || true
    SPEEDTEST_RETRANS_TRACE_PID=""
    return 1
  fi
  SPEEDTEST_RETRANS_TRACE_READY=1
  return 0
}

speedtest_retrans_trace_start() {
  local output_file="$1" program
  SPEEDTEST_RETRANS_TRACE_PID=""
  SPEEDTEST_RETRANS_TRACE_FILE="${output_file}.retrans-trace"
  SPEEDTEST_RETRANS_TRACE_ERR="${SPEEDTEST_RETRANS_TRACE_FILE}.err"
  SPEEDTEST_RETRANS_TRACE_READY=0
  SPEEDTEST_RETRANS_TRACE_KEY=""
  [ "${SPEEDTEST_RETRANS_TRACE_ENABLED:-1}" = "1" ] || return 1
  [ "${SPEEDTEST_RETRANS_TRACE_DISABLED:-0}" -eq 0 ] || return 1
  command -v bpftrace >/dev/null 2>&1 || return 1
  program=$(speedtest_retrans_trace_program "$SPEEDTEST_RETRANS_TRACE_SCRIPT" 2>/dev/null || true)
  if [ -n "$program" ] && speedtest_retrans_trace_launch "$output_file" "$program" 1; then
    SPEEDTEST_RETRANS_TRACE_KEY="seq"
    return 0
  fi
  program=$(speedtest_retrans_trace_program "$SPEEDTEST_RETRANS_TRACE_FALLBACK_SCRIPT" 2>/dev/null || true)
  if [ -n "$program" ] && speedtest_retrans_trace_launch "$output_file" "$program" 0; then
    SPEEDTEST_RETRANS_TRACE_KEY="skb"
    return 0
  fi
  SPEEDTEST_RETRANS_TRACE_READY=0
  SPEEDTEST_RETRANS_TRACE_DISABLED=1
  return 1
}

speedtest_retrans_trace_stop() {
  local pid="${SPEEDTEST_RETRANS_TRACE_PID:-}" status=0 attempt
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    kill -INT "$pid" 2>/dev/null || true
    for attempt in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for attempt in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
      done
    fi
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || status=$?
    [ "$status" -eq 0 ] || [ "$status" -eq 130 ] || {
      SPEEDTEST_RETRANS_TRACE_READY=0
    }
  fi
  SPEEDTEST_RETRANS_TRACE_PID=""
}

speedtest_retrans_trace_count_ipv4() {
  local trace_file="$1" server_ip="$2" a b c d key="${SPEEDTEST_RETRANS_TRACE_KEY:-skb}"
  [ -s "$trace_file" ] || {
    printf '0\n'
    return 0
  }
  IFS=. read -r a b c d <<< "$server_ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ &&
     "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || {
    printf -- '-\n'
    return 0
  }
  awk -F'|' -v a="$a" -v b="$b" -v c="$c" -v d="$d" -v key="$key" '
    $1 == 2 && $2 == a && $3 == b && $4 == c && $5 == d {
      if (key == "seq" && $18 ~ /^0x[0-9a-fA-F]+$/ &&
          $19 ~ /^[0-9]+$/ && $20 ~ /^[0-9]+$/ &&
          $18 != "0x0" && $19 != $20) {
        unique[$18 ":" $19 ":" $20] = 1
      } else if (key != "seq" && $18 ~ /^0x[0-9a-fA-F]+$/ &&
                 $19 ~ /^0x[0-9a-fA-F]+$/ &&
                 $18 != "0x0" && $19 != "0x0") {
        unique[$18 ":" $19] = 1
      }
    }
    END {
      count = 0
      for (key in unique) count++
      print count + 0
    }
  ' "$trace_file"
}

speedtest_counter_start() {
  local probe_type="$1" server_ip="$2" hook chain tool="iptables"
  speedtest_counter_stop_current
  [ -n "$server_ip" ] || return 1
  [[ "$server_ip" == *:* ]] && tool="ip6tables"
  command -v "$tool" &>/dev/null || return 1

  if [ "$probe_type" = "download" ]; then
    hook="INPUT"
  else
    hook="OUTPUT"
  fi
  chain="TCPQ_TOS_$$_$RANDOM"

  $USE_SUDO "$tool" -N "$chain" >/dev/null 2>&1 || return 1
  $USE_SUDO "$tool" -I "$hook" 1 -j "$chain" >/dev/null 2>&1 || {
    $USE_SUDO "$tool" -F "$chain" >/dev/null 2>&1 || true
    $USE_SUDO "$tool" -X "$chain" >/dev/null 2>&1 || true
    return 1
  }

  if [ "$probe_type" = "download" ]; then
    $USE_SUDO "$tool" -A "$chain" -p tcp -s "$server_ip" --sport 443 -j RETURN >/dev/null 2>&1 || {
      SPEEDTEST_COUNTER_CHAIN="$chain"
      SPEEDTEST_COUNTER_HOOK="$hook"
      SPEEDTEST_COUNTER_TOOL="$tool"
      speedtest_counter_stop_current
      return 1
    }
  else
    $USE_SUDO "$tool" -A "$chain" -p tcp -d "$server_ip" --dport 443 -j RETURN >/dev/null 2>&1 || {
      SPEEDTEST_COUNTER_CHAIN="$chain"
      SPEEDTEST_COUNTER_HOOK="$hook"
      SPEEDTEST_COUNTER_TOOL="$tool"
      speedtest_counter_stop_current
      return 1
    }
  fi

  SPEEDTEST_COUNTER_CHAIN="$chain"
  SPEEDTEST_COUNTER_HOOK="$hook"
  SPEEDTEST_COUNTER_TOOL="$tool"
  return 0
}

speedtest_counter_bytes() {
  local tool="${SPEEDTEST_COUNTER_TOOL:-iptables}"
  [ -n "${SPEEDTEST_COUNTER_CHAIN:-}" ] || {
    printf -- '-'
    return 0
  }
  $USE_SUDO "$tool" -L "$SPEEDTEST_COUNTER_CHAIN" -v -x -n 2>/dev/null | awk '
    NR > 2 && $3 == "RETURN" { print $2; found=1; exit }
    END { if (!found) print "-" }
  '
}

speedtest_counter_packets() {
  local tool="${SPEEDTEST_COUNTER_TOOL:-iptables}"
  [ -n "${SPEEDTEST_COUNTER_CHAIN:-}" ] || {
    printf -- '-'
    return 0
  }
  $USE_SUDO "$tool" -L "$SPEEDTEST_COUNTER_CHAIN" -v -x -n 2>/dev/null | awk '
    NR > 2 && $3 == "RETURN" { print $1; found=1; exit }
    END { if (!found) print "-" }
  '
}
speedtest_tos_bucket_host() {
  local region="$1" bucket
  case "$region" in
    cn-beijing) bucket="beijing" ;;
    cn-shanghai) bucket="shanghai" ;;
    cn-guangzhou) bucket="guangzhou" ;;
    *) return 1 ;;
  esac
  printf 'probe-bucket-%s.tos-%s.volces.com' "$bucket" "$region"
}

speedtest_tos_object_size_bytes() {
  local value="${SPEEDTEST_TOS_SIZE^^}" number unit multiplier
  if [[ "$value" =~ ^([0-9]+([.][0-9]+)?)[[:space:]]*([KMGT]?I?B?)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  case "$unit" in
    ""|B) multiplier=1 ;;
    K|KB|KI|KIB) multiplier=1024 ;;
    M|MB|MI|MIB) multiplier=1048576 ;;
    G|GB|GI|GIB) multiplier=1073741824 ;;
    T|TB|TI|TIB) multiplier=1099511627776 ;;
    *) return 1 ;;
  esac
  awk -v number="$number" -v multiplier="$multiplier" 'BEGIN {
    bytes = number * multiplier;
    if (bytes < 1) exit 1;
    printf "%.0f", bytes;
  }'
}

speedtest_tos_upload_key() {
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
  if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{16,}$ ]]; then
    uuid="$(date +%s%N)-$RANDOM"
  fi
  printf 'upload/%s' "$uuid"
}

speedtest_curl_seconds_ms() {
  awk -v value="$1" 'BEGIN {
    if (value !~ /^[0-9]+([.][0-9]+)?$/) print "-";
    else printf "%d", value * 1000 + 0.5;
  }'
}

speedtest_curl_delta_ms() {
  awk -v start="$1" -v end="$2" 'BEGIN {
    if (start !~ /^[0-9]+([.][0-9]+)?$/ || end !~ /^[0-9]+([.][0-9]+)?$/) {
      print "-";
      exit;
    }
    delta = (end - start) * 1000;
    if (delta < 0) delta = 0;
    printf "%d", delta + 0.5;
  }'
}

speedtest_curl_rate_mbps() {
  awk -v bytes_per_second="$1" 'BEGIN {
    if (bytes_per_second !~ /^[0-9]+([.][0-9]+)?$/ || bytes_per_second <= 0) {
      print "failed";
      exit;
    }
    printf "%.2f", bytes_per_second / 1000000;
  }'
}

speedtest_zero_stream() {
  local bytes="$1" full_blocks remainder
  full_blocks=$((bytes / 1048576))
  remainder=$((bytes % 1048576))
  [ "$full_blocks" -gt 0 ] && dd if=/dev/zero bs=1048576 count="$full_blocks" 2>/dev/null
  [ "$remainder" -gt 0 ] && dd if=/dev/zero bs=1 count="$remainder" 2>/dev/null
}

speedtest_tos_delete_object() {
  local host="$1" server_ip="$2" key="$3"
  [ -n "$host" ] && [ -n "$server_ip" ] && [ -n "$key" ] || return 0
  curl -4 --noproxy '*' --http1.1 -sS -o /dev/null \
    --connect-timeout 5 --max-time 10 \
    --resolve "$host:443:$server_ip" -X DELETE \
    "https://$host/$key" >/dev/null 2>&1 || true
}
speedtest_run_probe() {
  local probe_type="$1" output_file="$2" server_ip="$3"
  local before after nstat_retrans retrans start_bytes end_bytes start_packets end_packets packet_delta delta_bytes counter_enabled
  local host key size timeout meta raw_file exit_code result parsed transfer_bytes partial_timeout probe_pid
  local tcp_info_file tcp_info_available=0 tcp_info_retrans=0
  local tcp_info_data_segs_out=0 tcp_info_segs_out=0 tcp_info_bytes_retrans=0 tcp_info_ratio="-"
  local tcp_info_ratio_denominator=0
  local tcp_info_mode="none" tcp_info_reason="unknown" trace_unique_retrans=0 trace_ratio="-" trace_available=0 trace_valid=0
  local http_code bytes_download speed_download bytes_upload speed_upload
  local dns_time connect_time appconnect_time pretransfer_time starttransfer_time total_time remote_ip
  local dns_ms build_ms send_ms wait_ms total_ms rate_bytes_per_second rate_mb display_connect_ms display_tls_ms
  local reported_connect_ms reported_tls_ms
  local tcp_info_preload="" preload_value
  local -a curl_args

  host=$(speedtest_tos_bucket_host "$SPEEDTEST_TOS_REGION" 2>/dev/null || true)
  size=$(speedtest_tos_object_size_bytes 2>/dev/null || true)
  timeout="$SPEEDTEST_TOS_TIMEOUT"
  [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || timeout=15
  raw_file="${output_file}.curl"
  key=""

  if [ -z "$host" ] || ! [[ "$server_ip" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || [ -z "$size" ] || [ "$size" -le 0 ] || [ "$SPEEDTEST_TOS_NETWORK" != "public" ]; then
    printf 'Average %s rate: failed\n\nTime consuming details\n' "$probe_type" > "$output_file"
    printf 'Build connection cost: -1 ms\nTls handshake cost: -1 ms\n' >> "$output_file"
    : > "${output_file}.err"
    printf 'failed|0|-1|-1'
    return 0
  fi

  curl_args=(
    curl -4 --noproxy '*' --http1.1 -sS --fail
    --connect-timeout 5 --max-time "$timeout"
    --resolve "$host:443:$server_ip"
    -A 'TcpQuality fixed TOS probe'
    -w '%{http_code}|%{size_download}|%{speed_download}|%{size_upload}|%{speed_upload}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_pretransfer}|%{time_starttransfer}|%{time_total}|%{remote_ip}'
    -o /dev/null
  )
  if [ "$probe_type" = "upload" ]; then
    key=$(speedtest_tos_upload_key)
    curl_args+=(
      -X PUT -H "Content-Length: $size" --upload-file -
      "https://$host/$key"
    )
  else
    curl_args+=(
      --range "0-$((size - 1))"
      "https://$host/download/test"
    )
  fi

  counter_enabled=0
  if speedtest_counter_start "$probe_type" "$server_ip"; then
    counter_enabled=1
    start_bytes=$(speedtest_counter_bytes)
    start_packets=$(speedtest_counter_packets)
  else
    SPEEDTEST_RANK_ELIGIBLE=0
    SPEEDTEST_RANK_DISABLED_REASON="target_counter_unavailable"
    start_bytes=$(speedtest_net_bytes "$probe_type")
    start_packets="-"
  fi
  before=$(speedtest_retrans_count)
  tcp_info_file="${output_file}.tcpinfo"
  speedtest_tcp_info_monitor_start "$server_ip" "$tcp_info_file" "-4" || true
  tcp_info_mode="${SPEEDTEST_TCP_INFO_ACTIVE_MODE:-none}"
  tcp_info_preload="${SPEEDTEST_TCP_INFO_ACTIVE_PRELOAD:-}"
  if [ "$tcp_info_mode" = "getsockopt" ] && [ -n "$tcp_info_preload" ]; then
    preload_value="$tcp_info_preload"
    [ -n "${LD_PRELOAD:-}" ] && preload_value="$preload_value:$LD_PRELOAD"
    curl_args=(
      env
      "LD_PRELOAD=$preload_value"
      "TCPQUALITY_TCP_INFO_FILE=$tcp_info_file"
      "TCPQUALITY_TCP_INFO_TARGET=$server_ip"
      "${curl_args[@]}"
    )
  fi
  if speedtest_retrans_trace_start "$output_file"; then
    trace_available=1
  fi
  set +e
  if [ "$probe_type" = "upload" ]; then
    (
      set +e
      speedtest_zero_stream "$size" | "${curl_args[@]}" > "$raw_file" 2>"${output_file}.err"
      pipeline_status=("${PIPESTATUS[@]}")
      exit "${pipeline_status[1]:-1}"
    ) &
    probe_pid=$!
  else
    (
      set +e
      "${curl_args[@]}" > "$raw_file" 2>"${output_file}.err"
    ) &
    probe_pid=$!
  fi
  wait "$probe_pid"
  exit_code=$?
  set -e
  speedtest_tcp_info_monitor_stop
  speedtest_retrans_trace_stop
  if [ "$trace_available" -ne 1 ] || [ "${SPEEDTEST_RETRANS_TRACE_READY:-0}" -ne 1 ]; then
    trace_available=0
  fi
  if [ -s "$tcp_info_file" ]; then
    IFS='|' read -r tcp_info_retrans tcp_info_data_segs_out tcp_info_segs_out tcp_info_bytes_retrans < "$tcp_info_file" || true
    if [[ "$tcp_info_retrans" =~ ^[0-9]+$ ]] &&
       [[ "$tcp_info_data_segs_out" =~ ^[0-9]+$ ]] &&
       [[ "$tcp_info_segs_out" =~ ^[0-9]+$ ]] &&
       [[ "$tcp_info_bytes_retrans" =~ ^[0-9]+$ ]]; then
      tcp_info_available=1
      if [ "$tcp_info_data_segs_out" -gt 0 ]; then
        tcp_info_ratio_denominator="$tcp_info_data_segs_out"
      else
        tcp_info_ratio_denominator="$tcp_info_segs_out"
      fi
      tcp_info_ratio=$(awk -v retrans="$tcp_info_retrans" -v packets="$tcp_info_ratio_denominator" 'BEGIN {
        if (packets <= 0) print "-";
        else {
          ratio = retrans / packets * 100;
          if (ratio < 0) ratio = 0;
          if (ratio > 100) ratio = 100;
          printf "%.2f%%", ratio;
        }
      }')
    fi
  fi
  if [ "$tcp_info_available" -eq 1 ]; then
    tcp_info_reason="ok"
  elif [ "$tcp_info_mode" = "getsockopt" ]; then
    tcp_info_reason="getsockopt_no_valid_snapshot"
  elif [ "$tcp_info_mode" = "ss" ]; then
    tcp_info_reason="ss_no_valid_snapshot"
  else
    tcp_info_reason="${SPEEDTEST_TCP_INFO_FAILURE_REASON:-monitor_not_started}"
  fi
  if [ "$trace_available" -eq 1 ]; then
    trace_unique_retrans=$(speedtest_retrans_trace_count_ipv4 "$SPEEDTEST_RETRANS_TRACE_FILE" "$server_ip" 2>/dev/null || true)
    if [[ "$trace_unique_retrans" =~ ^[0-9]+$ ]] && [ "$tcp_info_available" -eq 1 ]; then
      if [ "$trace_unique_retrans" -gt 0 ] && [ "$trace_unique_retrans" -le "$tcp_info_retrans" ]; then
        trace_ratio_denominator=$(awk -v packets="$tcp_info_ratio_denominator" -v retrans="$tcp_info_retrans" 'BEGIN {
          if (packets !~ /^[0-9]+$/ || retrans !~ /^[0-9]+$/ || packets <= 0) print 0;
          else {
            value = packets - retrans;
            if (value <= 0) value = packets;
            print value;
          }
        }')
        trace_ratio=$(speedtest_unique_retrans_percent "$trace_unique_retrans" "$tcp_info_ratio_denominator" "$tcp_info_retrans")
        if [ "$trace_ratio" != "-" ]; then
          trace_valid=1
        fi
      else
        # A successfully attached trace can still be unusable when the
        # kernel/BTF layout makes seq/end_seq unreadable. Never let that
        # synthetic zero count override the socket-level TCP_INFO result.
        trace_ratio_denominator="-"
        trace_ratio="-"
      fi
    fi
  fi
  if [ "$counter_enabled" -eq 1 ]; then
    end_bytes=$(speedtest_counter_bytes)
    end_packets=$(speedtest_counter_packets)
    if [ "$start_bytes" = "-" ] || [ "$end_bytes" = "-" ]; then
      SPEEDTEST_RANK_ELIGIBLE=0
      SPEEDTEST_RANK_DISABLED_REASON="target_counter_read_failed"
    fi
  else
    end_bytes=$(speedtest_net_bytes "$probe_type")
    end_packets="-"
  fi
  speedtest_counter_stop_current
  after=$(speedtest_retrans_count)
  nstat_retrans=$((after - before))
  [ "$nstat_retrans" -ge 0 ] || nstat_retrans=0
  retrans="$nstat_retrans"
  if [ "$tcp_info_available" -eq 1 ]; then
    if [ "$trace_available" -eq 1 ] && [ "$trace_valid" -eq 1 ] && [ "$trace_ratio" != "-" ]; then
      retrans="$trace_ratio"
    else
      retrans="$tcp_info_ratio"
    fi
  else
    # nstat is host-global and cannot be attributed to this connection. Never
    # turn it into a percentage when the connection-level sample is missing.
    retrans="-"
  fi

  meta=$(cat "$raw_file" 2>/dev/null || true)
  IFS='|' read -r http_code bytes_download speed_download bytes_upload speed_upload \
    dns_time connect_time appconnect_time pretransfer_time starttransfer_time total_time remote_ip <<< "$meta"
  dns_ms=$(speedtest_curl_seconds_ms "$dns_time")
  build_ms=$(speedtest_curl_delta_ms "$dns_time" "$connect_time")
  tls_ms=$(speedtest_curl_delta_ms "$connect_time" "$appconnect_time")
  total_ms=$(speedtest_curl_seconds_ms "$total_time")
  if [ "$probe_type" = "upload" ]; then
    wait_ms=0
    send_ms=$(speedtest_curl_delta_ms "$pretransfer_time" "$total_time")
    rate_bytes_per_second="${speed_upload:-0}"
    transfer_bytes="${bytes_upload:-0}"
  else
    send_ms=0
    wait_ms=$(speedtest_curl_delta_ms "$pretransfer_time" "$starttransfer_time")
    rate_bytes_per_second="${speed_download:-0}"
    transfer_bytes="${bytes_download:-0}"
  fi
  partial_timeout=0
  if speedtest_curl_partial_timeout_valid "$exit_code" "$total_time" "$timeout" "$transfer_bytes"; then
    partial_timeout=1
    # 达到 max-time 但未完成时，明确使用完整运行时长计算平均速率。
    rate_bytes_per_second=$(speedtest_curl_average_rate "$transfer_bytes" "$total_time")
  fi
  rate_mb=$(speedtest_curl_rate_mbps "$rate_bytes_per_second")
  {
    if [ "$rate_mb" = "failed" ]; then
      printf 'Average %s rate: failed\n' "$probe_type"
    else
      printf 'Average %s rate: %sMB/s\n' "$probe_type" "$rate_mb"
    fi
    printf '\nTime consuming details\n'
    printf 'Resolve dns cost: %s ms\n' "$dns_ms"
    printf 'Build connection cost: %s ms\n' "$build_ms"
    printf 'Tls handshake cost: %s ms\n' "$tls_ms"
    printf 'Send request cost: %s ms\n' "$send_ms"
    printf 'Wait response cost: %s ms\n' "$wait_ms"
    printf 'Total cost: %s ms\n' "$total_ms"
    printf 'Fixed target: %s (%s)\n' "$server_ip" "${remote_ip:-unknown}"
  } > "$output_file"

  parsed=$(speedtest_parse_rate_mbps < "$output_file" || true)
  result="$parsed"
  # 达到 max-time 且已传输数据属于有效的时间窗口样本；连接阶段超时、
  # 连接重置和其他非零退出码仍然判定为失败。
  if [ "$parsed" = "failed" ]; then
    result="failed"
  elif [ "$exit_code" -eq 0 ]; then
    ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && result="failed"
  elif [ "$partial_timeout" -ne 1 ]; then
    result="failed"
  fi

  if [ "$result" = "failed" ]; then
    # 失败方向没有有效的目标重传/延迟数据；nstat 是主机全局计数，不能作为该方向的结果。
    retrans="failed"
    reported_connect_ms="failed"
    reported_tls_ms="failed"
    sed -i \
      -e "s/^Average ${probe_type} rate: .*/Average ${probe_type} rate: failed/" \
      -e 's/^Build connection cost: .*/Build connection cost: failed/' \
      -e 's/^Tls handshake cost: .*/Tls handshake cost: failed/' \
      "$output_file"
  else
    reported_connect_ms="$build_ms"
    reported_tls_ms="$tls_ms"
  fi

  if [ "$counter_enabled" -eq 1 ]; then
    if [ "$start_bytes" = "-" ] || [ "$end_bytes" = "-" ]; then
      SPEEDTEST_RANK_ELIGIBLE=0
      SPEEDTEST_RANK_DISABLED_REASON="target_counter_read_failed"
    else
      delta_bytes=$((end_bytes - start_bytes))
      if [ "$delta_bytes" -le 0 ]; then
        SPEEDTEST_RANK_ELIGIBLE=0
        SPEEDTEST_RANK_DISABLED_REASON="target_counter_zero"
      fi
    fi
  fi

  if [ "$probe_type" = "upload" ] && [ -n "$key" ]; then
    speedtest_tos_delete_object "$host" "$server_ip" "$key"
  fi
  rm -f "$raw_file"
  rm -f "$tcp_info_file" "${tcp_info_file}.tmp" \
    "$SPEEDTEST_RETRANS_TRACE_FILE" "$SPEEDTEST_RETRANS_TRACE_ERR"
  display_connect_ms="$reported_connect_ms"
  display_tls_ms="$reported_tls_ms"
  # 连接耗时按旧兼容口径存 2 倍值，TLS 耗时保留原始 curl 值；
  # TUI 展示时连接耗时除以 2 显示为 ms，使 TLS 延迟显示为握手耗时的一半。
  [[ "$display_connect_ms" =~ ^[0-9]+$ ]] && display_connect_ms=$((display_connect_ms * 2))
  printf '%s|%s|%s|%s' "${result:-failed}" "$retrans" "$display_connect_ms" "$display_tls_ms"
  return 0
}

speedtest_format_mbps() {
  local bandwidth="$1"
  printf '%s' "$bandwidth"
}

speedtest_display_width() {
  local text="$1" char width=0
  while [ -n "$text" ]; do
    char=${text:0:1}
    text=${text:1}
    case "$char" in
      [[:ascii:]]) width=$((width + 1)) ;;
      *) width=$((width + 2)) ;;
    esac
  done
  printf '%s' "$width"
}

speedtest_pad_left() {
  local width="$1" text="$2" actual padding
  actual=$(speedtest_display_width "$text")
  padding=$((width - actual))
  [ "$padding" -gt 0 ] && printf '%*s' "$padding" ''
  printf '%s' "$text"
}

speedtest_print_group_header() {
  local column_label="${2:-IPv4}" retrans_label="${3:-回程重传}"

  # The terminal formatter counts UTF-8 bytes, so align CJK headings by display width.
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 "$column_label"; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 "$retrans_label"; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '回程速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '去程速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '回程延迟'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '去程延迟'; printf '%b' "$NC"
  printf '\n'
}

speedtest_metric_failed() {
  case "${1,,}" in
    ""|-|failed|fail)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

speedtest_latency_text() {
  local value="$1"
  case "${value,,}" in
    failed|fail)
      printf 'failed'
      return
      ;;
  esac
  if [[ "$value" =~ ^-?[0-9]+$ ]] && [ "$value" -ge 0 ]; then
    awk -v value="$value" 'BEGIN { printf "%dms", int(value / 2 + 0.5) }'
  else
    printf '-'
  fi
}

speedtest_latency_color() {
  local value="$1" latency
  if ! [[ "$value" =~ ^-?[0-9]+$ ]] || [ "$value" -lt 0 ]; then
    printf '%s' "$RED"
    return
  fi
  latency=$(awk -v value="$value" 'BEGIN { printf "%d", int(value / 2 + 0.5) }')
  if [ "$latency" -gt 240 ]; then
    printf '%s' "$RED"
  elif [ "$latency" -gt 150 ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

speedtest_show_progress() {
  local done="$1" total="$2"
  if [ "${SPEEDTEST_BACKGROUND:-0}" -eq 1 ]; then
    printf '%s/%s\n' "$done" "$total" > "$SPEEDTEST_PROGRESS_FILE"
    return
  fi
  echo -ne "\r  ${CYAN}测速进度${NC} "
  bar "$done" "$total"
  echo -ne "   "
}

speedtest_speed_color() {
  local value="$1" label="$2" level_name
  if [ "$value" = "failed" ]; then
    printf '%s' "$RED"
  elif [ "$label" = "不限" ] || [[ "$label" != *Mbps ]]; then
    level_name=$(awk -v value="$value" 'BEGIN {
      if (value <= 20) print "bad"
      else if (value <= 150) print "warn"
      else print "ok"
    }')
    case "$level_name" in
      ok) printf '%s' "$GREEN" ;;
      warn) printf '%s' "$YELLOW" ;;
      *) printf '%s' "$RED" ;;
    esac
  else
    level_name=$(awk -v value="$value" -v target="${label%Mbps}" 'BEGIN {
      if (value >= target * 0.8) print "ok"
      else if (value >= target * 0.6) print "warn"
      else print "bad"
    }')
    case "$level_name" in
      ok) printf '%s' "$GREEN" ;;
      warn) printf '%s' "$YELLOW" ;;
      *) printf '%s' "$RED" ;;
    esac
  fi
}

speedtest_retrans_color() {
  local value="$1"
  if [[ "$value" == *% ]]; then
    value="${value%\%}"
    if ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf '%s' "$RED"
    elif awk -v value="$value" 'BEGIN { exit !(value >= 20) }'; then
      printf '%s' "$RED"
    elif awk -v value="$value" 'BEGIN { exit !(value > 10) }'; then
      printf '%s' "$YELLOW"
    else
      printf '%s' "$GREEN"
    fi
    return
  fi
  if [ "$value" = "failed" ] || [ "$value" -gt 999 ] 2>/dev/null; then
    printf '%s' "$RED"
  elif [ "$value" -ge 100 ] 2>/dev/null; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

speedtest_load_background_state() {
  local type value a b c d e f g
  SPEEDTEST_ROWS=()
  [ -s "$SPEEDTEST_STATE_FILE" ] || {
    speedtest_set_failed_rows
    return 1
  }

  while IFS=$'\t' read -r type value; do
    case "$type" in
      META)
        IFS='|' read -r a b c d e f <<<"$value"
        SPEEDTEST_TELECOM_ID="$a"
        SPEEDTEST_TELECOM_CITY="$b"
        SPEEDTEST_UNICOM_ID="$c"
        SPEEDTEST_UNICOM_CITY="$d"
        SPEEDTEST_MOBILE_ID="$e"
        SPEEDTEST_MOBILE_CITY="$f"
        ;;
      RANK)
        IFS='|' read -r a b c d e f g <<<"$value"
        RANK_SESSION_ID="$a"
        RANK_SESSION_TOKEN="$b"
        RANK_SESSION_STARTED_AT="$c"
        RANK_SESSION_EXPIRES_AT="$d"
        RANK_SESSION_IP4="$e"
        SPEEDTEST_RANK_ELIGIBLE="${f:-0}"
        SPEEDTEST_RANK_DISABLED_REASON="$g"
        ;;
      ROW)
        SPEEDTEST_ROWS+=("$value")
        ;;
    esac
  done < "$SPEEDTEST_STATE_FILE"

  [ "${#SPEEDTEST_ROWS[@]}" -gt 0 ] || speedtest_set_failed_rows
}

# ---------- 用户选择工具（新增） ----------
speedtest_carrier_list() {
  if [ -n "$SELECTED_ISPS" ]; then
    printf '%s\n' $SELECTED_ISPS
  else
    printf '%s\n' 电信 联通 移动
  fi
}

set_selected_isps() {
  local list="$1" item cn
  list=${list//，/,}
  list=${list// /,}
  if [ "$list" = "all" ]; then
    SELECTED_ISPS=""
    return 0
  fi
  SELECTED_ISPS=""
  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    case "$item" in
      ct) cn="电信" ;;
      cu) cn="联通" ;;
      cm) cn="移动" ;;
      *) return 1 ;;
    esac
    case " $SELECTED_ISPS " in
      *" $cn "*) ;;
      *) SELECTED_ISPS="$SELECTED_ISPS $cn" ;;
    esac
  done
  [ -n "$SELECTED_ISPS" ]
}

set_selected_cities() {
  local list="$1" item cn
  list=${list//，/,}
  list=${list// /,}
  if [ "$list" = "all" ]; then
    SELECTED_CITIES=""
    return 0
  fi
  SELECTED_CITIES=""
  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    case "$item" in
      bj) cn="北京" ;;
      sh) cn="上海" ;;
      gd) cn="广东" ;;
      *) return 1 ;;
    esac
    case " $SELECTED_CITIES " in
      *" $cn "*) ;;
      *) SELECTED_CITIES="$SELECTED_CITIES $cn" ;;
    esac
  done
  [ -n "$SELECTED_CITIES" ]
}

speedtest_group_specs() {
  local city region found=0
  if [ -n "$SELECTED_CITIES" ]; then
    for city in $SELECTED_CITIES; do
      case "$city" in
        北京) region="cn-beijing" ;;
        上海) region="cn-shanghai" ;;
        广东) region="cn-guangzhou" ;;
        *) continue ;;
      esac
      printf '%s\n' "$city|$region|unlimited"
      found=1
    done
    [ "$found" -eq 1 ] && return 0
  fi
  printf '%s\n' \
    "北京|cn-beijing|unlimited" \
    "上海|cn-shanghai|unlimited" \
    "广东|cn-guangzhou|unlimited"
}

# ---------- 结果展示辅助（"-"=未测方向，显示为 - ） ----------
speedtest_speed_text() {
  local value="$1"
  if [ "$value" = "-" ]; then
    printf '-'
  elif speedtest_metric_failed "$value"; then
    printf 'failed'
  else
    printf '%sMbps' "$value"
  fi
}

speedtest_direction_latency_text() {
  local latency="$1" speed="$2"
  if [ "$speed" = "-" ]; then
    printf '-'
  elif speedtest_metric_failed "$speed"; then
    printf 'failed'
  else
    speedtest_latency_text "$latency"
  fi
}

# ---------- 单线程测速主流程（改造：运营商/城市筛选 + 方向控制） ----------
# 结果行格式（每运营商一列，用 ; 分隔）：
#   label;upload|upload_retrans|download|download_retrans|server_id|city|upload_connect|upload_tls|download_connect|download_tls
# 术语约定（与原版 TcpQuality 一致）：回程=上传(upload)，去程=下载(download)
collect_speedtest_results() {
  local group group_region rate label carrier workdir result_file candidate server_id city candidate_region
  local upload upload_retrans upload_connect upload_tls download download_retrans download_connect download_tls done total offset
  local -a carriers=()
  local carrier_values=() row
  while IFS= read -r carrier; do carriers+=("$carrier"); done < <(speedtest_carrier_list)
  offset=${SPEEDTEST_PROGRESS_OFFSET:-0}
  done="$offset"
  total=${SPEEDTEST_PROGRESS_TOTAL:-0}
  [ "$total" -gt 0 ] 2>/dev/null || total=$((offset + $(speedtest_group_count) * ${#carriers[@]}))

  if [ "${SPEEDTEST_APPEND_STATE:-0}" -eq 1 ]; then
    speedtest_load_background_state || true
  else
    SPEEDTEST_ROWS=()
  fi

  [ "$(uname)" = "Linux" ] || {
    echo -e "${RED}[X] 单线程测速目前仅支持 Linux${NC}"
    exit 1
  }
  require_raw_socket_privilege
  check_curl
  speedtest_dependencies_ready || install_speedtest_dependencies || {
    echo -e "${RED}[X] 测速依赖安装失败${NC}"
    exit 1
  }
  load_remote_speedtest_nodes || true
  ensure_public_ips_for_rank
  install_speedtest_counter_dependency || true
  if ! command -v iptables &>/dev/null; then
    SPEEDTEST_RANK_ELIGIBLE=0
    SPEEDTEST_RANK_DISABLED_REASON="iptables_unavailable"
  fi
  if ! request_rank_session; then
    [ -n "$SPEEDTEST_RANK_DISABLED_REASON" ] || SPEEDTEST_RANK_DISABLED_REASON="rank_session_request_failed"
  fi
  SPEEDTEST_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$SPEEDTEST_IFACE" ] || {
    echo -e "${RED}[X] 无法识别默认网络接口${NC}"
    exit 1
  }
  if [ "${SPEEDTEST_BACKGROUND:-0}" -eq 1 ]; then
    trap 'speedtest_cleanup' EXIT
    trap 'speedtest_cleanup; exit 130' INT TERM
  fi

  echo -e "${BOLD}${CYAN}单线程测速${NC}"
  echo
  speedtest_show_progress 0 "$total"

  while IFS='|' read -r label group_region rate; do
    [ -n "$label" ] || continue
    carrier_values=()

    for carrier in "${carriers[@]}"; do
      workdir=$(mktemp -d "$RESULT_DIR/speedtest.XXXXXX")
      result_file="$workdir/result"
      candidate=$(speedtest_pick_candidate "$carrier" "$group_region")
      server_id=${candidate%%|*}
      city=${candidate#*|}
      city=${city%%|*}
      candidate_region=${candidate##*|}
      [ -n "$candidate_region" ] && [ "$candidate_region" != "$candidate" ] || candidate_region="$group_region"
      [ -n "$city" ] || city=$(speedtest_region_title "$group_region")
      SPEEDTEST_TOS_REGION="$candidate_region"
      speedtest_set_selected "$carrier" "$server_id" "$city"

      # 术语（与原版 TcpQuality 一致）：去程 = 下载(download)，回程 = 上传(upload)
      # 模式：ul=仅去程(下载)  dl=仅回程(上传)  both=下载+上传
      if [ "$SPEEDTEST_DIRECTION" = "ul" ] || [ "$SPEEDTEST_DIRECTION" = "both" ]; then
        IFS='|' read -r download download_retrans download_connect download_tls <<<"$(speedtest_run_probe download "$result_file.download" "$server_id")"
      else
        download="-"; download_retrans="-"; download_connect="-"; download_tls="-"
      fi
      if [ "$SPEEDTEST_DIRECTION" = "dl" ] || [ "$SPEEDTEST_DIRECTION" = "both" ]; then
        IFS='|' read -r upload upload_retrans upload_connect upload_tls <<<"$(speedtest_run_probe upload "$result_file.upload" "$server_id")"
      else
        upload="-"; upload_retrans="-"; upload_connect="-"; upload_tls="-"
      fi

      if speedtest_result_valid "$upload" || speedtest_result_valid "$download"; then
        carrier_values+=("$(speedtest_format_mbps "$upload")|$upload_retrans|$(speedtest_format_mbps "$download")|$download_retrans|$server_id|$city|$upload_connect|$upload_tls|$download_connect|$download_tls")
      else
        carrier_values+=("failed|failed|failed|failed|$server_id|$city|$upload_connect|$upload_tls|$download_connect|$download_tls")
      fi
      rm -rf "$workdir"
      done=$((done + 1))
      speedtest_show_progress "$done" "$total"
    done

    row="$label"
    for cv in "${carrier_values[@]}"; do row+=";$cv"; done
    SPEEDTEST_ROWS+=("$row")
  done < <(speedtest_group_specs)

  speedtest_cleanup
  if [ "$SPEEDTEST_RANK_ELIGIBLE" -ne 1 ]; then
    RANK_SESSION_ID=""
    RANK_SESSION_TOKEN=""
    RANK_SESSION_STARTED_AT=""
    RANK_SESSION_EXPIRES_AT=""
    RANK_SESSION_IP4=""
  fi
  if [ -n "${SPEEDTEST_STATE_FILE:-}" ]; then
    {
      printf 'META\t%s|%s|%s|%s|%s|%s\n' \
        "$SPEEDTEST_TELECOM_ID" "$SPEEDTEST_TELECOM_CITY" \
        "$SPEEDTEST_UNICOM_ID" "$SPEEDTEST_UNICOM_CITY" \
        "$SPEEDTEST_MOBILE_ID" "$SPEEDTEST_MOBILE_CITY"
      printf 'RANK\t%s|%s|%s|%s|%s|%s|%s\n' \
        "${RANK_SESSION_ID:-}" "${RANK_SESSION_TOKEN:-}" \
        "${RANK_SESSION_STARTED_AT:-}" "${RANK_SESSION_EXPIRES_AT:-}" \
        "${RANK_SESSION_IP4:-}" "${SPEEDTEST_RANK_ELIGIBLE:-0}" \
        "${SPEEDTEST_RANK_DISABLED_REASON:-}"
      printf 'ROW\t%s\n' "${SPEEDTEST_ROWS[@]}"
    } > "$SPEEDTEST_STATE_FILE"
  fi
  echo
}

speedtest_set_failed_rows() {
  SPEEDTEST_ROWS=()
  local label region rate carrier row
  local -a carriers=()
  while IFS= read -r carrier; do carriers+=("$carrier"); done < <(speedtest_carrier_list)
  while IFS='|' read -r label region rate; do
    [ -n "$label" ] || continue
    row="$label"
    for carrier in "${carriers[@]}"; do
      row+=";failed|failed|failed|failed|||-|-|-|-"
    done
    SPEEDTEST_ROWS+=("$row")
  done < <(speedtest_group_specs)
}

show_speedtest_results() {
  local row label rest result upload upload_retrans download download_retrans server_id city upload_connect upload_tls download_connect download_tls index carrier region
  local upload_text download_text speed_color retrans_color tls_color
  local -a carriers=()
  local results=()
  while IFS= read -r carrier; do carriers+=("$carrier"); done < <(speedtest_carrier_list)
  echo -e "${BOLD}${CYAN}单线程测速${NC}"
  echo
  for row in "${SPEEDTEST_ROWS[@]}"; do
    label="${row%%;*}"
    rest="${row#*;}"
    results=()
    IFS=';' read -ra results <<< "$rest"
    speedtest_print_group_header "$label" "IPv4"
    for index in "${!results[@]}"; do
      result="${results[$index]}"
      carrier="${carriers[$index]}"
      IFS='|' read -r upload upload_retrans download download_retrans server_id city upload_connect upload_tls download_connect download_tls <<<"$result"
      region="${city:-$(speedtest_selected_city "$carrier")}${carrier}"
      [ -n "${city:-$(speedtest_selected_city "$carrier")}" ] || region="${carrier}失败"
      printf '  '
      printf '%b' "$CYAN"; speedtest_pad_left 12 "$region"; printf '%b' "$NC"
      printf '  '
      # 回程重传（上传方向）
      if [ "$upload_retrans" = "-" ]; then
        retrans_color="$DIM"
      else
        retrans_color=$(speedtest_retrans_color "$upload_retrans")
      fi
      printf '%b' "$retrans_color"; speedtest_pad_left 10 "$upload_retrans"; printf '%b' "$NC"
      printf '  '
      # 回程速度（上传）
      if [ "$upload" = "-" ]; then
        upload_text="-"; speed_color="$DIM"
      else
        upload_text=$(speedtest_speed_text "$upload")
        speed_color=$(speedtest_speed_color "$upload" "$label")
      fi
      printf '%b' "$speed_color"; speedtest_pad_left 12 "$upload_text"; printf '%b' "$NC"
      printf '  '
      # 去程速度（下载）
      if [ "$download" = "-" ]; then
        download_text="-"; speed_color="$DIM"
      else
        download_text=$(speedtest_speed_text "$download")
        speed_color=$(speedtest_speed_color "$download" "$label")
      fi
      printf '%b' "$speed_color"; speedtest_pad_left 12 "$download_text"; printf '%b' "$NC"
      printf '  '
      # 回程延迟（上传）
      upload_tls_text=$(speedtest_direction_latency_text "$upload_tls" "$upload")
      if [ "$upload" = "-" ]; then
        tls_color="$DIM"
      elif speedtest_metric_failed "$upload"; then
        tls_color="$RED"
      else
        tls_color=$(speedtest_latency_color "$upload_tls")
      fi
      printf '%b' "$tls_color"; speedtest_pad_left 10 "$upload_tls_text"; printf '%b' "$NC"
      printf '  '
      # 去程延迟（下载）
      download_tls_text=$(speedtest_direction_latency_text "$download_tls" "$download")
      if [ "$download" = "-" ]; then
        tls_color="$DIM"
      elif speedtest_metric_failed "$download"; then
        tls_color="$RED"
      else
        tls_color=$(speedtest_latency_color "$download_tls")
      fi
      printf '%b' "$tls_color"; speedtest_pad_left 10 "$download_tls_text"; printf '%b' "$NC"
      printf '\n'
    done
    echo
  done
}

run_speedtest_mode() {
  local start_time end_time start_epoch end_epoch elapsed tg_tmp traffic_begin traffic_end traffic_bytes
  check_curl
  # 记录开始测试的时间（测速开始时刻）
  start_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST')
  start_epoch=$(date +%s)
  # 测速前流量基数
  traffic_begin=$(speedtest_traffic_bytes)
  detect_ip_stack
  collect_speedtest_results
  # 记录输出结果的时间（测速完成时刻）与耗时
  end_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST')
  end_epoch=$(date +%s)
  elapsed=$((end_epoch - start_epoch))
  [ "$elapsed" -lt 0 ] && elapsed=0
  # 测速消耗流量（结束-开始，含发送+接收）
  traffic_end=$(speedtest_traffic_bytes)
  traffic_bytes=$((traffic_end - traffic_begin))
  [ "$traffic_bytes" -lt 0 ] && traffic_bytes=0
  clear 2>/dev/null || true
  tg_tmp=$(mktemp)
  {
    if [ -n "$TG_DEVICE_NAME" ]; then
      # 设置了设备名：单行时间（开始-结束）+ 耗时，不显示 IP/ASN
      echo -e "${BOLD}${CYAN}【${TG_DEVICE_NAME}】${start_time}-${end_time#* } 耗时：${elapsed} 秒${NC}"
      echo -e "  ${DIM}消耗流量：$(speedtest_traffic_text "$traffic_bytes")${NC}"
    else
      # 未设置设备名：双时间 + IP/ASN
      echo -e "${BOLD}${CYAN}开始测试时间：${start_time}${NC}"
      echo -e "${DIM}输出结果时间：${end_time}    耗时：${elapsed} 秒${NC}"
      echo
      show_ip_asn_info
      echo -e "  ${DIM}消耗流量：$(speedtest_traffic_text "$traffic_bytes")${NC}"
    fi
    echo
    show_speedtest_results
    echo
  } | tee "$tg_tmp"
  echo
  # 仅定时任务推送：非定时模式下不推送
  if [ "$TG_ONLY_CRON" = "1" ] && [ "$SCHEDULED" -ne 1 ]; then
    echo -e "${DIM}（已开启“仅定时任务推送”，本次手动测速不推送 Telegram）${NC}"
  else
    tg_send_result "$tg_tmp"
  fi
  rm -f "$tg_tmp"
}
# ===================== 配置 / Telegram 推送 / 定时测速 =====================
load_config() {
  TG_ENABLED=0; TG_BOT_TOKEN=""; TG_CHAT_ID=""; TG_DEVICE_NAME=""
  CRON_ENABLED=0; CRON_TIMES="12:00,22:00"
  LAST_DIRECTION="both"; LAST_ISPS=""; LAST_CITIES=""
  TG_ONLY_CRON=0
  [ -f "$CONF_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    [ -n "$k" ] || continue
    case "$k" in
      TG_ENABLED)    TG_ENABLED="$v" ;;
      TG_BOT_TOKEN)  TG_BOT_TOKEN="$v" ;;
      TG_CHAT_ID)    TG_CHAT_ID="$v" ;;
      TG_DEVICE_NAME) TG_DEVICE_NAME="$v" ;;
      CRON_ENABLED)  CRON_ENABLED="$v" ;;
      CRON_TIMES)    CRON_TIMES="$v" ;;
      CRON_DIRECTION) CRON_DIRECTION="$v" ;;
      CRON_ISPS)     CRON_ISPS="$v" ;;
      CRON_CITIES)   CRON_CITIES="$v" ;;
      LAST_DIRECTION) LAST_DIRECTION="$v" ;;
      LAST_ISPS)     LAST_ISPS="$v" ;;
      LAST_CITIES)   LAST_CITIES="$v" ;;
      TG_ONLY_CRON)   TG_ONLY_CRON="$v" ;;
    esac
  done < "$CONF_FILE"
}

save_config() {
  cat > "$CONF_FILE" <<EOF
# TcpQuality 单线程测速 配置
TG_ENABLED=${TG_ENABLED:-0}
TG_BOT_TOKEN=${TG_BOT_TOKEN:-}
TG_CHAT_ID=${TG_CHAT_ID:-}
TG_DEVICE_NAME=${TG_DEVICE_NAME:-}
CRON_ENABLED=${CRON_ENABLED:-0}
CRON_TIMES=${CRON_TIMES:-12:00,22:00}
CRON_DIRECTION=${CRON_DIRECTION:-both}
CRON_ISPS=${CRON_ISPS:-}
CRON_CITIES=${CRON_CITIES:-}
LAST_DIRECTION=${LAST_DIRECTION:-both}
LAST_ISPS=${LAST_ISPS:-}
LAST_CITIES=${LAST_CITIES:-}
TG_ONLY_CRON=${TG_ONLY_CRON:-0}
EOF
  chmod 600 "$CONF_FILE"
}

# 发送一条 Telegram 文本消息；0=成功 1=失败（失败详情写入 TG_LAST_ERROR）
tg_send_text() {
  local text="$1" resp rc desc
  TG_LAST_ERROR=""
  [ "$TG_ENABLED" = "1" ] || { TG_LAST_ERROR="推送未启用（TG_ENABLED=0）"; return 1; }
  [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || { TG_LAST_ERROR="Bot Token 或 Chat ID 未配置"; return 1; }
  resp=$(curl -sS --max-time 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    TG_LAST_ERROR="网络请求失败（curl 错误码 $rc）：$(printf '%s' "$resp" | head -1)"
    return 1
  fi
  # 解析 Telegram 返回的 JSON：ok 字段为 true 才算成功
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    return 0
  fi
  desc=$(printf '%s' "$resp" | sed -n 's/.*"description": *"\([^"]*\)".*/\1/p')
  TG_LAST_ERROR="Telegram 接口返回失败：${desc:-$(printf '%s' "$resp" | head -c 200)}"
  return 1
}

tg_send_test() {
  if [ "$TG_ENABLED" != "1" ] || [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo -e "${YELLOW}[!] 推送未启用或未配置完整，请先完成配置${NC}"
    return 1
  fi
  echo -e "${DIM}正在发送测试消息到 chat_id=${TG_CHAT_ID} ...${NC}"
  if tg_send_text "TcpQuality 测试消息 [OK]"; then
    echo -e "${GREEN}[OK] 测试消息已发送，请检查 Telegram 是否收到${NC}"
  else
    echo -e "${RED}[X] 发送失败：${TG_LAST_ERROR}${NC}"
    echo
    echo -e "  排查指引："
    echo -e "  1) 确认 Bot Token 正确：用 @BotFather 的 /mybots 重新获取，格式为 数字:字母数字"
    echo -e "  2) 必须先用你的 Telegram 账号向该 bot 发送任意一条消息（建立会话），否则 bot 无法给你发消息"
    echo -e "  3) 核对 Chat ID：浏览器打开下面链接，看返回 json 里 chat 的 id 字段"
    echo -e "     https://api.telegram.org/bot<你的TOKEN>/getUpdates"
    echo -e "  4) 海外机器无需代理；若在国内使用需为 curl 配置代理"
  fi
}

# 发送测速结果（自动分片，每片约 3800 字符）
tg_send_result() {
  local file="$1" stripped buf line ok=1
  [ "$TG_ENABLED" = "1" ] || return 0
  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo -e "${YELLOW}[!] Telegram 推送未配置完整，跳过${NC}"
    return 0
  fi
  stripped=$(sed -r 's/\x1B\[[0-9;]*[mK]//g' "$file")
  buf=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${#buf}" -gt 3800 ]; then
      tg_send_text "$buf" || { ok=0; last_err="$TG_LAST_ERROR"; }
      buf=""
    fi
    buf+="$line"$'\n'
  done <<< "$stripped"
  if [ -n "$buf" ]; then
    tg_send_text "$buf" || { ok=0; last_err="$TG_LAST_ERROR"; }
  fi
  if [ "$ok" -eq 1 ]; then
    echo -e "${GREEN}[OK] 测速结果已发送到 Telegram${NC}"
  else
    echo -e "${YELLOW}[!] 部分 TG 消息发送失败：${last_err:-未知错误}${NC}"
    echo -e "${YELLOW}[!] 可用 --tg-test 命令进行诊断${NC}"
  fi
}

# ---------- Telegram 推送配置向导 ----------
tg_config_wizard() {
  local choice
  while :; do
    clear 2>/dev/null || true
    echo -e "${BOLD}${CYAN}Telegram 推送配置${NC}"
    echo "  当前状态：$([ "$TG_ENABLED" = "1" ] && echo -e "${GREEN}已启用${NC}" || echo -e "${DIM}未启用${NC}")"
    echo "  Bot Token：${TG_BOT_TOKEN:+已设置}${TG_BOT_TOKEN:-未设置}"
    echo "  Chat ID：${TG_CHAT_ID:-未设置}"
    echo "  设备名称：${TG_DEVICE_NAME:-未设置}"
    echo "  推送范围：$([ "$TG_ONLY_CRON" = "1" ] && echo -e "${GREEN}仅定时任务${NC}" || echo -e "${DIM}所有测速${NC}")"
    echo
    echo "  1) 启用推送"
    echo "  2) 禁用推送"
    echo "  3) 设置 Bot Token"
    echo "  4) 设置 Chat ID"
    echo "  5) 设置设备名称"
    echo "  6) 仅定时任务推送开关（当前：$([ "$TG_ONLY_CRON" = "1" ] && echo 开启 || echo 关闭)）"
    echo "  7) 发送测试消息"
    echo "  0) 返回主菜单"
    echo
    read -rp "  请选择 [0-7]：" choice
    case "$choice" in
      1) TG_ENABLED=1; save_config; echo -e "${GREEN}[OK] 已启用推送${NC}" ;;
      2) TG_ENABLED=0; save_config; echo -e "${YELLOW}[!] 已禁用推送${NC}" ;;
      3) read -rp "  请输入 Bot Token（回车取消）：" TG_BOT_TOKEN
         [ -n "$TG_BOT_TOKEN" ] && save_config && echo -e "${GREEN}[OK] Bot Token 已保存${NC}" ;;
      4) read -rp "  请输入 Chat ID（回车取消）：" TG_CHAT_ID
         [ -n "$TG_CHAT_ID" ] && save_config && echo -e "${GREEN}[OK] Chat ID 已保存${NC}" ;;
      5) read -rp "  请输入设备名称（回车取消，显示在报告顶部）：" TG_DEVICE_NAME
         [ -n "$TG_DEVICE_NAME" ] && save_config && echo -e "${GREEN}[OK] 设备名称已保存${NC}" ;;
      6) if [ "$TG_ONLY_CRON" = "1" ]; then
           TG_ONLY_CRON=0; save_config
           echo -e "${YELLOW}[!] 已关闭“仅定时任务推送”：所有测速都会推送${NC}"
         else
           TG_ONLY_CRON=1; save_config
           echo -e "${GREEN}[OK] 已开启“仅定时任务推送”：仅定时测速时推送${NC}"
         fi ;;
      7) tg_send_test ;;
      0) return 0 ;;
      *) echo -e "${RED}  无效输入，请选择 0-7${NC}" ;;
    esac
    read -rp "  按回车继续..."
  done
}

# ---------- 定时测速 ----------
# 校验时间串（格式 HH:MM[,HH:MM...]，hour 0-23，min 0-59）；0=合法 1=非法
validate_cron_times() {
  local t hour
  for t in ${1//,/ }; do
    t=${t// /}
    [ -n "$t" ] || continue
    case "$t" in
      [0-9]:[0-5][0-9]|[0-9][0-9]:[0-5][0-9]) ;;
      *) return 1 ;;
    esac
    hour="${t%%:*}"
    [ "$hour" -le 23 ] || return 1
  done
  return 0
}

# 生成 crontab 条目（北京时间 HH:MM，多组用逗号分隔）
# 获取脚本真实路径；通过管道/远程方式执行（bash <(curl ...) / curl | bash）时无真实文件，返回空
get_script_path() {
  local p
  p="$(readlink -f "$0" 2>/dev/null)"
  if [ -n "$p" ] && [ -f "$p" ] && [[ "$p" != /dev/fd/* ]] && [[ "$p" != *"pipe:["* ]]; then
    printf '%s' "$p"
  fi
}

cron_schedule_line() {
  local t hour min script_path conf_line log_file
  script_path="$(get_script_path)"
  conf_line="CONF_FILE=${CONF_FILE:-$HOME/.tcpquality.conf}"
  log_file="${TCQ_CRON_LOG:-${CONF_FILE:-$HOME/.tcpquality.conf}.cron.log}"
  for t in ${CRON_TIMES//,/ }; do
    t=${t// /}
    [ -n "$t" ] || continue
    hour="${t%%:*}"; min="${t##*:}"
    # 去掉前导 0，避免 cron 八进制解析问题
    hour=$((10#$hour))
    min=$((10#$min))
    # 用 bash 显式调用脚本，避免 /bin/sh 直接执行因缺少执行权限而失败
    # （路径不加引号，保证与去重/验证的匹配模式一致）
    printf '%s %s * * * %s bash %s --scheduled >> %s 2>&1\n' "$min" "$hour" "$conf_line" "$script_path" "$log_file"
  done
}

# 检测 cron 服务是否在运行（进程名 / PID 文件 / 宽泛匹配三层兜底）
cron_service_running() {
  local pid_file pid
  # 1) 进程名精确匹配（Debian/Ubuntu: cron，RHEL: crond）
  pgrep -x cron &>/dev/null && return 0
  pgrep -x crond &>/dev/null && return 0
  # 2) PID 文件兜底：cron 已在运行但进程名未被 pgrep 匹配到时
  for pid_file in /var/run/crond.pid /var/run/cron.pid /run/crond.pid; do
    if [ -f "$pid_file" ]; then
      pid=$(cat "$pid_file" 2>/dev/null || true)
      if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
    fi
  done
  # 3) 宽泛匹配 cron 守护进程路径
  pgrep -f '[/s]bin/cron|[/s]bin/crond' &>/dev/null && return 0
  return 1
}

# 安装 cron（按系统包管理器自动选择）
install_cron() {
  echo -e "${DIM}正在安装 cron 服务，请稍候...${NC}"
  local ok=0
  if command -v apt-get &>/dev/null; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y cron >/dev/null 2>&1 && ok=1
  elif command -v dnf &>/dev/null; then
    dnf install -y cronie >/dev/null 2>&1 && ok=1
  elif command -v yum &>/dev/null; then
    yum install -y cronie >/dev/null 2>&1 && ok=1
  elif command -v apk &>/dev/null; then
    apk add --no-cache cron >/dev/null 2>&1 && ok=1
  fi
  if [ "$ok" -ne 1 ]; then
    echo -e "${RED}[X] 自动安装失败，请手动安装 cron（如：apt-get install -y cron）${NC}"
    return 1
  fi
  echo -e "${GREEN}[OK] cron 已安装${NC}"
  # 尝试启动服务
  (service cron start 2>/dev/null || service crond start 2>/dev/null || \
   systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null) >/dev/null 2>&1 || true
  sleep 1
  if cron_service_running; then
    echo -e "${GREEN}[OK] cron 服务已启动${NC}"
  else
    echo -e "${YELLOW}[!] cron 已安装但服务未自动启动，请手动运行：service cron start${NC}"
  fi
  return 0
}

# 校验 cron 功能：crontab 命令缺失时提示安装
ensure_cron_available() {
  local install_ans
  if command -v crontab &>/dev/null; then
    return 0
  fi
  echo -e "${RED}[!] 未检测到 cron 定时服务（crontab 命令不存在）${NC}"
  echo -e "  定时测速依赖 cron 在指定时间自动触发脚本。"
  read -rp "  是否现在安装 cron？[y/N]：" install_ans
  case "$install_ans" in
    y|Y|yes|YES)
      install_cron
      ;;
    *)
      echo -e "${YELLOW}[!] 已跳过安装。不安装 cron 将无法使用定时测速功能。${NC}"
      ;;
  esac
  command -v crontab &>/dev/null
}

# 尝试启动 cron 服务并确认
ensure_cron_service() {
  if cron_service_running; then
    return 0
  fi
  echo -e "${DIM}检测到 cron 服务未运行，尝试启动...${NC}"
  (service cron start 2>/dev/null || service crond start 2>/dev/null || \
   systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null) >/dev/null 2>&1 || true
  sleep 1
  if cron_service_running; then
    echo -e "${GREEN}[OK] cron 服务已启动${NC}"
  else
    # 启动报错但 PID 锁存在（如 crond.pid）→ 说明 cron 实际已在运行
    if [ -f /var/run/crond.pid ] || [ -f /var/run/cron.pid ] || [ -f /run/crond.pid ]; then
      echo -e "${YELLOW}[!] cron 服务已在运行（检测到 PID 锁），无需重复启动${NC}"
      return 0
    fi
    echo -e "${RED}[!] 无法自动启动 cron 服务！定时任务将不会触发。${NC}"
    echo -e "${RED}[!] 请手动运行：service cron start（或 systemctl start cron）${NC}"
  fi
}

setup_cron() {
  local existing schedule script_path
  # 先检测脚本是否有真实文件路径（管道/远程执行时无法定时）
  script_path="$(get_script_path)"
  if [ -z "$script_path" ]; then
    echo -e "${RED}[X] 无法启用定时测速：当前通过管道/远程方式运行（bash <(curl ...)），脚本没有真实文件路径。${NC}"
    echo -e "  ${YELLOW}定时任务需要脚本落盘后才能被 cron 调用。请先将脚本保存到本地：${NC}"
    echo "    curl -fsSL <脚本URL> -o /root/tgtest.sh && chmod +x /root/tgtest.sh"
    echo "    然后重新运行：bash /root/tgtest.sh"
    return 1
  fi
  if ! validate_cron_times "$CRON_TIMES"; then
    echo -e "${YELLOW}[!] 测速时间配置无效，已重置为默认 12:00,22:00${NC}"
    CRON_TIMES="12:00,22:00"
    save_config
  fi
  # cron 功能校验：缺失则提示安装
  if ! ensure_cron_available; then
    echo -e "${RED}[X] cron 不可用，无法启用定时测速${NC}"
    return 1
  fi
  # 确保 cron 服务运行
  ensure_cron_service
  # 兜底：给脚本补可执行权限（crontab 用 bash 调用后非必需，但更稳妥）
  if [ ! -x "$script_path" ]; then
    chmod +x "$script_path" 2>/dev/null || true
  fi
  # 过滤已有条目，避免重复
  existing=$(crontab -l 2>/dev/null | grep -vF -- "$script_path --scheduled" || true)
  schedule=$(cron_schedule_line)
  if [ -n "$existing" ]; then
    { printf '%s\n' "$existing"; printf '%s\n' "$schedule"; } | crontab -
  else
    printf '%s\n' "$schedule" | crontab -
  fi
  # 验证写入是否成功
  if crontab -l 2>/dev/null | grep -qF -- "$script_path --scheduled"; then
    CRON_ENABLED=1
    save_config
    echo -e "${GREEN}[OK] 已启用定时测速：每天 $(echo "$CRON_TIMES" | sed 's/,/ 和 /g')（北京时间）${NC}"
    echo "  crontab 条目："
    printf '%s\n' "$schedule" | sed 's/^/    /'
    echo "  运行日志：$(cron_log_file)"
  else
    echo -e "${RED}[X] crontab 写入失败，请检查当前用户是否有 crontab 权限${NC}"
    return 1
  fi
}

disable_cron() {
  local existing
  existing=$(crontab -l 2>/dev/null | grep -vF -- "$(get_script_path) --scheduled" || true)
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing" | crontab -
  else
    crontab -r 2>/dev/null || true
  fi
  CRON_ENABLED=0
  save_config
  echo -e "${YELLOW}[!] 已禁用定时测速${NC}"
}

# ---------- 上次测速条件（回车快速测速） ----------
save_last_choice() {
  LAST_DIRECTION="$SPEEDTEST_DIRECTION"
  LAST_ISPS="$SELECTED_ISPS"
  LAST_CITIES="$SELECTED_CITIES"
  save_config
}

load_last_choice() {
  SPEEDTEST_DIRECTION="${LAST_DIRECTION:-both}"
  SELECTED_ISPS="$LAST_ISPS"
  SELECTED_CITIES="$LAST_CITIES"
}

last_preset_display() {
  local dir city isp
  case "${LAST_DIRECTION:-both}" in
    dl) dir="仅回程" ;;
    ul) dir="仅去程" ;;
    *)  dir="下载+上传" ;;
  esac
  city=$(echo ${LAST_CITIES:-})
  isp=$(echo ${LAST_ISPS:-})
  [ -n "$city" ] || city="全部"
  [ -n "$isp" ] || isp="三网"
  echo "$dir / 城市:$city / 运营商:$isp"
}

# 安装 cdntest 快捷命令
install_cdntest() {
  local target="/usr/local/bin/cdntest" script_path
  script_path="$(get_script_path)"
  if [ -z "$script_path" ]; then
    echo -e "${YELLOW}[!] 当前通过管道/远程方式运行，无法安装 cdntest，请先落盘保存脚本${NC}"
    return 1
  fi
  if ln -sf "$script_path" "$target" 2>/dev/null; then
    chmod +x "$script_path" 2>/dev/null || true
    echo -e "${GREEN}[OK] 已安装快捷命令 cdntest${NC}"
    echo "  现在可直接输入 cdntest 运行测速"
  else
    echo -e "${RED}[X] 无法写入 $target（需要 root 权限）${NC}"
    echo -e "  请手动执行：sudo ln -sf $script_path /usr/local/bin/cdntest"
  fi
}

# ---------- 定时测速预设 ----------
cron_preset_display() {
  local dir city isp
  case "$CRON_DIRECTION" in
    dl) dir="仅回程" ;;
    ul) dir="仅去程" ;;
    *)  dir="下载+上传" ;;
  esac
  city=$(echo $CRON_CITIES)
  isp=$(echo $CRON_ISPS)
  [ -n "$city" ] || city="全部"
  [ -n "$isp" ] || isp="三网"
  echo "$dir / 城市:$city / 运营商:$isp"
}

# 设置定时测速预设（复用向导界面，结果保存到 CRON_*）
cron_preset_wizard() {
  SPEEDTEST_DIRECTION="both"; SELECTED_ISPS=""; SELECTED_CITIES=""
  run_wizard "定时测速预设（回车使用默认：下载+上传 / 全部城市 / 三网）"
  CRON_DIRECTION="$SPEEDTEST_DIRECTION"
  CRON_ISPS="$SELECTED_ISPS"
  CRON_CITIES="$SELECTED_CITIES"
  save_config
  echo -e "${GREEN}[OK] 定时测速预设已保存：$(cron_preset_display)${NC}"
}

# cron 运行日志路径
cron_log_file() {
  echo "${TCQ_CRON_LOG:-${CONF_FILE:-$HOME/.tcpquality.conf}.cron.log}"
}

# 立即执行一次定时测速（验证链路）
cron_run_now() {
  echo -e "${DIM}立即执行一次定时测速（等同 --scheduled，使用当前预设）...${NC}"
  echo
  SPEEDTEST_DIRECTION="${CRON_DIRECTION:-both}"
  SELECTED_ISPS="$CRON_ISPS"
  SELECTED_CITIES="$CRON_CITIES"
  echo -e "  本次参数：$(cron_preset_display)"
  echo
  run_speedtest_mode
  echo
  echo -e "${GREEN}[OK] 定时测速执行完成${NC}"
}

# 查看定时任务状态（诊断）
cron_status() {
  local script_path entries
  script_path="$(get_script_path)"
  echo "  --- cron 服务状态 ---"
  if cron_service_running; then
    echo "    [运行中]"
  else
    echo -e "    ${RED}[未运行] — 定时任务不会触发！请运行：service cron start${NC}"
  fi
  echo "  --- 定时测速 crontab 条目 ---"
  entries=$(crontab -l 2>/dev/null | grep -- '--scheduled' || true)
  if [ -n "$entries" ]; then
    printf '%s\n' "$entries" | sed 's/^/    /'
  else
    echo -e "    ${YELLOW}（无条目 — 请先启用定时测速）${NC}"
  fi
  echo "  --- 脚本路径 ---"
  if [ -f "$script_path" ]; then
    echo "    $script_path [存在]"
  else
    echo -e "    ${RED}$script_path [不存在！脚本被移动或删除]${NC}"
  fi
  echo "  --- 运行日志 ---"
  echo "    $(cron_log_file)"
  if [ -f "$(cron_log_file)" ]; then
    echo "    最近日志："
    tail -n 5 "$(cron_log_file)" 2>/dev/null | sed 's/^/    /'
  else
    echo "    （尚无日志，任务可能未执行）"
  fi
}

# ---------- 定时测速配置向导 ----------
cron_config_wizard() {
  local choice new_times
  while :; do
    clear 2>/dev/null || true
    echo -e "${BOLD}${CYAN}定时测速配置${NC}"
    echo "  当前状态：$([ "$CRON_ENABLED" = "1" ] && echo -e "${GREEN}已启用${NC}" || echo -e "${DIM}未启用${NC}")"
    echo "  测速时间（北京时间）：${CRON_TIMES}"
    echo "  测速预设：$(cron_preset_display)"
    echo
    echo "  1) 启用定时测速（每天 ${CRON_TIMES}）"
    echo "  2) 禁用定时测速"
    echo "  3) 修改测速时间"
    echo "  4) 设置测速预设"
    echo "  5) 立即运行一次（测试链路）"
    echo "  6) 查看任务状态"
    echo "  0) 返回主菜单"
    echo
    read -rp "  请选择 [0-6]：" choice
    case "$choice" in
      1) setup_cron ;;
      2) disable_cron ;;
      3) read -rp "  请输入测速时间（格式 HH:MM,HH:MM，回车保持 ${CRON_TIMES}）：" new_times
         new_times=${new_times:-$CRON_TIMES}
         if validate_cron_times "$new_times"; then
           CRON_TIMES="$new_times"; save_config
           if [ "$CRON_ENABLED" = "1" ]; then setup_cron; fi
           echo -e "${GREEN}[OK] 时间已更新为 ${CRON_TIMES}${NC}"
         else
           echo -e "${RED}[X] 时间格式无效（示例：12:00,22:00）${NC}"
         fi ;;
      4) cron_preset_wizard ;;
      5) cron_run_now ;;
      6) cron_status ;;
      0) return 0 ;;
      *) echo -e "${RED}  无效输入，请选择 0-6${NC}" ;;
    esac
    read -rp "  按回车继续..."
  done
}

# ===================== 参数解析 =====================
parse_args() {
  if [ $# -gt 0 ]; then HAS_CLI_ARGS=1; fi
  UL_FLAG=0
  DL_FLAG=0
  SPEEDTEST_DIRECTION="both"
  while [ $# -gt 0 ]; do
    case "$1" in
      --isp)
        if [ -z "${2:-}" ] || ! set_selected_isps "$2"; then
          echo -e "${RED}[X] --isp 只支持：ct,cu,cm（可逗号组合或 all）${NC}" >&2
          exit 1
        fi
        shift 2
        ;;
      --city)
        if [ -z "${2:-}" ] || ! set_selected_cities "$2"; then
          echo -e "${RED}[X] --city 只支持：bj,sh,gd（可逗号组合或 all）${NC}" >&2
          exit 1
        fi
        shift 2
        ;;
      --ul)
        UL_FLAG=1
        shift
        ;;
      --dl)
        DL_FLAG=1
        shift
        ;;
      --scheduled|--cron)
        SCHEDULED=1
        shift
        ;;
      --tg-test)
        load_config
        tg_send_test
        exit 0
        ;;
      *)
        echo -e "${RED}[X] 不支持的参数: $1${NC}" >&2
        exit 1
        ;;
    esac
  done

  if [ "$UL_FLAG" -eq 1 ] && [ "$DL_FLAG" -eq 1 ]; then
    SPEEDTEST_DIRECTION="both"
  elif [ "$UL_FLAG" -eq 1 ]; then
    SPEEDTEST_DIRECTION="ul"
  elif [ "$DL_FLAG" -eq 1 ]; then
    SPEEDTEST_DIRECTION="dl"
  fi
}

# ===================== 交互式向导 =====================
# 无参数运行时进入；回车使用默认值（both / all city / all isp）
run_wizard() {
  local choice city_choice isp_choice c
  local wizard_title="${1:-单线程测速向导}"
  local mode_name="下载+上传" city_names="" isp_names=""
  local -a city_pool=(北京 上海 广东)
  local -a isp_pool=(电信 联通 移动)

  echo -e "${BOLD}${CYAN}${wizard_title}${NC}"
  echo "  回车使用默认值（回程+去程 / 全部城市 / 三网）"
  echo ""
  echo "  测速模式："
  echo "    1) 下载+上传   2) 仅回程   3) 仅去程"
  while :; do
    read -rp "  请选择 [1-3，默认1]：" choice
    choice=${choice:-1}
    case "$choice" in
      1) SPEEDTEST_DIRECTION="both"; mode_name="下载+上传"; break ;;
      2) SPEEDTEST_DIRECTION="dl";   mode_name="仅回程";     break ;;
      3) SPEEDTEST_DIRECTION="ul";   mode_name="仅去程";     break ;;
      *) echo "    无效输入，请输入 1-3" ;;
    esac
  done

  echo ""
  echo "  测速城市（多选用逗号，如 1,3）："
  echo "    1) 北京   2) 上海   3) 广东   4) 全部"
  while :; do
    read -rp "  请选择 [默认4]：" city_choice
    city_choice=${city_choice:-4}
    SELECTED_CITIES=""
    if [ "$city_choice" = "4" ]; then
      city_names=""
      break
    fi
    city_names=""
    ok=1
    IFS=',' read -ra sel <<< "$city_choice"
    for c in "${sel[@]}"; do
      c=${c// /}
      case "$c" in
        1|2|3)
          [ -n "$city_names" ] && city_names+=","
          city_names+="${city_pool[$((c-1))]}"
          case " $SELECTED_CITIES " in
            *" ${city_pool[$((c-1))]} "*) ;;
            *) SELECTED_CITIES="$SELECTED_CITIES ${city_pool[$((c-1))]}" ;;
          esac
          ;;
        *) ok=0 ;;
      esac
    done
    if [ "$ok" -eq 1 ] && [ -n "$SELECTED_CITIES" ]; then
      break
    fi
    echo "    无效输入，请输入 1-4 或用逗号组合 1,2,3"
  done

  echo ""
  echo "  测速运营商（多选用逗号，如 1,2）："
  echo "    1) 电信   2) 联通   3) 移动   4) 全部"
  while :; do
    read -rp "  请选择 [默认4]：" isp_choice
    isp_choice=${isp_choice:-4}
    SELECTED_ISPS=""
    if [ "$isp_choice" = "4" ]; then
      isp_names=""
      break
    fi
    isp_names=""
    ok=1
    IFS=',' read -ra sel <<< "$isp_choice"
    for c in "${sel[@]}"; do
      c=${c// /}
      case "$c" in
        1|2|3)
          [ -n "$isp_names" ] && isp_names+=","
          isp_names+="${isp_pool[$((c-1))]}"
          case " $SELECTED_ISPS " in
            *" ${isp_pool[$((c-1))]} "*) ;;
            *) SELECTED_ISPS="$SELECTED_ISPS ${isp_pool[$((c-1))]}" ;;
          esac
          ;;
        *) ok=0 ;;
      esac
    done
    if [ "$ok" -eq 1 ] && [ -n "$SELECTED_ISPS" ]; then
      break
    fi
    echo "    无效输入，请输入 1-4 或用逗号组合 1,2,3"
  done

  local city_display isp_display
  if [ -n "$SELECTED_CITIES" ]; then city_display="$city_names"; else city_display="全部"; fi
  if [ -n "$SELECTED_ISPS" ]; then isp_display="$isp_names"; else isp_display="全部"; fi
  echo ""
  echo -e "  已选择：模式=${mode_name}，城市=${city_display}，运营商=${isp_display}"
  echo ""
}

# ===================== 交互主菜单 =====================
run_main_menu() {
  local menu_choice
  while :; do
    clear 2>/dev/null || true
    echo -e "${BOLD}${CYAN}TcpQuality 单线程测速工具${NC}"
    echo
    echo "  请选择功能："
    echo "    1) 单线程测速向导"
    echo "    2) 按上次条件测速（$(last_preset_display)）"
    echo "    3) 配置 Telegram 推送"
    echo "    4) 配置定时测速"
    echo "    5) 安装 cdntest 快捷命令"
    echo "    0) 退出"
    echo
    echo "  直接回车 = 按上次条件测速"
    read -rp "  请选择 [0-5，默认2]：" menu_choice
    menu_choice=${menu_choice:-2}
    case "$menu_choice" in
      1) run_wizard; return 0 ;;
      2) load_last_choice; return 0 ;;
      3) tg_config_wizard ;;
      4) cron_config_wizard ;;
      5) install_cdntest ;;
      0) exit 0 ;;
      *) echo -e "${RED}  无效输入，请选择 0-5${NC}"; sleep 1 ;;
    esac
  done
}

# ===================== 主流程 =====================
main() {
  clear 2>/dev/null || true
  init_privilege
  load_config

  # 定时模式：非交互，应用定时测速预设（未设置则默认全部城市 / 三网 / 双向）
  if [ "$SCHEDULED" -eq 1 ]; then
    SPEEDTEST_DIRECTION="${CRON_DIRECTION:-both}"
    SELECTED_ISPS="$CRON_ISPS"
    SELECTED_CITIES="$CRON_CITIES"
  # 无 CLI 参数 → 交互主菜单；有 CLI 参数 → 行为不变
  elif [ "$HAS_CLI_ARGS" -eq 0 ]; then
    run_main_menu
  fi

  # 非定时模式：把本次选择的参数保存为“上次条件”，供下次回车快速测速
  if [ "$SCHEDULED" -ne 1 ]; then
    save_last_choice
  fi

  run_speedtest_mode
  exit 0
}

parse_args "$@"
main
