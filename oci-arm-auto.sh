#!/usr/bin/env bash
#===============================================================================
# oci-arm-auto.sh — 甲骨文云 Always Free ARM 实例抢购：服务器端一键部署
#
# 在任意全新 Ubuntu/Debian 服务器上运行一次，自动完成：
#   1. 安装 OCI CLI（uv / pipx / venv 三种途径自动择一）
#   2. 在本机生成 API 密钥对（RSA 2048，私钥永不离开服务器）；支持 --key 复用现有私钥
#   3. 引导你在控制台"粘贴公钥"（全程唯一手动步骤，复制粘贴即可）
#   4. 写入 ~/.oci/config 并验证认证（失败可重试）
#   5. 自动查询：全部可用区（轮换重试）/ 公有子网 / 最新 Ubuntu ARM 镜像
#   6. 生成实例 SSH 密钥、安装抢购核心脚本（oci-arm-catcher.sh）、写入 .env（2 OCPU / 12GB / 300s）
#   7. nohup 后台启动抢购（断 SSH 继续运行）
#
# 用法:
#   bash oci-arm-auto.sh [选项]
#
# 选项:
#   --key FILE          使用已有 API 私钥（如从控制台下载的 .pem），自动计算指纹
#   --name NAME         实例显示名（默认 arm-free-1）
#   --ocpus N           实例 OCPU 数（默认 2，2026-06 起免费额度上限 2）
#   --memory N          实例内存 GB（默认 12，免费额度上限 12）
#   --interval SEC      重试间隔秒数（默认 300，过低可能触发限流）
#   --subnet OCID       指定子网（跳过自动查询）
#   --image OCID        指定镜像（跳过自动查询）
#   --os NAME           镜像操作系统（默认 "Canonical Ubuntu"；可传 "Oracle Linux"）
#   --noninteractive    非交互模式：所有输入必须来自环境变量，缺一即报错
#   --no-start          只完成安装与配置，不启动抢购进程
#   -h, --help          显示本帮助
#   -V, --version       显示版本号
#
# 环境变量（全自动模式必需）:
#   OCI_USER_OCID, OCI_TENANCY_OCID, OCI_REGION
#   OCI_PUBLIC_KEY_ADDED=yes   跳过"已粘贴公钥"的等待
#   （OCI_SUBNET_ID / OCI_IMAGE_ID / OCI_OS 可选，等价于 --subnet / --image / --os）
#   OCI_ARM_CATCHER_SRC=path   核心脚本来源（默认：与安装器同目录的 oci-arm-catcher.sh）
#
# 退出码: 0 成功；1 执行失败；2 参数错误
#===============================================================================

set -Eeuo pipefail

VERSION="3.0.0"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
info() { printf '%s\n' "${c_bld}==>${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}  ✓${c_rst} $*"; }
warn() { printf '%s\n' "${c_yel}  !${c_rst} $*"; }
die()  { printf '%s\n' "${c_red}  ✗ $*${c_rst}" >&2; exit 1; }
on_err() { printf '\n%s✗ 第 %s 行执行失败（试运行 -h 查看用法）%s\n' "$c_red" "$LINENO" "$c_rst" >&2; }
trap on_err ERR

OCI_DIR="$HOME/.oci"
KEY_FILE="$OCI_DIR/oci_api_key.pem"
PUB_FILE="$OCI_DIR/oci_api_key_public.pem"
CONFIG_FILE="$OCI_DIR/config"
CATCHER_DIR="$HOME/oci-arm-catcher"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMPORT_KEY=""; NONINTERACTIVE=0; NO_START=0
DISPLAY_NAME="${DISPLAY_NAME:-arm-free-1}"
OCPUS_ARG="${OCPUS:-2}"; MEMORY_ARG="${MEMORY_GB:-12}"; INTERVAL_ARG="${RETRY_INTERVAL:-300}"
SUBNET_ID="${OCI_SUBNET_ID:-}"; IMAGE_ID="${OCI_IMAGE_ID:-}"; OS_NAME="${OCI_OS:-Canonical Ubuntu}"

usage() { awk 'NR<=2{next} /^#={5,}/{exit} /^#/{sub(/^# ?/,""); print}' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)            IMPORT_KEY="${2:?缺少 FILE 参数}"; shift 2 ;;
    --name)           DISPLAY_NAME="${2:?缺少 NAME 参数}"; shift 2 ;;
    --ocpus)          OCPUS_ARG="${2:?缺少 N 参数}"; shift 2 ;;
    --memory)         MEMORY_ARG="${2:?缺少 N 参数}"; shift 2 ;;
    --interval)       INTERVAL_ARG="${2:?缺少 SEC 参数}"; shift 2 ;;
    --subnet)         SUBNET_ID="${2:?缺少 OCID 参数}"; shift 2 ;;
    --image)          IMAGE_ID="${2:?缺少 OCID 参数}"; shift 2 ;;
    --os)             OS_NAME="${2:?缺少 NAME 参数}"; shift 2 ;;
    --noninteractive) NONINTERACTIVE=1; shift ;;
    --no-start)       NO_START=1; shift ;;
    -h|--help)        usage ;;
    -V|--version)     echo "oci-arm-auto.sh $VERSION"; exit 0 ;;
    *)                echo "未知参数: $1（-h 查看用法）" >&2; exit 2 ;;
  esac
done

# ── 0. 系统依赖（仅缺失时安装，不做无意义的全量升级）─────────────────────────
ensure_deps() {
  local missing=() cmd m
  for cmd in openssl python3 ssh-keygen; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if command -v python3 >/dev/null 2>&1 \
     && ! command -v uv >/dev/null 2>&1 && ! command -v pipx >/dev/null 2>&1; then
    python3 -c 'import venv' >/dev/null 2>&1 || missing+=("python3-venv")
  fi
  (( ${#missing[@]} == 0 )) && return 0
  warn "缺少依赖: ${missing[*]}"
  if command -v apt-get >/dev/null 2>&1 && { [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null; }; then
    info "通过 apt 安装缺失依赖 ..."
    local pkgs=()
    for m in "${missing[@]}"; do
      case "$m" in
        openssl)      pkgs+=(openssl) ;;
        ssh-keygen)   pkgs+=(openssh-client) ;;
        python3)      pkgs+=(python3 python3-venv python3-pip) ;;
        python3-venv) pkgs+=(python3-venv python3-pip) ;;
        *)            pkgs+=("$m") ;;
      esac
    done
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  else
    die "缺少依赖且无法自动安装（需要 root 或免密 sudo + apt）: ${missing[*]}"
  fi
}

# ── 1. OCI CLI ────────────────────────────────────────────────────────────────
ensure_oci_cli() {
  export PATH="$HOME/.local/bin:$PATH"
  if command -v oci >/dev/null 2>&1; then
    ok "OCI CLI 已安装: $(oci --version 2>/dev/null || echo '?')"
    return
  fi
  info "安装 OCI CLI ..."
  if command -v uv >/dev/null 2>&1; then
    uv tool install oci-cli
  elif command -v pipx >/dev/null 2>&1; then
    pipx install oci-cli
  else
    python3 -m venv "$HOME/.local/share/oci-cli-venv"
    "$HOME/.local/share/oci-cli-venv/bin/pip" install --quiet --upgrade pip oci-cli
    ln -sf "$HOME/.local/share/oci-cli-venv/bin/oci" "$HOME/.local/bin/oci"
  fi
  command -v oci >/dev/null 2>&1 || die "OCI CLI 安装失败，请手动安装（pip install oci-cli）后重试"
  ok "OCI CLI: $(oci --version)"
}

# 让 oci 在"当前会话 + 未来登录 shell"均可用（幂等）
ensure_cli_on_login_path() {
  export PATH="$HOME/.local/bin:$PATH"
  hash -r
  command -v oci >/dev/null 2>&1 || die "oci 不在 PATH（预期位于 ~/.local/bin）"
  if ! bash -lc 'command -v oci' >/dev/null 2>&1; then
    if ! grep -qs 'oci-arm-auto.*PATH' "$HOME/.bashrc"; then
      printf '\n# oci-arm-auto: PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
      ok "已追加 ~/.local/bin 到 ~/.bashrc（未来登录 shell 可直接用 oci）"
    fi
  fi
}

# ── 2. API 密钥 + 指纹 ────────────────────────────────────────────────────────
setup_api_key() {
  mkdir -p "$OCI_DIR"; chmod 700 "$OCI_DIR"
  if [[ -n "$IMPORT_KEY" ]]; then
    [[ -f "$IMPORT_KEY" ]] || die "私钥文件不存在: $IMPORT_KEY"
    cp -f "$IMPORT_KEY" "$KEY_FILE"
    ok "已导入私钥: $IMPORT_KEY"
  elif [[ -f "$KEY_FILE" ]]; then
    warn "复用已存在的 $KEY_FILE（如需换新密钥请先删除该文件）"
  else
    info "生成 API 密钥对（RSA 2048，私钥不出本机）..."
    openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null
  fi
  chmod 600 "$KEY_FILE"
  openssl rsa -in "$KEY_FILE" -check -noout >/dev/null 2>&1 || die "私钥无效或已损坏: $KEY_FILE"
  openssl rsa -pubout -in "$KEY_FILE" -out "$PUB_FILE" 2>/dev/null
  FINGERPRINT=$(openssl rsa -pubout -outform DER -in "$KEY_FILE" 2>/dev/null | openssl md5 -c | awk '{print $NF}')
  [[ -n "$FINGERPRINT" ]] || die "无法计算密钥指纹"
  ok "密钥指纹: $FINGERPRINT"
}

show_public_key_guide() {
  printf '\n%s——————————————————————————————————————————————\n' "$c_bld"
  printf '现在请在浏览器里完成一次「粘贴公钥」（约 1 分钟）：\n\n'
  printf '  1. 登录 Oracle 云控制台 → 右上角头像 → 用户设置（我的概要信息）\n'
  printf '  2. 进入"令牌和密钥" → API 密钥 → 添加 API 密钥 → 选 "粘贴公钥"\n'
  printf '  3. 把下面整段公钥粘贴进去，点"添加"\n\n'
  printf '公钥（同时已存到 %s）：\n' "$PUB_FILE"
  cat "$PUB_FILE"
  printf '——————————————————————————————————————————————%s\n\n' "$c_rst"
}

confirm_key_added() {
  if [[ "${OCI_PUBLIC_KEY_ADDED:-}" == "yes" ]]; then
    ok "跳过等待（OCI_PUBLIC_KEY_ADDED=yes）"
    return
  fi
  [[ $NONINTERACTIVE -eq 0 ]] || die "非交互模式需设置 OCI_PUBLIC_KEY_ADDED=yes"
  read -r -p "已在控制台点完添加？按回车开始验证认证… " _ || true
}

# ── 3. 三个非密标识 ───────────────────────────────────────────────────────────
read_identifiers() {
  USER_OCID="${OCI_USER_OCID:-}"
  TENANCY_OCID="${OCI_TENANCY_OCID:-}"
  REGION="${OCI_REGION:-}"
  if [[ -n "$USER_OCID" && -n "$TENANCY_OCID" && -n "$REGION" ]]; then
    ok "已从环境变量读取 User OCID / Tenancy OCID / Region"
  else
    [[ $NONINTERACTIVE -eq 0 ]] || die "非交互模式需要 OCI_USER_OCID / OCI_TENANCY_OCID / OCI_REGION"
    printf '\n请提供三个非敏感标识（控制台直接复制，它们不是密钥）：\n'
    [[ -n "$USER_OCID" ]]    || read -r -p "  User OCID    （头像→用户设置→我的概要信息页可复制，ocid1.user. 开头）: " USER_OCID
    [[ -n "$TENANCY_OCID" ]] || read -r -p "  Tenancy OCID （头像→租户名→租户详细信息页可复制，ocid1.tenancy. 开头）: " TENANCY_OCID
    [[ -n "$REGION" ]]       || read -r -p "  Region       （控制台右上角区域菜单对应代码，如 us-phoenix-1）: " REGION
  fi
  [[ "$USER_OCID" == ocid1.user.* ]]       || die "User OCID 格式不对（应以 ocid1.user. 开头）"
  [[ "$TENANCY_OCID" == ocid1.tenancy.* ]] || die "Tenancy OCID 格式不对（应以 ocid1.tenancy. 开头）"
  [[ "$REGION" =~ ^[a-z][a-z-]*-[0-9]$ ]]  || die "Region 格式不对（示例: us-phoenix-1）"
}

write_config() {
  info "写入 $CONFIG_FILE ..."
  cat > "$CONFIG_FILE" <<EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
tenancy=$TENANCY_OCID
region=$REGION
key_file=$KEY_FILE
EOF
  chmod 600 "$CONFIG_FILE"
}

test_auth() { oci iam region list --output table >/dev/null 2>&1; }

verify_loop() {
  info "验证认证（oci iam region list）..."
  if test_auth; then ok "认证成功"; return; fi
  warn '认证失败。常见原因：公钥尚未添加 / 粘贴不完整 / 添加后还没点"添加"'
  if [[ $NONINTERACTIVE -eq 1 || ! -t 0 ]]; then
    die "非交互模式下认证失败，请确认公钥已在控制台添加"
  fi
  while ! test_auth; do read -r -p "  修好后按回车重试（Ctrl+C 放弃）… " _ || break; done
  ok "认证成功"
}

# ── 4. 查询 AD / 子网 / 镜像 ──────────────────────────────────────────────────
query_ads() {
  info "查询可用性域 ..."
  AD_LIST=$(oci iam availability-domain list --query 'data[].name' --output json \
    | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)))')
  [[ -n "$AD_LIST" ]] || die "未获取到可用性域"
  ok "可用性域（将轮换重试）: $AD_LIST"
}

query_subnet() {
  if [[ -n "$SUBNET_ID" ]]; then
    [[ "$SUBNET_ID" == ocid1.subnet.* ]] || die "--subnet/OCI_SUBNET_ID 格式不对"
    ok "子网（已指定）: $SUBNET_ID"
    return
  fi
  info "查询公有子网 ..."
  local json
  json=$(oci network subnet list --compartment-id "$TENANCY_OCID" --all \
    --query 'data[].{n:"display-name",id:id,noPub:"prohibit-public-ip-on-vnic"}' --output json)
  local SUBNET_IDS=() SUBNET_NAMES=()
  while IFS=$'\t' read -r sid sname; do
    [[ -n "$sid" ]] && { SUBNET_IDS+=("$sid"); SUBNET_NAMES+=("$sname"); }
  done < <(printf '%s' "$json" | python3 -c '
import sys, json
for s in json.load(sys.stdin):
    if not s.get("noPub"):
        print((s["id"] or "") + "\t" + (s.get("n") or "-"))
')
  local count=${#SUBNET_IDS[@]}
  (( count > 0 )) || die "租户下没有允许公网 IP 的子网。请先在控制台创建 VCN 和公有子网（或确认区域正确）"
  if (( count == 1 )); then
    SUBNET_ID="${SUBNET_IDS[0]}"
    ok "子网: ${SUBNET_NAMES[0]}"
    return
  fi
  [[ $NONINTERACTIVE -eq 0 ]] || die "发现多个公有子网，非交互模式请用 --subnet 指定"
  local i choice
  printf '  发现多个公有子网，请选择：\n'
  for ((i = 0; i < count; i++)); do
    printf '    %d) %-24s %s\n' $((i + 1)) "${SUBNET_NAMES[$i]}" "${SUBNET_IDS[$i]}"
  done
  read -r -p "  输入序号 [1-$count]: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )) || die "无效的选择: $choice"
  SUBNET_ID="${SUBNET_IDS[$((choice - 1))]}"
  ok "子网: ${SUBNET_NAMES[$((choice - 1))]}"
}

query_image() {
  if [[ -n "$IMAGE_ID" ]]; then
    [[ "$IMAGE_ID" == ocid1.image.* ]] || die "--image/OCI_IMAGE_ID 格式不对"
    ok "镜像（已指定）: $IMAGE_ID"
    return
  fi
  info "查询最新 $OS_NAME ARM（aarch64）镜像 ..."
  local json pick
  json=$(oci compute image list --compartment-id "$TENANCY_OCID" \
    --operating-system "$OS_NAME" --shape "VM.Standard.A1.Flex" \
    --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0:30].{n:"display-name",id:id}' --output json)
  pick=$(printf '%s' "$json" | python3 -c '
import sys, json, re
os_name = sys.argv[1]
rows = [i for i in json.load(sys.stdin)
        if "aarch" in (i.get("n") or "").lower() and "Minimal" not in (i.get("n") or "")]
if "Canonical Ubuntu" in os_name:
    best = None
    for i in rows:
        m = re.search(r"Ubuntu-(\d+)\.(\d+)", i["n"])
        if not m:
            continue
        ver = (int(m.group(1)), int(m.group(2)))
        if best is None or ver > best[0]:
            best = (ver, i["n"], i["id"])
    print((best[1] + "\t" + best[2]) if best else "")
else:
    print((rows[0]["n"] + "\t" + rows[0]["id"]) if rows else "")
' "$OS_NAME")
  [[ -n "$pick" ]] || die "未找到 $OS_NAME aarch64 镜像（检查区域/权限是否正确，或用 --image 指定）"
  IMAGE_NAME="${pick%%$'\t'*}"
  IMAGE_ID="${pick##*$'\t'}"
  ok "镜像: $IMAGE_NAME"
}

# ── 5. 实例 SSH 密钥 ──────────────────────────────────────────────────────────
ensure_ssh_key() {
  if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
    info "生成实例 SSH 密钥（ed25519，无口令）..."
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -f "$HOME/.ssh/id_ed25519" -N ""
  fi
  ok "实例 SSH 公钥: $HOME/.ssh/id_ed25519.pub（私钥同名无 .pub，用于登录新实例）"
}

# ── 6. 安装抢购核心脚本 + .env ────────────────────────────────────────────────
setup_catcher() {
  local src="${OCI_ARM_CATCHER_SRC:-$SCRIPT_DIR/oci-arm-catcher.sh}"
  [[ -f "$src" ]] || die "未找到核心脚本 oci-arm-catcher.sh。请将其与 oci-arm-auto.sh 放在同一目录（或用 OCI_ARM_CATCHER_SRC 指定路径）"
  mkdir -p "$CATCHER_DIR"
  cp -f "$src" "$CATCHER_DIR/oci-arm-catcher.sh"
  chmod +x "$CATCHER_DIR/oci-arm-catcher.sh"
  cat > "$CATCHER_DIR/.env" <<EOF
COMPARTMENT_ID=$TENANCY_OCID
DISPLAY_NAME=$DISPLAY_NAME
SSH_KEY_FILE=$HOME/.ssh/id_ed25519.pub
AVAILABILITY_DOMAINS=$AD_LIST
SUBNET_ID=$SUBNET_ID
IMAGE_ID=$IMAGE_ID
OCPUS=$OCPUS_ARG
MEMORY_GB=$MEMORY_ARG
RETRY_INTERVAL=$INTERVAL_ARG
EOF
  chmod 600 "$CATCHER_DIR/.env"
  ok "核心脚本与 .env 已就绪: $CATCHER_DIR/（$OCPUS_ARG OCPU / ${MEMORY_ARG}GB / ${INTERVAL_ARG}s）"
}

start_catcher() {
  if [[ $NO_START -eq 1 ]]; then
    warn "按 --no-start 跳过启动。手动启动：cd ~/oci-arm-catcher && nohup ./oci-arm-catcher.sh > catcher.log 2>&1 &"
    return
  fi
  if pgrep -f oci-arm-catcher.sh >/dev/null 2>&1; then
    warn "已有抢购进程在运行，跳过启动"
    return
  fi
  info "后台启动抢购（断 SSH 也会继续）..."
  ( cd "$CATCHER_DIR" && nohup ./oci-arm-catcher.sh > catcher.log 2>&1 < /dev/null & )
  sleep 3
  if pgrep -f oci-arm-catcher.sh >/dev/null 2>&1; then
    ok "抢购已启动 (PID: $(pgrep -f oci-arm-catcher.sh | head -1))"
  else
    warn "未检测到进程，请查看日志: tail -20 ~/oci-arm-catcher/catcher.log"
  fi
}

print_summary() {
  cat <<EOF

${c_grn}${c_bld}部署完成${c_rst}（oci-arm-auto.sh v$VERSION）

  实例配置 : VM.Standard.A1.Flex / $OCPUS_ARG OCPU / ${MEMORY_ARG}GB / 名称 $DISPLAY_NAME
  重试策略 : 每 ${INTERVAL_ARG} 秒，容量不足时自动轮换可用区
  查看进度 : tail -f ~/oci-arm-catcher/catcher.log
  停止抢购 : pkill -f oci-arm-catcher.sh
  成功判据 : 日志出现 "SUCCESS! Instance created: ocid1.instance..."（脚本随后自动退出）
  登录新机 : ssh -i ~/.ssh/id_ed25519 ubuntu@<新实例公网IP>
             （Ubuntu 镜像默认用户 ubuntu；Oracle Linux 镜像为 opc）

  额度提示 : 2026-06 起 Always Free 的 A1 上限为 2 OCPU + 12GB，超配会报 LimitExceeded；
             若为按需付费账户，超配会产生费用，请先确认账单口径。
  安全提示 : API 私钥（$KEY_FILE）请勿外传；不再需要时可在控制台删除对应 API Key。

EOF
}

main() {
  ensure_deps
  ensure_oci_cli
  ensure_cli_on_login_path
  setup_api_key
  show_public_key_guide
  confirm_key_added
  read_identifiers
  write_config
  verify_loop
  query_ads
  query_subnet
  query_image
  ensure_ssh_key
  setup_catcher
  start_catcher
  print_summary
}
main "$@"