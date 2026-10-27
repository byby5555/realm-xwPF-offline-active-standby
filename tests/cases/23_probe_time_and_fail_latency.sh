#!/bin/bash
# 用例组 23 · 探测端时间源单位契约 + 失败样本时延分布（T110~T113）
#
# 背景（Chief 拍板 · 本轮）：
#   ① **now_us 两条分支单位不一致**（真缺陷）：
#      函数声称「取当前时间（微秒）」，但 `date +%s%N` 分支返回的是**纳秒**（19 位），
#      而调用方统一按 (t1-t0)/1000 取毫秒 ⇒ **回退分支上时延被放大 1000 倍**。
#      受害面 = bash<5（无 EPOCHREALTIME）+ GNU coreutils ⇒ CentOS 7 / RHEL 7 这类老 VPS；
#      bash 5+ 不受影响；busybox 取不到时间戳 ⇒ 降级为「无时延」（优雅）。
#      ⇒ 这条**不是**阶段 2 才需要修：N5 阶段 1 已有的「成功样本时延」在老 bash 机器上就是错的。
#   ② **失败样本的时延没被记**（口径与用户拍板的不一致）：
#      用户拍板的口径 = 「失败率 + **失败时延分布**」；实现只记成功样本的时延
#      （push_quality_sample 失败时只追加成败位、丢弃 lat_ms）。
#      ⇒ 本组把「失败样本时延入窗口 / 滚动同步丢 / 进统计与展示」钉成不变式。
#
# ★ 负向对照形态：
#   · T110：注入式退化（把「纳秒→微秒」的换算去掉 = 缺陷版）⇒ 同一断言必须判红。
#   · T111：注入式退化（把失败样本的时延丢掉 = 修复前的行为）⇒ 同一断言必须判红。
#   · T113：注入式退化（读窗口时不取失败时延列）⇒ 同一断言必须判红。
#   每个退化都带**退化生效自检**（改不动就直接判红）—— 否则负向对照静默失效、腿变恒真。
#
# ★ 被测产物只来自冻结态（git show $BASE_SHA:<path>），绝不 source 工作区文件。

# ══════════════════════════════════════════════════════════════
# T110 · now_us 两条分支的单位一致（都产出微秒）
# ══════════════════════════════════════════════════════════════
# ★ 判据要点：
#   ① **位数落在区间**（15~17），不是「位数 ≥ 13」——
#      下限断言挡不住 19 位（纳秒）⇒ 那是**不具判别力**的断言。
#   ② **跨 1 秒的毫秒差**落在 500~10000 —— 纳秒没换算会是 ~1000000 ⇒ 越界。
#   ③ 两条分支都要测：默认分支（bash 5 走 EPOCHREALTIME）与
#      **强制回退分支**（NOW_US_FORCE_FALLBACK=1）——
#      bash 4 的机器上默认分支就是回退分支，bash 5 的机器上默认分支永远测不到回退分支
#      ⇒ 不强制覆盖 ⇒ 回退分支就是盲区。
case_T110_now_us_unit_consistent() {
    h_case_begin "T110" "探测端时间源 now_us：两条分支单位一致（都产出微秒，不是纳秒）" \
        "冻结态 lib/health.sh 的 now_us（含 NOW_US_FORCE_FALLBACK 强制回退分支）" \
        "两分支各取两次时间戳跨一次 sleep，算毫秒差 + 数返回值的位数" \
        "两分支位数都落在 15~17（微秒量级）、毫秒差都落在 500~10000；把纳秒→微秒的换算去掉 ⇒ 同一断言判红"

    # ── 腿 A/B：两条分支的位数与毫秒差 ──────────────────────────
    local out
    out=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        d0=$(now_us); d0=${#d0}
        t0=$(now_us); sleep 1; t1=$(now_us)
        m0=$(( (t1 - t0) / 1000 ))
        export NOW_US_FORCE_FALLBACK=1
        d1=$(now_us); d1=${#d1}
        u0=$(now_us); sleep 1; u1=$(now_us)
        m1=$(( (u1 - u0) / 1000 ))
        echo "$d0 $m0 $d1 $m1"
    ')
    local d0 m0 d1 m1
    read -r d0 m0 d1 m1 <<< "$out"
    h_log "默认分支：位数=${d0:-（读不到）} 毫秒差=${m0:-（读不到）}；强制回退分支：位数=${d1:-（读不到）} 毫秒差=${m1:-（读不到）}"

    # 位数：微秒 = 15~17 位（纳秒 19 位落在区间外 ⇒ 有判别力）
    h_check_ge "15" "${d0:-0}" "默认分支 now_us 返回值位数 ≥ 15（微秒量级；纳秒是 19 位）"
    h_check_le "17" "${d0:-99}" "默认分支 now_us 返回值位数 ≤ 17（微秒量级）"
    h_check_ge "15" "${d1:-0}" "强制回退分支 now_us 返回值位数 ≥ 15（回退分支也必须是微秒）"
    h_check_le "17" "${d1:-99}" "强制回退分支 now_us 返回值位数 ≤ 17（回退分支也必须是微秒）"

    # 毫秒差：睡 1 秒 ≈ 1000ms；纳秒没换算 ⇒ ~1000000ms（越界）
    h_check_ge "500" "${m0:-0}" "默认分支：跨 1 秒的毫秒差 ≥ 500（真的在计时）"
    h_check_le "10000" "${m0:-999999999}" "默认分支：跨 1 秒的毫秒差 ≤ 10000（纳秒没换算会放大 1000 倍）"
    h_check_ge "500" "${m1:-0}" "回退分支：跨 1 秒的毫秒差 ≥ 500（真的在计时）"
    h_check_le "10000" "${m1:-999999999}" "回退分支：跨 1 秒的毫秒差 ≤ 10000（纳秒没换算会放大 1000 倍）"

    # ── 负向对照：注入式退化（把纳秒→微秒的换算去掉）────────────
    #    同一套断言在缺陷版上必须判红 ⇒ 证明上面几条不是恒真。
    local lib_bad="$SBX_ROOT/lib_health_nowus_ns.sh"
    # ★ 退化针对**换算表达式本身**，不针对某一行文本：
    #   产品改一次实现（换算挪到别处、写法微调、局部变量改名）时，
    #   按文本匹配的 sed 会**静默失配** ⇒ 退化没生效 ⇒ 负向对照失效、
    #   腿 A/B 变成**恒真断言**（这类假绿最难发现：断言还在，判别力没了）。
    #   这里把「除以 1000 的那处换算」替换成原值 ⇒ 缺陷版直接输出纳秒。
    #   （只认 `$(( 变量 / 1000 ))` 这一种形态 ⇒ 不会被 `(t1 - t0) / 1000` 误伤）
    #   ★ 替换结果必须带 `$`（`$\1` 而不是 `\1`）：
    #     bash 里 `VAR=t` 赋的是**字面量 "t"**，不是变量 t 的值
    #     ⇒ 少了这个 `$`，缺陷版会输出 "t"（1 位）而不是纳秒（19 位），
    #       负向对照照样「跑了」，但断的不是同一条腿 ⇒ 判别力是假的。
    sed -E 's|\$\(\( *([A-Za-z_][A-Za-z0-9_]*) */ *1000 *\)\)|$\1|g' "$SBX_RUN/lib/health.sh" > "$lib_bad" 2>/dev/null
    h_check_file "$lib_bad" "缺陷版 lib/health.sh（去掉了纳秒→微秒的换算）"

    # ── 退化生效自检（**形态无关**：只看语义，不看具体写法）──────
    #   `grep -c` 在「0 处匹配」时会**打印 0 并以退出码 1 结束** ⇒ 这里只能 `|| true`，
    #   写成 `|| echo 0` 会多打一个 0（断言拿到 "0\n0"）。
    local conv_re='\$\(\( *[A-Za-z_][A-Za-z0-9_]* */ *1000 *\)\)'
    local n_conv
    n_conv=$(grep -cE "$conv_re" "$SBX_RUN/lib/health.sh" 2>/dev/null || true)
    n_conv=${n_conv:-0}
    h_check_ge 1 "$n_conv" "退化生效自检 · 原版里确实存在「纳秒→微秒」的换算（退化目标存在）"

    local n_conv_bad
    n_conv_bad=$(grep -cE "$conv_re" "$lib_bad" 2>/dev/null || true)
    n_conv_bad=${n_conv_bad:-0}
    h_check_eq "0" "$n_conv_bad" \
        "退化生效自检：缺陷版里已没有纳秒→微秒的换算（没生效 ⇒ 负向对照失效、腿 A/B 恒真）"

    # 兜底：缺陷版必须**确实与原版不同**（sed 一个字没改也要抓到）
    local n_diff=0
    cmp -s "$SBX_RUN/lib/health.sh" "$lib_bad" 2>/dev/null || n_diff=1
    h_check_eq "1" "$n_diff" "退化生效自检 · 缺陷版确实与原版不同（退化真的动过手）"

    local out_bad bd bm
    out_bad=$(_run_in_sandbox '
        source "$2" >/dev/null 2>&1
        export NOW_US_FORCE_FALLBACK=1
        d1=$(now_us); d1=${#d1}
        u0=$(now_us); sleep 1; u1=$(now_us)
        m1=$(( (u1 - u0) / 1000 ))
        echo "$d1 $m1"
    ' "$lib_bad")
    read -r bd bm <<< "$out_bad"
    h_log "缺陷版：位数=${bd:-（读不到）} 毫秒差=${bm:-（读不到）}"
    h_check_ge "19" "${bd:-0}" "缺陷版的位数 ≥ 19（纳秒）⇒ 腿 A/B 的 15~17 断言在缺陷版上会判红（有判别力）"
    h_check_ge "100000" "${bm:-0}" "缺陷版的毫秒差 ≥ 100000（放大 1000 倍）⇒ 腿 A/B 的 ≤10000 断言在缺陷版上会判红"
}

# ══════════════════════════════════════════════════════════════
# T111 · 失败样本的时延进了窗口（落地「失败率 + 失败时延分布」口径）
# ══════════════════════════════════════════════════════════════
# ★ 场景：两个目标都指向**必定拒连**的端口（127.0.0.1:1 / :2）⇒ 每轮都是失败样本
#   （拒连是瞬时的，不会拖满超时预算 ⇒ 跑得快、结果确定）。
#
# ★ 不变式（钉对齐，不钉字面量）：
#   失败样本个数 == FAIL_LAT_SEQ 的个数（失败时延与成败位一一对应）
#   没有成功样本 ⇒ LAT_SEQ 为空（成功时延与失败时延**分开存**）
case_T111_fail_latency_recorded_in_window() {
    h_case_begin "T111" "质量窗口记失败样本的时延（失败率 + 失败时延分布）" \
        "冻结态生成的 health_check.sh + 沙箱规则（目标指向必定拒连的端口）" \
        "连跑 2 轮探测 → 读质量指标文件的 SAMPLE_SEQ / LAT_SEQ / FAIL_LAT_SEQ 三列" \
        "失败样本个数 == FAIL_LAT_SEQ 的个数；没有成功样本 ⇒ LAT_SEQ 为空；注入「失败时延被丢弃」的坏实现 ⇒ 同一断言判红"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local qm="$SBX_ROOT/var.lib.realm/quality_metrics.conf"
    local hc="$SBX_ROOT/health_check.sh"
    local hc_bad="$SBX_ROOT/health_check_bad_t111.sh"

    # 读某目标那一行的三列（SAMPLE_SEQ / LAT_SEQ / FAIL_LAT_SEQ）
    _t111_cols() {
        awk -F'|' '$1 == "127.0.0.1:1" && $2 == "1" { print $3 "|" $4 "|" $6; exit }' "$qm" 2>/dev/null
    }

    # 生成冻结态探测脚本（好版本）
    rm -f "$hc"
    _run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' > "$hc" 2>/dev/null
    h_check_file "$hc" "生成的 health_check.sh"

    # ── 腿 A：连跑 2 轮 ⇒ 失败样本的时延必须进窗口 ─────────────
    mkdir -p "$rules" "$(dirname "$health")"
    _n5_make_rules "$rules" "127.0.0.1" 1 2
    _n5_check_rule_ids "$rules" "T111 腿 A"
    rm -f "$qm"
    local r
    for r in 1 2; do
        bash "$hc" >/dev/null 2>&1
    done

    local cols seq lat fail_lat rest n_fail n_fail_lat
    cols=$(_t111_cols)
    seq="${cols%%|*}"; rest="${cols#*|}"; lat="${rest%%|*}"; fail_lat="${rest#*|}"
    n_fail=$(printf '%s' "$seq" | tr ',' '\n' | grep -c '^1$' || true)
    n_fail_lat=$(printf '%s' "$fail_lat" | tr ',' '\n' | grep -c '^[0-9][0-9]*$' || true)
    h_log "SAMPLE_SEQ=[${seq:-（读不到）}] LAT_SEQ=[${lat:-（读不到）}] FAIL_LAT_SEQ=[${fail_lat:-（读不到）}] 失败位=${n_fail:-0} 失败时延个数=${n_fail_lat:-0}"
    h_check_ge "1" "${n_fail:-0}" "腿 A 前置：场景里确实产生了失败样本（目标指向必定拒连的端口）"
    h_check_eq "${n_fail:-0}" "${n_fail_lat:-0}" "失败样本的个数 == FAIL_LAT_SEQ 的个数（失败时延与成败位一一对齐）"
    h_check_eq "" "$lat" "没有成功样本 ⇒ LAT_SEQ 为空（成功时延与失败时延分开存）"

    # ── 负向对照：注入「失败时延被丢弃」（= 修复前的行为）─────────
    #    退化点选在**落盘那一行**：把末列（失败时延）不写出去 ⇒
    #    窗口里根本没有失败时延（修复前的真实形态）。
    #    ★ 不能改成「传空的上次失败时延」—— 那样只会丢**历史**，
    #      本次样本的失败时延照样会被记下来（退化不成形 ⇒ 负向对照没有判别力）。
    sed 's#|\${_q_win}|\${_q_new_fail_lat}"#|\${_q_win}"#' "$hc" > "$hc_bad" 2>/dev/null
    h_check_file "$hc_bad" "缺陷版 health_check.sh（注入式退化：失败时延不落盘）"
    h_check_file_has "$hc_bad" '|${_q_win}" >> "$_quality_rows_new"' \
        "退化生效自检：缺陷版的落盘行确实不再写失败时延列（否则负向对照没生效）"

    rm -f "$qm"
    for r in 1 2; do
        bash "$hc_bad" >/dev/null 2>&1
    done
    local cols_bad seq_bad fail_lat_bad n_fail_lat_bad
    cols_bad=$(_t111_cols)
    seq_bad="${cols_bad%%|*}"
    fail_lat_bad="${cols_bad##*|}"
    n_fail_lat_bad=$(printf '%s' "$fail_lat_bad" | tr ',' '\n' | grep -c '^[0-9][0-9]*$' || true)
    h_log "缺陷版：SAMPLE_SEQ=[${seq_bad:-（读不到）}] FAIL_LAT_SEQ=[${fail_lat_bad:-（读不到）}]"
    h_check_eq "0" "${n_fail_lat_bad:-0}" "缺陷版把失败时延丢了 ⇒ FAIL_LAT_SEQ 为空 ⇒ 腿 A 的对齐断言在缺陷版上会判红（有判别力）"
}

# ══════════════════════════════════════════════════════════════
# T112 · 窗口滚动时失败样本时延同步丢
# ══════════════════════════════════════════════════════════════
# ★ 为什么单独一条：环形滚动要丢最旧那次样本，
#   而**成功样本的时延**与**失败样本的时延**存在两个序列里 ——
#   丢错序列 ⇒ 计数与时延**错位**（看着像「失败很快」/「成功很慢」的假象）。
# ★ 函数级测（不依赖真机网络）：直接调 push_quality_sample，结果确定。
case_T112_fail_latency_rolls_with_window() {
    h_case_begin "T112" "质量窗口滚动时失败样本时延同步丢（不越滚越多、不错位）" \
        "冻结态 lib/health.sh 的 push_quality_sample" \
        "函数级：序列甲（失败,成功,成功,成功）与序列乙（成功,失败,失败,成功），窗口都是 3，各推 4 次" \
        "丢最旧的失败样本 ⇒ FAIL_LAT_SEQ 同步少一个；丢最旧的成功样本 ⇒ 只丢 LAT_SEQ；两个序列始终与 SAMPLE_SEQ 对齐"

    local out
    out=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        push3() {
            local cur="$1" isfail="$2" lat="$3" win="$4"
            # ★ 必须**分行**赋值：同一条 local 里所有右侧会**一次性展开**
            #   （`local r="${cur#*|}" l="${r%%|*}"` 里的 l 会拿到 r 的**旧值** = 空）
            #   ⇒ 那样失败时延会被悄悄丢掉（本条用例第一版就踩了这个坑）。
            local s r l f
            s="${cur%%|*}"
            r="${cur#*|}"
            l="${r%%|*}"
            f="${r#*|}"
            push_quality_sample "$s" "$l" "$f" "$isfail" "$lat" "$win"
        }
        a=$(push3 "" 1 2500 3)
        a=$(push3 "$a" 0 10 3)
        a=$(push3 "$a" 0 20 3)
        a=$(push3 "$a" 0 30 3)
        b=$(push3 "" 0 10 3)
        b=$(push3 "$b" 1 2500 3)
        b=$(push3 "$b" 1 3000 3)
        b=$(push3 "$b" 0 40 3)
        echo "S1=$a"
        echo "S2=$b"
    ')

    local s1 s2
    s1=$(printf '%s\n' "$out" | grep '^S1=' | cut -d= -f2-)
    s2=$(printf '%s\n' "$out" | grep '^S2=' | cut -d= -f2-)
    h_log "序列甲 = ${s1:-（读不到）}；序列乙 = ${s2:-（读不到）}"

    # 序列甲：最旧的是**失败**样本 ⇒ 它连同 FAIL_LAT_SEQ 一起被丢
    local a_seq a_rest a_lat a_fail
    a_seq="${s1%%|*}"; a_rest="${s1#*|}"; a_lat="${a_rest%%|*}"; a_fail="${a_rest#*|}"
    h_check_eq "0,0,0" "$a_seq" "序列甲：窗口 3 ⇒ 只剩 3 个样本（0,0,0）"
    h_check_eq "10,20,30" "$a_lat" "序列甲：三个成功样本的时延都在 LAT_SEQ 里"
    h_check_eq "" "$a_fail" "序列甲：最旧的失败样本被丢时，它的时延也一起被丢（FAIL_LAT_SEQ 空）"

    # 序列乙：最旧的是**成功**样本 ⇒ 只丢 LAT_SEQ，失败时延不动
    local b_seq b_rest b_lat b_fail
    b_seq="${s2%%|*}"; b_rest="${s2#*|}"; b_lat="${b_rest%%|*}"; b_fail="${b_rest#*|}"
    h_check_eq "1,1,0" "$b_seq" "序列乙：窗口 3 ⇒ 只剩 3 个样本（1,1,0）"
    h_check_eq "40" "$b_lat" "序列乙：最旧的成功样本被丢 ⇒ 只剩最后一个成功样本的时延"
    h_check_eq "2500,3000" "$b_fail" "序列乙：两个失败样本的时延都在（最旧丢的是成功样本，不该动它）"

    # 对齐不变式：失败时延的个数 == 失败位的个数（两个序列都要成立）
    local n1 n1f n2 n2f
    n1=$(printf '%s' "$a_seq" | tr ',' '\n' | grep -c '^1$' || true)
    n1f=$(printf '%s' "$a_fail" | tr ',' '\n' | grep -c '^[0-9][0-9]*$' || true)
    n2=$(printf '%s' "$b_seq" | tr ',' '\n' | grep -c '^1$' || true)
    n2f=$(printf '%s' "$b_fail" | tr ',' '\n' | grep -c '^[0-9][0-9]*$' || true)
    h_check_eq "${n1:-0}" "${n1f:-0}" "序列甲：失败时延个数 == 失败位个数"
    h_check_eq "${n2:-0}" "${n2f:-0}" "序列乙：失败时延个数 == 失败位个数"
}

# ══════════════════════════════════════════════════════════════
# T113 · 失败时延分布进统计与展示
# ══════════════════════════════════════════════════════════════
# ★ 口径落点：菜单那一列（quality_window_display）与它背后的统计
#   （quality_window_stats）都必须能看到**失败样本**的时延，
#   否则「失败率 + 失败时延分布」这个口径只落了一半（指标文件里有、看不到）。
case_T113_fail_latency_in_stats_and_display() {
    h_case_begin "T113" "失败时延分布进统计与展示（菜单那一列能看到失败样本的时延）" \
        "冻结态 lib/health.sh 的 quality_window_stats / quality_window_display + 造一个窗口文件" \
        "写一个含 2 次失败 + 1 次成功的窗口 → 读统计与展示串" \
        "统计里失败时延的个数/均值/最大值正确；展示串含失败率与失败时延；注入「读窗口时不取失败时延列」的坏实现 ⇒ 同一断言判红"

    local qm="$SBX_ROOT/var.lib.realm/quality_metrics.conf"
    mkdir -p "$(dirname "$qm")"
    {
        echo "# Realm质量观测指标（只观测，不动作）"
        echo "# 格式: TARGET|RULE_ID|SAMPLE_SEQ|LAT_SEQ|WINDOW|FAIL_LAT_SEQ"
        echo "127.0.0.1:1|1|1,0,1|10|3|2500,3000"
    } > "$qm"
    h_check_file "$qm" "造出来的质量指标文件（含 2 次失败 + 1 次成功）"

    local out stats disp
    # ★ _run_in_sandbox 的位置参数：$1 = 冻结态根（SBX_RUN），$2 起 = 追加的参数。
    #   ⇒ 追加的第一个参数是 $2、第二个是 $3（写错下标 ⇒ source 到不存在的路径 ⇒ 静默空输出）。
    out=$(_run_in_sandbox '
        export QUALITY_METRICS_FILE="$2"
        source "$3/lib/health.sh" >/dev/null 2>&1
        stats=$(quality_window_stats "127.0.0.1:1" "1")
        disp=$(quality_window_display "127.0.0.1:1" "1")
        echo "STATS=$stats"
        echo "DISP=$disp"
    ' "$qm" "$SBX_RUN")
    stats=$(printf '%s\n' "$out" | grep '^STATS=' | cut -d= -f2-)
    disp=$(printf '%s\n' "$out" | grep '^DISP=' | cut -d= -f2-)
    h_log "统计 = ${stats:-（读不到）}；展示 = ${disp:-（读不到）}"

    h_check_eq "3|2|1|10|2750|3000|2" "$stats" \
        "统计：采样 3 / 失败 2 / 成功 1 / 成功时延均值 10 / 失败时延均值 2750 / 最大 3000 / 失败时延个数 2"
    h_check_contains "$disp" "失败率 66% (2/3)" "展示串含失败率（2/3 = 66%）"
    h_check_contains "$disp" "成功时延均值 10ms" "展示串含成功样本时延均值"
    h_check_contains "$disp" "失败时延 均 2750ms 最大 3000ms" "展示串含**失败样本**的时延分布（均值 + 最大值）"

    # ── 接线检查：菜单那一列**确实**用的是这个展示函数 ────────────
    #   ★ 查的不是「字符串长什么样」，是「谁在拼这个串」：
    #     · lib/rules.sh 的展示块必须调 quality_window_display
    #       （否则指标照写、但菜单上看不到 = 口径只落了一半）；
    #     · 拼串的地方只有 lib/health.sh 一处（rules.sh 里不该再有第二处拼接）。
    local rules_src="$SBX_SRC/lib/rules.sh"
    h_check_file "$rules_src" "冻结态 lib/rules.sh"
    h_check_file_has "$rules_src" 'quality_window_display "$target" "$_own_rule"' \
        "接线：菜单的展示块确实调 quality_window_display（指标写了但没人看得到 = 口径只落一半）"
    h_check_eq "0" "$(grep -c '窗口: 失败率' "$rules_src" 2>/dev/null || true)" \
        "展示串只在 lib/health.sh 一处拼（rules.sh 里没有第二处拼接 ⇒ 两处不会漂）"

    # ── 负向对照：注入式退化（读窗口时不取失败时延列）────────────
    local lib_bad="$SBX_ROOT/lib_health_nofaillat.sh"
    sed 's|\$3 "|" \$4 "|" \$6|\$3 "|" \$4 "|" ""|' "$SBX_RUN/lib/health.sh" > "$lib_bad" 2>/dev/null
    h_check_file "$lib_bad" "缺陷版 lib/health.sh（读窗口时不取失败时延列）"
    h_check_eq "0" "$(grep -c '\$6; exit' "$lib_bad" 2>/dev/null || true)" \
        "退化生效自检：缺陷版已不读失败时延列（没生效 ⇒ 负向对照失效、腿 A 恒真）"

    local out_bad stats_bad disp_bad
    out_bad=$(_run_in_sandbox '
        export QUALITY_METRICS_FILE="$2"
        source "$3" >/dev/null 2>&1
        stats=$(quality_window_stats "127.0.0.1:1" "1")
        disp=$(quality_window_display "127.0.0.1:1" "1")
        echo "STATS=$stats"
        echo "DISP=$disp"
    ' "$qm" "$lib_bad")
    stats_bad=$(printf '%s\n' "$out_bad" | grep '^STATS=' | cut -d= -f2-)
    disp_bad=$(printf '%s\n' "$out_bad" | grep '^DISP=' | cut -d= -f2-)
    h_log "缺陷版：统计 = ${stats_bad:-（读不到）}；展示 = ${disp_bad:-（读不到）}"
    h_check_not_contains "$disp_bad" "均 2750ms 最大 3000ms" \
        "缺陷版看不到失败样本时延 ⇒ 腿 A 的展示断言在缺陷版上会判红（有判别力）"
}
