#!/bin/bash
# 用例组 34 · 菜单项 5「探测参数设置」（超时/采样可配 + 持久化）+ 主备优先级排序 + 备注/参数弱化
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   ① 菜单里必须有第 5 项「探测参数设置」，能改**单次探测超时**与**每目标采样次数**，
#      改完**落盘**（${CONFIG_DIR}/menu_probe.conf）⇒ 下次进菜单还生效。
#      ★ 老实现只认环境变量 ⇒ 用户在菜单里压根没法调（换终端/重登就丢，等于没有）。
#   ② 生效口径必须是 **环境变量 > 配置文件 > 内置默认**
#      （env 留给临时覆盖/台架注入；配置��是菜单写的那份）。
#   ③ 菜单里的目标序号必须按**主备优先级**排（权重大的排前面），
#      且排序后**权重不能串位**（1 号显示的权重必须是 1 号自己的权重）。
#      ★ 菜单顺序必须与路由端挑主的顺序一致（同一个实现）⇒ 用户看到的谁是主就是真的主。
#   ④ 备注与参数（权重/百分比/时延/窗口指标）必须**弱化**（暗色），
#      状态（[健康]/[故障]）才保留醒目色；
#      探测结果行不许把 ANSI 转义序列当**字面文本**吐到屏幕上。
#
# ★ 负向对照用**真实旧实现**（历史对象 menu-probe-pre = 本轮改动前的冻结点），
#   不是文本匹配注入 ⇒ 产品重构一次也不会让对照静默失效。

# ── 造一条规则（写全官方键集：缺键在 set -u 下会直接崩）──
_t137_make_rule() {
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
RULE_NOTE="T137 菜单探测参数/优先级用例"
ENABLED="true"
CREATED_TIME="2026-10-30 00:00:00"
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
_t137_make_group() {
    local dir="$1" id0="$2" port="$3" name="$4" h0="$5" p0="$6" h1="$7" p1="$8" weights="$9"
    _t137_make_rule "$dir/rule-$id0.conf" "$id0" "$port" "$name" "$h0" "$p0" "active-standby" "$weights" "true"
    _t137_make_rule "$dir/rule-$((id0 + 1)).conf" "$((id0 + 1))" "$port" "$name" "$h1" "$p1" "active-standby" "0" "true"
}

# 去掉 ANSI 颜色转义序列（ESC[0;90m / ESC[0m 这类）
#
# ★ 曾经写成纯 bash 的 ${s//$'\033'\[[0-9;]*m/} —— **错**：
#   glob 里的 `[0-9;]*` 是「一个集合字符 + 任意多个任意字符」，
#   那个 `*` 会**跨行吞掉大段正文**（从第一个 ESC[2J 一直吃到后面某个 m）
#   ⇒ 剥完只剩一行残渣，看起来像「菜单没渲染」。
#   ⇒ 这里改用 sed 的 ERE（`[0-9;]*` 才是「零个或多个集合字符」），ESC 用字面字节传入。
_t137_strip_ansi() {
    local s="$1" esc
    esc="$(printf '\033')"
    printf '%s' "$s" | sed -e "s/${esc}\\[[0-9;]*m//g"
}

# 渲染一次「负载均衡管理」菜单（$1=lib 根 $2=CONFIG_DIR）
# ★ 一律在 set -u 下跑：菜单是交互入口，stdin 可能是 EOF / 非终端。
_t137_render_menu() {
    local libroot="$1" cfgdir="$2"
    bash -c '
        set -u
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        printf "0\n" | load_balance_management_menu
    ' _ "$libroot" "$cfgdir" 2>&1
}

# 跑一次「探测参数设置」菜单（$1=lib 根 $2=CONFIG_DIR $3=喂给菜单的输入）
_t137_probe_settings() {
    local libroot="$1" cfgdir="$2" input="$3"
    bash -c '
        set -u
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        printf "%b" "$3" | menu_probe_settings_menu
    ' _ "$libroot" "$cfgdir" "$input" 2>&1
}

# 造一份「记录探测预算」的 lib/（只换最里层 I/O，产品路径不动）
_t137_make_probe_lib() {
    local dst="$1"
    rm -rf "$dst" 2>/dev/null
    mkdir -p "$dst/lib"
    cp "$SBX_RUN/lib/"*.sh "$dst/lib/" 2>/dev/null
    cat >> "$dst/lib/health.sh" <<'EOS'

# T137-INSTR: 记录每次探测收到的预算（只换最里层 I/O，产品路径不动）
check_connectivity() {
    local tgt="$1" prt="$2" to="$3"
    [ -n "${XW_CONC_DIR:-}" ] && printf '%s\n' "$to" >> "$XW_CONC_DIR/timeouts"
    return 0
}
EOS
}

# 在沙箱里跑一次「立即测试所有目标时延」（$1=lib 根 $2=CONFIG_DIR $3=计数目录 $4=env 超时 $5=env 采样）
_t137_run_probe() {
    local libroot="$1" cfgdir="$2" conc="$3" envto="${4:-}" envsam="${5:-}"
    bash -c '
        export CONFIG_DIR="$2"
        export XW_CONC_DIR="$3"
        [ -n "$4" ] && export MENU_PROBE_TIMEOUT="$4"
        [ -n "$5" ] && export MENU_PROBE_SAMPLES="$5"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        probe_all_targets_latency
    ' _ "$libroot" "$cfgdir" "$conc" "$envto" "$envsam" 2>&1
}

# 跑一次读端（生成 realm endpoints），输出 balance 权重串
_t137_gen_balance() {
    local libroot="$1" cfgdir="$2"
    bash -c '
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null | grep -o "\"balance\": \"[^\"]*\"" | head -1
    ' _ "$libroot" "$cfgdir" 2>&1
}

# 取一份 lib/ 副本（历史对照用）
_t137_tree_at() {
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

# 取规则/配置文件里的某个键
_t137_field() {
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | sed "s/^${key}=//; s/^\"//; s/\"$//"
}

# ══════════════════════════════════════════════════════════════
# T137 · 菜单项 5「探测参数设置」+ 主备优先级排序 + 备注/参数弱化
# ══════════════════════════════════════════════════════════════
case_T137_menu_probe_settings_persisted_and_priority_order() {
    h_case_begin "T137" "菜单项 5「探测参数设置」：超时/采样可配且落盘生效；目标序号按主备优先级排；备注与参数弱化" \
        "沙箱 rules（active-standby，两目标，权重 0,10）+ 记录探测预算的 lib/" \
        "load_balance_management_menu / menu_probe_settings_menu / probe_all_targets_latency + 负向对照（真实旧实现）" \
        "菜单有第 5 项且能改超时/采样并落盘生效；env > 文件 > 默认；目标序号按优先级排且权重不串位；备注与参数用暗色、探测结果不吐字面转义序列；旧实现做不到"

    local rules="$SBX_ROOT/realm/rules"
    local cfg="$SBX_ROOT/realm"
    local healthdir="$SBX_ROOT/realm/health"
    local work="$SBX_ROOT/t137_work"
    local conc="$SBX_ROOT/t137_conc"
    local conc2="$SBX_ROOT/t137_conc2"
    local conf="$cfg/menu_probe.conf"

    mkdir -p "$rules" "$healthdir"
    rm -f "$rules"/rule-*.conf "$conf" "$healthdir"/health_status.conf
    rm -rf "$work" "$conc" "$conc2"

    # ── 腿 1（阳性）：菜单里有第 5 项，且目标序号按**主备优先级**排 ──
    #   权重串 "0,10" ⇒ 第二个目标才是主（权重 10）⇒ 菜单的 1 号必须是它。
    _t137_make_group "$rules" 1 18444 "中转" 127.0.0.1 28081 127.0.0.1 28082 "0,10"

    local menu clean
    menu=$(_t137_render_menu "$SBX_RUN" "$cfg")
    clean="$(_t137_strip_ansi "$menu")"
    h_log "--- 菜单片段 ---"
    printf '%s\n' "$clean" | grep -aE '端口 18444|2808|立即测试|探测参数' | head -8 | sed 's/^/    /'

    h_check_not_contains "$menu" "unbound variable" "菜单在 set -u 下没崩（无 unbound variable）"
    h_check_contains "$clean" "5. 探测参数设置" "菜单提供第 5 项「探测参数设置」"
    h_check_contains "$clean" "4. 立即测试所有目标时延" "菜单项 4 仍在（没被新项挤掉）"

    h_check_contains "$clean" "1. 127.0.0.1:28082" "目标序号按主备优先级排（1 号 = 权重 10 的那个目标）"
    h_check_contains "$clean" "2. 127.0.0.1:28081" "2 号 = 权重 0 的那个目标"

    # 顺序断言：1 号必须**真的排在前面**（不是两行都在，只是内容对）
    local ln1 ln2
    ln1=$(printf '%s\n' "$clean" | grep -an '1\. 127\.0\.0\.1:28082' | head -1 | cut -d: -f1)
    ln2=$(printf '%s\n' "$clean" | grep -an '2\. 127\.0\.0\.1:28081' | head -1 | cut -d: -f1)
    h_log "1 号行号=${ln1:-无} / 2 号行号=${ln2:-无}"
    case "${ln1:-}:${ln2:-}" in
        *:*)
            if [ -n "$ln1" ] && [ -n "$ln2" ] && [ "$ln1" -lt "$ln2" ]; then
                h_pass "主备优先级排序：1 号（权重 10）排在 2 号（权重 0）前面"
            else
                h_fail "主备优先级排序：期望 1 号(${ln1}) 排在 2 号(${ln2}) 前面"
            fi
            ;;
    esac

    # ── 腿 2（阳性）：排序后权重**不能串位**（1 号显示的权重必须是 1 号自己的）──
    h_check_contains "$clean" "1. 127.0.0.1:28082 [权重: 10]" "1 号显示的权重是自己的 10（没串位）"
    h_check_contains "$clean" "2. 127.0.0.1:28081 [权重: 0]" "2 号显示的权重是自己的 0（没串位）"

    # ── 腿 3（阳性）：菜单项 5 能改超时/采样，并**落盘** ──
    local out
    out=$(_t137_probe_settings "$SBX_RUN" "$cfg" "1\n5\n\n2\n4\n\n0\n")
    h_log "--- 探测参数设置菜单片段 ---"
    printf '%s\n' "$(_t137_strip_ansi "$out")" | grep -aE '单次探测超时|采样次数|已保存' | head -6 | sed 's/^/    /'

    h_check_not_contains "$out" "unbound variable" "探测参数设置菜单在 set -u 下没崩"
    h_check_contains "$out" "已保存" "菜单项 5 保存时给出明确回执"
    h_check_eq "5" "$(_t137_field "$conf" PROBE_TIMEOUT)" "改完超时后落盘 PROBE_TIMEOUT=5"
    h_check_eq "4" "$(_t137_field "$conf" PROBE_SAMPLES)" "改完采样后落盘 PROBE_SAMPLES=4"

    # ── 腿 4（阳性）：落盘的值**真的生效**（探测用的就是它，不是内置默认）──
    _t137_make_probe_lib "$work"
    mkdir -p "$conc"
    local pout budgets n_probe
    pout=$(_t137_run_probe "$work" "$cfg" "$conc")
    budgets=$(sort -u "$conc/timeouts" 2>/dev/null | tr '\n' ' ')
    n_probe=$(wc -l < "$conc/timeouts" 2>/dev/null | tr -d ' ')
    case "$n_probe" in ''|*[!0-9]*) n_probe=0 ;; esac
    h_log "--- 探测输出（用落盘的参数）---"
    printf '%s\n' "$(_t137_strip_ansi "$pout")" | grep -aE '次成功|合计' | head -4 | sed 's/^/    /'
    h_log "探测次数=$n_probe 预算集合=$budgets"

    h_check_eq "5 " "$budgets" "探测用的是**落盘的超时 5s**（不是内置默认 2s）"
    h_check_eq "8" "$n_probe" "探测次数 = 2 个目标 × 落盘的 4 次采样 = 8 次"
    h_check_contains "$(_t137_strip_ansi "$pout")" "4/4 次成功" "结果行按落盘的采样次数报（4/4）"

    # ── 腿 5（阳性）：环境变量**优先于**配置文件 ──
    mkdir -p "$conc2"
    local pout2 budgets2
    pout2=$(_t137_run_probe "$work" "$cfg" "$conc2" 9 7)
    budgets2=$(sort -u "$conc2/timeouts" 2>/dev/null | tr '\n' ' ')
    local n_probe2
    n_probe2=$(wc -l < "$conc2/timeouts" 2>/dev/null | tr -d ' ')
    case "$n_probe2" in ''|*[!0-9]*) n_probe2=0 ;; esac
    h_log "env 覆盖时：预算集合=$budgets2 次数=$n_probe2"

    h_check_eq "9 " "$budgets2" "环境变量优先于配置文件（预算取 9s，不是落盘的 5s）"
    h_check_eq "14" "$n_probe2" "环境变量优先于配置文件（采样取 7 次，不是落盘的 4 次）"

    # ── 腿 5b（阳性）：手改配置文件带**尾随空格 / CRLF** 也不能被静默忽略 ──
    #   否则用户看到的是「保存了却没生效」（值被判非法 ⇒ 悄悄退回默认 2s）
    printf 'PROBE_TIMEOUT= 7 \r\nPROBE_SAMPLES=3\r\n' > "$conf"
    local t_ws
    t_ws=$(bash -c '
        export CONFIG_DIR="$1"
        source "$2/lib/core.sh" >/dev/null 2>&1
        menu_probe_timeout
    ' _ "$cfg" "$SBX_RUN" 2>&1 | tr -d '\r\n')
    h_log "手改（带空格/CRLF）后读到的超时: $t_ws"
    h_check_eq "7" "$t_ws" "配置文件带尾随空格/CRLF 时值仍生效（不被静默退回默认）"

    # ── 腿 6（阳性）：备注与参数**弱化**（暗色），状态才保留醒目色 ──
    h_check_contains "$menu" "0;90m[权重: 10]" "权重参数用暗色（0;90）显示"
    h_check_contains "$menu" "0;90m[时延:" "时延参数用暗色（0;90）显示"
    h_check_not_contains "$menu" "0;34m[时延:" "时延参数不再用亮蓝色（0;34）"
    h_check_contains "$menu" "0;90m注:" "备注用暗色（0;90）显示"
    h_check_contains "$menu" "0;32m[健康]" "状态标签仍保留醒目色（绿色）"

    # ── 腿 7（阳性）：探测结果行不许把 ANSI 转义序列当**字面文本**吐出来 ──
    h_check_not_contains "$pout" '\033[' "探测结果行不吐字面转义序列（老实现会打出 \\033[0;32m）"
    h_check_contains "$pout" "可达" "探测结果行照常显示结果文字"

    # ── 腿 8（阳性）：菜单顺序与路由端挑主的顺序一致（同一个实现）──
    local balance
    balance=$(_t137_gen_balance "$SBX_RUN" "$cfg")
    h_log "--- 读端 balance ---"
    h_log "    $balance"
    h_check_contains "$balance" "roundrobin: 0, 1" "读端按 0,10 挑主（第二个目标是主）⇒ 与菜单 1 号一致"

    # 权重 10 的那个目标故障 ⇒ 主备切换到权重 0 的那个（菜单 2 号接管）
    # ★ 状态文件的键是 **(归属规则 ID, 目标地址)**：
    #   28081 归 rule-1、28082 归 rule-2 ⇒ 键分别是 "1|…28081" / "2|…28082"
    #   （键写错 ⇒ 读端查不到 ⇒ 当成健康 ⇒ 断言会红得莫名其妙）
    cat > "$healthdir/health_status.conf" <<'EOF'
1|127.0.0.1:28081|healthy|0|3|1792810000|0|5
2|127.0.0.1:28082|failed|3|3|1792810000|0|0
EOF
    balance=$(_t137_gen_balance "$SBX_RUN" "$cfg")
    h_log "    （10 权重目标故障后）$balance"
    h_check_contains "$balance" "roundrobin: 1, 0" "10 权重的目标故障后，权重 0 的那个接管"

    # ── 腿 9（负向对照）：真实旧实现必须**做不到**这些事 ──
    local pre_sha oldtree
    pre_sha="$(sbx_history_sha menu-probe-pre 2>/dev/null || true)"
    if [ -z "$pre_sha" ]; then
        h_fail "负向对照取不到历史实现：sbx_history_sha menu-probe-pre 没给到 sha"
        return
    fi
    if ! git -C "$SBX_REPO" cat-file -e "${pre_sha}^{commit}" 2>/dev/null; then
        h_fail "负向对照取不到历史实现：历史对象 $pre_sha 不在本地对象库"
        return
    fi
    oldtree=$(_t137_tree_at "$pre_sha" "$SBX_ROOT/t137_oldtree") || {
        h_fail "负向对照取不到历史实现的 lib/（$pre_sha）"
        return
    }

    # 对照有效性自检：旧实现与当前实现确实不同，且旧实现压根没有这些概念
    local n_diff=0
    if ! diff -q "$SBX_RUN/lib/rules.sh" "$oldtree/lib/rules.sh" >/dev/null 2>&1; then n_diff=1; fi
    h_check_eq "1" "$n_diff" "负向对照自检 · 旧实现的 rules.sh 与当前实现确实不同（对照不是空跑）"
    h_check_not_contains "$(cat "$oldtree/lib/rules.sh" 2>/dev/null)" "探测参数设置" \
        "负向对照自检 · 旧实现里没有「探测参数设置」这个菜单项"
    h_check_not_contains "$(cat "$oldtree/lib/core.sh" 2>/dev/null)" "port_group_priority_order" \
        "负向对照自检 · 旧实现里没有主备优先级的唯一实现"

    # 旧实现跑同一条腿：菜单里没有第 5 项、序号不按优先级排
    rm -f "$rules"/rule-*.conf
    _t137_make_group "$rules" 1 18444 "中转" 127.0.0.1 28081 127.0.0.1 28082 "0,10"

    local old_menu old_clean
    old_menu=$(_t137_render_menu "$oldtree" "$cfg")
    old_clean="$(_t137_strip_ansi "$old_menu")"
    h_log "--- 负向对照（旧实现）菜单片段 ---"
    printf '%s\n' "$old_clean" | grep -aE '端口 18444|2808|立即测试' | head -6 | sed 's/^/    /'

    h_check_not_contains "$old_clean" "探测参数设置" "负向对照：旧实现的菜单里没有第 5 项（探测参数没法在菜单里配）"
    h_check_contains "$old_clean" "1. 127.0.0.1:28081" "负向对照：旧实现的序号按合并顺序（1 号是权重 0 的那个，不是主）"
    h_check_not_contains "$old_clean" "1. 127.0.0.1:28082" "负向对照：旧实现不会把主（权重 10）排到 1 号"

    # 旧实现的探测结果行会吐出字面转义序列
    #   （老实现用 printf "%s" 打印颜色变量 ⇒ ESC 序列被当普通文本；
    #     目标不可达时那一行是红色，所以不钉死具体颜色，钉「有字面 ESC 序列」）
    local old_pout
    old_pout=$(_t137_run_probe "$oldtree" "$cfg" "$conc2")
    h_check_contains "$old_pout" '\033[0;' "负向对照：旧实现的探测结果行把 ANSI 转义序列当字面文本吐出来"

    # 旧实现也没有落盘配置 ⇒ 菜单改不动超时
    rm -f "$conf"
    _t137_probe_settings "$oldtree" "$cfg" "1\n5\n\n0\n" >/dev/null 2>&1
    h_check_eq "" "$(_t137_field "$conf" PROBE_TIMEOUT)" "负向对照：旧实现没有落盘探测参数（改了也存不住）"

    rm -rf "$oldtree" "$work" "$conc" "$conc2"
    rm -f "$rules"/rule-*.conf "$conf" "$healthdir"/health_status.conf
}
