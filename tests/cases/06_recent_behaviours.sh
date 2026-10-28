#!/bin/bash
# 用例组 06 · 第 2 轮 M1/M2/M5/M7/M8 的行为回归（第 4 轮新增）
#
# 这几条都是**产品行为变了**的地方，台架必须跟着长出用例，否则改完没人知道对不对：
#
#   M1  规则文件解析唯一化：read_rule_file 唯一实现在 lib/health.sh，白名单逐行解析，
#       **不 source / 不 eval**。health_check.sh 以 root 跑，规则文件里带 $(...) 就是提权面。
#       → T35 断言规则里的命令不会被执行。
#   M2  进主备时清空 TARGET_STATES：主备模式下 lib/realm.sh 用 TARGET_STATES 覆盖 REMOTE_HOST，
#       留着剔除模式留下的陈旧结果会让备机静默丢掉流量。 → T36。
#   M5  健康检查起不来 → 打印真实原因 + 回滚 BALANCE_MODE / FAILOVER_ENABLED / TARGET_STATES。
#       不回滚就会留下「配置显示主备、实际不切换」的半吊子状态。 → T37。
#   M7  新增规则字段 PREV_BALANCE_MODE：进主备时记下原模式，权重改回全 >0 时**切回原模式**
#       （iphash 不再被写死 roundrobin 覆盖）。 → T38。
#   M8  含 0 切主备前二次确认：答 n 即取消；回车 = 确认；第三个参数 1 = 调用方已确认过，不再问。
#       → T39。

# 读规则文件里某个字段的值（沙箱内）
_rule_field() {
    local file="$1" key="$2"
    [ -f "$file" ] || { printf '<无文件>'; return; }
    local v
    v=$(grep -m1 "^${key}=" "$file" 2>/dev/null | sed -E "s|^${key}=(.*)$|\1|")
    [ -z "$v" ] && v="<无此键>"
    printf '%s' "$v"
}

# ─────────────────────────────────────────────────────────────
# T35 · M1 安全：规则文件解析绝不执行其中内容
case_T35_rule_parse_no_exec() {
    h_case_begin "T35" "规则文件解析不执行其中内容（M1 安全）" \
        "沙箱 rules（含 \$(...) 的规则文件）" \
        "read_rule_file <规则文件>" \
        "规则里的命令不会被执行；白名单外的键不会被赋值"

    local marker="$SBX_ROOT/rule_exec_marker"
    local rule="$SBX_ROOT/realm/rules/rule-1.conf"
    mkdir -p "$(dirname "$rule")"
    rm -f "$marker"

    # EVIL 的值里带命令替换；EVIL2 是裸命令替换。两者都必须在解析时**不被执行**。
    cat > "$rule" <<EOF
RULE_ID=1
RULE_ROLE="1"
RULE_NAME="evil-probe"
LISTEN_PORT=8080
REMOTE_HOST=10.0.0.1
REMOTE_PORT=8080
ENABLED="true"
BALANCE_MODE="off"
WEIGHTS="1,0"
EVIL="\$(touch $marker)"
EVIL2=\$(touch $marker)
EOF

    # 主口径：走产品解析器
    local out
    out=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        read_rule_file "$2"
        echo "RC=$?"
        echo "EVIL=[${EVIL:-<未定义>}]"
    ' "$rule")
    h_log "解析输出: $(printf '%s' "$out" | tr '\n' ' ')"

    if [ -f "$marker" ]; then
        h_fail "规则文件里的命令被执行了（$marker 已生成）—— read_rule_file 仍在执行规则内容"
    else
        h_pass "规则文件里的命令未被执行（无 marker 生成）"
    fi
    h_check_contains "$out" "EVIL=[<未定义>]" "白名单外的键未被赋值"
    h_check_contains "$out" "RC=0" "read_rule_file 返回码"

    # 第二口径（防空过）：同一份规则文件如果被 source，命令**确实会执行** ——
    # 这证明上面那条「未执行」的断言不是空过。
    rm -f "$marker"
    bash -c "source '$rule'" >/dev/null 2>&1
    if [ -f "$marker" ]; then
        h_pass "第二口径：同一份规则文件被 source 时命令确实会执行（断言有效）"
    else
        h_fail "第二口径：source 同一份规则文件竟没执行命令 —— fixture 写错了，本用例的断言没有意义"
    fi
    rm -f "$marker"
}

# ─────────────────────────────────────────────────────────────
# T36 · M2：进主备时清空 TARGET_STATES
case_T36_enter_standby_clears_target_states() {
    h_case_begin "T36" "进主备时清空 TARGET_STATES（M2）" \
        "沙箱 rules（TARGET_STATES 非空）" \
        "auto_enable_active_standby 8080" \
        "进主备后 TARGET_STATES 被清空；不进主备时保持原样"

    local rule="$SBX_ROOT/realm/rules/rule-1.conf"
    local out
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 roundrobin false "1,0" "10.0.0.1,10.0.0.2"
    # 塞一个非空的 TARGET_STATES（模拟剔除模式留下的陈旧结果）
    sed -i 's|^TARGET_STATES=.*|TARGET_STATES="10.0.0.9"|' "$rule"
    h_log "进主备前 TARGET_STATES=$(_rule_field "$rule" TARGET_STATES)"

    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        auto_enable_active_standby 8080
        echo "RC=$?"
    ')
    h_log "输出: $(printf '%s' "$out" | tr '\n' ' ')"
    h_check_file_has "$rule" 'TARGET_STATES=""' "进主备后 TARGET_STATES"
    h_check_file_has "$rule" 'BALANCE_MODE="active-standby"' "进主备后 BALANCE_MODE"

    # 第二口径：权重全 >0（不进主备）时，TARGET_STATES 必须**原样保留**。
    # 注意：「进不进主备」由 apply_port_group_weight_config 的权重判定决定，
    # auto_enable_active_standby 本身不看权重、只要被调用就会切主备 —— 用它做对照组是错的。
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    local rule2="$SBX_ROOT/realm/rules/rule-2.conf"
    _make_rule "$rule2" 8090 roundrobin false "5,5" "10.0.0.1,10.0.0.2"
    sed -i 's|^TARGET_STATES=.*|TARGET_STATES="10.0.0.9"|' "$rule2"
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        apply_port_group_weight_config 8090 "5,5"
        echo "RC=$?"
    ')
    h_check_file_has "$rule2" 'TARGET_STATES="10.0.0.9"' "不进主备时 TARGET_STATES 保持原样"
}

# ─────────────────────────────────────────────────────────────
# T37 · M5：健康检查起不来 → 回滚主备开关
case_T37_health_start_failure_rollback() {
    h_case_begin "T37" "健康检查起不来时回滚主备开关（M5）" \
        "沙箱 rules + ensure_health_check_service 桩返回 1" \
        "apply_port_group_weight_config 8080 '1,0' 1" \
        "打印真实原因；BALANCE_MODE / FAILOVER_ENABLED / TARGET_STATES 全部回滚"

    local rule="$SBX_ROOT/realm/rules/rule-1.conf"
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 roundrobin false "1,0" "10.0.0.1,10.0.0.2"
    sed -i 's|^TARGET_STATES=.*|TARGET_STATES="10.0.0.9"|' "$rule"

    local out
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 1; }   # 探测端起不来
        apply_port_group_weight_config 8080 "1,0" 1
        echo "RC=$?"
    ')
    h_log "输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"

    h_check_contains "$out" "健康检查服务启动失败" "打印了真实失败原因"
    h_check_contains "$out" "已回滚" "明确告知已回滚"

    # 回滚后必须回到进主备之前的状态
    h_check_file_has "$rule" 'BALANCE_MODE="roundrobin"' "回滚后 BALANCE_MODE"
    h_check_file_has "$rule" 'FAILOVER_ENABLED="false"' "回滚后 FAILOVER_ENABLED"
    h_check_file_has "$rule" 'TARGET_STATES="10.0.0.9"' "回滚后 TARGET_STATES"

    # 第二口径：探测端正常时**不该**回滚
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 roundrobin false "1,0" "10.0.0.1,10.0.0.2"
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }   # 探测端正常
        apply_port_group_weight_config 8080 "1,0" 1
        echo "RC=$?"
    ')
    h_check_not_contains "$out" "已回滚" "探测端正常时不应回滚"
    h_check_file_has "$rule" 'BALANCE_MODE="active-standby"' "探测端正常时 BALANCE_MODE 保持主备"
}

# ─────────────────────────────────────────────────────────────
# T38 · M7：进主备记原模式，权重改回全 >0 时切回**原模式**
case_T38_prev_balance_mode_restore() {
    h_case_begin "T38" "切回原负载均衡模式（M7 PREV_BALANCE_MODE）" \
        "沙箱 rules（BALANCE_MODE=iphash）" \
        "auto_enable_active_standby → apply_port_group_weight_config '5,5'" \
        "进主备时记下 PREV_BALANCE_MODE=iphash；权重全 >0 时切回 iphash 而非写死 roundrobin"

    local rule="$SBX_ROOT/realm/rules/rule-1.conf"
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 iphash false "1,0" "10.0.0.1,10.0.0.2"

    local out
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        auto_enable_active_standby 8080
        echo "RC=$?"
    ')
    h_log "进主备后 BALANCE_MODE=$(_rule_field "$rule" BALANCE_MODE)  PREV_BALANCE_MODE=$(_rule_field "$rule" PREV_BALANCE_MODE)"
    h_check_file_has "$rule" 'BALANCE_MODE="active-standby"' "进主备后 BALANCE_MODE"
    h_check_file_has "$rule" 'PREV_BALANCE_MODE="iphash"' "进主备时记下的原模式"

    # 权重改回全 >0 → 必须切回 iphash（不是写死 roundrobin）
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        apply_port_group_weight_config 8080 "5,5"
        echo "RC=$?"
    ')
    h_log "切回输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    h_log "切回后 BALANCE_MODE=$(_rule_field "$rule" BALANCE_MODE)"
    h_check_file_has "$rule" 'BALANCE_MODE="iphash"' "切回后 BALANCE_MODE（应为原模式 iphash）"

    # 第二口径：原模式是 roundrobin 时，切回也应是 roundrobin
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 roundrobin false "1,0" "10.0.0.1,10.0.0.2"
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        auto_enable_active_standby 8080
    ')
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        apply_port_group_weight_config 8080 "5,5"
    ')
    h_check_file_has "$rule" 'BALANCE_MODE="roundrobin"' "原模式为 roundrobin 时切回 roundrobin"
}

# ─────────────────────────────────────────────────────────────
# T39 · M8：含 0 切主备前的二次确认
case_T39_active_standby_confirm() {
    h_case_begin "T39" "含 0 切主备前的二次确认（M8）" \
        "沙箱 rules + 喂 stdin" \
        "apply_port_group_weight_config 8080 '1,0'" \
        "答 n → 取消且模式不变；回车 → 确认切主备；第三个参数 1 → 不询问"

    local rule="$SBX_ROOT/realm/rules/rule-1.conf"
    local out

    # 场景 1：答 n → 取消
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 roundrobin false "1,0" "10.0.0.1,10.0.0.2"
    out=$(printf 'n\n\n' | _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        apply_port_group_weight_config 8080 "1,0"
        echo "RC=$?"
    ')
    h_log "场景1(答n) 输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    h_check_contains "$out" "已取消主备模式切换" "答 n 时明确提示已取消"
    h_check_file_has "$rule" 'BALANCE_MODE="roundrobin"' "答 n 时 BALANCE_MODE 保持原样"

    # 场景 2：回车 = 确认
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 roundrobin false "1,0" "10.0.0.1,10.0.0.2"
    out=$(printf '\n' | _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        apply_port_group_weight_config 8080 "1,0"
        echo "RC=$?"
    ')
    h_log "场景2(回车) 输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    # ⚠ 不能断言提示文本：bash 的 `read -p` 只在 **stdin 是终端** 时才把提示打到 stderr
    #   （bash 手册原文："The prompt is displayed only if input is coming from a terminal"）。
    #   沙箱里喂的是管道 → 提示根本不显示。只能断言**行为**。
    h_check_not_contains "$out" "已取消主备模式切换" "回车（未答 n）时不应取消"
    h_check_file_has "$rule" 'BALANCE_MODE="active-standby"' "回车确认后切到主备"

    # 场景 3：第三个参数 1 = 调用方已确认过 → 不再询问
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_rule "$rule" 8080 roundrobin false "1,0" "10.0.0.1,10.0.0.2"
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        apply_port_group_weight_config 8080 "1,0" 1
        echo "RC=$?"
    ')
    h_log "场景3(第三个参数=1) 输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    # 「注意：切到主备模式会同时做三件事」是询问分支里 echo 到 stdout 的，管道里也看得到 → 可断言
    h_check_not_contains "$out" "注意：切到主备模式会同时做三件事" "第三个参数=1 时不应再询问"
    h_check_file_has "$rule" 'BALANCE_MODE="active-standby"' "第三个参数=1 时仍应切到主备"
}
