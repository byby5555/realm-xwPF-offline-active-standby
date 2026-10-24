#!/bin/bash
# 用例组 11 · 时延测量（第 7 轮新增 · 从 tests/test_latency.sh 并入唯一入口）
#
# 来源：原独立脚本 tests/test_latency.sh（A~F 六组）—— 本轮并入 run_tests.sh，
#       原脚本改成薄封装（内部 exec 到 run_tests.sh --only T51），保证「只有一个真源」。
#
# 被测对象：冻结态 $SBX_SRC/lib/health.sh（now_us / probe_with_latency / latency_avg_ms /
#          format_latency_display / get_health_status_record / health_check_script_body）
#          + 冻结态 $SBX_SRC/lib/rules.sh（load_balance_management_menu 的渲染）
#
# ★ 与原脚本的差别（重要）：
#   1) 被测代码来自**冻结态**（git show $BASE_SHA:<path>），不是工作区；
#   2) 路径靠沙箱重定向（/etc/realm → ${SBX}/realm），不再手工 sed；
#   3) 时间源**在沙箱里打桩**：now_us 优先用 bash 5 的 EPOCHREALTIME，
#      拿不到时回退 date +%s%N —— 两者都产出微秒数，断言只认「纯数字 + 单调 + 量级」，
#      不认具体数值（数值会飘，钉数值就是钉实现）。
#   4) 本地监听端口用 _start_listener（自动挑可用的 python），不写死 python3。

# 判定器：状态记录的一行必须是什么形状
# 用法：_t51_judge_status <行内容>
# 输出："<PASS|FAIL>\t<说明>"
_t51_judge_status() {
    local line="$1"
    local nf lat hist
    nf=$(printf '%s' "$line" | awk -F'|' '{print NF}')
    if [ "$nf" != "9" ]; then
        printf 'FAIL\t状态记录字段数 = %s（期望 9）\n' "$nf"
        return 1
    fi
    lat=$(printf '%s' "$line" | cut -d'|' -f8)
    if ! printf '%s' "$lat" | grep -qE '^[0-9]+$'; then
        printf 'FAIL\t第 8 个字段不是时延毫秒数：<%s>\n' "$lat"
        return 1
    fi
    hist=$(printf '%s' "$line" | cut -d'|' -f9)
    if ! printf '%s' "$hist" | grep -qE '^[0-9]+(,[0-9]+)*$'; then
        printf 'FAIL\t第 9 个字段不是时延历史：<%s>\n' "$hist"
        return 1
    fi
    printf 'PASS\t状态记录 9 字段，第 8 是时延、第 9 是历史\n'
    return 0
}

case_T51_latency_merged() {
    h_case_begin "T51" "时延测量：打点 / 探测 / 辅助函数 / 生成物真跑 / 菜单渲染" \
        "沙箱 rules + 本地监听端口 + 冻结态 health.sh / rules.sh" \
        "now_us / probe_with_latency / latency_avg_ms / format_latency_display / get_health_status_record / health_check_script_body / load_balance_management_menu" \
        "时延打点是纯数字且单调；探测把真实时延写进 PROBE_LATENCY_MS；生成的 health_check.sh 跑一轮后状态记录是 9 字段（第 8 时延、第 9 历史，历史封顶 5）；菜单在 set -u 下渲染出 [时延: Nms (均 Mms)]"

    local port=18097
    local dead_port=18098

    # ── A. 时间打点 now_us ──
    local a
    a=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        t1=$(now_us); rc1=$?
        t2=$(now_us); rc2=$?
        echo "T1=$t1"
        echo "T2=$t2"
        echo "RC1=$rc1"
        echo "RC2=$rc2"
    ' 2>&1)
    local t1 t2 rc1 rc2
    t1=$(printf '%s' "$a" | grep -a '^T1=' | head -1 | cut -d= -f2-)
    t2=$(printf '%s' "$a" | grep -a '^T2=' | head -1 | cut -d= -f2-)
    rc1=$(printf '%s' "$a" | grep -a '^RC1=' | head -1 | cut -d= -f2-)
    rc2=$(printf '%s' "$a" | grep -a '^RC2=' | head -1 | cut -d= -f2-)
    h_log "now_us: t1=$t1 t2=$t2 rc1=$rc1 rc2=$rc2"
    h_check_eq "0" "$rc1" "now_us 退出码 0"
    h_check_eq "0" "$rc2" "now_us 退出码 0（第二次）"
    h_check_contains "$t1" "" "now_us 取到时间戳"
    local is_num=否
    printf '%s' "$t1" | grep -qE '^[0-9]+$' && is_num=是
    h_check_eq "是" "$is_num" "now_us 返回纯数字（微秒）"
    local mono=否
    if printf '%s' "$t1" | grep -qE '^[0-9]+$' && printf '%s' "$t2" | grep -qE '^[0-9]+$'; then
        [ "$t2" -ge "$t1" ] && mono=是
    fi
    h_check_eq "是" "$mono" "now_us 单调不减"
    local len=${#t1}
    h_check_ge 13 "$len" "now_us 量级合理（≥ 13 位微秒）"

    # ── B. 带耗时的探测 probe_with_latency ──
    if ! _start_listener "$port"; then
        h_fail "起不来本地监听端口，B 组无法执行"
        return
    fi
    local b
    b=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        probe_with_latency "127.0.0.1" "$2" 3
        echo "RC=$?"
        echo "MS=$PROBE_LATENCY_MS"
    ' "$port" 2>&1)
    local prc pms
    prc=$(printf '%s' "$b" | grep -a '^RC=' | head -1 | cut -d= -f2-)
    pms=$(printf '%s' "$b" | grep -a '^MS=' | head -1 | cut -d= -f2-)
    h_log "probe_with_latency: rc=$prc PROBE_LATENCY_MS=$pms"
    h_check_eq "0" "$prc" "可达端口 → 探测退出码 0"
    local ms_num=否
    printf '%s' "$pms" | grep -qE '^[0-9]+$' && ms_num=是
    h_check_eq "是" "$ms_num" "PROBE_LATENCY_MS 是纯数字"
    local ms_ok=否
    if [ "$ms_num" = "是" ]; then
        [ "$pms" -lt 3000 ] && ms_ok=是
    fi
    h_check_eq "是" "$ms_ok" "PROBE_LATENCY_MS 合理（< 3000ms）"

    # 对照口径：关闭的端口 → 失败
    local b2
    b2=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        probe_with_latency "127.0.0.1" "$2" 2
        echo "RC=$?"
    ' "$dead_port" 2>&1)
    local prc2
    prc2=$(printf '%s' "$b2" | grep -a '^RC=' | head -1 | cut -d= -f2-)
    h_check_rc "nonzero" "$prc2" "关闭端口 → 探测退出码非 0"

    # ── C. 时延辅助函数 ──
    local c
    c=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        echo "AVG3=$(latency_avg_ms "10,20,30")"
        echo "AVG1=$(latency_avg_ms "15")"
        latency_avg_ms "" >/dev/null 2>&1
        echo "AVGEMPTY_RC=$?"
        echo "DISP_HIST=$(format_latency_display "12" "10,20,30")"
        echo "DISP_NOHIST=$(format_latency_display "12" "")"
        echo "DISP_NONE=$(format_latency_display "" "")"
    ' 2>&1)
    local avg3 avg1 avgempty disp_hist disp_nohist disp_none
    avg3=$(printf '%s' "$c" | grep -a '^AVG3=' | head -1 | cut -d= -f2-)
    avg1=$(printf '%s' "$c" | grep -a '^AVG1=' | head -1 | cut -d= -f2-)
    avgempty=$(printf '%s' "$c" | grep -a '^AVGEMPTY_RC=' | head -1 | cut -d= -f2-)
    disp_hist=$(printf '%s' "$c" | grep -a '^DISP_HIST=' | head -1 | cut -d= -f2-)
    disp_nohist=$(printf '%s' "$c" | grep -a '^DISP_NOHIST=' | head -1 | cut -d= -f2-)
    disp_none=$(printf '%s' "$c" | grep -a '^DISP_NONE=' | head -1 | cut -d= -f2-)
    h_check_eq "20" "$avg3" "latency_avg_ms 求平均（10,20,30）"
    h_check_eq "15" "$avg1" "latency_avg_ms 单值"
    h_check_rc "nonzero" "$avgempty" "latency_avg_ms 空输入 → 非 0"
    h_check_eq "12ms (均 20ms)" "$disp_hist" "format_latency_display 带历史"
    h_check_eq "12ms" "$disp_nohist" "format_latency_display 无历史"
    h_check_eq "-" "$disp_none" "format_latency_display 无数据"

    # get_health_status_record：状态文件是产品自己写的，这里手工造一行同格式的
    local sf="$SBX_ROOT/realm/health/health_status.conf"
    mkdir -p "$(dirname "$sf")"
    cat > "$sf" <<'EOF'
# Realm健康状态文件
1|127.0.0.1|healthy|0|3|1792810000|0|12|10,12,14
EOF
    local rec
    rec=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        get_health_status_record "127.0.0.1"
        echo "RC=$?"
        get_health_status_record "10.9.9.9" >/dev/null 2>&1
        echo "RC_MISS=$?"
    ' 2>&1)
    local recline recrc recmiss
    recline=$(printf '%s' "$rec" | grep -a '^1|127.0.0.1|' | head -1)
    recrc=$(printf '%s' "$rec" | grep -a '^RC=' | head -1 | cut -d= -f2-)
    recmiss=$(printf '%s' "$rec" | grep -a '^RC_MISS=' | head -1 | cut -d= -f2-)
    h_check_eq "1|127.0.0.1|healthy|0|3|1792810000|0|12|10,12,14" "$recline" "get_health_status_record 返回整行"
    h_check_eq "0" "$recrc" "get_health_status_record 存在时返回 0"
    h_check_rc "nonzero" "$recmiss" "get_health_status_record 目标不存在 → 非 0"

    # ── D. 生成的 health_check.sh 真跑一轮 ──
    local rules="$SBX_ROOT/realm/rules"
    mkdir -p "$rules"
    cat > "$rules/rule-1.conf" <<'EOF'
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
    local hc="$SBX_ROOT/health_check.sh"
    _run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' > "$hc" 2>/dev/null
    h_check_file "$hc" "生成的 health_check.sh"
    local hsrc
    hsrc=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' 2>/dev/null | grep -c '^check_connectivity() {')
    h_check_ge 1 "$hsrc" "生成的 health_check.sh 里探测实现存在（机械抽取生效）"

    rm -f "$sf"
    local hrc
    hrc=$(bash "$hc" >/dev/null 2>&1; echo $?)
    h_check_eq "0" "$hrc" "健康检查脚本退出码 0"

    local line1
    line1=$(grep '^1|127.0.0.1|' "$sf" 2>/dev/null | head -1)
    h_log "状态记录: $line1"
    local v1
    v1=$(_t51_judge_status "$line1")
    h_log "状态判定: $(printf '%s' "$v1" | cut -f1) —— $(printf '%s' "$v1" | cut -f2-)"
    h_check_contains "$v1" "PASS" "状态记录是 9 字段（第 8 时延、第 9 历史）"

    # 历史累积：再跑两轮 → 3 个样本
    bash "$hc" >/dev/null 2>&1
    bash "$hc" >/dev/null 2>&1
    local hist2 cnt2
    hist2=$(grep '^1|127.0.0.1|' "$sf" 2>/dev/null | head -1 | cut -d'|' -f9)
    cnt2=$(printf '%s' "$hist2" | tr ',' '\n' | grep -c .)
    h_log "跑 3 轮后的历史: $hist2（$cnt2 个样本）"
    h_check_eq "3" "$cnt2" "时延历史累积到 3 个样本"

    # 再跑 4 轮 → 封顶 5
    local i
    for i in 1 2 3 4; do bash "$hc" >/dev/null 2>&1; done
    local hist3 cnt3
    hist3=$(grep '^1|127.0.0.1|' "$sf" 2>/dev/null | head -1 | cut -d'|' -f9)
    cnt3=$(printf '%s' "$hist3" | tr ',' '\n' | grep -c .)
    h_log "跑 7 轮后的历史: $hist3（$cnt3 个样本）"
    h_check_eq "5" "$cnt3" "时延历史最多保留 5 个样本"

    # ── E. 菜单展示时延（静态 + set -u 下真渲染）──
    local n_lat n_fn n_entry n_hint
    n_lat=$(grep -c 'failover_info\$latency_info' "$SBX_SRC/lib/rules.sh" 2>/dev/null || true)
    n_fn=$(grep -c '^probe_all_targets_latency() {' "$SBX_SRC/lib/rules.sh" 2>/dev/null || true)
    n_entry=$(grep -c '立即测试所有目标时延' "$SBX_SRC/lib/rules.sh" 2>/dev/null || true)
    n_hint=$(grep -c '由后台健康检查持续更新' "$SBX_SRC/lib/rules.sh" 2>/dev/null || true)
    [ -z "$n_lat" ] && n_lat=0
    [ -z "$n_fn" ] && n_fn=0
    [ -z "$n_entry" ] && n_entry=0
    [ -z "$n_hint" ] && n_hint=0
    h_log "菜单静态：latency_info=$n_lat probe_all_targets_latency=$n_fn 入口=$n_entry 提示=$n_hint"
    h_check_ge 1 "$n_lat" "菜单里展示了时延信息（命中数下限护栏）"
    h_check_eq "1" "$n_fn" "定义了「立即测试所有目标时延」函数"
    h_check_eq "1" "$n_entry" "菜单提供「立即测试所有目标时延」入口"
    h_check_eq "1" "$n_hint" "菜单提示时延来源与刷新周期"

    # 真渲染一次（set -u 下也必须跑得通）
    cat > "$sf" <<'EOF'
1|127.0.0.1|healthy|0|3|1792810000|0|12|10,12,14
2|127.0.0.2|healthy|0|3|1792810000|0|88|80,90
EOF
    cat > "$rules/rule-1.conf" <<'EOF'
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
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF
    cat > "$rules/rule-2.conf" <<'EOF'
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
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF
    local menu_out
    menu_out=$(_run_in_sandbox '
        # ★ $1 = 代码根（$SBX_RUN），$2 = 沙箱 realm 目录（额外传进来的）
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        ( set -u; printf "0\n" | load_balance_management_menu )
    ' "$SBX_ROOT/realm" 2>&1)
    h_log "菜单渲染片段: $(printf '%s' "$menu_out" | grep -a '时延' | head -2 | tr '\n' ' ' | cut -c1-200)"
    h_check_contains "$menu_out" '[时延: 12ms (均 12ms)]' "菜单渲染出主目标时延"
    h_check_contains "$menu_out" '[时延: 88ms (均 85ms)]' "菜单渲染出备目标时延"
    h_check_eq "2" "$(printf '%s' "$menu_out" | grep -ac '\[健康\]' || true)" "菜单渲染出两条目标的健康状态"
    h_check_contains "$menu_out" "立即测试所有目标时延" "菜单含「立即测试所有目标时延」入口"
    h_check_not_contains "$menu_out" "unbound variable" "菜单在 set -u 下没崩"

    # ── 负向对照 1：把 latency_avg_ms 弄坏 → 菜单里的「均 Nms」必须变 → 断言会红 ──
    # 注入到**副本**（不改冻结态、不改仓库）
    # ★ 破坏手法按**语义**定位：不在原文里找某一行改写（写法一改就静默失效），
    #   而是在副本**末尾追加一个同名函数覆盖**（bash 里后定义覆盖先定义）——
    #   无论产品怎么改写 latency_avg_ms 的内部实现，这个覆盖都一定生效。
    local badlib="$SBX_ROOT/t51_badlib"
    rm -rf "$badlib"
    mkdir -p "$badlib/lib"
    cp "$SBX_RUN/lib/"*.sh "$badlib/lib/" 2>/dev/null
    cat >> "$badlib/lib/health.sh" <<'EOS'

# T51-NEG: 负向对照 —— 把平均时延算坏
latency_avg_ms() {
    echo 0
}
EOS
    local n_inj
    n_inj=$(grep -c 'T51-NEG' "$badlib/lib/health.sh" 2>/dev/null || true)
    [ -z "$n_inj" ] && n_inj=0
    h_check_eq "1" "$n_inj" "负向对照 1 的破坏手法生效（覆盖点 == 1）"
    local bad_menu
    bad_menu=$(bash -c '
        export CONFIG_DIR="$1"
        source "$2/lib/core.sh" >/dev/null 2>&1
        source "$2/lib/health.sh" >/dev/null 2>&1
        source "$2/lib/rules.sh" >/dev/null 2>&1
        source "$2/lib/realm.sh" >/dev/null 2>&1
        ( set -u; printf "0\n" | load_balance_management_menu )
    ' _ "$SBX_ROOT/realm" "$badlib" 2>&1)
    h_log "坏副本的菜单时延片段: $(printf '%s' "$bad_menu" | grep -a '时延' | head -1 | tr '\n' ' ' | cut -c1-160)"
    h_check_contains "$bad_menu" "均 0ms" "负向对照 1：平均值被覆盖成 0 后菜单渲染出坏值（说明破坏真的生效了）"
    h_check_not_contains "$bad_menu" '[时延: 12ms (均 12ms)]' "负向对照 1：平均值算坏后菜单不再渲染出期望的时延串（说明断言拦得住）"

    # ── 负向对照 2：把状态记录截断成 8 字段 → 状态判定必须判红 ──
    local v2
    v2=$(_t51_judge_status "1|127.0.0.1|healthy|0|3|1792810000|0|12")
    h_log "截断行判定: $(printf '%s' "$v2" | cut -f1) —— $(printf '%s' "$v2" | cut -f2-)"
    h_check_contains "$v2" "FAIL" "负向对照 2：字段数不对时必须判红"
    h_check_contains "$v2" "字段数" "负向对照 2：判红原因指到「字段数」"

    # ── 负向对照 3：第 8 字段不是数字 → 状态判定必须判红 ──
    local v3
    v3=$(_t51_judge_status "1|127.0.0.1|healthy|0|3|1792810000|0|N/A|10,12")
    h_log "非数字时延判定: $(printf '%s' "$v3" | cut -f1) —— $(printf '%s' "$v3" | cut -f2-)"
    h_check_contains "$v3" "FAIL" "负向对照 3：时延字段非数字时必须判红"
    h_check_contains "$v3" "第 8 个字段" "负向对照 3：判红原因指到「第 8 个字段」"
}
