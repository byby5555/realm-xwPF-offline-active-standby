#!/bin/bash
# 用例组 02 · 权重输入校验与主备（active-standby）规则状态
#
# 覆盖重点回归清单：
#   - 权重 1,0,0 合法
#   - 权重 0,0,0 必须被拒绝并提示，不得静默接受
#   - 权重数量与目标数不符必须被拒绝
#   - 权重超出 0-10 必须被拒绝
#   - 权重 1,0,0 → 规则里 BALANCE_MODE=active-standby、FAILOVER_ENABLED=true

# 在沙箱里 source 产品代码，执行一个函数，返回 rc + 输出
# 用法：_run_in_sandbox <bash 代码片段> [额外参数...]
_run_in_sandbox() {
    local code="$1"
    shift
    bash -c "$code" _ "$SBX_RUN" "$@" 2>&1
}

# 造一条规则文件（沙箱内）
_make_rule() {
    local file="$1" port="${2:-8080}" mode="${3:-roundrobin}" failover="${4:-false}" weights="${5:-1,0,0}" hosts="${6:-10.0.0.1,10.0.0.2,10.0.0.3}"
    mkdir -p "$(dirname "$file")"
    cat > "$file" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=rule-test
SECURITY_LEVEL=standard
LISTEN_PORT=$port
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$hosts
REMOTE_PORT=8080
ENABLED=true
BALANCE_MODE="$mode"
FAILOVER_ENABLED="$failover"
WEIGHTS="$weights"
EOF
}

case_T10_weight_valid() {
    h_case_begin "T10" "权重 1,0,0 合法" \
        "沙箱副本 core.sh + rules.sh" \
        "validate_weight_input '1,0,0' 3" \
        "返回码 0（合法）"

    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        declare -F validate_weight_input >/dev/null || { echo "FUNCTION_MISSING"; exit 3; }
        validate_weight_input "1,0,0" 3
    ')
    rc=$?
    h_log "输出: ${out:-<空>}"
    h_check_rc "0" "$rc" "validate_weight_input '1,0,0' 3"
}

case_T11_weight_all_zero() {
    h_case_begin "T11" "权重 0,0,0 必须被拒绝" \
        "沙箱副本 core.sh + rules.sh" \
        "validate_weight_input '0,0,0' 3" \
        "返回码非 0，并给出「不能全部为 0」的提示"

    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        validate_weight_input "0,0,0" 3
    ')
    rc=$?
    h_log "输出: ${out:-<空>}"
    h_check_rc "nonzero" "$rc" "validate_weight_input '0,0,0' 3"
    h_check_contains "$out" "全部为 0" "拒绝提示文案"
}

case_T12_weight_count_mismatch() {
    h_case_begin "T12" "权重数量与目标数不符必须被拒绝" \
        "沙箱副本 core.sh + rules.sh" \
        "validate_weight_input '1,0' 3" \
        "返回码非 0，并提示数量不匹配"

    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        validate_weight_input "1,0" 3
    ')
    rc=$?
    h_log "输出: ${out:-<空>}"
    h_check_rc "nonzero" "$rc" "validate_weight_input '1,0' 3"
    h_check_contains "$out" "数量不匹配" "拒绝提示文案"
}

case_T13_weight_range() {
    h_case_begin "T13" "权重越界/非法字符必须被拒绝" \
        "沙箱副本 core.sh + rules.sh" \
        "validate_weight_input '11,0,0' / '1,0,-1' / '1,0,x' / '10,0,0'" \
        "越界与非法输入返回码非 0；10,0,0（边界）返回码 0"

    local snippet='
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        w="$2"; n="$3"
        validate_weight_input "$w" "$n"
        rc=$?
        echo "RC=$rc"
        exit $rc
    '

    local out rc
    out=$(_run_in_sandbox "$snippet" "11,0,0" 3); rc=$?
    h_log "11,0,0 -> ${out:-<空>}"
    h_check_rc "nonzero" "$rc" "validate_weight_input '11,0,0' 3"

    out=$(_run_in_sandbox "$snippet" "1,0,-1" 3); rc=$?
    h_log "1,0,-1 -> ${out:-<空>}"
    h_check_rc "nonzero" "$rc" "validate_weight_input '1,0,-1' 3"

    out=$(_run_in_sandbox "$snippet" "1,0,x" 3); rc=$?
    h_log "1,0,x -> ${out:-<空>}"
    h_check_rc "nonzero" "$rc" "validate_weight_input '1,0,x' 3"

    out=$(_run_in_sandbox "$snippet" "10,0,0" 3); rc=$?
    h_log "10,0,0 -> ${out:-<空>}"
    h_check_rc "0" "$rc" "validate_weight_input '10,0,0' 3（边界合法）"
}

case_T14_active_standby_rule_state() {
    h_case_begin "T14" "权重 1,0,0 → 规则进入主备态" \
        "沙箱 rules 目录（自造 rule-1.conf）" \
        "auto_enable_active_standby 8080" \
        "规则文件写入 BALANCE_MODE=active-standby、FAILOVER_ENABLED=true，并补齐健康检查参数"

    local rule="$SBX_ROOT/realm/rules/rule-1.conf"
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 roundrobin false "1,0,0"

    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        auto_enable_active_standby 8080
        echo "RC=$?"
    ')
    rc=$?
    h_log "输出: ${out:-<空>}"
    h_log "--- 规则文件内容 ---"
    while IFS= read -r l; do h_log "  $l"; done < "$rule"

    h_check_file_has "$rule" 'BALANCE_MODE="active-standby"' "BALANCE_MODE"
    h_check_file_has "$rule" 'FAILOVER_ENABLED="true"' "FAILOVER_ENABLED"
    h_check_file_has "$rule" 'HEALTH_CHECK_INTERVAL="4"' "HEALTH_CHECK_INTERVAL"
    h_check_file_has "$rule" 'FAILURE_THRESHOLD="2"' "FAILURE_THRESHOLD"
    h_check_file_has "$rule" 'SUCCESS_THRESHOLD="2"' "SUCCESS_THRESHOLD"
    h_check_file_has "$rule" 'CONNECTION_TIMEOUT="3"' "CONNECTION_TIMEOUT"
    h_check_file_has "$rule" 'RECOVERY_COOLDOWN="120"' "RECOVERY_COOLDOWN"
}

case_T15_weights_contain_zero() {
    h_case_begin "T15" "权重含 0 的主备判定" \
        "沙箱副本 core.sh + rules.sh" \
        "weights_contain_zero '1,0,0' / '1,1,1'" \
        "含 0 → 返回 0（识别为主备）；全 >0 → 返回非 0"

    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        weights_contain_zero "1,0,0"; echo "RC_ZERO=$?"
        weights_contain_zero "1,1,1"; echo "RC_NOZERO=$?"
    ')
    h_log "输出: ${out:-<空>}"
    h_check_contains "$out" "RC_ZERO=0" "含 0 判定"
    h_check_contains "$out" "RC_NOZERO=1" "全大于 0 判定"
}
