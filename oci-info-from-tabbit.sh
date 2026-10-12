#!/usr/bin/env bash
#===============================================================================
# oci-info-from-tabbit.sh — 甲骨文云接入信息提取（Tabbit 浏览器版）
#
# 从你已登录 Oracle 云控制台的 Tabbit 浏览器标签页中，自动提取：
#   · User OCID       用户标识
#   · Tenancy OCID    租户标识
#   · REGION          当前区域代码（如 us-phoenix-1）
#   · 控制台密钥指纹   已注册 API 密钥的指纹（供核对，非机密）
#
# 抓取完成后自动把控制台标签页还原到"实例"列表页，不影响你的浏览状态。
# 输出为标准 KEY=VALUE（可直接 eval 或 -o 写入文件），配合服务器端
# oci-arm-auto.sh 使用可实现全自动部署。
#
# 适用环境 : Windows + Git Bash；Tabbit 已安装且已登录 cloud.oracle.com（中文界面）
# 依赖     : tabbit-cli（Tabbit 自带；非标准安装位置用 TABBIT_CLI 环境变量指定）、grep -P
#
# 用法:
#   bash oci-info-from-tabbit.sh [选项]
#
# 选项:
#   -o, --write-env FILE   将结果写入 FILE（chmod 600，可直接 source）
#   -q, --quiet            静默模式：仅输出结果，不显示进度
#   -h, --help             显示本帮助
#   -V, --version          显示版本号
#
# 示例:
#   bash oci-info-from-tabbit.sh
#   bash oci-info-from-tabbit.sh -q -o oci-info.env && source oci-info.env
#
# 退出码: 0 成功；1 环境/登录/抓取失败；2 参数错误
#===============================================================================

set -Eeuo pipefail

VERSION="2.0.0"
TASK="OCI Info"
QUIET=0
WRITE_ENV=""
TABBIT_CLI="${TABBIT_CLI:-}"

# ── 输出 ──────────────────────────────────────────────────────────────────────
log() { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*" >&2; }
ok()  { [[ $QUIET -eq 1 ]] || printf '  ✓ %s\n' "$*" >&2; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

usage() { awk 'NR<=2{next} /^#={5,}/{exit} /^#/{sub(/^# ?/,""); print}' "$0"; exit 0; }

# ── 清理：无论成败都释放任务归属，避免标签页被残留任务占用 ───────────────────
cleanup() {
  if [[ -n "${TABBIT_CLI:-}" && -x "$TABBIT_CLI" ]]; then
    "$TABBIT_CLI" finish --task "$TASK" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── 参数 ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--write-env) WRITE_ENV="${2:?缺少 FILE 参数}"; shift 2 ;;
    -q|--quiet)     QUIET=1; shift ;;
    -h|--help)      usage ;;
    -V|--version)   echo "oci-info-from-tabbit.sh $VERSION"; exit 0 ;;
    *)              echo "未知参数: $1（-h 查看用法）" >&2; exit 2 ;;
  esac
done

# ── 定位 tabbit-cli（标准位置自动推导；可用 TABBIT_CLI 覆盖）─────────────────
to_posix() {
  local p="${1//\\//}"
  if [[ "$p" =~ ^([A-Za-z]): ]]; then
    p="/${BASH_REMATCH[1],,}${p:2}"     # C:\... → /c/...
  fi
  printf '%s' "$p"
}
if [[ -z "$TABBIT_CLI" ]]; then
  win_dir="${LOCALAPPDATA:-${USERPROFILE:+${USERPROFILE}/AppData/Local}}"
  if [[ -n "$win_dir" ]]; then
    TABBIT_CLI="$(to_posix "$win_dir")/Tabbit/LocalAgent/bin/tabbit-cli.exe"
  fi
fi
[[ -n "$TABBIT_CLI" && -f "$TABBIT_CLI" ]] || die "未找到 tabbit-cli。请设置 TABBIT_CLI 环境变量指向 tabbit-cli.exe 的完整路径"

RID="$(date +%s)"

# ── 查找已登录的控制台标签页（优先当前激活的）────────────────────────────────
log "==> 查找甲骨文控制台标签页 ..."
inv="$("$TABBIT_CLI" create --task "$TASK" 2>&1 || true)"
OC_URL_RE='"tabId":\K[0-9]+(?=,"title":"[^"]*","url":"https://cloud\.oracle\.com)'
tab="$(printf '%s' "$inv" | grep -oP "\"active\":true,[^{}]*?$OC_URL_RE" | head -1 || true)"
[[ -n "$tab" ]] || tab="$(printf '%s' "$inv" | grep -oP "$OC_URL_RE" | head -1 || true)"
[[ -n "$tab" ]] || die "Tabbit 中没有找到甲骨文控制台标签页。请先在 Tabbit 打开并登录 https://cloud.oracle.com"
ok "使用标签页: $tab"

# ── 1) User OCID（用户菜单 → 用户设置 → 我的概要信息）─────────────────────────
log "==> 读取 User OCID ..."
r1="$("$TABBIT_CLI" nodejs --task "$TASK" --tab "$tab" --request-id "info-user-$RID" <<'JS' 2>&1
const frame = page.frameLocator("#sandbox-maui-preact-container");
if (/sign-in|\/login/.test(page.url())) throw new Error("控制台未登录，请先在 Tabbit 里登录甲骨文云控制台");
await page.getByRole("button", {name: "用户菜单", exact: true}).click();
const item = page.getByText("用户设置", {exact: true});
await item.waitFor({state: "visible", timeout: 5000});
if ((await item.count()) !== 1) throw new Error("用户设置入口不唯一");
await item.click();
let ocid = "";
for (let i = 0; i < 30; i++) {
  await page.waitForTimeout(300);
  const list = await frame.getByText(/ocid1\.user\./).allTextContents();
  if (list.length) { ocid = list[0]; break; }
}
if (!ocid) throw new Error("未读取到 User OCID");
return {userOcid: ocid};
JS
)"
USER_OCID="$(printf '%s' "$r1" | grep -oP '"userOcid":"\K[^"]+' | head -1 || true)"
[[ -n "$USER_OCID" ]] || die "抓取 User OCID 失败，原始返回：$(printf '%s' "$r1" | tail -c 400)"
ok "User OCID 已获取"

# ── 2) API 密钥指纹（我的概要信息 → 令牌和密钥 → API 密钥）───────────────────
log "==> 读取控制台密钥指纹 ..."
r2="$("$TABBIT_CLI" nodejs --task "$TASK" --request-id "info-fp-$RID" <<'JS' 2>&1
const FP = /^([0-9a-f]{2}:){15}[0-9a-f]{2}$/i;
const frame = page.frameLocator("#sandbox-maui-preact-container");
const tab = frame.getByText("令牌和密钥", {exact: true});
if ((await tab.count()) === 1) await tab.click();
let fps = [];
for (let i = 0; i < 20; i++) {
  await page.waitForTimeout(250);
  fps = await frame.getByText(FP).allTextContents();
  if (fps.length) break;
}
return {fingerprints: [...new Set(fps)]};
JS
)"
FPS="$(printf '%s' "$r2" | grep -oP '([0-9a-f]{2}:){15}[0-9a-f]{2}' | paste -sd' ' - || true)"
ok "指纹: ${FPS:-（未读取到，非致命）}"

# ── 3) Tenancy OCID + 区域（已验证的租户详情页 URL；完成后还原标签页）─────────
log "==> 读取 Tenancy OCID 与区域 ..."
r3="$("$TABBIT_CLI" nodejs --task "$TASK" --request-id "info-tenancy-$RID" <<'JS' 2>&1
const url0 = page.url();
const region = new URL(url0).searchParams.get("region") || "";
if (!region) throw new Error("无法从控制台 URL 解析区域代码，请确认控制台页面已加载");
await page.goto(`https://cloud.oracle.com/tenancy?region=${region}`, {waitUntil: "domcontentloaded"});
const frame = page.frameLocator("#sandbox-maui-preact-container");
let ocid = "";
for (let i = 0; i < 30; i++) {
  const list = await frame.getByText(/ocid1\.tenancy\./).allTextContents();
  if (list.length) { ocid = list[0]; break; }
  await page.waitForTimeout(300);
}
if (!ocid) throw new Error("未读取到 Tenancy OCID");
await page.goto(`https://cloud.oracle.com/compute/instances?region=${region}`, {waitUntil: "domcontentloaded"});
return {tenancyOcid: ocid, region};
JS
)"
TENANCY_OCID="$(printf '%s' "$r3" | grep -oP '"tenancyOcid":"\K[^"]+' | head -1 || true)"
REGION="$(printf '%s' "$r3" | grep -oP '"region":"\K[^"]+' | head -1 || true)"
[[ -n "$TENANCY_OCID" && -n "$REGION" ]] || die "抓取 Tenancy OCID / 区域失败，原始返回：$(printf '%s' "$r3" | tail -c 400)"
ok "Tenancy OCID 与区域已获取"

# ── 可选：写入 env 文件 ───────────────────────────────────────────────────────
if [[ -n "$WRITE_ENV" ]]; then
  (umask 177; cat > "$WRITE_ENV" <<EOF
# OCI 接入信息 — 由 oci-info-from-tabbit.sh v$VERSION 于 $(date '+%F %T') 生成
# 用法: source <本文件> 后直接运行 oci-arm-auto.sh
export OCI_USER_OCID=$USER_OCID
export OCI_TENANCY_OCID=$TENANCY_OCID
export OCI_REGION=$REGION
EOF
  )
  log "==> 已写入 $WRITE_ENV"
fi

# ── 结果输出（stdout 仅含可直接 eval 的行；OCRID/指纹均非机密，文件仍建议 600）─
echo "# 控制台已有密钥指纹: ${FPS:-无}"
echo "export OCI_USER_OCID=$USER_OCID"
echo "export OCI_TENANCY_OCID=$TENANCY_OCID"
echo "export OCI_REGION=$REGION"
[[ $QUIET -eq 1 ]] || {
  echo "#"
  echo "# 下一步: 在服务器执行 oci-arm-auto.sh（把上面三行作为环境变量传入），"
  echo "#         中间只需在控制台粘贴一次脚本生成的公钥。"
} >&2