#!/usr/bin/env bash
#===============================================================================
# arm-free-catcher.sh — 甲骨文云 Always Free 实例抢购核心脚本（v4.0.0）
#
# 演进（相对 v3.x oci-arm-catcher.sh）：
#   · 两层循环：内层连续遍历全部 AD（AD_GAP 短间隔），外层整体退避 ±10% 抖动
#     ——修复"AD 轮换与重试间隔绑定，每 15 分钟才换 AD"（oci-arm-kit#1）
#   · 异步成功判定：launch 只保证 accepted，随后轮询实例状态至 RUNNING 才判成功
#     ——修复"launch 返回码 0 即算成功"的假成功（oci-arm-kit#2）
#   · 错误码优先双轨分类：解析 OCI 标准错误码（"code": "OutOfCapacity"），
#     429 单独指数退避不计失败，文本仅兜底（oci-arm-kit#4）
#   · 容量探针：发起前先查 compute-capacity-report，筛除明显不可用的 AD/shape
#   · 保活与通知：内置日志落盘+轮换、webhook 通知、--once 单次语义（配 cron 自愈）
#   · 工程化：--dry-run、--boot-volume-size、--user-data-file、退出码语义化
#
# 运行策略：
#   · 容量不足/瞬时故障（OutOfCapacity/InternalError/429/5xx）→ 继续重试
#   · 配额/权限/参数错误（LimitExceeded/InvalidParameter…）→ 立即停止并写明原因
#   · 创建成功（实例 RUNNING 且拿到公网 IP）→ 打印信息、通知、退出 0
#
# 配置来源（优先级从高到低）：命令行 > 环境变量 > --env-file/默认 .env > 交互
#
# 用法:
#   ./arm-free-catcher.sh [选项]
#
# 选项:
#   --env-file FILE   指定配置文件（默认依次查找 ./.env、脚本同目录/.env）
#   --name NAME       实例显示名（默认 arm-free-1）
#   --shape SHAPE     实例规格（默认 VM.Standard.A1.Flex）
#   --ocpus N         Flex 规格 OCPU（默认 2）
#   --memory N        Flex 规格内存 GB（默认 12）
#   --ad-gap SEC      AD 间短间隔（默认 16，社区实证安全值，>=5）
#   --interval SEC    外层退避基数（默认 300，实际加 ±10% 抖动）
#   --max-attempts N  最大外层轮数（默认 0=无限）
#   --poll-timeout SEC 单实例异步轮询超时（默认 300）
#   --boot-volume-size N  boot volume GB（默认不传，用镜像默认）
#   --user-data-file F   cloud-init user-data 文件路径
#   --no-probe        关闭容量探针（默认开启）
#   --async           异步模式（默认）：launch 后自行轮询至 RUNNING
#   --once            单轮语义：遍历全部 AD 各试一次，成功 0 / 容量不足 3
#   --dry-run         只校验配置与认证，打印将执行的命令，退出 4
#   --stack-id OCID   Stack Apply 模式（Resource Manager）
#   -h, --help        显示本帮助
#   -V, --version     显示版本号
#
# 配置项（.env 键名，同选项名大写）:
#   COMPARTMENT_ID DISPLAY_NAME SSH_KEY_FILE SUBNET_ID IMAGE_ID SHAPE
#   AVAILABILITY_DOMAIN(S) AD_GAP RETRY_INTERVAL POLL_TIMEOUT
#   BOOT_VOLUME_SIZE USER_DATA_FILE NOTIFY_WEBHOOK NOTIFY_TYPE LOG_FILE
#
# 退出码: 0 成功；1 配置错误/不可重试错误；2 参数错误；3 --once 无容量；4 dry-run
#===============================================================================

set -Eeuo pipefail

VERSION="4.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 输出 / 日志 ────────────────────────────────────────────────────────────────
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/catcher.log}"
LOG_MAX_BYTES=$((10 * 1024 * 1024))

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local sz; sz=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  (( sz > LOG_MAX_BYTES )) && mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
}
log() {   # log LEVEL msg... — 同时写 stdout 与日志文件
  local lvl="$1"; shift
  local line="[$(_ts)] [$lvl] $*"
  printf '%s\n' "$line"
  _rotate_log
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}
info() { log INFO "$@"; }
ok()   { log OK   "$@"; }
warn() { log WARN "$@"; }
die()  { log ERROR "$@"; exit 1; }

# ── 通知（webhook，失败只 warn 不影响主流程）───────────────────────────────────
notify() {
  local title="$1" body="$2"
  [[ -n "${NOTIFY_WEBHOOK:-}" ]] || return 0
  local text="$title
$body"
  local payload
  case "${NOTIFY_TYPE:-feishu}" in
    feishu)    payload=$(printf '{"msg_type":"text","content":{"text":"%s"}}' "$(printf '%s' "$text" | sed 's/"/\\"/g' | tr '\n' '\\n')") ;;
    telegram)  payload=$(printf '{"chat_id":"%s","text":"%s"}}' "${NOTIFY_CHAT_ID:--1}" "$(printf '%s' "$text" | sed 's/"/\\"/g' | tr '\n' '\\n')")" ;;
    serverchan) payload=$(printf '{"title":"%s","desp":"%s"}' "$(printf '%s' "$title" | sed 's/"/\\"/g')" "$(printf '%s' "$body" | sed 's/"/\\"/g' | tr '\n' '\\n')")" ;;
    *)         payload="$text" ;;
  esac
  curl -s -m 10 -X POST -H 'Content-Type: application/json' -d "$payload" "$NOTIFY_WEBHOOK" >/dev/null 2>&1 \
    || warn "通知发送失败（不影响抢购）: $NOTIFY_WEBHOOK"
}

usage() { awk 'NR<=2{next} /^#={5,}/{exit} /^#/{sub(/^# ?/,""); print}' "$0"; exit 0; }

# ── 参数解析 ──────────────────────────────────────────────────────────────────
ENV_FILE=""; STACK_ID="${STACK_ID:-}"
CLI_NAME=""; CLI_SHAPE=""; CLI_OCPUS=""; CLI_MEMORY=""
CLI_AD_GAP=""; CLI_INTERVAL=""; CLI_POLL=""; CLI_MAX_ATTEMPTS=""
CLI_BOOT_SIZE=""; CLI_USER_DATA=""
NO_PROBE=0; ONCE=0; DRY_RUN=0; ASYNC_MODE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)      ENV_FILE="${2:?缺少 FILE 参数}"; shift 2 ;;
    --stack-id)      STACK_ID="${2:?缺少 OCID 参数}"; shift 2 ;;
    --name)          CLI_NAME="${2:?缺少 NAME 参数}"; shift 2 ;;
    --shape)         CLI_SHAPE="${2:?缺少 SHAPE 参数}"; shift 2 ;;
    --ocpus)         CLI_OCPUS="${2:?缺少 N 参数}"; shift 2 ;;
    --memory)        CLI_MEMORY="${2:?缺少 N 参数}"; shift 2 ;;
    --ad-gap)        CLI_AD_GAP="${2:?缺少 SEC 参数}"; shift 2 ;;
    --interval)      CLI_INTERVAL="${2:?缺少 SEC 参数}"; shift 2 ;;
    --poll-timeout)  CLI_POLL="${2:?缺少 SEC 参数}"; shift 2 ;;
    --max-attempts)  CLI_MAX_ATTEMPTS="${2:?缺少 N 参数}"; shift 2 ;;
    --boot-volume-size) CLI_BOOT_SIZE="${2:?缺少 N 参数}"; shift 2 ;;
    --user-data-file)   CLI_USER_DATA="${2:?缺少 FILE 参数}"; shift 2 ;;
    --no-probe)      NO_PROBE=1; shift ;;
    --sync)          ASYNC_MODE=0; shift ;;
    --async)         ASYNC_MODE=1; shift ;;
    --once)          ONCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage ;;
    -V|--version)    echo "arm-free-catcher.sh $VERSION"; exit 0 ;;
    *) echo "未知参数: $1（-h 查看用法）" >&2; exit 2 ;;
  esac
done

# ── 配置读取：环境变量 > 配置文件 > 交互 ──────────────────────────────────────
CONFIG_KEYS=(STACK_ID COMPARTMENT_ID DISPLAY_NAME SSH_KEY_FILE AVAILABILITY_DOMAIN
             AVAILABILITY_DOMAINS SUBNET_ID IMAGE_ID SHAPE OCPUS MEMORY_GB
             AD_GAP RETRY_INTERVAL POLL_TIMEOUT MAX_ATTEMPTS BOOT_VOLUME_SIZE
             USER_DATA_FILE NOTIFY_WEBHOOK NOTIFY_TYPE NOTIFY_CHAT_ID LOG_FILE)
declare -A PRESET=()
for k in "${CONFIG_KEYS[@]}"; do
  [[ -n "${!k:-}" ]] && PRESET[$k]="${!k}"
done

loaded=""
if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || die "配置文件不存在: $ENV_FILE"
  loaded="$ENV_FILE"
else
  for f in "./.env" "$SCRIPT_DIR/.env"; do
    [[ -f "$f" ]] && { loaded="$f"; break; }
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
[[ -n "$CLI_SHAPE" ]]    && SHAPE="$CLI_SHAPE"
[[ -n "$CLI_OCPUS" ]]    && OCPUS="$CLI_OCPUS"
[[ -n "$CLI_MEMORY" ]]   && MEMORY_GB="$CLI_MEMORY"
[[ -n "$CLI_AD_GAP" ]]   && AD_GAP="$CLI_AD_GAP"
[[ -n "$CLI_INTERVAL" ]] && RETRY_INTERVAL="$CLI_INTERVAL"
[[ -n "$CLI_POLL" ]]     && POLL_TIMEOUT="$CLI_POLL"
[[ -n "$CLI_MAX_ATTEMPTS" ]] && MAX_ATTEMPTS="$CLI_MAX_ATTEMPTS"
[[ -n "$CLI_BOOT_SIZE" ]] && BOOT_VOLUME_SIZE="$CLI_BOOT_SIZE"
[[ -n "$CLI_USER_DATA" ]] && USER_DATA_FILE="$CLI_USER_DATA"

SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
DISPLAY_NAME="${DISPLAY_NAME:-arm-free-1}"
OCPUS="${OCPUS:-2}"; MEMORY_GB="${MEMORY_GB:-12}"
AD_GAP="${AD_GAP:-16}"; RETRY_INTERVAL="${RETRY_INTERVAL:-300}"   # AD_GAP 16s = hitrov/oci-arm-host-capacity 生产实证值；外层 300s = deeplabua 默认(polite)
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"; MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"

# 基础检查（非交互 shell 常见 ~/.local/bin 不在 PATH，先自愈）
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
command -v oci >/dev/null 2>&1 || die "未找到 oci 命令（OCI CLI）"
# python3 优先，回退 python（Windows Git Bash 常只有 python.exe）
PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || die "未找到 python3/python"
command -v curl >/dev/null 2>&1 || die "未找到 curl（通知功能需要）"

# 全局锁：防同机多入口并发（systemd + cron + 手动同时跑会超额创建）
# dry-run 跳过锁检查（诊断优先）
acquire_lock() {
  command -v flock >/dev/null 2>&1 || { warn "flock 不可用，全局锁降级跳过"; return 0; }
  LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/.catcher.lock}"
  exec 9>"$LOCK_FILE" || { warn "无法打开锁文件 $LOCK_FILE，跳过"; return 0; }
  flock -n 9 || die "另一抢购进程持有锁（$LOCK_FILE）——防重创建保护。确认无其他进程在跑后删除该文件重试。"
  ok "已获取全局锁: $LOCK_FILE"
}
[[ "$DRY_RUN" -eq 1 ]] || acquire_lock
[[ "$OCPUS" =~ ^[0-9]+$ && "$MEMORY_GB" =~ ^[0-9]+$ ]] || die "OCPUS/MEMORY_GB 必须是数字"
[[ "$AD_GAP" =~ ^[0-9]+$ && "$RETRY_INTERVAL" =~ ^[0-9]+$ && "$POLL_TIMEOUT" =~ ^[0-9]+$ ]] \
  || die "AD_GAP/RETRY_INTERVAL/POLL_TIMEOUT 必须是数字"
(( AD_GAP >= 5 )) || die "AD_GAP 过小（建议 >=5，避免触发限流）"
(( RETRY_INTERVAL >= 60 )) || die "RETRY_INTERVAL 过小（建议 >=300）"
[[ -z "${BOOT_VOLUME_SIZE:-}" || "$BOOT_VOLUME_SIZE" =~ ^[0-9]+$ ]] || die "BOOT_VOLUME_SIZE 必须是数字"

# ── 模式判断与输入补全 ────────────────────────────────────────────────────────
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
  ask COMPARTMENT_ID "COMPARTMENT_ID （租户 OCID，ocid1.tenancy. 开头）"
  ask SSH_KEY_FILE   "SSH_KEY_FILE   （实例登录公钥路径，如 ~/.ssh/id_ed25519.pub）"
  ask SUBNET_ID      "SUBNET_ID      （公有子网 OCID，ocid1.subnet. 开头）"
  ask IMAGE_ID       "IMAGE_ID       （镜像 OCID，ocid1.image. 开头）"
  if [[ -z "${AVAILABILITY_DOMAINS:-}" && -z "${AVAILABILITY_DOMAIN:-}" ]]; then
    ask AVAILABILITY_DOMAIN "AVAILABILITY_DOMAIN （如 XXXX:PHX-AD-1；多个用逗号填 AVAILABILITY_DOMAINS）"
  fi
  missing=()
  [[ -n "${COMPARTMENT_ID:-}" ]] || missing+=("COMPARTMENT_ID")
  [[ -n "${SSH_KEY_FILE:-}"   ]] || missing+=("SSH_KEY_FILE")
  [[ -n "${SUBNET_ID:-}"      ]] || missing+=("SUBNET_ID")
  [[ -n "${IMAGE_ID:-}"       ]] || missing+=("IMAGE_ID")
  (( ${#missing[@]} == 0 )) || die "缺少必填配置: ${missing[*]}"
  [[ -z "${AVAILABILITY_DOMAINS:-}" && -z "${AVAILABILITY_DOMAIN:-}" ]] && die "缺少 AVAILABILITY_DOMAIN 或 AVAILABILITY_DOMAINS"
  [[ "$COMPARTMENT_ID" == ocid1.tenancy.* || "$COMPARTMENT_ID" == ocid1.compartment.* ]] || die "COMPARTMENT_ID 格式不对"
  [[ "$SUBNET_ID" == ocid1.subnet.* ]] || die "SUBNET_ID 格式不对"
  [[ "$IMAGE_ID"  == ocid1.image.*  ]] || die "IMAGE_ID 格式不对"
  SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
  [[ -f "$SSH_KEY_FILE" ]] || die "SSH 公钥文件不存在: $SSH_KEY_FILE"
  [[ -z "${USER_DATA_FILE:-}" || -f "${USER_DATA_FILE/#\~/$HOME}" ]] || die "USER_DATA_FILE 不存在: $USER_DATA_FILE"
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

# ── 错误分类（错误码优先，文本兜底）────────────────────────────────────────────
# OCI 官方 API Errors 表口径：429/409-IncorrectState/500/503 → "Yes, with backoff."；
# 400 LimitExceeded → 不可重试。容量不足在控制面表现为 500 + code=OutOfCapacity。
err_code_of() { printf '%s' "$1" | grep -oP '"code"\s*:\s*"\K[^"]+' | head -1 || true; }
err_msg_of() {
  printf '%s' "$1" | grep -oP '"message"\s*:\s*"\K[^"]+' | head -1 \
    || printf '%s' "$1" | grep -vE '^\s*[{[]' | grep -v '^\s*$' | head -1 || true
}
# 不可重试（配额/权限/参数）——错误码
STOP_CODES='LimitExceeded|NotAuthorizedOrNotFound|NotAuthenticated|InvalidParameter|CannotParseRequest|NotAllowed|MissingParameter|IncorrectState'
# 可重试（容量/限流/瞬时）——错误码
RETRY_CODES='OutOfCapacity|InternalError|TooManyRequests|ServiceUnavailable|RequestTimeout|ServiceError|WorkRequestCanceled'
# 文本兜底（收紧：不再裸匹配 FAILED）
STOP_RE='[Ll]imit for this tenancy|limit[s]? .*exceeded|out of quota|QuotaExceeded|NotAuthorizedOrNotFound|NotAuthenticated'
RETRY_RE='out of host capacity|out of capacity|InternalError|ServiceUnavailable|Service Unavailable'
# 网络层特征（HTTP 请求根本没到达/没返回——launch 可能已受理）
NETWORK_RE='timed out|RequestException|ConnectionError|Temporary failure|Max retries exceeded|could not connect|Network is unreachable'

classify() {  # classify OUTPUT → 返回 retry|stop|throttle|network|unknown
  local out="$1" code
  code="$(err_code_of "$out")"
  case "$code" in
    TooManyRequests) echo throttle; return ;;
    LimitExceeded|NotAuthorizedOrNotFound|NotAuthenticated|InvalidParameter|CannotParseRequest|NotAllowed|MissingParameter)
      echo stop; return ;;
    OutOfCapacity|InternalError|ServiceUnavailable|RequestTimeout|ServiceError|WorkRequestCanceled)
      echo retry; return ;;
  esac
  # 4xx 但 message 是容量类（OCI 偶有此行为）→ 可重试
  if printf '%s' "$out" | grep -qiE 'out of (host )?capacity' && ! printf '%s' "$out" | grep -qiE "$STOP_RE"; then
    echo retry; return
  fi
  # 网络层：无错误码、请求未达 OCI——launch 可能已成功，须同 AD 先查后试
  if printf '%s' "$out" | grep -qiE "$NETWORK_RE"; then echo network; return; fi
  if printf '%s' "$out" | grep -qiE "$STOP_RE"; then echo stop; return; fi
  if printf '%s' "$out" | grep -qiE "$RETRY_RE"; then echo retry; return; fi
  echo unknown
}

throttle_backoff() {  # 429 专用：指数退避 1s→60s（官方"数秒起最长 60 秒"）
  local w=1
  while (( w <= 60 )); do
    warn "触发限流(429)，退避 ${w}s …"
    sleep "$w" 9>&-   # 9>&-：sleep 子进程不继承锁 fd（防父进程被杀后孤儿 sleep 持锁）
    w=$(( w * 2 ))
  done
  warn "限流退避完成，继续重试"
}

# ── 容量探针（只读；筛除明显不可用的 AD/shape，非充分判据）─────────────────────
probe_ad() {
  local ad="$1"
  [[ "$NO_PROBE" -eq 1 ]] && return 0
  local out status shape_cfg=""
  # flex 规格的容量报告必须带 shape-config，否则报 InvalidParameter
  if [[ "$SHAPE" == *.Flex ]]; then
    shape_cfg=",\"instance-shape-config\":{\"ocpus\":$OCPUS,\"memory-in-gbs\":$MEMORY_GB}"
  fi
  out=$(oci compute compute-capacity-report create \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$ad" \
    --shape-availabilities "[{\"instance-shape\":\"$SHAPE\"$shape_cfg}]" \
    --connection-timeout 30 --read-timeout 60 --no-retry 2>&1) || true
  status=$(printf '%s' "$out" | grep -oP '"availability-status"\s*:\s*"\K[^"]+' | head -1 || true)
  if [[ "$status" == "AVAILABLE" ]]; then
    info "探针 $ad: AVAILABLE"
    return 0
  fi
  info "探针 $ad: ${status:-无响应}（本轮跳过）"
  return 1
}

# ── launch 与异步成功判定 ─────────────────────────────────────────────────────
build_launch_args() {   # 填充全局数组 LAUNCH_CMD（直接执行，避开管道续行陷阱）
  local ad="$1"
  LAUNCH_CMD=(oci compute instance launch
    --compartment-id "$COMPARTMENT_ID"
    --availability-domain "$ad"
    --display-name "$DISPLAY_NAME"
    --shape "$SHAPE"
    --image-id "$IMAGE_ID"
    --subnet-id "$SUBNET_ID"
    --ssh-authorized-keys-file "$SSH_KEY_FILE"
    --assign-public-ip true
    --no-retry)
  # Flex 规格才接受 shape-config；micro 等固定规格传了报 InvalidParameter
  [[ "$SHAPE" == *.Flex ]] && LAUNCH_CMD+=(--shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}")
  [[ -n "${BOOT_VOLUME_SIZE:-}" ]] && LAUNCH_CMD+=(--boot-volume-size-in-gbs "$BOOT_VOLUME_SIZE")
  [[ -n "${USER_DATA_FILE:-}" ]] && LAUNCH_CMD+=(--user-data-file "${USER_DATA_FILE/#\~/$HOME}")
  return 0   # 防止末尾条件短路返回 1 被调用处 set -e 捕获
}

instance_id_of() {
  printf '%s' "$1" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null \
    || printf '%s' "$1" | grep -oP 'ocid1\.instance\.[A-Za-z0-9._-]+' | head -1 || true
}

instance_state() {
  oci compute instance get --instance-id "$1" --output json 2>/dev/null \
    | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["data"]["lifecycle-state"])' 2>/dev/null || echo UNKNOWN
}

public_ip_of() {
  oci compute instance list-vnics --instance-id "$1" --output json 2>/dev/null \
    | "$PY" -c 'import sys,json
v=json.load(sys.stdin)["data"]
print(v[0]["public-ip"] if v and v[0].get("public-ip") else "")' 2>/dev/null || true
}

# 异步判定：轮询实例状态至 RUNNING（成功）/TERMINATED|FAILED（容量类失败）
# 轮询间隔 5s→10s→20s 退避，总时长受 POLL_TIMEOUT 封顶
await_running() {
  local iid="$1" waited=0 gap=5 state
  while (( waited < POLL_TIMEOUT )); do
    state="$(instance_state "$iid")"
    case "$state" in
      RUNNING) return 0 ;;
      TERMINATED|FAILED|TERMINATING)
        warn "实例 $iid 进入 $state（provisioning 被拒/失败，按容量类处理）"
        RUN_OUT="{\"code\":\"OutOfCapacity\",\"message\":\"instance $iid entered $state during provisioning\"}"
        return 1 ;;
      *) : ;;  # PROVISIONING/STARTING 等继续等
    esac
    sleep "$gap" 9>&-
    waited=$(( waited + gap ))
    gap=$(( gap < 20 ? gap * 2 : 20 ))
  done
  warn "轮询超时（${POLL_TIMEOUT}s）：实例 $iid 仍未 RUNNING（state=$state）"
  return 1
}

launch_and_await() {
  local ad="$1" out rc=0 iid state
  info "发起创建（AD: $ad，异步模式）…"
  build_launch_args "$ad"
  out="$("${LAUNCH_CMD[@]}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    RUN_OUT="$out"
    return 1
  fi
  iid="$(instance_id_of "$out")"
  [[ -n "$iid" ]] || { RUN_OUT="$out"; warn "无法解析 instance OCID"; return 1; }
  RUN_OUT="$out"
  info "创建请求已受理: $iid，开始轮询（异步判定）…"
  if await_running "$iid"; then
    LAUNCHED_ID="$iid"
    return 0
  fi
  return 1
}

attempt_launch_stack() {
  local rc=0
  RUN_OUT="$(oci resource-manager job create-apply-job \
    --stack-id "$STACK_ID" \
    --execution-plan-strategy AUTO_APPROVED \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED \
    --wait-interval-seconds 10 \
    --max-wait-seconds 600 \
    --no-retry 2>&1)" || rc=$?
  printf '%s' "$RUN_OUT" | grep -qi '"lifecycle-state":\s*"SUCCEEDED"' && return 0
  return "$rc"
}

succeed() {  # succeed AD —— 统一成功路径：打印 + 通知 + 退出 0
  local ad="$1" pub
  pub="$(public_ip_of "$LAUNCHED_ID")"
  ok "SUCCESS! 实例已创建并 RUNNING"
  ok "  OCID    : $LAUNCHED_ID"
  ok "  公网 IP : ${pub:-（VNIC 未就绪，稍后 oci compute instance list-vnics --instance-id $LAUNCHED_ID）}"
  ok "  登录    : ssh -i <私钥> ubuntu@${pub:-<ip>}（Ubuntu 镜像默认用户 ubuntu）"
  notify "oci-arm-kit 抢购成功 🎉" "实例 $DISPLAY_NAME 已创建（$ad）
OCID: $LAUNCHED_ID
公网 IP: ${pub:-pending}"
  exit 0
}

# ── dry-run：校验配置与认证，打印将执行的命令 ──────────────────────────────────
dry_run() {
  info "dry-run：校验配置（不发起创建）…"
  oci iam region list --output json >/dev/null 2>&1 || die "认证失败：oci iam region list 无响应（检查 ~/.oci/config）"
  ok "认证有效（oci iam region list 通）"
  if [[ "$MODE" == "stack" ]]; then
    info "Stack 模式，将执行: oci resource-manager job create-apply-job --stack-id $STACK_ID --execution-plan-strategy AUTO_APPROVED"
  else
    local ad
    for ad in "${ADS[@]}"; do
      probe_ad "$ad" || true
      build_launch_args "$ad"
      info "AD $ad 将执行:"
      printf '    %q ' "${LAUNCH_CMD[@]}"; echo
    done
  fi
  ok "dry-run 完成（退出码 4）。去掉 --dry-run 开始抢购。"
  exit 4
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
# 防重创建：同名实例已 RUNNING/PROVISIONING 则不重复发起（脚本重启/多入口部署场景）
preflight_existing() {
  [[ "$MODE" == "direct" ]] || return 0
  # ListInstances 不支持 lifecycle-state 服务端过滤，按 display-name 查后客户端过滤
  local existing
  existing=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_ID" \
    --display-name "$DISPLAY_NAME" \
    --output json 2>/dev/null \
    | "$PY" -c 'import sys,json
d=json.load(sys.stdin).get("data",[])
live=[i for i in d if i.get("lifecycle-state") in ("RUNNING","PROVISIONING")]
print(live[0]["id"] if live else "")' 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    local ip
    ip="$(public_ip_of "$existing")"
    ok "已存在同名实例（RUNNING/PROVISIONING）: $existing"
    ok "  公网 IP: ${ip:-（查询中，稍后 list-vnics）}——防重创建，不重复发起"
    notify "oci-arm-kit：实例已存在" "$DISPLAY_NAME 已在运行: $existing
公网 IP: ${ip:-pending}"
    exit 0
  fi
  info "防重预检通过（无同名 RUNNING/PROVISIONING 实例）"
}

printf '\n%sarm-free-catcher.sh v%s（%s 模式）%s\n' "$c_bld" "$VERSION" "$MODE" "$c_rst"
info "规格: $SHAPE | AD 间 ${AD_GAP}s | 外层 ${RETRY_INTERVAL}s±10% | 轮询超时 ${POLL_TIMEOUT}s | 探针 $(( NO_PROBE ? 0 : 1 ))"

[[ "$DRY_RUN" -eq 1 ]] && dry_run
preflight_existing

attempt=0; sweep=0; RUN_OUT=""; LAUNCHED_ID=""
while true; do
  sweep=$(( sweep + 1 ))
  info "── 第 $sweep 轮 sweep（外层间隔将加 ±10% 抖动）──"

  if [[ "$MODE" == "stack" ]]; then
    attempt=$(( attempt + 1 ))
    if attempt_launch_stack; then
      jid="$(printf '%s' "$RUN_OUT" | grep -oP 'ocid1\.ormjob\.[A-Za-z0-9._-]+' | head -1 || true)"
      ok "SUCCESS! Stack Apply 成功: ${jid:-unknown}"
      notify "oci-arm-kit 抢购成功" "Stack apply 成功: ${jid:-unknown}"
      exit 0
    fi
    case "$(classify "$RUN_OUT")" in
      stop) die "不可重试错误（$(err_msg_of "$RUN_OUT")）" ;;
      throttle) throttle_backoff; continue ;;
      network)
        warn "网络类错误，2s 后重试"
        sleep 2 9>&-
        if attempt_launch_stack; then
          ok "SUCCESS! Stack Apply 成功"
          notify "oci-arm-kit Stack 抢购成功" "Stack $STACK_ID apply 成功"
          exit 0
        fi
        warn "重试仍失败: $(err_msg_of "$RUN_OUT")"
        if (( ONCE )); then exit 3; fi
        sleep $(( RETRY_INTERVAL + RANDOM % (RETRY_INTERVAL / 5) - RETRY_INTERVAL / 10 )) 9>&- 9>&-
        ;;
      retry|unknown)
        warn "本轮失败: $(err_msg_of "$RUN_OUT")"
        if (( ONCE )); then exit 3; fi
        if (( MAX_ATTEMPTS > 0 && sweep >= MAX_ATTEMPTS )); then
          warn "已达最大轮数 MAX_ATTEMPTS=$MAX_ATTEMPTS"; exit 3
        fi
        sleep $(( RETRY_INTERVAL + RANDOM % (RETRY_INTERVAL / 5) - RETRY_INTERVAL / 10 )) 9>&- 9>&-
        ;;
    esac
    continue
  fi

  for ad in "${ADS[@]}"; do
    attempt=$(( attempt + 1 ))
    info "[$(date -u '+%H:%M:%SZ')] sweep#$sweep 尝试 #$attempt（AD: $ad）"

    # 探针：明显不可用则跳过（省一次 create，降低限流面）
    if ! probe_ad "$ad"; then
      if (( ONCE )); then continue; fi
      sleep "$AD_GAP" 9>&-
      continue
    fi

    if launch_and_await "$ad"; then
      succeed "$ad"
    fi

    case "$(classify "$RUN_OUT")" in
      stop)
        die "不可重试错误（$(err_msg_of "$RUN_OUT")）——多为配额已满或配置问题" ;;
      throttle)
        throttle_backoff
        continue ;;
      network)
        # 网络类：launch 可能已受理只是响应丢失。等效 opc-retry-token 的 CLI 实现：
        # 不换 AD，先查防重（查到了=刚才已创建成功，收下），2s 后同 AD 重试一次
        warn "网络类错误（$(err_msg_of "$RUN_OUT")）——同 AD 先查后试"
        sleep 2 9>&-
        if launch_and_await "$ad"; then
          succeed "$ad"
        fi
        case "$(classify "$RUN_OUT")" in
          stop) die "不可重试错误（$(err_msg_of "$RUN_OUT")）——多为配额已满或配置问题" ;;
          throttle) throttle_backoff; continue ;;
          retry|unknown) warn "重试仍失败: $(err_msg_of "$RUN_OUT")" ;;
        esac
        ;;
      retry|unknown)
        warn "创建失败: $(err_msg_of "$RUN_OUT")"
        ;;
    esac
    if (( ONCE )); then continue; fi
    sleep "$AD_GAP"
  done

  if (( ONCE )); then
    warn "--once 模式：本轮无容量（尝试 $attempt 次）"
    exit 3
  fi
  if (( MAX_ATTEMPTS > 0 && sweep >= MAX_ATTEMPTS )); then
    warn "已达最大轮数 MAX_ATTEMPTS=$MAX_ATTEMPTS"
    exit 3
  fi
  # 外层退避：基数 + ±10% 随机抖动（错峰，避免整点撞限流）
  sleep $(( RETRY_INTERVAL + RANDOM % (RETRY_INTERVAL / 5) - RETRY_INTERVAL / 10 )) 9>&-
done
