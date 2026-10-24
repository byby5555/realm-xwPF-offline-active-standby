#!/bin/bash
# set -u（未定义变量即报错）下的健壮性测试
# 用法: bash tests/test_set_u.sh
#
# 背景：realm 配置生成路径大量使用 declare -A 关联数组，
#       旧写法 ${arr[$key]} 在 set -u 下访问未设置的键会「致命中断」整个 shell，
#       导致 config.json 被写成空、realm 起不来（界面却显示「生成成功」）。
#       修复：所有关联数组读取一律写成 ${arr[$key]:-}。
#
# 本用例同时带一个「对照组」：证明旧写法在 set -u 下确实会失败，
# 避免出现「测试怎么写都绿」的情况。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"

SANDBOX="$(mktemp -d)"
PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 期望 [$3] 实际 [$2]"; fi; }

mkdir -p "$SANDBOX/rules" "$SANDBOX/health"

export CONFIG_DIR="$SANDBOX"
export HEALTH_STATUS_FILE="$SANDBOX/health/health_status.conf"

# shellcheck disable=SC1090
source "$REPO/lib/core.sh"
CONFIG_DIR="$SANDBOX"
RULES_DIR="$SANDBOX/rules"
# shellcheck disable=SC1090
source "$REPO/lib/health.sh"
# shellcheck disable=SC1090
source "$REPO/lib/rules.sh"
# shellcheck disable=SC1090
source "$REPO/lib/realm.sh"

service_restart() { return 0; }
ensure_health_check_service() { return 0; }

cat > "$SANDBOX/rules/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=setu-test
SECURITY_LEVEL=none
LISTEN_PORT=8080
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=10.0.0.1,10.0.0.2
REMOTE_PORT=8080
ENABLED=true
BALANCE_MODE="active-standby"
TARGET_STATES=""
WEIGHTS="10,0"
FAILOVER_ENABLED="true"
EOF

echo "=============================================="
echo "A. 对照组：旧写法在 set -u 下确实致命"
echo "=============================================="
old_rc=$( ( set -u; declare -A a=(); k=missing; echo "${a[$k]}" ) >/dev/null 2>&1; echo $? )
check "旧写法 ${a[missing]} 在 set -u 下退出码非 0" \
      "$([ "$old_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
new_rc=$( ( set -u; declare -A a=(); k=missing; echo "${a[$k]:-}" ) >/dev/null 2>&1; echo $? )
check "新写法 ${a[missing]:-} 在 set -u 下退出码为 0" "$new_rc" "0"

echo "=============================================="
echo "B. 配置生成在 set -u 下不再中断"
echo "=============================================="
normal_out=$(generate_endpoints_from_rules 2>/dev/null)
normal_rc=$?
check "普通模式下生成成功" "$normal_rc" "0"

strict_out=$( ( set -u; generate_endpoints_from_rules ) 2>&1 )
strict_rc=$?
check "set -u 下生成不致命中断" "$strict_rc" "0"

strict_clean=$( ( set -u; generate_endpoints_from_rules ) 2>/dev/null )
check "set -u 下输出与普通模式一致" "$([ "$strict_clean" = "$normal_out" ] && echo same || echo differ)" "same"
check "set -u 下仍生成出 balance 字段" \
      "$(printf '%s' "$strict_clean" | grep -c '"balance"')" "1"
check "set -u 下仍生成出两个目标" \
      "$(printf '%s' "$strict_clean" | grep -o '10\.0\.0\.[12]' | sort -u | wc -l | tr -d ' ')" "2"
check "set -u 下无 unbound variable 报错" \
      "$(printf '%s' "$strict_out" | grep -c 'unbound variable')" "0"

echo "=============================================="
echo "C. 其他被调用到的函数在 set -u 下健壮"
echo "=============================================="
check "read_rule_file 在 set -u 下成功" \
      "$( ( set -u; read_rule_file "$SANDBOX/rules/rule-1.conf" ) >/dev/null 2>&1; echo $? )" "0"
check "reorder_rule_ids 在 set -u 下成功" \
      "$( ( set -u; reorder_rule_ids ) >/dev/null 2>&1; echo $? )" "0"

echo "=============================================="
echo "结果: PASS=$PASS FAIL=$FAIL"
echo "=============================================="
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
