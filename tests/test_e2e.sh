#!/bin/bash
# 主备 / 剔除两种故障转移模式的端到端场景测试
# 用法: bash tests/test_e2e.sh
#
# 场景与 docs/active-standby-logic.md 的「自动化测试覆盖」一一对应：
#   主备模式(active-standby)：1 平时 / 2 主挂 / 3 主+备1挂 / 4 主恢复 / 5 备1单挂 / 6 全挂
#   剔除模式(roundrobin 回归) ：7 全健康 / 8 主挂 / 9 主+备1挂 / 10 全挂 / 11 failover off
#
# 断言的是 generate_endpoints_from_rules 真正生成的 realm 配置。

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

H1=10.0.0.1
H2=10.0.0.2
H3=10.0.0.3

# 造一条规则（单规则多地址）
mkrule() {
    local mode="$1" failover="$2" weights="$3" hosts="$4"
    rm -f "$SANDBOX"/rules/rule-*.conf
    cat > "$SANDBOX/rules/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=e2e-test
SECURITY_LEVEL=none
LISTEN_PORT=8080
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$hosts
REMOTE_PORT=8080
ENABLED=true
BALANCE_MODE="$mode"
TARGET_STATES=""
WEIGHTS="$weights"
FAILOVER_ENABLED="$failover"
EOF
}

# 写健康状态：参数依次是 host status
write_health() {
    {
        echo "# Realm健康状态文件"
        local i=1
        for pair in "$@"; do
            echo "${i}|${pair%%:*}|${pair##*:}|0|3|100|0"
            i=$((i + 1))
        done
    } > "$HEALTH_STATUS_FILE"
}

balance_of() {
    generate_endpoints_from_rules 2>/dev/null | grep -o '"balance": "[^"]*"' | head -1
}

target_count() {
    local out
    out=$(generate_endpoints_from_rules 2>/dev/null)
    printf '%s' "$out" | grep -o '10\.0\.0\.[123]' | sort -u | wc -l | tr -d ' '
}

echo "=============================================="
echo "主备模式 (active-standby)"
echo "=============================================="
mkrule "active-standby" "true" "1,0,0" "$H1,$H2,$H3"

write_health "$H1:healthy" "$H2:healthy" "$H3:healthy"
check "场景1 平时 → 1,0,0" "$(balance_of)" '"balance": "roundrobin: 1, 0, 0"'

write_health "$H1:failed" "$H2:healthy" "$H3:healthy"
check "场景2 主挂 → 0,1,0" "$(balance_of)" '"balance": "roundrobin: 0, 1, 0"'

write_health "$H1:failed" "$H2:failed" "$H3:healthy"
check "场景3 主+备1挂 → 0,0,1" "$(balance_of)" '"balance": "roundrobin: 0, 0, 1"'

write_health "$H1:healthy" "$H2:failed" "$H3:healthy"
check "场景4 主恢复 → 1,0,0" "$(balance_of)" '"balance": "roundrobin: 1, 0, 0"'

write_health "$H1:healthy" "$H2:failed" "$H3:healthy"
check "场景5 备1单挂 → 主不变 1,0,0" "$(balance_of)" '"balance": "roundrobin: 1, 0, 0"'

write_health "$H1:failed" "$H2:failed" "$H3:failed"
check "场景6 全挂 → 兜底 1,0,0（不断流）" "$(balance_of)" '"balance": "roundrobin: 1, 0, 0"'

echo "=============================================="
echo "剔除模式 (roundrobin 回归)"
echo "=============================================="
mkrule "roundrobin" "true" "1,1,1" "$H1,$H2,$H3"

write_health "$H1:healthy" "$H2:healthy" "$H3:healthy"
check "场景7 全健康 → 3 个目标都在" "$(target_count)" "3"

write_health "$H1:failed" "$H2:healthy" "$H3:healthy"
check "场景8 主挂 → 剔除故障目标，剩 2 个" "$(target_count)" "2"

write_health "$H1:failed" "$H2:failed" "$H3:healthy"
check "场景9 主+备1挂 → 只剩 1 个" "$(target_count)" "1"

write_health "$H1:failed" "$H2:failed" "$H3:failed"
check "场景10 全挂 → 保留第一个，不断流" "$(target_count)" "1"

mkrule "roundrobin" "false" "1,1,1" "$H1,$H2,$H3"
write_health "$H1:failed" "$H2:failed" "$H3:failed"
check "场景11 failover off → 不做过滤，3 个都在" "$(target_count)" "3"

echo "=============================================="
echo "结果: PASS=$PASS FAIL=$FAIL"
echo "=============================================="
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
