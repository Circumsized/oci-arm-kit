#!/usr/bin/env bash
#===============================================================================
# arm-free-selftest.sh — arm-free-catcher.sh (v4.x) 自检（不触网）
#
# 用桩(stub) oci 命令（按调用类型分发）+ 桩 sleep 验证核心算法的关键行为：
#   1. 探针无池 → 跳过 launch → --once 退出码 3
#   2. 探针可用 + 容量不足 → 轮换 AD → 第二次成功（exit 0 + 公网 IP）
#   3. 假成功场景：launch accepted 但实例 TERMINATING → 判败继续（v4 灵魂用例）
#   4. LimitExceeded（配额类）→ 立即停止（exit 1）
#   5. network 类错误 → 同 AD 先查后试 → 成功（exit 0）
#   6. 429 限流 → 指数退避后继续 → 成功（exit 0）
#   7. 防重预检：同名 RUNNING 已存在 → 不发起创建（exit 0）
#   8. 缺少必填配置 → exit 1
#
# 用法: bash tests/arm-free-selftest.sh
# 依赖: bash、python3、grep -P（Linux/Git Bash 均可）
#===============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATCHER="$HERE/../arm-free-catcher.sh"
[[ -f "$CATCHER" ]] || { echo "❌ 找不到 $CATCHER"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# ── 桩 oci：按调用类型分发（探针/preflight/launch/get/vnics）──────────────────
cat > "$tmp/bin/oci" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"compute-capacity-report create"*)
    ad=""; prev=""
    for a in "$@"; do [[ "$prev" == "--availability-domain" ]] && ad="$a"; prev="$a"; done
    status="AVAILABLE"
    IFS=',' read -ra pairs <<< "${STUB_PROBE_MAP:-}"
    for p in "${pairs[@]}"; do [[ "$p" == "$ad="* ]] && status="${p#*=}"; done
    echo "{\"data\":{\"availability-domain\":\"$ad\",\"shape-availabilities\":[{\"instance-shape\":\"VM.Standard.E2.1.Micro\",\"availability-status\":\"$status\"}]}}"
    exit 0 ;;
  *"instance list"*"--display-name"*)
    # preflight 防重查询
    if [[ "${STUB_PREFLIGHT:-empty}" == "exists" ]]; then
      echo "{\"data\":[{\"id\":\"ocid1.instance.oc1.selftest.existing1\",\"lifecycle-state\":\"RUNNING\"}]}"
    else
      echo "{\"data\":[]}"
    fi
    exit 0 ;;
  *"instance launch"*)
    n=0; [[ -f "${STUB_L_STATE:?}" ]] && n="$(cat "$STUB_L_STATE")"
    n=$((n + 1)); echo "$n" > "$STUB_L_STATE"
    out="$(sed -n "${n}p" "${STUB_LAUNCH_SCRIPT:?}")"
    printf '%s\n' "$out"
    [[ "$out" == *'"id"'* ]] ;;
  *"instance get"*)
    echo "{\"data\":{\"id\":\"ocid1.instance.oc1.selftest.aaaa\",\"lifecycle-state\":\"${STUB_GET_STATE:-RUNNING}\"}}"
    exit 0 ;;
  *"list-vnics"*)
    echo "{\"data\":[{\"public-ip\":\"${STUB_PUBLIC_IP:-203.0.113.10}\",\"private-ip\":\"10.0.0.10\"}]}"
    exit 0 ;;
  *)
    echo "{\"data\":[]}"; exit 0 ;;
esac
STUB
chmod +x "$tmp/bin/oci"

# ── 桩 sleep：所有等待瞬间完成 ────────────────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"

# ── 公共测试配置 ─────────────────────────────────────────────────────────────
echo "ssh-ed25519 AAAASELFTEST selftest" > "$tmp/id_ed25519.pub"
cat > "$tmp/arm.env" <<EOF
COMPARTMENT_ID=ocid1.tenancy.oc1..selftest
DISPLAY_NAME=selftest
SSH_KEY_FILE=$tmp/id_ed25519.pub
AVAILABILITY_DOMAINS=AD-A,AD-B
SUBNET_ID=ocid1.subnet.oc1..selftest
IMAGE_ID=ocid1.image.oc1..selftest
SHAPE=VM.Standard.E2.1.Micro
AD_GAP=5
RETRY_INTERVAL=60
EOF
cat > "$tmp/bad.env" <<EOF
COMPARTMENT_ID=ocid1.tenancy.oc1..selftest
EOF

pass=0; fail=0
run_case() {   # run_case <名称> <launch脚本文件> <env文件> [额外参数...]
  local name="$1" script="$2" envf="$3"; shift 3
  rm -f "$tmp/state"
  RC=0
  STUB_PROBE_MAP="${STUB_PROBE_MAP:-AD-A=AVAILABLE,AD-B=AVAILABLE}" \
  STUB_PREFLIGHT="${STUB_PREFLIGHT:-empty}" \
  STUB_GET_STATE="${STUB_GET_STATE:-RUNNING}" \
  STUB_PUBLIC_IP="${STUB_PUBLIC_IP:-203.0.113.10}" \
  STUB_L_STATE="$tmp/state" STUB_LAUNCH_SCRIPT="$script" \
  LOCK_FILE="$tmp/test.lock" LOG_FILE="$tmp/test.log" \
    PATH="$tmp/bin:$PATH" \
    bash "$CATCHER" --env-file "$envf" "$@" >"$tmp/out" 2>&1 </dev/null || RC=$?
}
check() {   # check <描述> <期望rc> <grep模式或空>
  local desc="$1" want="$2" pat="${3:-}"
  if [[ "$RC" -eq "$want" ]] && { [[ -z "$pat" ]] || grep -q "$pat" "$tmp/out"; }; then
    echo "  ✓ $desc"; pass=$(( pass + 1 ))
  else
    echo "  ✗ $desc（rc=$RC，期望 $want${pat:+，且匹配 '$pat'}）"; sed 's/^/    | /' "$tmp/out" | tail -10
    fail=$(( fail + 1 ))
  fi
}
launch_count() { [[ -f "$tmp/state" ]] && cat "$tmp/state" || echo 0; }

echo "== 用例 1：探针无池 → 跳过 launch → --once 退出码 3 =="
cat > "$tmp/s1" <<'EOF'
InternalError: Out of host capacity.
EOF
STUB_PROBE_MAP="AD-A=OUT_OF_HOST_CAPACITY,AD-B=OUT_OF_HOST_CAPACITY" \
  run_case t1 "$tmp/s1" "$tmp/arm.env" --once
check "退出码 3" 3 "本轮无容量"
check "未发起 launch（探针全跳过）" 3 ""
[[ "$(launch_count)" -eq 0 ]] && { echo "  ✓ launch 次数为 0"; pass=$((pass+1)); } \
  || { echo "  ✗ launch 被调用了 $(launch_count) 次（应为 0）"; fail=$((fail+1)); }

echo "== 用例 2：探针可用 + 容量不足 → 轮换 AD → 成功（带 IP）=="
cat > "$tmp/s2" <<'EOF'
InternalError: Out of host capacity.
{"data": {"id": "ocid1.instance.oc1.selftest.aaaa", "lifecycle-state": "PROVISIONING"}}
EOF
run_case t2 "$tmp/s2" "$tmp/arm.env"
check "退出码 0" 0 "SUCCESS! 实例已创建并 RUNNING"
check "第 1 次落在 AD-A" 0 "尝试 #1（AD: AD-A）"
check "重试轮换到 AD-B" 0 "尝试 #2（AD: AD-B）"
check "公网 IP 已带出" 0 "203.0.113.10"

echo "== 用例 3：假成功场景——launch accepted 但实例 TERMINATING → 判败继续 =="
cat > "$tmp/s3" <<'EOF'
{"data": {"id": "ocid1.instance.oc1.selftest.bbbb", "lifecycle-state": "PROVISIONING"}}
EOF
STUB_GET_STATE="TERMINATING" run_case t3 "$tmp/s3" "$tmp/arm.env" --once
check "退出码 3（判败后无容量）" 3 "本轮无容量"
check "识别出 TERMINATING 并归为容量类" 3 "entered TERMINATING during provisioning"

echo "== 用例 4：LimitExceeded（配额类）→ 立即停止 =="
cat > "$tmp/s4" <<'EOF'
{"code": "LimitExceeded", "message": "The following service limits were exceeded: standard-e2-micro-instances"}
EOF
run_case t4 "$tmp/s4" "$tmp/arm.env"
check "退出码 1" 1 "不可重试错误"

echo "== 用例 5：network 类错误 → 同 AD 先查后试 → 成功 =="
cat > "$tmp/s5" <<'EOF'
HTTPSConnectionPool(host='iaas.us-phoenix-1.oraclecloud.com', port=443): Max retries exceeded with url: /20160918/instances (Caused by ConnectTimeoutError)
{"data": {"id": "ocid1.instance.oc1.selftest.cccc", "lifecycle-state": "PROVISIONING"}}
EOF
run_case t5 "$tmp/s5" "$tmp/arm.env"
check "退出码 0" 0 "SUCCESS!"
check "走了同 AD 先查后试分支" 0 "同 AD 先查后试"
# network 重试复用同 AD：两次"发起创建"都锚定 AD-A，且从未出现 AD-B 尝试
if [[ "$(grep -c "发起创建（AD: AD-A" "$tmp/out")" -eq 2 ]] && ! grep -q "AD-B" "$tmp/out"; then
  echo "  ✓ 两次发起都锚定 AD-A（未换 AD）"; pass=$(( pass + 1 ))
else
  echo "  ✗ AD 锚定不符合预期"; sed 's/^/    | /' "$tmp/out" | tail -6; fail=$(( fail + 1 ))
fi

echo "== 用例 6：429 限流 → 指数退避后继续 → 成功 =="
cat > "$tmp/s6" <<'EOF'
{"code": "TooManyRequests", "message": "User-rate limit exceeded."}
{"data": {"id": "ocid1.instance.oc1.selftest.dddd", "lifecycle-state": "PROVISIONING"}}
EOF
run_case t6 "$tmp/s6" "$tmp/arm.env"
check "退出码 0" 0 "SUCCESS!"
check "识别限流并退避" 0 "触发限流(429)"

echo "== 用例 7：防重预检——同名 RUNNING 已存在 → 不发起创建 =="
cat > "$tmp/s7" <<'EOF'
{"data": {"id": "ocid1.instance.oc1.selftest.eeee", "lifecycle-state": "PROVISIONING"}}
EOF
STUB_PREFLIGHT="exists" run_case t7 "$tmp/s7" "$tmp/arm.env"
check "退出码 0（收下已有实例）" 0 "已存在同名实例"
check "未发起 launch" 0 ""
[[ "$(launch_count)" -eq 0 ]] && { echo "  ✓ launch 次数为 0"; pass=$((pass+1)); } \
  || { echo "  ✗ launch 被调用了 $(launch_count) 次（应为 0）"; fail=$((fail+1)); }

echo "== 用例 8：缺少必填配置 → 退出码 1 =="
run_case t8 "$tmp/s2" "$tmp/bad.env"
check "退出码 1 且列出缺项" 1 "缺少必填配置"

echo
if (( fail == 0 )); then
  echo "全部通过：$pass 项检查 ✓"
else
  echo "失败 $fail 项 / 共 $(( pass + fail )) 项" >&2
  exit 1
fi
