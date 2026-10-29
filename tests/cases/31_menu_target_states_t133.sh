#!/bin/bash
# 用例组 31 · 菜单端口组：TARGET_STATES 形态的目标要**看得见**、要**查得到时延**；
#                    菜单项 4「立即测试所有目标时延」要**并发** + **短超时** + **多采样**
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   ① 三端口径必须同源：菜单（显示）＝探测端（判定流 / 快探测）＝路由端（realm endpoint）
#      统一用 rule_target_endpoints（lib/core.sh 的唯一实现）。
#      ★ 修复前菜单只认 REMOTE_HOST × REMOTE_PORT ⇒ 主备模式下
#        「每个目标自带端口」（TARGET_STATES）的目标在菜单里**整个看不见**
#        ⇒ 连带时延 / 健康 / 质量指标都查不到（查表键就是 host:port）。
#      ⇒ 退化形态下菜单会显示「暂无符合条件的负载均衡组」（组里只剩 1 个目标 ⇒ 连组都不显示）。
#   ② 去重必须**精确匹配**：老的「字符串包含」判断会把 `a:80` 当成 `a:8080` 的重复
#      ⇒ 先声明长端口时短端口那个目标被整个丢掉 ⇒ 组里少了目标 ⇒ 主备切换静默失效。
#   ③ 菜单项 4 必须**并发**：串行 = N 个目标 × 单次超时（老口径 10s）
#      ⇒ 4 个目标最坏 40 秒，菜单像卡死。
#   ④ 菜单项 4 的单次探测预算必须是**短超时**（菜单自己的 MENU_PROBE_TIMEOUT），
#      不是规则里写死的 CONNECTION_TIMEOUT（10s）。
#   ⑤ 菜单项 4 必须**多采样**：报「成功次数/采样次数」，能区分
#      「偶发失败」与「彻底不通」。
#
# ★ 全部在沙箱里做：规则 / 状态 / 观测文件都落在沙箱路径（路径重定向在源码层生效）。

# ── 造一条「每目标自带端口」的主备规则（TARGET_STATES 形态）──
_t131_make_rule() {
    local rule_file="$1"
    local target_states="$2"
    local remote_host="${3:-127.0.0.1}"
    local remote_port="${4:-18091}"
    local weights="${5:-10,0}"

    cat > "$rule_file" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME="menu-target-states"
SECURITY_LEVEL=none
LISTEN_PORT=8080
LISTEN_IP="0.0.0.0"
THROUGH_IP="::"
REMOTE_HOST="$remote_host"
REMOTE_PORT="$remote_port"
FORWARD_TARGET=""
TLS_SERVER_NAME=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_NOTE="菜单目标形态用例"
ENABLED=true
CREATED_TIME="2026-10-29 00:00:00"
BALANCE_MODE="active-standby"
PREV_BALANCE_MODE=""
TARGET_STATES="$target_states"
WEIGHTS="$weights"
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

# 在沙箱里渲染一次负载均衡菜单（$1 = lib 根，$2 = CONFIG_DIR）
_t131_render_menu() {
    local libroot="$1" cfgdir="$2"
    bash -c '
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        source "$1/lib/realm.sh"  >/dev/null 2>&1
        ( set -u; printf "0\n" | load_balance_management_menu )
    ' _ "$libroot" "$cfgdir" 2>&1
}

# ── 造一份 lib/ 副本（可注入退化）──
_t131_make_lib_copy() {
    local dst="$1"
    mkdir -p "$dst/lib"
    cp "$SBX_RUN/lib/"*.sh "$dst/lib/" 2>/dev/null
    printf '%s' "$dst"
}


# ══════════════════════════════════════════════════════════════
# T133 · 菜单端口组：TARGET_STATES 形态的目标要看得见 + 查得到时延
# ══════════════════════════════════════════════════════════════
case_T133_menu_shows_target_states_targets_with_latency() {
    h_case_begin "T133" "菜单端口组：TARGET_STATES 形态（每目标自带端口）的目标要看得见、查得到时延" \
        "沙箱 rules（TARGET_STATES = 127.0.0.1:18091,127.0.0.2:18092）+ 判定流状态文件 + 快探测观测文件" \
        "load_balance_management_menu（set -u 下真渲染）+ 负向对照（把共用真源退回旧口径）" \
        "两个目标都在菜单里列出来（2个服务器）、各自都有时延、权重按合并列表对齐（10 / 0）；负向对照（退回旧口径）时备机整个消失"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local obs="$SBX_ROOT/var.lib.realm/fast_probe.conf"
    local cfg="$SBX_ROOT/realm"

    mkdir -p "$rules" "$SBX_ROOT/realm/health" "$SBX_ROOT/var.lib.realm"
    rm -f "$rules"/rule-*.conf "$health" "$obs"

    # 主备规则：每个目标自带端口（TARGET_STATES 形态）
    #   REMOTE_HOST 只有 1 个地址、REMOTE_PORT 只有 1 个端口
    #   ⇒ 旧口径（REMOTE_HOST × REMOTE_PORT）只会枚举出 **1** 个目标
    _t131_make_rule "$rules/rule-1.conf" "127.0.0.1:18091,127.0.0.2:18092"

    # 判定流状态文件：两个目标各一行（行键 = RULE_ID|目标）
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|127.0.0.1:18091|healthy|0|3|1792810000|0|12|10,12,14
1|127.0.0.2:18092|healthy|0|3|1792810000|0|88|80,90
EOF

    # 快探测观测文件：两个目标各一行（时延口径：7ms / 9ms）
    cat > "$obs" <<'EOF'
# Realm快探测观测文件（只观测，不参与切换）
127.0.0.1:18091|1|ok|7|1792810000|oo|7,8
127.0.0.2:18092|1|ok|9|1792810000|o|9
EOF

    # ── 腿 1（阳性）：菜单要列出两个目标，各自带时延 ──
    local menu
    menu=$(_t131_render_menu "$SBX_RUN" "$cfg")
    h_log "--- 菜单片段 ---"
    printf '%s\n' "$menu" | grep -aE '端口 8080|时延|个服务器' | head -8 | sed 's/^/    /'

    h_check_not_contains "$menu" "unbound variable" "菜单在 set -u 下没崩"
    h_check_contains "$menu" "127.0.0.1:18091" "菜单列出了主目标（127.0.0.1:18091）"
    h_check_contains "$menu" "127.0.0.2:18092" "菜单列出了 TARGET_STATES 里的备机（127.0.0.2:18092）"
    h_check_contains "$menu" "2个服务器" "端口组按合并后的目标数显示（2 个服务器，不是 1 个）"
    h_check_contains "$menu" "[时延: 7ms (均 7ms)]" "主目标查得到时延（快探测的 7ms）"
    h_check_contains "$menu" "[时延: 9ms (均 9ms)]" "TARGET_STATES 形态的备机也查得到时延（9ms）"
    # 权重按**合并后的目标列表**对齐（与路由端同口径）：第一个 10、第二个 0
    h_check_contains "$menu" "[权重: 10]" "第一个目标的权重按合并列表取 10"
    h_check_contains "$menu" "[权重: 0]" "第二个目标的权重按合并列表取 0"

    # ── 腿 2（负向对照）：把共用真源退回**旧口径** ⇒ 备机必须整个消失 ──
    #   注入手法 = 语义退化（不是文本匹配产品新代码）：
    #   把 rule_target_endpoints 换成「只认 REMOTE_HOST × REMOTE_PORT」的旧实现
    #   —— 这正是修复前菜单/探测端的行为。
    local badlib
    badlib=$(_t131_make_lib_copy "$SBX_ROOT/t133_badlib")
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
    ' "$SBX_RUN/lib/core.sh" > "$badlib/lib/core.sh" 2>/dev/null

    local n_diff=0
    if ! diff -q "$SBX_RUN/lib/core.sh" "$badlib/lib/core.sh" >/dev/null 2>&1; then n_diff=1; fi
    h_check_eq "1" "$n_diff" "负向对照自检 · 退化副本确实换掉了共用真源（破坏手法生效）"
    h_check_contains "$(cat "$badlib/lib/core.sh" 2>/dev/null)" 'printf "%s" "${REMOTE_HOST}:${REMOTE_PORT}"' "负向对照副本用的确实是旧口径"

    local menu_bad
    menu_bad=$(_t131_render_menu "$badlib" "$cfg")
    h_log "--- 负向对照 菜单片段 ---"
    printf '%s\n' "$menu_bad" | grep -aE '端口 8080|个服务器|暂无符合' | head -5 | sed 's/^/    /'

    h_check_not_contains "$menu_bad" "127.0.0.2:18092" "负向对照：退回旧口径后，TARGET_STATES 形态的备机在菜单里不见了"
    h_check_contains "$menu_bad" "暂无符合条件的负载均衡组" "负向对照：旧口径下组里只剩 1 个目标 ⇒ 整个端口组都不显示（这就是修复前的症状）"

    rm -rf "$badlib"
    rm -f "$rules"/rule-*.conf "$health" "$obs"
}


# ══════════════════════════════════════════════════════════════
# T134 · 菜单项 4：并发 + 短超时 + 多采样
# ══════════════════════════════════════════════════════════════
#
# ★ 怎么测「并发」才不靠运气：
#   真实网络探测的耗时不可控 ⇒ 断言「总耗时 < X 秒」会飘。
#   ⇒ 这里把**最里层的 I/O**（check_connectivity）换成「可控的慢探测」：
#     每次探测固定 sleep 1 秒，并留下一个「在飞」的标记目录。
#   ⇒ 「同一时刻有几个探测在飞」就是**并发度**，直接数标记目录即可（确定值）。
#   ★ 换的只是最里层 I/O，产品路径
#     （probe_all_targets_latency → probe_with_latency → check_connectivity）原封不动。
#
# ── 造一份「慢探测」版 lib/（注入的是测量手段，不是退化）──
_t134_make_slow_probe_lib() {
    local dst="$1"
    mkdir -p "$dst/lib"
    cp "$SBX_RUN/lib/"*.sh "$dst/lib/" 2>/dev/null
    cat >> "$dst/lib/health.sh" <<'EOS'

# T134-INSTR: 可控的慢探测（只换最里层 I/O，产品路径不动）
#   · 每次探测固定 sleep 1 秒 ⇒ 并发/串行在耗时上分得开
#   · 留下「在飞」标记目录 ⇒ 并发度可以直接数出来
#   · 记下每次探测收到的超时预算 ⇒ 验证用的是菜单的短超时，不是规则的 CONNECTION_TIMEOUT
#   · 每目标第几次采样：放在**子进程自己的变量**里
#     （每个目标一个后台子进程 ⇒ 各自一份计数，互不干扰；
#       用共享文件会读改写竞争 ⇒ 计数乱跳 ⇒ 「偶发失败」那一档测不稳）
check_connectivity() {
    local tgt="$1" prt="$2" to="$3"
    local id="" n=0

    _XW_CALL_N=$(( ${_XW_CALL_N:-0} + 1 ))

    [ -n "${XW_CONC_DIR:-}" ] && mkdir -p "$XW_CONC_DIR/live" 2>/dev/null

    if [ -n "${XW_CONC_DIR:-}" ]; then
        id="$(mktemp -d "$XW_CONC_DIR/live/p.XXXXXX" 2>/dev/null)"
        n="$(ls -1 "$XW_CONC_DIR/live" 2>/dev/null | wc -l)"
        printf '%s\n' "$n" >> "$XW_CONC_DIR/counts"
        printf '%s\n' "$to" >> "$XW_CONC_DIR/timeouts"
    fi

    sleep 1

    [ -n "$id" ] && rmdir "$id" 2>/dev/null

    # 结果口径（造出三种状态）：
    #   端口尾数 3 → 一直不通      ⇒ 0/3 次成功（不可达）
    #   端口尾数 2 → 第 2 次不通    ⇒ 2/3 次成功（部分可达）
    #   其余      → 一直通          ⇒ 3/3 次成功（全可达）
    case "$prt" in
        *3) return 1 ;;
        *2) [ "$_XW_CALL_N" -eq 2 ] && return 1 ;;
    esac
    return 0
}
EOS
}

# 在沙箱里跑一次「立即测试所有目标时延」（$1 = lib 根，$2 = CONFIG_DIR，$3 = 计数目录）
# $4 = 采样次数（默认 3）；$5 = "setu" 时在 set -u 下跑
_t134_run_probe() {
    local libroot="$1" cfgdir="$2" conc="$3"
    local samples="${4:-3}" setu="${5:-}"
    if [ "$setu" = "setu" ]; then
        bash -c '
            set -u
            export CONFIG_DIR="$2"
            export XW_CONC_DIR="$3"
            export MENU_PROBE_SAMPLES="$4"
            export MENU_PROBE_TIMEOUT=1
            source "$1/lib/core.sh"  >/dev/null 2>&1
            source "$1/lib/health.sh" >/dev/null 2>&1
            source "$1/lib/rules.sh"  >/dev/null 2>&1
            probe_all_targets_latency
            echo "PROBE_RC=0"
        ' _ "$libroot" "$cfgdir" "$conc" "$samples" 2>&1
    else
        bash -c '
            export CONFIG_DIR="$2"
            export XW_CONC_DIR="$3"
            export MENU_PROBE_SAMPLES="$4"
            export MENU_PROBE_TIMEOUT=1
            source "$1/lib/core.sh"  >/dev/null 2>&1
            source "$1/lib/health.sh" >/dev/null 2>&1
            source "$1/lib/rules.sh"  >/dev/null 2>&1
            _t0=$(date +%s)
            probe_all_targets_latency
            _t1=$(date +%s)
            echo "ELAPSED=$((_t1 - _t0))"
        ' _ "$libroot" "$cfgdir" "$conc" "$samples" 2>&1
    fi
}

case_T134_menu_probe_is_concurrent_short_timeout_multisample() {
    h_case_begin "T134" "菜单项 4「立即测试所有目标时延」：并发 + 短超时 + 多采样" \
        "沙箱 rules（TARGET_STATES 形态 4 个目标）+ 可控慢探测版 lib/" \
        "probe_all_targets_latency + 负向对照（把并发退化成串行）" \
        "并发度 ≥ 2（负向对照里 = 1）；单次探测预算是菜单的 1s（不是规则的 10s）；每个目标报「成功次数/采样次数」；TARGET_STATES 形态的目标也测得到"

    local rules="$SBX_ROOT/realm/rules"
    local cfg="$SBX_ROOT/realm"
    local work="$SBX_ROOT/t134_work"
    local conc="$SBX_ROOT/t134_conc"
    local badconc="$SBX_ROOT/t134_badconc"
    local suconc="$SBX_ROOT/t134_suconc"

    mkdir -p "$rules" "$SBX_ROOT/realm/health" "$SBX_ROOT/var.lib.realm"
    rm -f "$rules"/rule-*.conf
    rm -rf "$work" "$conc" "$badconc" "$suconc"
    mkdir -p "$conc/live" "$badconc/live" "$suconc/live"

    # 4 个目标（每目标自带端口）：18091 通 / 18092 第 2 次不通 / 18093 一直不通 / 18094 通
    _t131_make_rule "$rules/rule-1.conf" \
        "127.0.0.1:18091,127.0.0.1:18092,127.0.0.1:18093,127.0.0.1:18094" \
        "127.0.0.1" "18091" "10,0,0,0"

    # ── 腿 1（阳性）：并发 + 短超时 + 多采样 ──
    _t134_make_slow_probe_lib "$work"

    local out elapsed
    out=$(_t134_run_probe "$work" "$cfg" "$conc")
    elapsed=$(printf '%s\n' "$out" | grep -a '^ELAPSED=' | head -1 | cut -d= -f2)
    case "$elapsed" in ''|*[!0-9]*) elapsed=0 ;; esac
    h_log "--- 探测输出 ---"
    printf '%s\n' "$out" | grep -aE '次成功|合计|并发' | head -8 | sed 's/^/    /'
    h_log "耗时 ${elapsed}s"

    # 目标清单：TARGET_STATES 形态的 4 个目标都要在（老口径只认 REMOTE_HOST × REMOTE_PORT ⇒ 只有 1 个）
    h_check_contains "$out" "127.0.0.1:18091" "探测清单里有目标 18091"
    h_check_contains "$out" "127.0.0.1:18092" "探测清单里有目标 18092"
    h_check_contains "$out" "127.0.0.1:18093" "探测清单里有目标 18093"
    h_check_contains "$out" "127.0.0.1:18094" "探测清单里有目标 18094"
    h_check_contains "$out" "合计 4 个目标" "一共测了 4 个目标（TARGET_STATES 形态也测得到）"

    # 多采样：报「成功次数/采样次数」
    h_check_contains "$out" "3/3 次成功" "一直通的目标报 3/3 次成功（多采样）"
    h_check_contains "$out" "2/3 次成功" "偶发失败的目标报 2/3 次成功（能区分偶发与彻底不通）"
    h_check_contains "$out" "0/3 次成功" "一直不通的目标报 0/3 次成功"

    # 汇总口径：全可达 / 部分可达 / 不可达
    h_check_contains "$out" "全可达 2" "汇总里全可达 2 个（18091 / 18094）"
    h_check_contains "$out" "部分可达 1" "汇总里部分可达 1 个（18092）"
    h_check_contains "$out" "不可达 1" "汇总里不可达 1 个（18093）"

    # ★ 每个目标的结果必须**各自独立**（不许四个目标共用一份结果）
    #   历史坑：写结果文件时用错了序号变量 ⇒ 四个后台子进程把结果写进**同一个文件**
    #   ⇒ 汇总时四行显示同一份结果（看起来「全可达」，实际每个目标的结果都丢了）。
    local n_lines n_distinct
    n_lines=$(printf '%s\n' "$out" | grep -ac '次成功'); n_lines=${n_lines:-0}
    n_distinct=$(printf '%s\n' "$out" | grep -aoE '[0-9]+/3 次成功' | sort -u | wc -l | tr -d ' ')
    case "$n_distinct" in ''|*[!0-9]*) n_distinct=0 ;; esac
    h_log "结果行数 $n_lines / 不同的成功次数 $n_distinct 种"
    h_check_eq "4" "$n_lines" "每个目标各一行结果（4 行）"
    h_check_eq "3" "$n_distinct" "不同目标的成功次数**互不相同**（3/3、2/3、0/3 各一份 ⇒ 没共用同一个结果文件）"

    # 短超时：每次探测收到的预算必须是菜单的 1s（不是规则里的 CONNECTION_TIMEOUT=10）
    local n_to bad_to n_to1
    n_to=$(h_count '^' "$conc/timeouts"); n_to=${n_to:-0}
    bad_to=$(grep -cv '^1$' "$conc/timeouts" 2>/dev/null); bad_to=${bad_to:-0}
    n_to1=$(grep -c '^1$' "$conc/timeouts" 2>/dev/null); n_to1=${n_to1:-0}
    h_log "探测次数 $n_to / 预算=1 的次数 $n_to1 / 其它预算 $bad_to"
    h_check_eq "12" "$n_to" "4 个目标 × 3 次采样 = 12 次探测"
    h_check_eq "0" "$bad_to" "每次探测的预算都是菜单的 1s（没用规则里写死的 10s）"

    # 并发：数「同时在飞」的探测数
    local maxc
    maxc=$(sort -n "$conc/counts" 2>/dev/null | tail -1)
    case "$maxc" in ''|*[!0-9]*) maxc=0 ;; esac
    h_log "并发度（同时在飞的探测数）峰值: $maxc"
    h_check_ge "2" "$maxc" "探测是并发跑的（同一时刻有 ≥2 个探测在飞）"
    # 串行的话：4 目标 × 3 次 × 1 秒 = 12 秒；并发 ≈ 3 秒
    h_check_le "8" "$elapsed" "总耗时远小于串行的 12 秒（串行口径：4 目标 × 3 次 × 1 秒）"

    # ── 腿 2（负向对照）：把并发退化成串行 ⇒ 断言必须红 ──
    #   注入手法：把「) &」（后台启动）改成「)」（同步执行）—— 只改一处，语义明确。
    local badlib="$SBX_ROOT/t134_badlib"
    rm -rf "$badlib"; mkdir -p "$badlib/lib"
    cp "$work/lib/"*.sh "$badlib/lib/" 2>/dev/null
    awk '
        /^probe_all_targets_latency\(\) \{/ { inblk=1; print; next }
        inblk && /^}/ { inblk=0; print; next }
        inblk && /^[[:space:]]*\)[[:space:]]*&[[:space:]]*$/ {
            sub(/[[:space:]]*&[[:space:]]*$/, "")
            print
            next
        }
        { print }
    ' "$work/lib/rules.sh" > "$badlib/lib/rules.sh" 2>/dev/null

    local n_diff=0 n_amp
    if ! diff -q "$work/lib/rules.sh" "$badlib/lib/rules.sh" >/dev/null 2>&1; then n_diff=1; fi
    n_amp=$(grep -c ') &' "$badlib/lib/rules.sh" 2>/dev/null); n_amp=${n_amp:-0}
    h_check_eq "1" "$n_diff" "负向对照自检 · 退化副本确实不同于原版（破坏手法生效）"
    h_check_eq "0" "$n_amp" "负向对照自检 · 退化副本里已经没有后台启动（) &）了"

    local out_bad elapsed_bad maxc_bad
    out_bad=$(_t134_run_probe "$badlib" "$cfg" "$badconc")
    elapsed_bad=$(printf '%s\n' "$out_bad" | grep -a '^ELAPSED=' | head -1 | cut -d= -f2)
    case "$elapsed_bad" in ''|*[!0-9]*) elapsed_bad=0 ;; esac
    maxc_bad=$(sort -n "$badconc/counts" 2>/dev/null | tail -1)
    case "$maxc_bad" in ''|*[!0-9]*) maxc_bad=0 ;; esac
    h_log "负向对照：并发度峰值 $maxc_bad / 耗时 ${elapsed_bad}s"

    h_check_eq "1" "$maxc_bad" "负向对照：退化成串行后并发度掉到 1（证明并发这条断言拦得住）"
    h_check_ge "10" "$elapsed_bad" "负向对照：退化成串行后耗时会涨到 10 秒以上（证明耗时那条断言拦得住）"

    # ── set -u 下不许崩（菜单整体是 set -u 跑的）──
    #   ★ 这条专门抓「变量名写错」这类错（未定义变量在 set -u 下直接中断），
    #     普通跑法里它只是「静默变空」⇒ 结果看起来还挺正常（更阴险）。
    local out_su
    out_su=$(_t134_run_probe "$work" "$cfg" "$suconc" 1 "setu")
    h_log "set -u 跑批输出尾部: $(printf '%s' "$out_su" | tail -3 | tr '\n' ' ' | cut -c1-200)"
    h_check_not_contains "$out_su" "unbound variable" "set -u 下探测不崩（没有未定义变量引用）"
    h_check_contains "$out_su" "PROBE_RC=0" "set -u 下探测正常跑完"

    rm -rf "$work" "$badlib" "$conc" "$badconc" "$suconc"
    rm -f "$rules"/rule-*.conf
}
