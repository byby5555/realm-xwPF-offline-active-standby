#!/bin/bash
# 用例组 02 · 权重输入校验与主备（active-standby）规则状态
#
# 覆盖重点回归清单：
#   - 权重 1,0,0 合法
#   - 权重 0,0,0 必须被拒绝并提示，不得静默接受
#   - 权重数量与目标数不符必须被拒绝
#   - 权重超出 0-10 必须被拒绝
#   - 权重 1,0,0 → 规则里 BALANCE_MODE=active-standby、FAILOVER_ENABLED=true

# 公共工具在 00_common.sh（_run_in_sandbox / _make_rule ...）

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
    # CONNECTION_TIMEOUT 的期望值**从产品自己声明的默认值抽**
    #   原因：探测预算 3s → 10s 是**产品侧**改动（check_connectivity 默认值 /
    #   lib/health.sh 的 ${CONNECTION_TIMEOUT:-N} / 规则模板默认值）。
    #   台架写死 "3" → 产品改一次就红一次（假红），而且红的原因会被误读成「台架坏了」。
    local ct_def
    ct_def=$(sed -n 's/.*_ensure_rule_field_default[^"]*"CONNECTION_TIMEOUT"[^"]*"\([0-9]\+\)".*/\1/p' "$SBX_SRC/lib/rules.sh" 2>/dev/null | head -1)
    [ -z "$ct_def" ] && ct_def=$(sed -n 's/.*CONNECTION_TIMEOUT:-\([0-9]\+\).*/\1/p' "$SBX_SRC/lib/health.sh" 2>/dev/null | head -1)
    if [ -z "$ct_def" ]; then
        h_log "抽不到产品声明的 CONNECTION_TIMEOUT 默认值 → 退回区间断言（1..30）"
        local ct_val
        ct_val=$(sed -n 's/^CONNECTION_TIMEOUT="\([0-9]\+\)".*/\1/p' "$rule" 2>/dev/null | head -1)
        if [ -n "$ct_val" ] && [ "$ct_val" -ge 1 ] && [ "$ct_val" -le 30 ]; then
            h_pass "CONNECTION_TIMEOUT=$ct_val 在 1..30 区间内"
        else
            h_fail "CONNECTION_TIMEOUT 取不到或不在 1..30 区间（值=<$ct_val>）"
        fi
    else
        h_log "产品声明的 CONNECTION_TIMEOUT 默认值 = $ct_def"
        h_check_file_has "$rule" "CONNECTION_TIMEOUT=\"$ct_def\"" "CONNECTION_TIMEOUT（跟产品声明的默认值）"
    fi
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
