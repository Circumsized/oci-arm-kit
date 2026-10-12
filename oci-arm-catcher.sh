#!/usr/bin/env bash
#===============================================================================
# oci-arm-catcher.sh — 甲骨文云 Always Free ARM 实例抢购核心脚本（独立运行版）
#
# 循环调用官方 CLI 创建 VM.Standard.A1.Flex 实例：
#   · 容量不足/瞬时故障类错误 → 等待 RETRY_INTERVAL 后重试，并轮换可用性域（AD）
#   · 配额已满/配置错误类错误 → 立即停止并写明原因（不做无谓重试）
#   · 创建成功 → 打印实例 OCID 并退出（0），不会重复创建
#
# 配置来源（优先级从高到低）:
#   1. 命令行参数
#   2. 环境变量（同名键）
#   3. 配置文件：--env-file 指定；默认依次查找 ./arm.env、脚本同目录/arm.env、
#      ./.env、脚本同目录/.env
#   4. 交互式输入（终端下逐项询问，并提示该信息在控制台/CLI 的位置）
#
# 用法:
#   ./oci-arm-catcher.sh [选项]
#
# 选项:
#   --env-file FILE   指定配置文件
#   --name NAME       实例显示名（默认 arm-free-1）
#   --ocpus N         实例 OCPU 数（默认 2）
#   --memory N        实例内存 GB（默认 12）
#   --interval SEC    重试间隔秒数（默认 300，低于 300 可能触发限流）
#   --once            只尝试一次：成功 0 / 容量不足 3 / 其他错误 1（适合 agent 巡检）
#   -h, --help        显示本帮助
#   -V, --version     显示版本号
#
# 必填配置项（.env 键名，值均为非机密标识）:
#   COMPARTMENT_ID        租户 OCID（根区间）或子区间 OCID
#   SSH_KEY_FILE          实例 SSH 公钥路径（.pub）
#   SUBNET_ID             允许公网 IP 的公有子网 OCID
#   IMAGE_ID              aarch64 镜像 OCID
#   AVAILABILITY_DOMAIN   单个可用性域；或 AVAILABILITY_DOMAINS 逗号分隔（轮换）
# 可选配置项:
#   DISPLAY_NAME(arm-free-1) OCPUS(2) MEMORY_GB(12) RETRY_INTERVAL(300)
#
# 退出码: 0 成功；1 配置错误/不可重试错误；2 参数错误；3 --once 模式容量不足
#===============================================================================

set -Eeuo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHAPE="VM.Standard.A1.Flex"     # Always Free ARM 规格，固定

# ── 输出 ──────────────────────────────────────────────────────────────────────
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
info() { printf '%s\n' "${c_bld}==>${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}  ✓${c_rst} $*"; }
warn() { printf '%s\n' "${c_yel}  !${c_rst} $*"; }
die()  { printf '%s\n' "${c_red}  ✗ $*${c_rst}" >&2; exit 1; }

usage() { awk 'NR<=2{next} /^#={5,}/{exit} /^#/{sub(/^# ?/,""); print}' "$0"; exit 0; }

# ── 错误分类 ──────────────────────────────────────────────────────────────────
# 不可重试（配额/权限/参数问题，重试无意义）——先匹配
STOP_RE='LimitExceeded|QuotaExceeded|NotAuthorizedOrNotFound|NotAuthenticated|InvalidParameter|CannotParseRequest|NotAllowed'
# 可重试（容量不足或瞬时故障）
RETRY_RE='out of host capacity|out of capacity|InternalError|TooManyRequests|ServiceUnavailable|Service Unavailable|timed out|RequestException|ConnectionError|Temporary failure'

is_stop_error()  { printf '%s' "$1" | grep -qiE "$STOP_RE"; }
is_retry_error() { printf '%s' "$1" | grep -qiE "$RETRY_RE"; }

# ── 参数解析 ──────────────────────────────────────────────────────────────────
ENV_FILE=""
CLI_NAME=""; CLI_OCPUS=""; CLI_MEMORY=""; CLI_INTERVAL=""
ONCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?缺少 FILE 参数}"; shift 2 ;;
    --name)     CLI_NAME="${2:?缺少 NAME 参数}"; shift 2 ;;
    --ocpus)    CLI_OCPUS="${2:?缺少 N 参数}"; shift 2 ;;
    --memory)   CLI_MEMORY="${2:?缺少 N 参数}"; shift 2 ;;
    --interval) CLI_INTERVAL="${2:?缺少 SEC 参数}"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    -h|--help)  usage ;;
    -V|--version) echo "oci-arm-catcher.sh $VERSION"; exit 0 ;;
    *) echo "未知参数: $1（-h 查看用法）" >&2; exit 2 ;;
  esac
done

# ── 读取配置：环境变量 > 配置文件 > 交互输入 ─────────────────────────────────
CONFIG_KEYS=(COMPARTMENT_ID DISPLAY_NAME SSH_KEY_FILE AVAILABILITY_DOMAIN AVAILABILITY_DOMAINS SUBNET_ID IMAGE_ID OCPUS MEMORY_GB RETRY_INTERVAL)
declare -A PRESET=()
for k in "${CONFIG_KEYS[@]}"; do
  [[ -n "${!k:-}" ]] && PRESET[$k]="${!k}"
done

loaded=""
if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || die "配置文件不存在: $ENV_FILE"
  loaded="$ENV_FILE"
else
  for f in "./arm.env" "$SCRIPT_DIR/arm.env" "./.env" "$SCRIPT_DIR/.env"; do
    if [[ -f "$f" ]]; then loaded="$f"; break; fi
  done
fi
if [[ -n "$loaded" ]]; then
  # shellcheck disable=SC1090
  source "$loaded"
  for k in "${!PRESET[@]}"; do printf -v "$k" '%s' "${PRESET[$k]}"; done   # 环境变量优先
  info "已加载配置: $loaded"
fi

# CLI 参数覆盖（最高优先级）
[[ -n "$CLI_NAME" ]]     && DISPLAY_NAME="$CLI_NAME"
[[ -n "$CLI_OCPUS" ]]    && OCPUS="$CLI_OCPUS"
[[ -n "$CLI_MEMORY" ]]   && MEMORY_GB="$CLI_MEMORY"
[[ -n "$CLI_INTERVAL" ]] && RETRY_INTERVAL="$CLI_INTERVAL"
DISPLAY_NAME="${DISPLAY_NAME:-arm-free-1}"; OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}";              RETRY_INTERVAL="${RETRY_INTERVAL:-300}"

# 交互式补全缺失项（仅终端；非终端环境直接报错列出缺项）
ask() {
  local var="$1" prompt="$2" val="${!1:-}"
  if [[ -z "$val" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "  $prompt: " val
      printf -v "$var" '%s' "$val"
    fi
  fi
}
ask COMPARTMENT_ID "COMPARTMENT_ID （控制台→头像→租户→租户详细信息页的 OCID，ocid1.tenancy. 开头）"
ask SSH_KEY_FILE   "SSH_KEY_FILE   （实例登录公钥路径，如 ~/.ssh/id_ed25519.pub）"
ask SUBNET_ID      "SUBNET_ID      （公有子网 OCID，ocid1.subnet. 开头，需允许公网 IP）"
ask IMAGE_ID       "IMAGE_ID       （aarch64 镜像 OCID，ocid1.image. 开头）"
if [[ -z "${AVAILABILITY_DOMAINS:-}" && -z "${AVAILABILITY_DOMAIN:-}" ]]; then
  ask AVAILABILITY_DOMAIN "AVAILABILITY_DOMAIN （可用性域，如 XXXX:PHX-AD-1；多个用逗号分隔填 AVAILABILITY_DOMAINS）"
fi

# ── 校验 ──────────────────────────────────────────────────────────────────────
missing=()
[[ -n "${COMPARTMENT_ID:-}" ]] || missing+=("COMPARTMENT_ID")
[[ -n "${SSH_KEY_FILE:-}"   ]] || missing+=("SSH_KEY_FILE")
[[ -n "${SUBNET_ID:-}"      ]] || missing+=("SUBNET_ID")
[[ -n "${IMAGE_ID:-}"       ]] || missing+=("IMAGE_ID")
(( ${#missing[@]} == 0 )) || die "缺少必填配置: ${missing[*]}（可写入 .env 或用交互模式提供）"
[[ -z "${AVAILABILITY_DOMAINS:-}" && -z "${AVAILABILITY_DOMAIN:-}" ]] && die "缺少 AVAILABILITY_DOMAIN 或 AVAILABILITY_DOMAINS"
[[ "$COMPARTMENT_ID" == ocid1.tenancy.* || "$COMPARTMENT_ID" == ocid1.compartment.* ]] || die "COMPARTMENT_ID 格式不对"
[[ "$SUBNET_ID" == ocid1.subnet.* ]] || die "SUBNET_ID 格式不对"
[[ "$IMAGE_ID"  == ocid1.image.*  ]] || die "IMAGE_ID 格式不对"
SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
[[ -f "$SSH_KEY_FILE" ]] || die "SSH 公钥文件不存在: $SSH_KEY_FILE"
[[ "$OCPUS" =~ ^[0-9]+$ ]] && [[ "$MEMORY_GB" =~ ^[0-9]+$ && "$RETRY_INTERVAL" =~ ^[0-9]+$ ]] || die "OCPUS/MEMORY_GB/RETRY_INTERVAL 必须是数字"
(( RETRY_INTERVAL >= 60 )) || die "RETRY_INTERVAL 过小（建议 >=300）"
(( RETRY_INTERVAL >= 300 )) || warn "RETRY_INTERVAL=$RETRY_INTERVAL 秒，低于 300 可能触发限流"
command -v oci >/dev/null 2>&1 || die "未找到 oci 命令（OCI CLI）——请先安装，见 README"
command -v python3 >/dev/null 2>&1 || die "未找到 python3（用于解析返回结果）"

# AD 列表（支持逗号分隔轮换）
declare -a ADS=()
if [[ -n "${AVAILABILITY_DOMAINS:-}" ]]; then
  IFS=',' read -ra raw_ads <<< "$AVAILABILITY_DOMAINS"
  for a in "${raw_ads[@]}"; do
    a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"   # 去空白
    [[ -n "$a" ]] && ADS+=("$a")
  done
else
  ADS=("$AVAILABILITY_DOMAIN")
fi
(( ${#ADS[@]} > 0 )) || die "可用性域列表为空"

# ── 主循环 ────────────────────────────────────────────────────────────────────
wait_between_attempts() {
  local left="$RETRY_INTERVAL"
  info "等待 $((left / 60)) 分钟后重试（Ctrl+C 可停止）"
  while (( left > 0 )); do
    local chunk=$(( left > 60 ? 60 : left ))
    sleep "$chunk"; left=$(( left - chunk ))
    if (( left > 60 )); then
      info "  …剩余 $(( left / 60 )) 分钟"
    fi
  done
  return 0
}

attempt_launch() {   # $1=AD → 输出 API 响应；成功返回 0，失败返回原始输出与码
  local ad="$1"
  local rc=0
  LAUNCH_OUT="$(oci compute instance launch \
    --compartment-id      "$COMPARTMENT_ID" \
    --availability-domain "$ad" \
    --display-name        "$DISPLAY_NAME" \
    --shape               "$SHAPE" \
    --shape-config        "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
    --image-id            "$IMAGE_ID" \
    --subnet-id           "$SUBNET_ID" \
    --ssh-authorized-keys-file "$SSH_KEY_FILE" \
    --assign-public-ip    true \
    --connection-timeout  60 \
    --read-timeout        120 \
    --no-retry 2>&1)" || rc=$?
  return "$rc"
}

instance_id_from() {
  printf '%s' "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null \
    || printf '%s' "$1" | grep -oP 'ocid1\.instance\.[A-Za-z0-9._-]+' | head -1 || true
}

printf '\n%soci-arm-catcher.sh v%s%s\n' "$c_bld" "$VERSION" "$c_rst"
info "实例: $DISPLAY_NAME | $SHAPE | $OCPUS OCPU / ${MEMORY_GB}GB | 重试间隔 ${RETRY_INTERVAL}s"
info "可用性域（轮换）: ${ADS[*]}"

attempt=0; ad_idx=0; LAUNCH_OUT=""
while true; do
  attempt=$(( attempt + 1 ))
  ad="${ADS[$ad_idx]}"
  info "[$(date '+%F %T')] 第 $attempt 次尝试（AD: $ad）"

  if attempt_launch "$ad"; then
    iid="$(instance_id_from "$LAUNCH_OUT")"
    printf '\n%s  SUCCESS! Instance created: %s%s\n' "$c_grn" "$iid" "$c_rst"
    info "实例已创建，脚本退出。请到控制台 Compute→Instances 查看，并用私钥登录。"
    exit 0
  fi

  # 取一行可读的错误信息
  err_line="$(printf '%s' "$LAUNCH_OUT" | grep -oP '"message"\s*:\s*"\K[^"]+' | head -1 \
              || printf '%s' "$LAUNCH_OUT" | grep -vE '^\s*[{[]' | grep -v '^\s*$' | head -1 || true)"
  echo "  → ${err_line:-$(printf '%s' "$LAUNCH_OUT" | tr '\n' ' ' | cut -c1-160)}"

  if is_stop_error "$LAUNCH_OUT"; then
    warn "该错误不在可重试范围（多为配额已满或配置问题），脚本停止。"
    exit 1
  fi

  if is_retry_error "$LAUNCH_OUT"; then
    if (( ONCE == 1 )); then
      info "--once 模式：本次容量不足，退出码 3。"
      exit 3
    fi
    ad_idx=$(( (ad_idx + 1) % ${#ADS[@]} ))
    wait_between_attempts
    continue
  fi

  warn "未知错误（不在可重试列表），脚本停止以便排查。"
  exit 1
done