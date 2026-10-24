#!/bin/bash
# 时延（延迟）测量测试
# 用法: bash tests/test_latency.sh
#
# 覆盖：
#   A. 时间打点 now_us
#   B. 带耗时的探测 probe_with_latency
#   C. 时延辅助函数（平均 / 格式化 / 读状态记录）
#   D. 生成的 health_check.sh 真跑一轮 → 状态文件里必须有真实时延
#   E. 负载均衡菜单确实展示了时延（静态核对）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"

SANDBOX="$(mktemp -d)"
PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 期望 [$3] 实际 [$2]"; fi; }

mkdir -p "$SANDBOX/health" "$SANDBOX/rules" "$SANDBOX/bin" "$SANDBOX/realm/health" "$SANDBOX/realm/rules" "$SANDBOX/lock"

# flock / journalctl 桩：生成的健康检查脚本要用
cat > "$SANDBOX/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$SANDBOX/bin/journalctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/bin/flock" "$SANDBOX/bin/journalctl"

export PATH="$SANDBOX/bin:$PATH"

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

echo "=============================================="
echo "A. 时间打点 now_us"
echo "=============================================="
t1=$(now_us); rc1=$?
t2=$(now_us); rc2=$?
check "now_us 退出码 0" "$rc1" "0"
check "now_us 退出码 0（第二次）" "$rc2" "0"
check "now_us 返回纯数字（微秒）" "$(echo "$t1" | grep -q '^[0-9]\+$' && echo yes || echo no)" "yes"
check "now_us 单调递增" "$([ "$t2" -ge "$t1" ] && echo yes || echo no)" "yes"
check "now_us 量级合理（> 1e12 微秒）" "$([ "${#t1}" -ge 13 ] && echo yes || echo no)" "yes"

echo "=============================================="
echo "B. 带耗时的探测 probe_with_latency"
echo "=============================================="
python -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',18099)); s.listen(8)
time.sleep(30)
" &
PY_PID=$!
sleep 1.5

probe_with_latency "127.0.0.1" "18099" 3
rc=$?
check "可达端口 → 退出码 0" "$rc" "0"
check "PROBE_LATENCY_MS 是数字" "$(echo "$PROBE_LATENCY_MS" | grep -q '^[0-9]\+$' && echo yes || echo no)" "yes"
check "PROBE_LATENCY_MS 合理（< 3000ms）" "$([ "$PROBE_LATENCY_MS" -lt 3000 ] && echo yes || echo no)" "yes"

probe_with_latency "127.0.0.1" "18098" 2
rc=$?
check "关闭端口 → 退出码非 0" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

kill $PY_PID 2>/dev/null; wait $PY_PID 2>/dev/null

echo "=============================================="
echo "C. 时延辅助函数"
echo "=============================================="
check "latency_avg_ms 求平均" "$(latency_avg_ms "10,20,30")" "20"
check "latency_avg_ms 单值" "$(latency_avg_ms "15")" "15"
latency_avg_ms "" >/dev/null 2>&1
check "latency_avg_ms 空输入 → 非 0" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"
check "format_latency_display 带历史" "$(format_latency_display "12" "10,20,30")" "12ms (均 20ms)"
check "format_latency_display 无历史" "$(format_latency_display "12" "")" "12ms"
check "format_latency_display 无数据" "$(format_latency_display "" "")" "-"

cat > "$HEALTH_STATUS_FILE" <<'EOF'
# Realm健康状态文件
1|127.0.0.1|healthy|0|3|1792810000|0|12|10,12,14
EOF
rec=$(get_health_status_record "127.0.0.1")
check "读状态记录返回整行" "$rec" "1|127.0.0.1|healthy|0|3|1792810000|0|12|10,12,14"
get_health_status_record "10.9.9.9" >/dev/null 2>&1
check "读不存在的目标 → 非 0" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"

echo "=============================================="
echo "D. 生成的 health_check.sh 真跑一轮"
echo "=============================================="
python -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',18097)); s.listen(8)
time.sleep(30)
" &
PY2=$!
sleep 1.5

health_check_script_body > "$SANDBOX/health_check.sh"
sed -i "s|/etc/realm|$SANDBOX/realm|g; s|/var/lock|$SANDBOX/lock|g" "$SANDBOX/health_check.sh"
cat > "$SANDBOX/realm/rules/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=latency-test
SECURITY_LEVEL=none
LISTEN_PORT=8080
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=18097
ENABLED=true
BALANCE_MODE="active-standby"
TARGET_STATES=""
WEIGHTS="10,0"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF

bash "$SANDBOX/health_check.sh" > "$SANDBOX/hc.log" 2>&1
check "健康检查脚本退出码 0" "$?" "0"

STATUS_FILE="$SANDBOX/realm/health/health_status.conf"
line=$(grep '^1|127.0.0.1|' "$STATUS_FILE" 2>/dev/null | head -1)
if [ -n "$line" ]; then ok "状态文件写入了目标记录"; else bad "状态文件没有记录"; fi
fields=$(echo "$line" | awk -F'|' '{print NF}')
check "状态记录 9 个字段（含时延）" "$fields" "9"
lat=$(echo "$line" | cut -d'|' -f8)
check "第 8 个字段是时延毫秒数" "$(echo "$lat" | grep -q '^[0-9]\+$' && echo yes || echo no)" "yes"
hist=$(echo "$line" | cut -d'|' -f9)
check "第 9 个字段是时延历史" "$(echo "$hist" | grep -q '^[0-9]\+' && echo yes || echo no)" "yes"

# 再跑两轮，历史应累积（最多保留 5 个样本）
bash "$SANDBOX/health_check.sh" >/dev/null 2>&1
bash "$SANDBOX/health_check.sh" >/dev/null 2>&1
line2=$(grep '^1|127.0.0.1|' "$STATUS_FILE" 2>/dev/null | head -1)
hist2=$(echo "$line2" | cut -d'|' -f9)
cnt=$(echo "$hist2" | tr ',' '\n' | grep -c .)
check "历史样本累积到 3 个" "$cnt" "3"

for i in 1 2 3 4; do bash "$SANDBOX/health_check.sh" >/dev/null 2>&1; done
line3=$(grep '^1|127.0.0.1|' "$STATUS_FILE" 2>/dev/null | head -1)
hist3=$(echo "$line3" | cut -d'|' -f9)
cnt3=$(echo "$hist3" | tr ',' '\n' | grep -c .)
check "历史样本最多保留 5 个" "$cnt3" "5"

kill $PY2 2>/dev/null; wait $PY2 2>/dev/null

echo "=============================================="
echo "E. 菜单展示时延"
echo "=============================================="
check "两条目标行都带上时延" "$(grep -c 'failover_info\$latency_info' "$REPO/lib/rules.sh")" "2"
check "定义了立即测试函数" "$(grep -c '^probe_all_targets_latency() {' "$REPO/lib/rules.sh")" "1"
check "菜单提供「立即测试所有目标时延」" "$(grep -c '立即测试所有目标时延' "$REPO/lib/rules.sh")" "1"
check "菜单提示时延来源与刷新周期" "$(grep -c '由后台健康检查持续更新' "$REPO/lib/rules.sh")" "1"

echo "=============================================="
echo "F. 真跑一次负载均衡菜单，看渲染结果"
echo "=============================================="
rm -f "$SANDBOX"/rules/rule-*.conf
cat > "$SANDBOX/rules/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=latency-menu
SECURITY_LEVEL=none
LISTEN_PORT=8080
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=18097
ENABLED=true
BALANCE_MODE="active-standby"
TARGET_STATES=""
WEIGHTS="10,0"
FAILOVER_ENABLED="true"
EOF
cat > "$SANDBOX/rules/rule-2.conf" <<EOF
RULE_ID=2
RULE_ROLE=1
RULE_NAME=latency-menu
SECURITY_LEVEL=none
LISTEN_PORT=8080
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.2
REMOTE_PORT=18097
ENABLED=true
BALANCE_MODE="active-standby"
TARGET_STATES=""
WEIGHTS="0"
FAILOVER_ENABLED="true"
EOF
cat > "$HEALTH_STATUS_FILE" <<'EOF'
1|127.0.0.1|healthy|0|3|1792810000|0|12|10,12,14
2|127.0.0.2|healthy|0|3|1792810000|0|88|80,90
EOF

# 菜单必须在 set -u 下也跑得通：任何一个未定义变量都会让菜单中途崩掉
menu_out=$( ( set -u; printf '0\n' | load_balance_management_menu ) 2>&1)
echo "$menu_out" | grep -E '127\.0\.0\.[12]:18097' | sed 's/^/    /'
check "菜单渲染出主目标时延" "$(echo "$menu_out" | grep -c '\[时延: 12ms (均 12ms)\]')" "1"
check "菜单渲染出备目标时延" "$(echo "$menu_out" | grep -c '\[时延: 88ms (均 85ms)\]')" "1"
check "菜单渲染出健康状态" "$(echo "$menu_out" | grep -c '\[健康\]')" "2"
check "菜单含立即测试入口" "$(echo "$menu_out" | grep -c '立即测试所有目标时延')" "1"
check "菜单在 set -u 下没崩" "$(echo "$menu_out" | grep -c 'unbound variable')" "0"

echo "=============================================="
echo "结果: PASS=$PASS FAIL=$FAIL"
echo "=============================================="
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
