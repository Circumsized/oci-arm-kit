#!/usr/bin/env bash
#===============================================================================
# oci-arm-catcher.sh — 甲骨文云 Always Free ARM 实例抢购核心脚本（独立运行版）
#
# 支持双执行引擎：
#   1. Direct Launch 模式（默认）:
#      直接调用 `oci compute instance launch` 创建实例，自动轮换可用性域（AD）。
#   2. Stack Apply 模式（传入 --stack-id 或配置 STACK_OCID / STACK_ID 时启用）:
#      调用 Oracle Resource Manager 核心命令：
#      `oci resource-manager job create-apply-job --stack-id "$STACK_OCID" --execution-plan-strategy AUTO_APPROVED`
#      自动等待作业执行结果，失败退避重试，成功退出。
#
# 运行策略:
#   · 容量不足/瞬时故障类错误 → 等待 RETRY_INTERVAL 后重试（Direct 模式下轮换 AD）
#   · 配额已满/配置错误类错误 → 立即停止并写明原因（不做无谓重试）
#   · 创建成功 → 打印实例/作业 OCID 并退出（0），不会重复创建
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
#   --stack-id OCID   启用 Stack 模式，直接执行已创建的 Resource Manager Stack
#   --env-file FILE   指定配置文件
#   --name NAME       实例显示名（默认 arm-free-1，Direct 模式生效）
#   --ocpus N         实例 OCPU 数（默认 2，Direct 模式生效）
#   --memory N        实例内存 GB（默认 12，Direct 模式生效）
#   --interval SEC    重试间隔秒数（默认 300，低于 300 可能触发限流）
#   --once            只尝试一次：成功 0 / 容量不足 3 / 其他错误 1（适合 Agent 巡检）
#   -h, --help        显示本帮助
#   -V, --version     显示版本号
#
# 配置项（.env 键名）:
#   【Direct 模式必填】
#     COMPARTMENT_ID        租户 OCID（根区间）或子区间 OCID
#     SSH_KEY_FILE          实例 SSH 公钥路径（.pub）
#     SUBNET_ID             允许公网 IP 的公有子网 OCID
#     IMAGE_ID              aarch64 镜像 OCID
#     AVAILABILITY_DOMAIN   单个可用性域；或 AVAILABILITY_DOMAINS 逗号分隔（轮换）
#   【Stack 模式必填】
#     STACK_OCID 或 STACK_ID   Resource Manager Stack OCID（ocid1.ormstack. 开头）
#   【通用可选】
#     DISPLAY_NAME(arm-free-1) OCPUS(2) MEMORY_GB(12) RETRY_INTERVAL(300)
#
# 退出码: 0 成功；1 配置错误/不可重试错误；2 参数错误；3 --once 模式容量不足
#===============================================================================

set -Eeuo pipefail

VERSION="1.1.0"
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
RETRY_RE='out of host capacity|out of capacity|InternalError|TooManyRequests|ServiceUnavailable|Service Unavailable|timed out|RequestException|ConnectionError|Temporary failure|FAILED|Job failed'

is_stop_error()  { printf '%s' "$1" | grep -qiE "$STOP_RE"; }
is_retry_error() { printf '%s' "$1" | grep -qiE "$RETRY_RE"; }

# ── 参数解析 ──────────────────────────────────────────────────────────────────
ENV_FILE=""
CLI_NAME=""; CLI_OCPUS=""; CLI_MEMORY=""; CLI_INTERVAL=""
CLI_STACK_ID=""
ONCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-id) CLI_STACK_ID="${2:?缺少 OCID 参数}"; shift 2 ;;
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
CONFIG_KEYS=(STACK_ID STACK_OCID COMPARTMENT_ID DISPLAY_NAME SSH_KEY_FILE AVAILABILITY_DOMAIN AVAILABILITY_DOMAINS SUBNET_ID IMAGE_ID OCPUS MEMORY_GB RETRY_INTERVAL)
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
[[ -n "$CLI_STACK_ID" ]] && STACK_ID="$CLI_STACK_ID"
[[ -n "$CLI_NAME" ]]     && DISPLAY_NAME="$CLI_NAME"
[[ -n "$CLI_OCPUS" ]]    && OCPUS="$CLI_OCPUS"
[[ -n "$CLI_MEMORY" ]]   && MEMORY_GB="$CLI_MEMORY"
[[ -n "$CLI_INTERVAL" ]] && RETRY_INTERVAL="$CLI_INTERVAL"
STACK_ID="${STACK_ID:-${STACK_OCID:-}}"
DISPLAY_NAME="${DISPLAY_NAME:-arm-free-1}"; OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}";              RETRY_INTERVAL="${RETRY_INTERVAL:-300}"

# 基础命令检查
command -v oci >/dev/null 2>&1 || die "未找到 oci 命令（OCI CLI）——请先安装，见 README"
command -v python3 >/dev/null 2>&1 || die "未找到 python3（用于解析返回结果）"
[[ "$OCPUS" =~ ^[0-9]+$ ]] && [[ "$MEMORY_GB" =~ ^[0-9]+$ && "$RETRY_INTERVAL" =~ ^[0-9]+$ ]] || die "OCPUS/MEMORY_GB/RETRY_INTERVAL 必须是数字"
(( RETRY_INTERVAL >= 60 )) || die "RETRY_INTERVAL 过小（建议 >=300）"
(( RETRY_INTERVAL >= 300 )) || warn "RETRY_INTERVAL=$RETRY_INTERVAL 秒，低于 300 可能触发限流"

# ── 模式判断与输入补全 ───────────────────────────────────────────────────────
ask() {
  local var="$1" prompt="$2" val="${!1:-}"
  if [[ -z "$val" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "  $prompt: " val
      printf -v "$var" '%s' "$val"
    fi
  fi
}

declare -a ADS=()
MODE="direct"

if [[ -n "$STACK_ID" ]]; then
  MODE="stack"
  [[ "$STACK_ID" == ocid1.ormstack.* ]] || die "STACK_ID 格式不对（应以 ocid1.ormstack. 开头）"
else
  # Direct 模式：补全与校验
  ask COMPARTMENT_ID "COMPARTMENT_ID （控制台→头像→租户→租户详细信息页的 OCID，ocid1.tenancy. 开头）"
  ask SSH_KEY_FILE   "SSH_KEY_FILE   （实例登录公钥路径，如 ~/.ssh/id_ed25519.pub）"
  ask SUBNET_ID      "SUBNET_ID      （公有子网 OCID，ocid1.subnet. 开头，需允许公网 IP）"
  ask IMAGE_ID       "IMAGE_ID       （aarch64 镜像 OCID，ocid1.image. 开头）"
  if [[ -z "${AVAILABILITY_DOMAINS:-}" && -z "${AVAILABILITY_DOMAIN:-}" ]]; then
    ask AVAILABILITY_DOMAIN "AVAILABILITY_DOMAIN （可用性域，如 XXXX:PHX-AD-1；多个用逗号分隔填 AVAILABILITY_DOMAINS）"
  fi

  missing=()
  [[ -n "${COMPARTMENT_ID:-}" ]] || missing+=("COMPARTMENT_ID")
  [[ -n "${SSH_KEY_FILE:-}"   ]] || missing+=("SSH_KEY_FILE")
  [[ -n "${SUBNET_ID:-}"      ]] || missing+=("SUBNET_ID")
  [[ -n "${IMAGE_ID:-}"       ]] || missing+=("IMAGE_ID")
  (( ${#missing[@]} == 0 )) || die "缺少必填配置: ${missing[*]}（可写入 .env、用交互模式提供，或使用 --stack-id 切换为 Stack 模式）"
  [[ -z "${AVAILABILITY_DOMAINS:-}" && -z "${AVAILABILITY_DOMAIN:-}" ]] && die "缺少 AVAILABILITY_DOMAIN 或 AVAILABILITY_DOMAINS"
  [[ "$COMPARTMENT_ID" == ocid1.tenancy.* || "$COMPARTMENT_ID" == ocid1.compartment.* ]] || die "COMPARTMENT_ID 格式不对"
  [[ "$SUBNET_ID" == ocid1.subnet.* ]] || die "SUBNET_ID 格式不对"
  [[ "$IMAGE_ID"  == ocid1.image.*  ]] || die "IMAGE_ID 格式不对"
  SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
  [[ -f "$SSH_KEY_FILE" ]] || die "SSH 公钥文件不存在: $SSH_KEY_FILE"

  if [[ -n "${AVAILABILITY_DOMAINS:-}" ]]; then
    IFS=',' read -ra raw_ads <<< "$AVAILABILITY_DOMAINS"
    for a in "${raw_ads[@]}"; do
      a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
      [[ -n "$a" ]] && ADS+=("$a")
    done
  else
    ADS=("$AVAILABILITY_DOMAIN")
  fi
  (( ${#ADS[@]} > 0 )) || die "可用性域列表为空"
fi

# ── 执行函数 ──────────────────────────────────────────────────────────────────
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

# 模式 1：Direct Launch (Compute API)
attempt_launch_direct() {
  local ad="$1"
  local rc=0
  RUN_OUT="$(oci compute instance launch \
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

# 模式 2：Stack Apply (Resource Manager API)
# 核心命令：
# oci resource-manager job create-apply-job --stack-id "$STACK_ID" --execution-plan-strategy AUTO_APPROVED
attempt_launch_stack() {
  local rc=0
  RUN_OUT="$(oci resource-manager job create-apply-job \
    --stack-id                 "$STACK_ID" \
    --execution-plan-strategy  AUTO_APPROVED \
    --wait-for-state           SUCCEEDED \
    --wait-for-state           FAILED \
    --wait-interval-seconds    10 \
    --max-wait-seconds         300 \
    --no-retry 2>&1)" || rc=$?

  # 如果返回 JSON 且状态为 SUCCEEDED，视为成功
  if printf '%s' "$RUN_OUT" | grep -qi '"lifecycle-state":\s*"SUCCEEDED"'; then
    return 0
  fi
  return "$rc"
}

target_id_from() {
  printf '%s' "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null \
    || printf '%s' "$1" | grep -oP 'ocid1\.(instance|ormjob)\.[A-Za-z0-9._-]+' | head -1 || echo "unknown"
}

printf '\n%soci-arm-catcher.sh v%s%s\n' "$c_bld" "$VERSION" "$c_rst"
if [[ "$MODE" == "stack" ]]; then
  info "模式: Stack Apply (Resource Manager)"
  info "Stack OCID: $STACK_ID | 重试间隔 ${RETRY_INTERVAL}s"
else
  info "模式: Direct Launch (Compute API)"
  info "实例: $DISPLAY_NAME | $SHAPE | $OCPUS OCPU / ${MEMORY_GB}GB | 重试间隔 ${RETRY_INTERVAL}s"
  info "可用性域（轮换）: ${ADS[*]}"
fi

attempt=0; ad_idx=0; RUN_OUT=""
while true; do
  attempt=$(( attempt + 1 ))

  if [[ "$MODE" == "stack" ]]; then
    info "[$(date '+%F %T')] 第 $attempt 次尝试 Stack Apply..."
    if attempt_launch_stack; then
      jid="$(target_id_from "$RUN_OUT")"
      printf '\n%s  SUCCESS! Stack Apply 成功执行: %s%s\n' "$c_grn" "$jid" "$c_rst"
      info "资源堆栈已成功应用，实例已创建。请到控制台 Compute→Instances 确认并登录。"
      exit 0
    fi
  else
    ad="${ADS[$ad_idx]}"
    info "[$(date '+%F %T')] 第 $attempt 次尝试（AD: $ad）"
    if attempt_launch_direct "$ad"; then
      iid="$(target_id_from "$RUN_OUT")"
      printf '\n%s  SUCCESS! Instance created: %s%s\n' "$c_grn" "$iid" "$c_rst"
      info "实例已创建，脚本退出。请到控制台 Compute→Instances 查看，并用私钥登录。"
      exit 0
    fi
  fi

  # 取一行可读的错误信息
  err_line="$(printf '%s' "$RUN_OUT" | grep -oP '"message"\s*:\s*"\K[^"]+' | head -1 \
              || printf '%s' "$RUN_OUT" | grep -vE '^\s*[{[]' | grep -v '^\s*$' | head -1 || true)"
  echo "  → ${err_line:-$(printf '%s' "$RUN_OUT" | tr '\n' ' ' | cut -c1-160)}"

  if is_stop_error "$RUN_OUT"; then
    warn "该错误不在可重试范围（多为配额已满或配置问题），脚本停止。"
    exit 1
  fi

  if is_retry_error "$RUN_OUT"; then
    if (( ONCE == 1 )); then
      info "--once 模式：本次容量不足，退出码 3。"
      exit 3
    fi
    if [[ "$MODE" == "direct" ]]; then
      ad_idx=$(( (ad_idx + 1) % ${#ADS[@]} ))
    fi
    wait_between_attempts
    continue
  fi

  warn "未知错误（不在可重试列表），脚本停止以便排查。"
  exit 1
done