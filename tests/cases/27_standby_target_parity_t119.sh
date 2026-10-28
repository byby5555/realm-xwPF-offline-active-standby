#!/bin/bash
# 用例组 27 · 主备目标枚举口径：探测端与路由端必须同一份
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   同一组目标要被两个地方枚举：
#     · 探测端（lib/health.sh 的探测脚本）：把探测结果写进状态文件
#       （行键 = RULE_ID|host:port）
#     · 路由端（lib/realm.sh 生成 endpoints）：按状态文件决定谁当主、谁当备
#   两端口径不一致 ⇒ 状态行匹配不上配置里的目标
#   ⇒ **主备切换静默失效**（不报错、不出日志、界面也看不出来）。
#
# ── 真实触发场景（真机 103.42.31.186 迁移时撞到）──────────────
#   老的「进程级主备池」支持「同 host 不同端口」的备机
#   （primary 103.42.31.186:28081 / backup 103.42.31.186:28082）。
#   规则级主备要表达同一件事，只能靠 TARGET_STATES（每项自带 host:port）。
#   而修复前：路由端认 TARGET_STATES、探测端只认 REMOTE_HOST × REMOTE_PORT
#   ⇒ 两边的目标集对不上 ⇒ 这类备机**永远切不过去**。
#
# ★ 全部在沙箱里做：规则/状态/生成物都落在沙箱路径（路径重定向在源码层生效）。

# 造一条「每目标自带端口」的主备规则
_t27_make_rule() {
    local rule_file="$1"
    local target_states="$2"
    local remote_host="$3"
    local remote_port="$4"

    cat > "$rule_file" <<EOF
RULE_ID=1
RULE_NAME="standby-parity"
RULE_ROLE="1"
SECURITY_LEVEL="none"
LISTEN_PORT="19900"
LISTEN_IP="0.0.0.0"
THROUGH_IP="::"
REMOTE_HOST="$remote_host"
REMOTE_PORT="$remote_port"
TLS_SERVER_NAME=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_NOTE="主备目标口径用例"
ENABLED="true"
CREATED_TIME="2026-10-26 00:00:00"
BALANCE_MODE="active-standby"
PREV_BALANCE_MODE=""
TARGET_STATES="$target_states"
WEIGHTS="10,0"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="10"
RECOVERY_COOLDOWN="120"
PROBE_QUALITY_WINDOW="20"
MPTCP_MODE="off"
PROXY_MODE="off"
EOF
}

# 路由端产出的目标集合（排序去重）
_t27_route_targets() {
    local endpoints="$1"
    printf '%s\n' "$endpoints" \
        | grep -oE '[0-9A-Za-z_.-]+:[0-9]+' \
        | grep -v ':19900$' \
        | sort -u
}

# 探测端写进状态文件的目标集合（排序去重）
_t27_state_targets() {
    local health="$1"
    [ -f "$health" ] || return 0
    grep -v '^#' "$health" 2>/dev/null \
        | awk -F'|' 'NF>=2 {print $2}' \
        | sort -u
}


case_T119_standby_probe_route_target_parity() {
    h_case_begin "T119" "主备目标口径：探测端与路由端枚举出同一组目标" \
        "沙箱规则（TARGET_STATES 形态：同 host 不同端口的备机）" \
        "generate_endpoints_from_rules（路由端） + 生成的 health_check.sh 跑一轮（探测端）" \
        "两边的目标集合完全一致；TARGET_STATES 里的备机（127.0.0.1:18102）两边都看得见"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local hc="$SBX_ROOT/health_check_t119.sh"
    mkdir -p "$rules" "$SBX_ROOT/realm/health"
    rm -f "$rules"/rule-*.conf "$health"

    # 同 host 不同端口：18101 是主、18102 是备
    _t27_make_rule "$rules/rule-1.conf" "127.0.0.1:18101,127.0.0.1:18102" "127.0.0.1" "18101"

    # ── 路由端 ──
    local endpoints
    endpoints=$(_run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        source "$1/lib/realm.sh"  >/dev/null 2>&1
        generate_endpoints_from_rules
    ' 2>/dev/null)
    h_log "--- 路由端 endpoints ---"
    printf '%s\n' "$endpoints" | head -20 | sed 's/^/    /'

    # ── 探测端（跑真正的生成物）──
    _run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' > "$hc" 2>/dev/null
    h_check_file "$hc" "生成的 health_check.sh"
    h_check_ge "1" "$(grep -c '^rule_target_endpoints() {' "$hc")" "生成物里带着共用真源（目标枚举口径）"

    bash "$hc" >/dev/null 2>&1
    h_log "--- 探测端写出的状态文件 ---"
    cat "$health" 2>/dev/null | sed 's/^/    /'

    local route_targets state_targets
    route_targets=$(_t27_route_targets "$endpoints")
    state_targets=$(_t27_state_targets "$health")
    h_log "--- 路由端目标集 ---"; printf '%s\n' "$route_targets" | sed 's/^/    /'
    h_log "--- 探测端目标集 ---"; printf '%s\n' "$state_targets" | sed 's/^/    /'

    h_check_contains "$route_targets" "127.0.0.1:18102" "路由端看得见 TARGET_STATES 里的备机"
    h_check_contains "$state_targets" "127.0.0.1:18102" "探测端也看得见 TARGET_STATES 里的备机"
    h_check_eq "$route_targets" "$state_targets" "探测端与路由端的目标集合完全一致"

    # 清理：别把这条规则留给后面的用例
    rm -f "$rules"/rule-*.conf "$health" "$hc"
}


case_T120_standby_probe_route_parity_negative_control() {
    h_case_begin "T120" "负向对照：探测端退回旧口径时，T119 的断言必须红" \
        "沙箱规则 + 被退化的生成物（目标枚举改回 REMOTE_HOST × REMOTE_PORT）" \
        "把生成物里的 rule_target_endpoints 换成旧口径再跑一轮" \
        "退化后状态文件里**不再有** 127.0.0.1:18102 ⇒ 证明 T119 的断言真的来自口径，不是恒绿"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local hc="$SBX_ROOT/health_check_t120.sh"
    local hcd="$SBX_ROOT/health_check_t120_degraded.sh"
    mkdir -p "$rules" "$SBX_ROOT/realm/health"
    rm -f "$rules"/rule-*.conf "$health"

    _t27_make_rule "$rules/rule-1.conf" "127.0.0.1:18101,127.0.0.1:18102" "127.0.0.1" "18101"

    _run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' > "$hc" 2>/dev/null

    # 注入式退化：把共用真源换成**旧口径**（只认 REMOTE_HOST × REMOTE_PORT）
    #   —— 这是修复前探测端的真实行为，不是凭空编的。
    awk '
        /^rule_target_endpoints\(\) \{/ {
            print "rule_target_endpoints() {"
            print "    printf \"%s\" \"${REMOTE_HOST}:${REMOTE_PORT}\""
            print "}"
            skip=1
            next
        }
        skip && /^\}/ { skip=0; next }
        skip { next }
        { print }
    ' "$hc" > "$hcd" 2>/dev/null
    h_check_file "$hcd" "退化的生成物"
    h_check_ge "1" "$(grep -c 'rule_target_endpoints() {' "$hcd")" "退化产物里还有这个函数（只是被换成了旧口径）"
    h_check_contains "$(cat "$hcd" 2>/dev/null)" 'printf "%s" "${REMOTE_HOST}:${REMOTE_PORT}"' "退化产物用的确实是旧口径"

    bash "$hcd" >/dev/null 2>&1
    local state_targets
    state_targets=$(_t27_state_targets "$health")
    h_log "--- 退化后探测端目标集 ---"; printf '%s\n' "$state_targets" | sed 's/^/    /'

    h_check_not_contains "$state_targets" "127.0.0.1:18102" "退化后探测端看不见那个备机了（= 口径不一致时确实会漏）"
    h_check_contains "$state_targets" "127.0.0.1:18101" "退化后只看得到 REMOTE_HOST × REMOTE_PORT 那一个目标"

    rm -f "$rules"/rule-*.conf "$health" "$hc" "$hcd"
}


case_T121_standby_auto_enable_keeps_explicit_target_states() {
    h_case_begin "T121" "进主备时不得抹掉「每目标自带端口」的备机" \
        "沙箱规则（TARGET_STATES 两种形态）" \
        "auto_enable_active_standby" \
        "显式目标列表（条目数 ≥ 完整目标数）必须原样保留；剔除模式残留（条目数更少）必须清空"

    local rules="$SBX_ROOT/realm/rules"
    mkdir -p "$rules"

    # ── 形态 1：显式的每目标端口列表（2 条）vs 完整目标（REMOTE_HOST 1 条）⇒ 保留 ──
    rm -f "$rules"/rule-*.conf
    _t27_make_rule "$rules/rule-1.conf" "127.0.0.1:18101,127.0.0.1:18102" "127.0.0.1" "18101"
    _run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        auto_enable_active_standby 19900
    ' >/dev/null 2>&1
    local kept
    kept=$(grep -E '^TARGET_STATES=' "$rules/rule-1.conf" | head -1)
    h_log "形态 1（显式每目标端口）处理后: $kept"
    h_check_contains "$kept" "18102" "显式写的每目标端口备机没有被抹掉"

    # ── 形态 2：剔除模式残留（1 条）vs 完整目标（REMOTE_HOST 2 条）⇒ 清空 ──
    rm -f "$rules"/rule-*.conf
    _t27_make_rule "$rules/rule-1.conf" "127.0.0.1:18101" "127.0.0.1,127.0.0.2" "18101"
    _run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        auto_enable_active_standby 19900
    ' >/dev/null 2>&1
    local cleared
    cleared=$(grep -E '^TARGET_STATES=' "$rules/rule-1.conf" | head -1)
    h_log "形态 2（剔除模式残留）处理后: $cleared"
    h_check_eq 'TARGET_STATES=""' "$cleared" "剔除模式残留仍然被清空（M2 旧行为保留）"

    rm -f "$rules"/rule-*.conf
}


# ─────────────────────────────────────────────────────────────
# T122 · 共用真源不可用时，探测端生成物不许被换成残缺版
#
# ★ 这组用例守的是「静默失效」的最后一道闸：
#   探测脚本（health_check.sh）里带着 rule_target_endpoints（目标枚举口径）。
#   抽取失败时如果**照装不误**，探测端就一个目标都枚举不到 ——
#   状态文件永远不更新 ⇒ 主备**永远不切**（不报错、不出日志、界面也看不出来）。
#   ⇒ 必须报错 + 拒绝安装 + 不许把原来能跑的那份覆盖掉。
# ─────────────────────────────────────────────────────────────

# 造一个 lib/：health.sh 是真的，core.sh 是被退化过的（没有 rule_target_endpoints）
_t122_make_degraded_lib() {
    local libdir="$1"
    mkdir -p "$libdir"
    cp "$SBX_RUN/lib/health.sh" "$libdir/health.sh"
    # 退化：从 core.sh 里把 rule_target_endpoints 整块拿掉
    #   （= 「core.sh 是旧版 / 这次没一起升级」的真实形态，不是凭空编的）
    awk '
        /^rule_target_endpoints\(\) \{/ { skip=1; next }
        skip && /^\}/ { skip=0; next }
        skip { next }
        { print }
    ' "$SBX_RUN/lib/core.sh" > "$libdir/core.sh"
}

case_T122_shared_core_missing_must_not_install_broken_probe() {
    h_case_begin "T122" "共用真源不可用时：必须报错 + 拒绝安装 + 不许覆盖能跑的那份" \
        "沙箱 lib/（health.sh 真的 + core.sh 被退化：没有 rule_target_endpoints）" \
        "health_check_script_regenerate" \
        "退化时退出码非 0 + 报错点名 rule_target_endpoints + 目标脚本保持原样（还是能跑的那份）"

    local base="$SBX_ROOT/t122"
    local libdir="$base/lib"
    local target="$base/health_check.sh"
    rm -rf "$base"
    mkdir -p "$base"

    # ── 腿 1（阳性对照）：真源在位 ⇒ 生成成功，且产物带着共用真源 ──
    mkdir -p "$libdir"
    cp "$SBX_RUN/lib/health.sh" "$libdir/health.sh"
    cp "$SBX_RUN/lib/core.sh" "$libdir/core.sh"

    local out rc n
    # ★ 必须 source **这个 lib/ 里的** health.sh：
    #   共用真源的定位是「health.sh 的同级目录」⇒ source 哪个 health.sh
    #   就决定了它去找哪个 core.sh。source 冻结态那份 = 永远找到好的 core.sh
    #   ⇒ 负向对照根本不会被触发（恒绿）。
    out=$(_run_in_sandbox '
        source "$2/health.sh" >/dev/null 2>&1
        health_check_script_regenerate "$3"
        exit $?
    ' "$libdir" "$target" 2>&1)
    rc=$?
    h_log "阳性对照输出: $(printf '%s' "$out" | tr '\n' ' ')"
    h_check_rc 0 "$rc" "阳性对照：共用真源在位时生成成功"
    n=$(grep -c '^rule_target_endpoints() {' "$target" 2>/dev/null); n=${n:-0}
    h_check_ge "1" "$n" "阳性对照：产物里带着共用真源"

    # ── 腿 2（负向对照）：共用真源退化 ⇒ 必须报错 + 拒绝安装 ──
    _t122_make_degraded_lib "$libdir"
    n=$(grep -c '^rule_target_endpoints() {' "$libdir/core.sh" 2>/dev/null); n=${n:-0}
    h_check_eq "0" "$n" "负向对照前提：core.sh 里已没有共用真源"

    # 放一份「原来能跑的脚本」当对照：失败时它必须原封不动
    printf '#!/bin/bash\necho OLD-WORKING-PROBE\n' > "$target"
    local before after
    before="$(cat "$target")"

    out=$(_run_in_sandbox '
        source "$2/health.sh" >/dev/null 2>&1
        health_check_script_regenerate "$3"
        exit $?
    ' "$libdir" "$target" 2>&1)
    rc=$?
    h_log "负向对照输出: $(printf '%s' "$out" | tr '\n' ' ')"
    h_check_contains "$out" "rule_target_endpoints" "负向对照：报错必须点名缺的是哪个函数"
    h_check_eq "1" "$rc" "负向对照：生成必须失败（退出码 1，不是「找不到命令」那种 127）"

    after="$(cat "$target" 2>/dev/null)"
    h_check_eq "$before" "$after" "负向对照：失败时原来能跑的那份脚本原封不动（没被残缺版覆盖）"

    rm -rf "$base"
}
