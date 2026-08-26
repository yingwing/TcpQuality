#!/usr/bin/env bash
set -e

RED='\033[0;31m';    GREEN='\033[0;32m';    YELLOW='\033[0;33m'
CYAN='\033[0;36m';   BOLD='\033[1m';        DIM='\033[2m'
NC='\033[0m'
USE_SUDO=""
GET_NODES_URL="${GET_NODES_URL:-https://tcpquality.ibsgss.uk/getNodes}"
SPEEDTEST_CARRIER_FILTER=()
SPEEDTEST_CITY_FILTER=()
SPEEDTEST_PROBE_MODE="both"
SPEEDTEST_ASN_API="${TCPQUALITY_ASN_API:-https://tcpquality.ibsgss.uk/route/asn?format=tsv}"
RESULT_DIR=$(mktemp -d)
SPEEDTEST_IFACE=""
SPEEDTEST_TOS_REGION="cn-beijing"
SPEEDTEST_TOS_NETWORK="public"
SPEEDTEST_TOS_SIZE="${TOS_PROBE_SIZE:-500MB}"
SPEEDTEST_TOS_TIMEOUT="${TOS_TIMEOUT:-10}"
SPEEDTEST_TOS_REMOTE_LOADED=0
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

init_privilege() {
  USE_SUDO=""
  if [ "$(uname)" != "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
    if command -v sudo &>/dev/null; then
      USE_SUDO="sudo"
    fi
  fi
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
  if install_with_package_manager "$desc" "$apt_pkg" "$dnf_pkg" "$yum_pkg" "$apk_pkg" "$pacman_pkg" "$brew_pkg" && command -v "$cmd" &>/dev/null; then
    :
  else
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

cleanup_result_dir() {
  printf '%b' "${NC:-\033[0m}"
  rm -rf "$RESULT_DIR"
}
trap cleanup_result_dir EXIT

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













add_isp_filter() {
  local arg="$1" item norm
  local IFS=','
  for item in $arg; do
    item=$(printf '%s' "$item" | tr -d '[:space:]')
    [ -n "$item" ] || continue
    case "$item" in
      电信|ct|CT|telecom|Telecom) norm="电信" ;;
      联通|cu|CU|unicom|Unicom|网通) norm="联通" ;;
      移动|cm|CM|mobile|Mobile|铁通) norm="移动" ;;
      *)
        echo -e "${RED}[X] 不支持的运营商: $item（支持：电信、联通、移动）${NC}" >&2
        return 1
        ;;
    esac
    SPEEDTEST_CARRIER_FILTER+=("$norm")
  done
  return 0
}

add_city_filter() {
  local arg="$1" item norm
  local IFS=','
  for item in $arg; do
    item=$(printf '%s' "$item" | tr -d '[:space:]')
    [ -n "$item" ] || continue
    case "$item" in
      北京|beijing|Beijing|cn-beijing|bj|BJ) norm="北京" ;;
      上海|shanghai|Shanghai|cn-shanghai|sh|SH) norm="上海" ;;
      广东|广州|guangdong|guangzhou|Guangdong|Guangzhou|cn-guangzhou|gd|GD|gz|GZ) norm="广东" ;;
      *)
        echo -e "${RED}[X] 不支持的城市: $item（支持：北京、上海、广东）${NC}" >&2
        return 1
        ;;
    esac
    SPEEDTEST_CITY_FILTER+=("$norm")
  done
  return 0
}

speedtest_active_carriers() {
  if [ "${#SPEEDTEST_CARRIER_FILTER[@]}" -gt 0 ]; then
    printf '%s\n' "${SPEEDTEST_CARRIER_FILTER[@]}"
  else
    printf '%s\n' 电信 联通 移动
  fi
}

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

speedtest_group_specs() {
  local line label region norm match
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    label="${line%%|*}"
    region="${line#*|}"
    region="${region%%|*}"
    if [ "${#SPEEDTEST_CITY_FILTER[@]}" -eq 0 ]; then
      printf '%s\n' "$line"
      continue
    fi
    match=0
    for norm in "${SPEEDTEST_CITY_FILTER[@]}"; do
      if [ "$label" = "$norm" ] || [ "$region" = "$norm" ]; then
        match=1
        break
      fi
    done
    [ "$match" -eq 1 ] && printf '%s\n' "$line"
  done <<'SPECS'
北京|cn-beijing|unlimited
上海|cn-shanghai|unlimited
广东|cn-guangzhou|unlimited
SPECS
}

speedtest_group_count() {
speedtest_group_specs | awk 'NF{count++} END{print count + 0}'
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
        ct_candidates+="${ct_candidates:+$'\n'}$ip|${prov:-北京}|$region"
        loaded_ct=1
        ;;
      联通|CU|ChinaUnicom|chinaunicom)
        cu_candidates+="${cu_candidates:+$'\n'}$ip|${prov:-北京}|$region"
        loaded_cu=1
        ;;
      移动|CM|ChinaMobile|chinamobile)
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

speedtest_selected_id() {
  case "$1" in
    电信) printf '%s' "$SPEEDTEST_TELECOM_ID" ;;
    联通) printf '%s' "$SPEEDTEST_UNICOM_ID" ;;
    移动) printf '%s' "$SPEEDTEST_MOBILE_ID" ;;
  esac
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
    return 0
  fi
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
  local tcp_info_ratio_denominator=0 retrans_source="nstat"
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
        trace_ratio_denominator="-"
        trace_ratio="-"
      fi
    fi
  fi
  if [ "$counter_enabled" -eq 1 ]; then
    end_bytes=$(speedtest_counter_bytes)
    end_packets=$(speedtest_counter_packets)
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
      if [ "$SPEEDTEST_RETRANS_TRACE_KEY" = "seq" ]; then
        retrans_source="ebpf_seq"
      else
        retrans_source="ebpf_skb"
      fi
    else
      retrans="$tcp_info_ratio"
      retrans_source="tcp_info_${tcp_info_mode}"
    fi
  else
    retrans="-"
    retrans_source="tcp_info_unavailable"
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
  if [ "$parsed" = "failed" ]; then
    result="failed"
  elif [ "$exit_code" -eq 0 ]; then
    ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && result="failed"
  elif [ "$partial_timeout" -ne 1 ]; then
    result="failed"
  fi

  if [ "$result" = "failed" ]; then
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
    if [ "$start_bytes" != "-" ] && [ "$end_bytes" != "-" ]; then
      delta_bytes=$((end_bytes - start_bytes))
    fi
  fi

  if [ "$probe_type" = "upload" ] && [ -n "$key" ]; then
    speedtest_tos_delete_object "$host" "$server_ip" "$key"
  fi
  rm -f "$raw_file" "$tcp_info_file" "${tcp_info_file}.tmp" "$SPEEDTEST_RETRANS_TRACE_FILE" "$SPEEDTEST_RETRANS_TRACE_ERR"
  display_connect_ms="$reported_connect_ms"
  display_tls_ms="$reported_tls_ms"
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
      exit 0
    }
  ' <<< "$ip"
}

speedtest_local_ip() {
  local api response
  local apis=(https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ident.me)
  for api in "${apis[@]}"; do
    response=$(curl -fsS4L --max-time 8 "$api" 2>/dev/null | awk 'NR==1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    if [[ "$response" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && is_public_ipv4 "$response"; then
      printf '%s' "$response"
      return 0
    fi
  done
  return 1
}

speedtest_local_asn() {
  local ip="$1"
  printf '%s\n' "$ip" | curl -4 -fsSL --connect-timeout 5 --max-time 15 \
    -X POST -H 'content-type: text/plain; charset=utf-8' \
    --data-binary @- "$SPEEDTEST_ASN_API" 2>/dev/null | awk -F'\t' '
    NR == 1 { next }
    {
      asn = $2
      owner = $3
      gsub(/^[Aa][Ss]/, "", asn)
      gsub(/[|\r\n]+/, " ", owner)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", owner)
      if (asn ~ /^[0-9]+$/) { printf "AS%s|%s\n", asn, owner; exit }
    }
  '
}

speedtest_print_group_header() {
  local column_label="${2:-IPv4}" retrans_label="${3:-去程重传}"

  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 "$column_label"; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 "$retrans_label"; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '去程速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '回程速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '去程延迟'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '回程延迟'; printf '%b' "$NC"
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
  echo -ne "\r  ${CYAN}测速进度${NC} "
  bar "$done" "$total"
  echo -ne "   "

}

speedtest_speed_color() {
  local value="$1" label="$2" level_name
  if [ "$value" = "-" ]; then
    printf '%s' "$DIM"
  elif [ "$value" = "failed" ]; then
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

collect_speedtest_results() {
local group group_region rate label carrier workdir result_file candidate server_id city candidate_region
  local upload upload_retrans upload_connect upload_tls download download_retrans download_connect download_tls done total
  local carriers=() carrier_values=()
  mapfile -t carriers < <(speedtest_active_carriers)
  done=0
  total=$(( $(speedtest_group_count) * ${#carriers[@]} ))
  SPEEDTEST_ROWS=()
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
  install_speedtest_counter_dependency || true
  SPEEDTEST_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$SPEEDTEST_IFACE" ] || {
    echo -e "${RED}[X] 无法识别默认网络接口${NC}"
    exit 1
  }
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
      case "$SPEEDTEST_PROBE_MODE" in
        download)
          IFS='|' read -r download download_retrans download_connect download_tls <<<"$(speedtest_run_probe download "$result_file.download" "$server_id")"
          upload="-" upload_retrans="-" upload_connect="-" upload_tls="-"
          ;;
        upload)
          IFS='|' read -r upload upload_retrans upload_connect upload_tls <<<"$(speedtest_run_probe upload "$result_file.upload" "$server_id")"
          download="-" download_retrans="-" download_connect="-" download_tls="-"
          ;;
        *)
          IFS='|' read -r download download_retrans download_connect download_tls <<<"$(speedtest_run_probe download "$result_file.download" "$server_id")"
          IFS='|' read -r upload upload_retrans upload_connect upload_tls <<<"$(speedtest_run_probe upload "$result_file.upload" "$server_id")"
          ;;
      esac
      if speedtest_result_valid "$upload" || speedtest_result_valid "$download"; then
        carrier_values+=("$(speedtest_format_mbps "$upload")|$upload_retrans|$(speedtest_format_mbps "$download")|$server_id|$city|$upload_connect|$upload_tls|$download_connect|$download_tls")
      else
        carrier_values+=("failed|failed|failed|$server_id|$city|$upload_connect|$upload_tls|$download_connect|$download_tls")
      fi
      rm -rf "$workdir"
      done=$((done + 1))
      speedtest_show_progress "$done" "$total"
    done
    local row="$label"
    for cv in "${carrier_values[@]}"; do
      row+=";$cv"
    done
    SPEEDTEST_ROWS+=("$row")
  done < <(speedtest_group_specs)
  speedtest_cleanup
  echo

}

show_speedtest_results() {
local row label result upload retrans download server_id city upload_connect upload_tls download_connect download_tls index carrier region upload_text download_text upload_tls_text download_tls_text
  local speed_color retrans_color tls_color local_ip masked_ip local_asn
  local carriers=() results=() row_parts=()
  echo -e "${BOLD}${CYAN}单线程测速${NC}"
  local_ip=$(speedtest_local_ip || true)
  if [ -n "$local_ip" ]; then
    masked_ip=$(printf '%s' "$local_ip" | awk -F. 'NF==4 {print $1"."$2".*.*"}')
    local_asn=$(speedtest_local_asn "$local_ip")
    [ -n "$local_asn" ] || local_asn="-"
    asn_num="${local_asn%%|*}"
    asn_name="${local_asn#*|}"
    [ "$asn_name" = "$asn_num" ] && asn_name=""
    echo -e "  ${DIM}本机：${masked_ip:-$local_ip}  ${asn_num}${asn_name:+ ${asn_name}}${NC}"
  fi
  echo
  for row in "${SPEEDTEST_ROWS[@]}"; do
    IFS=';' read -ra row_parts <<<"$row"
    label="${row_parts[0]}"
    results=("${row_parts[@]:1}")
    mapfile -t carriers < <(speedtest_active_carriers)
    speedtest_print_group_header "$label" "IPv4"
    for index in "${!results[@]}"; do
      result="${results[$index]}"
      carrier="${carriers[$index]}"
      IFS='|' read -r upload retrans download server_id city upload_connect upload_tls download_connect download_tls <<<"$result"
      region="${city:-$(speedtest_selected_city "$carrier")}${carrier}"
      [ -n "${city:-$(speedtest_selected_city "$carrier")}" ] || region="${carrier}失败"
      printf '  '
      printf '%b' "$CYAN"; speedtest_pad_left 12 "$region"; printf '%b' "$NC"
      printf '  '
      retrans_color=$(speedtest_retrans_color "$retrans")
      printf '%b' "$retrans_color"; speedtest_pad_left 10 "$retrans"; printf '%b' "$NC"
      printf '  '
      upload_text=$(speedtest_speed_text "$upload")
      speed_color=$(speedtest_speed_color "$upload" "$label")
      printf '%b' "$speed_color"; speedtest_pad_left 12 "$upload_text"; printf '%b' "$NC"
      printf '  '
      download_text=$(speedtest_speed_text "$download")
      speed_color=$(speedtest_speed_color "$download" "$label")
      printf '%b' "$speed_color"; speedtest_pad_left 12 "$download_text"; printf '%b' "$NC"
      printf '  '
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
  echo

}

append_speedtest_csv() {
local csv="$1" row label result upload retrans download server_id city upload_connect upload_tls download_connect download_tls index carrier
  local carriers=() results=() row_parts=()
  mapfile -t carriers < <(speedtest_active_carriers)
  for row in "${SPEEDTEST_ROWS[@]}"; do
    IFS=';' read -ra row_parts <<<"$row"
    label="${row_parts[0]}"
    results=("${row_parts[@]:1}")
    index=0
    for result in "${results[@]}"; do
      carrier="${carriers[$index]}"
      IFS='|' read -r upload retrans download server_id city upload_connect upload_tls download_connect download_tls <<<"$result"
      city="${city:-$(speedtest_selected_city "$carrier")}"
      server_id="${server_id:-$(speedtest_selected_id "$carrier")}"
      if [ "$upload" = "failed" ] || [ "$download" = "failed" ]; then
        printf '三网单线程速度,%s,%s,%s,,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
          "$label" "$carrier" "$city" "FAIL" "$upload" "$retrans" "$download" \
          "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
      else
        printf '三网单线程速度,%s,%s,%s,%s,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
          "$label" "$carrier" "$city" "$server_id" \
          "OK" "$upload" "$retrans" "$download" \
          "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
      fi
      index=$((index + 1))
    done
  done

}

run_speedtest_mode() {
local report_time csv
  collect_speedtest_results
  report_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')
  csv="/tmp/tcpquality_speedtest_$(date +%Y%m%d_%H%M%S).csv"
  printf '\xEF\xBB\xBF' > "$csv"
  echo "网络,IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms,线路,去程连接耗时ms,去程TLS握手耗时ms,回程连接耗时ms,回程TLS握手耗时ms,iPerf3重传次数,iPerf3方向" >> "$csv"
  append_speedtest_csv "$csv"
  clear
  echo -e "  ${DIM}报告时间：${report_time}${NC}"
  echo
  show_speedtest_results
  echo

}

speedtest_interactive_setup() {
  local choice cities_choice carriers_choice item mode_text city_text carrier_text
  local city_names=(北京 上海 广东)
  local carrier_names=(电信 联通 移动)
  echo -e "${BOLD}${CYAN}单线程测速向导${NC}"
  echo -e "  ${DIM}回车使用默认值（下载+上传 / 全部城市 / 三网）${NC}"
  echo
  printf '  测速模式：\n    1) 下载+上传   2) 仅下载（回程）   3) 仅上传（去程）\n  请选择 [1-3，默认1]：'
  read -r choice || true
  case "${choice:-1}" in
    2) SPEEDTEST_PROBE_MODE="download" ;;
    3) SPEEDTEST_PROBE_MODE="upload" ;;
    *) SPEEDTEST_PROBE_MODE="both" ;;
  esac
  echo
  printf '  测速城市（多选用逗号，如 1,3）：\n    1) 北京   2) 上海   3) 广东   4) 全部\n  请选择 [默认4]：'
  read -r cities_choice || true
  cities_choice=$(printf '%s' "${cities_choice:-4}" | tr ',' ' ')
  for item in $cities_choice; do
    case "$item" in
      1) SPEEDTEST_CITY_FILTER+=(北京) ;;
      2) SPEEDTEST_CITY_FILTER+=(上海) ;;
      3) SPEEDTEST_CITY_FILTER+=(广东) ;;
    esac
  done
  echo
  printf '  测速运营商（多选用逗号，如 1,2）：\n    1) 电信   2) 联通   3) 移动   4) 全部\n  请选择 [默认4]：'
  read -r carriers_choice || true
  carriers_choice=$(printf '%s' "${carriers_choice:-4}" | tr ',' ' ')
  for item in $carriers_choice; do
    case "$item" in
      1) SPEEDTEST_CARRIER_FILTER+=(电信) ;;
      2) SPEEDTEST_CARRIER_FILTER+=(联通) ;;
      3) SPEEDTEST_CARRIER_FILTER+=(移动) ;;
    esac
  done
  mode_text="下载+上传"
  [ "$SPEEDTEST_PROBE_MODE" = "download" ] && mode_text="仅下载（回程）"
  [ "$SPEEDTEST_PROBE_MODE" = "upload" ] && mode_text="仅上传（去程）"
  city_text=$(IFS=,; printf '%s' "${SPEEDTEST_CITY_FILTER[*]}")
  carrier_text=$(IFS=,; printf '%s' "${SPEEDTEST_CARRIER_FILTER[*]}")
  [ -n "$city_text" ] || city_text="全部"
  [ -n "$carrier_text" ] || carrier_text="三网"
  echo
  echo -e "  ${GREEN}已选择：模式=${mode_text}，城市=${city_text}，运营商=${carrier_text}${NC}"
}

parse_args() {
  if [ $# -eq 0 ]; then
    speedtest_interactive_setup
    return 0
  fi
while [ $# -gt 0 ]; do
    case "$1" in
      --isp)
        if [ -z "${2:-}" ] || ! add_isp_filter "$2"; then
          echo -e "${RED}[X] --isp 需要一个运营商参数（电信/联通/移动），可重复或逗号分隔${NC}" >&2
          exit 1
        fi
        shift 2
        ;;
      --city)
        if [ -z "${2:-}" ] || ! add_city_filter "$2"; then
          echo -e "${RED}[X] --city 需要一个城市参数（北京/上海/广东），可重复或逗号分隔${NC}" >&2
          exit 1
        fi
        shift 2
        ;;
      --dl)
        SPEEDTEST_PROBE_MODE="download"
        shift
        ;;
      --ul)
        SPEEDTEST_PROBE_MODE="upload"
        shift
        ;;
      *)
        echo -e "${RED}[X] 不支持的参数: $1${NC}" >&2
        exit 1
        ;;
    esac
  done
}

main() {
clear
  init_privilege
  run_speedtest_mode

}

parse_args "$@"
main