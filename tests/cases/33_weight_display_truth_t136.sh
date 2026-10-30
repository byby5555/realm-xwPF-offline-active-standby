#!/bin/bash
# 用例组 33 · 权重配置菜单：显示必须**忠实于落盘真值**；主备优先级权重（10,0）**不能被切模式抹掉**
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   ① 「当前权重」显示 == 磁盘真值：
#      磁盘 WEIGHTS="10,0" ⇒ 菜单必须显示 10 / 0。
#      磁盘 WEIGHTS=""（压根没配置）⇒ 菜单必须显示「未配置」，
#      **不许**拿「默认相等权重 1,1」糊弄（用户分不清「我设的就是 1」和「没设」）。
#   ② 切出主备（active-standby → roundrobin/iphash）时：
#      WEIGHTS 换成比例分摊默认（1,1,...），但**主备优先级权重必须存起来**（PREV_WEIGHTS）。
#   ③ 切回主备时：主备优先级权重必须**原样恢复**（10,0 回来）。
#      ★ 老实现切出去抹成 1,1、切回来不恢复 ⇒ 用户设的 10/0 永久丢失：
#        菜单显示「当前权重 1、1」，路由端也不再按 10/0 排主备优先级
#        （主备退化成「第一个健康的当主」）。
#   ④ 端口组编号必须**按端口号排序**：哈希序会让同一台机器两次进菜单编号不同，
#      而端口组常常同名（两个端口组都叫「中转」）⇒ 极易选错组。
#   ⑤ 读端必须按 10/0 排主备优先级：10 权重的主挂了 ⇒ 0 权重的备接管。
#
# ★ 负向对照用**真实旧实现**（历史对象 weight-display-pre），
#   不是文本匹配注入 ⇒ 产品重构一次也不会让对照静默失效。

# ── 造一条规则（写全官方键集：缺键在 set -u 下会直接崩）──
_t136_make_rule() {
    local file="$1" id="$2" port="$3" name="$4" host="$5" rport="$6"
    local mode="$7" weights="$8" failover="${9:-true}"

    mkdir -p "$(dirname "$file")"
    cat > "$file" <<EOF
RULE_ID="$id"
RULE_ROLE="1"
RULE_NAME="$name"
SECURITY_LEVEL="none"
LISTEN_PORT="$port"
LISTEN_IP="0.0.0.0"
THROUGH_IP="::"
REMOTE_HOST="$host"
REMOTE_PORT="$rport"
FORWARD_TARGET=""
TLS_SERVER_NAME=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_NOTE="T136 权重显示真值用例"
ENABLED="true"
CREATED_TIME="2026-10-29 00:00:00"
BALANCE_MODE="$mode"
PREV_BALANCE_MODE=""
PREV_WEIGHTS=""
TARGET_STATES=""
WEIGHTS="$weights"
FAILOVER_ENABLED="$failover"
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

# 造一个端口组（两条规则 = 两个目标；第一条存完整权重串，第二条存自己那个目标的单个权重）
_t136_make_group() {
    local dir="$1" id0="$2" port="$3" name="$4" h0="$5" p0="$6" h1="$7" p1="$8" weights="$9"
    _t136_make_rule "$dir/rule-$id0.conf" "$id0" "$port" "$name" "$h0" "$p0" "active-standby" "$weights" "true"
    _t136_make_rule "$dir/rule-$((id0 + 1)).conf" "$((id0 + 1))" "$port" "$name" "$h1" "$p1" "active-standby" "0" "true"
}

# 渲染一次「权重配置管理」菜单（$1=lib 根 $2=CONFIG_DIR $3=选中的组编号）
_t136_render_weight_menu() {
    local libroot="$1" cfgdir="$2" pick="$3"
    bash -c '
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        printf "%s\n\n" "$3" | weight_management_menu
    ' _ "$libroot" "$cfgdir" "$pick" 2>&1
}

# 渲染一次「切换负载均衡模式」菜单（$1=lib 根 $2=CONFIG_DIR $3=组编号 $4=模式选项 1..4）
_t136_switch_mode() {
    local libroot="$1" cfgdir="$2" pick="$3" mode="$4"
    bash -c '
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        printf "%s\n%s\n\n" "$3" "$4" | switch_balance_mode
    ' _ "$libroot" "$cfgdir" "$pick" "$mode" 2>&1
}

# 跑一次读端（生成 realm endpoints），输出 balance 权重串
_t136_gen_balance() {
    local libroot="$1" cfgdir="$2"
    bash -c '
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        source "$1/lib/realm.sh"  >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null | grep -o "\"balance\": \"[^\"]*\"" | head -1
    ' _ "$libroot" "$cfgdir" 2>&1
}

# 取一份 lib/ 副本（历史对照用）
_t136_tree_at() {
    local sha="$1" dest="$2" f rel
    rm -rf "$dest" 2>/dev/null
    mkdir -p "$dest/lib" 2>/dev/null
    for f in $(cd "$SBX_REPO" && git ls-tree -r --name-only "$sha" 2>/dev/null | grep '^lib/.*\.sh$'); do
        rel="$f"
        mkdir -p "$dest/$(dirname "$rel")" 2>/dev/null
        (cd "$SBX_REPO" && git show "$sha:$rel" 2>/dev/null) > "$dest/$rel"
    done
    [ -f "$dest/lib/rules.sh" ] || return 1
    printf '%s\n' "$dest"
}

# 取规则文件里的某个键
_t136_field() {
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | sed "s/^${key}=//; s/^\"//; s/\"$//"
}

# ══════════════════════════════════════════════════════════════
# T136 · 权重显示忠实落盘真值 + 主备优先级权重不被切模式抹掉
# ══════════════════════════════════════════════════════════════
case_T136_weight_display_matches_disk_and_standby_priority_survives_mode_switch() {
    h_case_begin "T136" "权重菜单显示必须忠实于落盘真值；主备优先级权重（10,0）不能被切模式抹掉" \
        "沙箱 rules（两个端口组，各 2 个目标，主备模式 + WEIGHTS=10,0）+ 健康状态文件" \
        "weight_management_menu / switch_balance_mode / generate_endpoints_from_rules + 负向对照（真实旧实现）" \
        "磁盘 10,0 ⇒ 菜单显示 10/0；磁盘空 ⇒ 菜单显示「未配置」而不是 1,1；切出主备存 PREV_WEIGHTS、切回主备恢复 10,0；端口组编号按端口号排序；10 权重主故障 ⇒ 0 权重备用接管"

    local rules="$SBX_ROOT/realm/rules"
    local cfg="$SBX_ROOT/realm"
    local healthdir="$SBX_ROOT/realm/health"

    mkdir -p "$rules" "$healthdir"
    rm -f "$rules"/rule-*.conf "$healthdir"/health_status.conf

    # ── 腿 1（阳性）：磁盘是 10,0 ⇒ 菜单必须显示 10 / 0 ──
    _t136_make_group "$rules" 1 18444 "中转" 127.0.0.1 28081 127.0.0.1 28082 "10,0"

    local menu
    menu=$(_t136_render_weight_menu "$SBX_RUN" "$cfg" 1)
    h_log "--- 权重菜单片段 ---"
    printf '%s\n' "$menu" | grep -aE '当前权重|权重配置:' | head -6 | sed 's/^/    /'

    h_check_not_contains "$menu" "unbound variable" "菜单在 set -u 之外也没崩（无 unbound variable）"
    h_check_contains "$menu" "127.0.0.1:28081 [当前权重: 10]" "菜单显示的当前权重 == 落盘真值（10）"
    h_check_contains "$menu" "127.0.0.1:28082 [当前权重: 0]" "菜单显示的当前权重 == 落盘真值（0）"
    h_check_not_contains "$menu" "[当前权重: 1]" "菜单没有把权重显示成 1（老实现的 1,1 症状）"

    # ── 腿 2（阳性）：磁盘没有权重配置 ⇒ 必须显示「未配置」，不许糊成 1,1 ──
    _t136_make_group "$rules" 1 18444 "中转" 127.0.0.1 28081 127.0.0.1 28082 ""
    menu=$(_t136_render_weight_menu "$SBX_RUN" "$cfg" 1)
    h_log "--- 空权重时的菜单片段 ---"
    printf '%s\n' "$menu" | grep -aE '当前权重|没有保存的权重' | head -6 | sed 's/^/    /'

    h_check_contains "$menu" "[当前权重: 未配置]" "磁盘上没有权重配置 ⇒ 菜单如实显示「未配置」"
    h_check_not_contains "$menu" "[当前权重: 1]" "没有权重配置时也不许显示成 1（老实现默认填 1,1）"
    h_check_contains "$menu" "没有保存的权重配置" "并说清楚是怎么来的（没保存 ≠ 设成 1）"

    # ── 腿 3（核心阳性）：切出主备 → 切回主备 ⇒ 10,0 必须回来 ──
    _t136_make_group "$rules" 1 18444 "中转" 127.0.0.1 28081 127.0.0.1 28082 "10,0"

    local out
    out=$(_t136_switch_mode "$SBX_RUN" "$cfg" 1 2)   # 1 = 切到轮询（切出主备）
    h_log "--- 切出主备 ---"
    printf '%s\n' "$out" | grep -aE '已更新|主备|轮询' | head -4 | sed 's/^/    /'

    h_check_eq "1,1" "$(_t136_field "$rules/rule-1.conf" WEIGHTS)" "切出主备后 WEIGHTS 换成比例分摊默认（1,1）"
    h_check_eq "10,0" "$(_t136_field "$rules/rule-1.conf" PREV_WEIGHTS)" "切出主备时把主备优先级权重存进 PREV_WEIGHTS（10,0）"

    out=$(_t136_switch_mode "$SBX_RUN" "$cfg" 1 4)   # 4 = 切回主备
    h_log "--- 切回主备 ---"
    printf '%s\n' "$out" | grep -aE '已更新|恢复|主备' | head -4 | sed 's/^/    /'

    h_check_eq "10,0" "$(_t136_field "$rules/rule-1.conf" WEIGHTS)" "切回主备后主备优先级权重**恢复**（10,0）"
    h_check_eq "0" "$(_t136_field "$rules/rule-2.conf" WEIGHTS)" "组内其余规则仍存自己那个目标的单个权重（0）"

    menu=$(_t136_render_weight_menu "$SBX_RUN" "$cfg" 1)
    h_check_contains "$menu" "127.0.0.1:28081 [当前权重: 10]" "切回主备后菜单显示的权重也跟着回来了（10）"
    h_check_contains "$menu" "127.0.0.1:28082 [当前权重: 0]" "切回主备后菜单显示的权重也跟着回来了（0）"

    # ── 腿 4（阳性）：端口组编号按端口号排序（哈希序会让同机两次编号不同）──
    rm -f "$rules"/rule-*.conf
    _t136_make_group "$rules" 1 18444 "中转" 127.0.0.1 28081 127.0.0.1 28082 "10,0"
    _t136_make_group "$rules" 3 18443 "中转" 127.0.0.1 18081 127.0.0.2 18081 "10,0"

    local list1 list2
    list1=$(printf '\n' | bash -c '
        export CONFIG_DIR="$1"
        source "$2/lib/core.sh"  >/dev/null 2>&1
        source "$2/lib/health.sh" >/dev/null 2>&1
        source "$2/lib/rules.sh"  >/dev/null 2>&1
        weight_management_menu
    ' _ "$cfg" "$SBX_RUN" 2>&1 | grep -aoE '端口: [0-9]+' | tr '\n' ' ')
    list2=$(printf '\n' | bash -c '
        export CONFIG_DIR="$1"
        source "$2/lib/core.sh"  >/dev/null 2>&1
        source "$2/lib/health.sh" >/dev/null 2>&1
        source "$2/lib/rules.sh"  >/dev/null 2>&1
        weight_management_menu
    ' _ "$cfg" "$SBX_RUN" 2>&1 | grep -aoE '端口: [0-9]+' | tr '\n' ' ')

    h_log "--- 端口组顺序（两次进入）---"
    h_log "    第一次: $list1"
    h_log "    第二次: $list2"

    h_check_eq "端口: 18443 端口: 18444 " "$list1" "端口组按端口号升序编号（先 18443 后 18444）"
    h_check_eq "$list1" "$list2" "两次进入菜单的端口组顺序一致（编号稳定）"

    # ── 腿 5（阳性）：读端按 10/0 排优先级 ⇒ 主故障时 0 权重备用接管 ──
    rm -f "$rules"/rule-*.conf
    _t136_make_group "$rules" 1 18444 "中转" 127.0.0.1 28081 127.0.0.1 28082 "10,0"

    # 健康状态：10 权重的那个目标（28081）判故障 ⇒ 备（28082）必须接管
    cat > "$healthdir/health_status.conf" <<'EOF'
# Realm健康状态文件
1|127.0.0.1:28081|failed|3|3|1792810000|0|0
1|127.0.0.1:28082|healthy|0|3|1792810000|0|5
EOF

    local balance
    balance=$(_t136_gen_balance "$SBX_RUN" "$cfg")
    h_log "--- 读端 balance ---"
    h_log "    $balance"

    h_check_contains "$balance" "roundrobin: 0, 1" "10 权重的主故障后，0 权重的备用接管（权重翻到备用）"

    # ── 腿 6（负向对照）：真实旧实现必须**做不到**「切回主备恢复 10,0」──
    local pre_sha oldtree
    pre_sha="$(sbx_history_sha weight-display-pre 2>/dev/null || true)"
    if [ -z "$pre_sha" ]; then
        h_fail "负向对照取不到历史实现：sbx_history_sha weight-display-pre 没给到 sha"
        return
    fi
    if ! git -C "$SBX_REPO" cat-file -e "${pre_sha}^{commit}" 2>/dev/null; then
        h_fail "负向对照取不到历史实现：历史对象 $pre_sha 不在本地对象库"
        return
    fi
    oldtree=$(_t136_tree_at "$pre_sha" "$SBX_ROOT/t136_oldtree") || {
        h_fail "负向对照取不到历史实现的 lib/（$pre_sha）"
        return
    }

    # 对照有效性自检：旧实现与当前实现必须**确实不同**
    local n_diff=0
    if ! diff -q "$SBX_RUN/lib/rules.sh" "$oldtree/lib/rules.sh" >/dev/null 2>&1; then n_diff=1; fi
    h_check_eq "1" "$n_diff" "负向对照自检 · 旧实现的 rules.sh 与当前实现确实不同（对照不是空跑）"

    # 对照自检 2：旧实现里**根本没有** PREV_WEIGHTS 这个概念
    h_check_not_contains "$(cat "$oldtree/lib/rules.sh" 2>/dev/null)" "PREV_WEIGHTS" \
        "负向对照自检 · 旧实现里没有 PREV_WEIGHTS（= 修复前不会保存主备优先级权重）"

    # 旧实现跑同一条腿：切出主备 → 切回主备 ⇒ 权重**不恢复**（老症状）
    rm -f "$rules"/rule-*.conf
    _t136_make_group "$rules" 1 18444 "中转" 127.0.0.1 28081 127.0.0.1 28082 "10,0"

    _t136_switch_mode "$oldtree" "$cfg" 1 2 >/dev/null 2>&1
    _t136_switch_mode "$oldtree" "$cfg" 1 4 >/dev/null 2>&1

    local old_weights old_menu
    old_weights=$(_t136_field "$rules/rule-1.conf" WEIGHTS)
    old_menu=$(_t136_render_weight_menu "$oldtree" "$cfg" 1)
    h_log "--- 负向对照（旧实现）---"
    h_log "    切回主备后 WEIGHTS=[$old_weights]"
    printf '%s\n' "$old_menu" | grep -aE '当前权重' | head -4 | sed 's/^/    /'

    # ★ 判别力：旧实现必须**红**在同一组断言上（否则说明断言测不出问题）
    h_check_eq "1,1" "$old_weights" "负向对照：旧实现切回主备后权重仍是 1,1（不恢复 ⇒ 这就是用户的症状）"
    h_check_contains "$old_menu" "[当前权重: 1]" "负向对照：旧实现的菜单显示 1、1（与用户截图逐字一致）"

    rm -rf "$oldtree"
    rm -f "$rules"/rule-*.conf "$healthdir"/health_status.conf
}
