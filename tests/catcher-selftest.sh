#!/usr/bin/env bash
#===============================================================================
# catcher-selftest.sh — oci-arm-catcher.sh 自检（不触网）
#
# 用桩(stub) oci 命令 + 桩 sleep 验证核心算法的关键行为：
#   1. 容量不足错误 → 重试并轮换可用性域 → 第二次成功后退出码 0
#   2. LimitExceeded（配额类）→ 立即停止，退出码 1
#   3. --once 模式容量不足 → 退出码 3
#   4. 缺少必填配置 → 退出码 1
#
# 用法: bash tests/catcher-selftest.sh
# 依赖: bash、python3、grep -P（Linux/Git Bash 均可）
#===============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATCHER="$HERE/../oci-arm-catcher.sh"
[[ -f "$CATCHER" ]] || { echo "❌ 找不到 $CATCHER"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# ── 桩 oci：按调用次数输出预置的第 n 行；输出含 "id" 视为成功(rc 0) ──────────
cat > "$tmp/bin/oci" <<'STUB'
#!/usr/bin/env bash
n=0; [[ -f "${STUB_STATE:?}" ]] && n="$(cat "$STUB_STATE")"
n=$((n + 1)); echo "$n" > "$STUB_STATE"
out="$(sed -n "${n}p" "${STUB_SCRIPT:?}")"
printf '%s\n' "$out"
[[ "$out" == *'"id"'* ]]
STUB
chmod +x "$tmp/bin/oci"

# ── 桩 sleep：让重试等待瞬间完成 ─────────────────────────────────────────────
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
OCPUS=2
MEMORY_GB=12
RETRY_INTERVAL=60
EOF
cat > "$tmp/bad.env" <<EOF
COMPARTMENT_ID=ocid1.tenancy.oc1..selftest
EOF

pass=0; fail=0
run_case() {   # run_case <名称> <脚本行文件或空> <env文件> [额外参数...]
  local name="$1" script="$2" envf="$3"; shift 3
  rm -f "$tmp/state"
  RC=0
  STUB_STATE="$tmp/state" STUB_SCRIPT="$script" PATH="$tmp/bin:$PATH" \
    "$CATCHER" --env-file "$envf" "$@" >"$tmp/out" 2>&1 </dev/null || RC=$?
}
check() {   # check <描述> <期望rc> <grep模式或空>
  local desc="$1" want="$2" pat="${3:-}"
  if [[ "$RC" -eq "$want" ]] && { [[ -z "$pat" ]] || grep -q "$pat" "$tmp/out"; }; then
    echo "  ✓ $desc"; pass=$(( pass + 1 ))
  else
    echo "  ✗ $desc（rc=$RC，期望 $want${pat:+，且匹配 '$pat'}）"; sed 's/^/    | /' "$tmp/out" | tail -8
    fail=$(( fail + 1 ))
  fi
}

echo "== 用例 1：容量不足 → 轮换 AD → 成功 =="
cat > "$tmp/s1" <<'EOF'
InternalError: Out of host capacity.
{"data": {"id": "ocid1.instance.oc1.selftest.aaaa", "lifecycle-state": "PROVISIONING"}}
EOF
run_case t1 "$tmp/s1" "$tmp/arm.env"
check "退出码 0" 0 "SUCCESS! Instance created"
check "第 1 次落在 AD-A" 0 "第 1 次尝试（AD: AD-A）"
check "重试轮换到 AD-B" 0 "第 2 次尝试（AD: AD-B）"

echo "== 用例 2：LimitExceeded（配额类）→ 立即停止 =="
cat > "$tmp/s2" <<'EOF'
{"code": "LimitExceeded", "message": "The following service limits were exceeded: standard-a1-core-count"}
EOF
run_case t2 "$tmp/s2" "$tmp/arm.env"
check "退出码 1" 1 "不在可重试范围"

echo "== 用例 3：--once 容量不足 → 退出码 3 =="
cat > "$tmp/s3" <<'EOF'
InternalError: Out of host capacity.
EOF
run_case t3 "$tmp/s3" "$tmp/arm.env" --once
check "退出码 3" 3 "退出码 3"

echo "== 用例 4：缺少必填配置 → 退出码 1 =="
run_case t4 "$tmp/s1" "$tmp/bad.env"
check "退出码 1 且列出缺项" 1 "缺少必填配置"

echo "== 用例 5：Stack Apply 模式（传入 STACK_OCID）→ 成功 =="
cat > "$tmp/s5" <<'EOF'
{"data": {"id": "ocid1.ormjob.oc1.selftest.job1", "lifecycle-state": "SUCCEEDED"}}
EOF
cat > "$tmp/stack.env" <<EOF
STACK_OCID=ocid1.ormstack.oc1.selftest.stack1
RETRY_INTERVAL=60
EOF
run_case t5 "$tmp/s5" "$tmp/stack.env"
check "Stack 模式识别并成功退出" 0 "Stack Apply (Resource Manager)"
check "命中成功日志" 0 "SUCCESS! Stack Apply 成功执行"

echo
if (( fail == 0 )); then
  echo "全部通过：$pass 项检查 ✓"
else
  echo "失败 $fail 项 / 共 $(( pass + fail )) 项" >&2
  exit 1
fi