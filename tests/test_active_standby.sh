#!/bin/bash
# 主备（active-standby）自动启用 + 优先级选主 + 故障切换 回归测试
# 用法: bash tests/test_active_standby.sh
# 不需要 root，不修改真实 /etc/realm

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
# core.sh 会把 CONFIG_DIR 固定为 /etc/realm，测试里再覆盖回沙箱
CONFIG_DIR="$SANDBOX"
RULES_DIR="$SANDBOX/rules"
# shellcheck disable=SC1090
source "$REPO/lib/rules.sh"
# shellcheck disable=SC1090
source "$REPO/lib/realm.sh"

# 打桩：避免真实重启 realm / 下载脚本
service_restart() { return 0; }
ensure_health_check_service() { return 0; }

mkrule() {
    local id="$1" host="$2" weights="$3" mode="$4" failover="$5"
    cat > "$SANDBOX/rules/rule-$id.conf" <<EOF
RULE_ID="$id"
RULE_ROLE="1"
RULE_NAME="standby-test-$id"
SECURITY_LEVEL="none"
LISTEN_PORT="443"
LISTEN_IP=""
THROUGH_IP="::"
REMOTE_HOST="$host"
REMOTE_PORT="8443"
FORWARD_TARGET=""
WS_PATH=""
WS_HOST=""
ENABLED="true"
CREATED_TIME="2026-01-01 00:00:00"
BALANCE_MODE="$mode"
TARGET_STATES=""
WEIGHTS="$weights"
FAILOVER_ENABLED="$failover"
EOF
}

write_health() {
    printf '%s\n' "$@" > "$HEALTH_STATUS_FILE"
}

balance_of() {
    generate_endpoints_from_rules 2>/dev/null | grep -o '"balance": "[^"]*"' | head -1
}

echo "=============================================="
echo "1. 权重输入校验"
echo "=============================================="
validate_weight_input "10,0" 2 >/dev/null 2>&1
check "10,0 合法" "$?" "0"
validate_weight_input "0,0" 2 >/dev/null 2>&1
check "0,0 被拒绝(全 0 无出口)" "$?" "1"
validate_weight_input "10,0,0" 2 >/dev/null 2>&1
check "数量不匹配被拒绝" "$?" "1"
validate_weight_input "10,11" 2 >/dev/null 2>&1
check "超范围 11 被拒绝" "$?" "1"

echo "=============================================="
echo "2. 权重含 0 检测"
echo "=============================================="
weights_contain_zero "10,0"; check "10,0 含 0" "$?" "0"
weights_contain_zero "5,5"; check "5,5 不含 0" "$?" "1"
weights_contain_zero "0"; check "单个 0 含 0" "$?" "0"

echo "=============================================="
echo "3. 权重含 0 → 自动主备 + 自动开启主备路由"
echo "=============================================="
rm -f "$SANDBOX"/rules/rule-*.conf
mkrule 1 "10.0.0.1" "" "roundrobin" "false"
mkrule 2 "10.0.0.2" "" "roundrobin" "false"

printf '\n' | apply_port_group_weight_config "443" "10,0" >/dev/null 2>&1

MODE1=$(grep '^BALANCE_MODE=' "$SANDBOX/rules/rule-1.conf" | head -1)
MODE2=$(grep '^BALANCE_MODE=' "$SANDBOX/rules/rule-2.conf" | head -1)
check "rule1 BALANCE_MODE" "$MODE1" 'BALANCE_MODE="active-standby"'
check "rule2 BALANCE_MODE" "$MODE2" 'BALANCE_MODE="active-standby"'

FO1=$(grep '^FAILOVER_ENABLED=' "$SANDBOX/rules/rule-1.conf" | head -1)
FO2=$(grep '^FAILOVER_ENABLED=' "$SANDBOX/rules/rule-2.conf" | head -1)
check "rule1 FAILOVER_ENABLED" "$FO1" 'FAILOVER_ENABLED="true"'
check "rule2 FAILOVER_ENABLED" "$FO2" 'FAILOVER_ENABLED="true"'

W1=$(grep '^WEIGHTS=' "$SANDBOX/rules/rule-1.conf" | head -1)
check "rule1 WEIGHTS 存完整序列" "$W1" 'WEIGHTS="10,0"'
W2=$(grep '^WEIGHTS=' "$SANDBOX/rules/rule-2.conf" | head -1)
check "rule2 WEIGHTS 存单个值" "$W2" 'WEIGHTS="0"'

for k in HEALTH_CHECK_INTERVAL FAILURE_THRESHOLD SUCCESS_THRESHOLD CONNECTION_TIMEOUT RECOVERY_COOLDOWN; do
    if grep -q "^${k}=" "$SANDBOX/rules/rule-1.conf"; then ok "$k 已补齐"; else bad "$k 缺失"; fi
done

echo "=============================================="
echo "4. 主备选主：权重大的当主"
echo "=============================================="
write_health "1|10.0.0.1|healthy|0|3|0|0" "2|10.0.0.2|healthy|0|3|0|0"
B=$(balance_of)
check "10,0 → 第一个为主" "$B" '"balance": "roundrobin: 1, 0"'

echo "=============================================="
echo "5. 主故障 → 自动切到备"
echo "=============================================="
write_health "1|10.0.0.1|failed|3|0|0|0" "2|10.0.0.2|healthy|0|3|0|0"
B=$(balance_of)
check "主故障 → 切到备" "$B" '"balance": "roundrobin: 0, 1"'

echo "=============================================="
echo "6. 主恢复 → 自动切回主"
echo "=============================================="
write_health "1|10.0.0.1|healthy|0|3|0|0" "2|10.0.0.2|healthy|0|3|0|0"
B=$(balance_of)
check "主恢复 → 切回主" "$B" '"balance": "roundrobin: 1, 0"'

echo "=============================================="
echo "7. 优先级：0,10 表示第二个当主"
echo "=============================================="
rm -f "$SANDBOX"/rules/rule-*.conf
mkrule 1 "10.0.0.1" "" "roundrobin" "false"
mkrule 2 "10.0.0.2" "" "roundrobin" "false"
printf '\n' | apply_port_group_weight_config "443" "0,10" >/dev/null 2>&1
write_health "1|10.0.0.1|healthy|0|3|0|0" "2|10.0.0.2|healthy|0|3|0|0"
B=$(balance_of)
check "0,10 → 第二个为主" "$B" '"balance": "roundrobin: 0, 1"'

echo "=============================================="
echo "8. 优先级：0,10 且第二个故障 → 回退第一个"
echo "=============================================="
write_health "1|10.0.0.1|healthy|0|3|0|0" "2|10.0.0.2|failed|3|0|0|0"
B=$(balance_of)
check "第二主故障 → 切回第一个" "$B" '"balance": "roundrobin: 1, 0"'

echo "=============================================="
echo "9. 全挂 → 强制优先级最高的目标兜底(不断流)"
echo "=============================================="
# 当前权重是 0,10 → 优先级最高的是第二个 → 兜底应给第二个
write_health "1|10.0.0.1|failed|3|0|0|0" "2|10.0.0.2|failed|3|0|0|0"
B=$(balance_of)
check "全挂(0,10) → 兜底第二个" "$B" '"balance": "roundrobin: 0, 1"'

# 对照：权重 10,0 → 优先级最高的是第一个 → 兜底应给第一个
rm -f "$SANDBOX"/rules/rule-*.conf
mkrule 1 "10.0.0.1" "" "roundrobin" "false"
mkrule 2 "10.0.0.2" "" "roundrobin" "false"
printf '\n' | apply_port_group_weight_config "443" "10,0" >/dev/null 2>&1
write_health "1|10.0.0.1|failed|3|0|0|0" "2|10.0.0.2|failed|3|0|0|0"
B=$(balance_of)
check "全挂(10,0) → 兜底第一个" "$B" '"balance": "roundrobin: 1, 0"'

echo "=============================================="
echo "10. 权重全 >0 且处于主备 → 自动切回轮询"
echo "=============================================="
rm -f "$SANDBOX"/rules/rule-*.conf
mkrule 1 "10.0.0.1" "" "active-standby" "true"
mkrule 2 "10.0.0.2" "" "active-standby" "true"
printf '\n' | apply_port_group_weight_config "443" "5,5" >/dev/null 2>&1
MODE1=$(grep '^BALANCE_MODE=' "$SANDBOX/rules/rule-1.conf" | head -1)
check "切回 roundrobin" "$MODE1" 'BALANCE_MODE="roundrobin"'
FO1=$(grep '^FAILOVER_ENABLED=' "$SANDBOX/rules/rule-1.conf" | head -1)
check "故障转移保持开启" "$FO1" 'FAILOVER_ENABLED="true"'

echo "=============================================="
echo "结果: PASS=$PASS FAIL=$FAIL"
echo "=============================================="
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
