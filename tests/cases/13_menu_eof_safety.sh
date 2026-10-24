# shellcheck shell=bash
#
# T53 · 交互式入口在 stdin 非终端（EOF）时必须干净退出
#
# ── 背景：这不是理论风险，是真机事故 ──────────────────────────
# 修复前（d0366b3:lib/ui.sh 的 show_menu）的形态：
#     while true; do
#         clear; 打印菜单; show_brief_status
#         read -p "请输入选择 [0-9]: " choice
#         case $choice in ... esac
#     done
# stdin 是 EOF（管道 / 后台 / cron / systemd / 无人值守）时：
#   · `read` **立刻**返回非 0（不阻塞），choice 为空
#   · `case` 不匹配任何分支 → 回到循环顶部
#   → **无限重绘 + 忙循环 + 无界输出**
# 真机后果：/tmp 是 tmpfs → 无界输出把 tmpfs 灌满 → 内存 + swap 耗尽
#   → sshd 握不上手，整机被压垮（真机实测 5.7 小时灌满 479MB tmpfs）。
# 修复（当前实现）：
#   ① 菜单读入统一走 helper（读到 EOF → **终止调用方**，不回菜单循环）
#   ② 菜单入口加 ui_require_tty 护栏（stdin 不是终端就不进菜单）
#
# ── 本用例钉的两层 ──────────────────────────────────────────
# 【第一层 · helper 契约】读到 EOF 时 helper 必须**终止调用方**
#   ★ 判据不能用「退出码」：helper 坏掉时脚本会继续往下跑、照样 rc=0 → 恒绿。
#     必须用**哨兵**：调用之后再打印一行 AFTER-CALLBACK-SENTINEL，
#     哨兵**不出现** = helper 终止了调用方；哨兵**出现** = 它没终止。
#   ★ 这层不能省：入口的 ui_require_tty 护栏会**先** exit，
#     根本走不到 helper —— 只测入口的话，把 helper 回退/删掉都抓不到。
#   ★ 覆盖 4 处实现：lib/core.sh（主脚本用）+ 3 个独立脚本各自内置的那份。
# 【第二层 · 入口端到端】菜单入口在 stdin=/dev/null 下：
#   ① 有限时间退出（自己退出，不能被 timeout 杀掉）② 输出字节数有上限 ③ 退出码 0
#   ＋ 防空过护栏：输出命中入口标志 + 输出非空
#   ＋ 负向对照：用**真实修复前实现**复现忙循环，断言「坏情况确实发生」。

# 修复前冻结点（EOF 忙循环修复之前的最后一个提交）
_T53_PRE_FIX_SHA="d0366b3"

# 输出字节数上限。
# 实测：修复后 170 字节；修复前 5 秒灌 171,903 字节。
# 上限取 64KB —— 离现状两个数量级、离坏情况一个数量级，两边都有余量。
_T53_BYTE_LIMIT=65536

# 哨兵：helper 调用**之后**才打印的一行。helper 终止调用方 → 它不出现。
_T53_SENTINEL="AFTER-CALLBACK-SENTINEL"

# 有 helper 契约的实现（4 处：主脚本 + 3 个独立脚本，各自带一份）
_T53_HELPER_HOSTS="lib/core.sh xwFailover.sh port-traffic-dog.sh speedtest.sh"

# 从冻结态文件里**现场抽** ui_read_into 的实现（不抄进测试）
_t53_extract_helper() {
    awk '
        /^ui_read_into\(\) *\{/ {inside=1}
        inside {print}
        inside && /^\} *$/ {exit}
    ' "$1"
}

# 退化副本：把「读到 EOF 就终止调用方」的护栏去掉
# （helper 是修复时**新引入**的，修复前没有等价形态 → 这条负向对照是
#   **注入式破坏**，不是历史实现；入口层那条负向对照才用真实旧实现）
_t53_degrade_helper() {
    awk '
        /^ui_read_into\(\) *\{/ {inside=1}
        inside {
            if ($0 ~ /^ *if ! read .*; then *$/) { print "    read -r -p \"$__prompt\" __val || true"; next }
            if ($0 ~ /^ *exit 0 *$/) { next }
            if ($0 ~ /^ *fi *$/) { next }
            if ($0 ~ /^ *#/) { next }
            print
        }
        inside && /^\} *$/ {exit}
    ' "$1"
}

# 跑一次 helper 契约：调用 helper 之后打印哨兵
# 用法：_t53_run_helper <helper文件> <输出文件>
_t53_run_helper() {
    local helper="$1" out="$2"
    timeout 10 bash -c '
        source "$1"
        ui_read_into "T53-PROMPT" __t53_v
        echo "AFTER-CALLBACK-SENTINEL"
    ' _ "$helper" </dev/null >"$out" 2>&1 || true
}

# ── 第一层：helper 契约（EOF 必须终止调用方）────────────────────
_t53_helper_contract() {
    local rel src hdir hfile dfile out_ok out_bad txt
    for rel in $_T53_HELPER_HOSTS; do
        src="$SBX_RUN/$rel"
        hdir="$SBX_ROOT/t53_helper"
        mkdir -p "$hdir"
        hfile="$hdir/$(printf '%s' "$rel" | tr '/' '_')"
        dfile="$hdir/$(printf '%s' "$rel" | tr '/' '_').degraded"

        if [ ! -f "$src" ]; then
            h_fail "$rel：冻结态文件不存在（$src）"
            continue
        fi
        _t53_extract_helper "$src" > "$hfile"
        _t53_degrade_helper "$src" > "$dfile"

        # 防空过护栏：抽取器没坏（抽到了东西、含函数头、含 EOF 护栏）
        local hbytes=0 has_fn=否 has_guard=否
        hbytes=$(wc -c <"$hfile" 2>/dev/null | tr -d ' ')
        [ -z "$hbytes" ] && hbytes=0
        grep -qF 'ui_read_into()' "$hfile" && has_fn=是
        grep -qF 'exit 0' "$hfile" && has_guard=是
        h_check_ge 40 "$hbytes" "$rel：抽取到的 helper 非空（防空过护栏）"
        h_check_eq "是" "$has_fn" "$rel：抽取到的 helper 含 ui_read_into 定义（防空过护栏）"
        h_check_eq "是" "$has_guard" "$rel：helper 自检 · 原实现含「读到 EOF 终止调用方」的护栏"

        # 负向对照的破坏手法自检：退化副本确实没有护栏了
        local deg_guard=否
        grep -qF 'exit 0' "$dfile" && deg_guard=是
        h_check_eq "否" "$deg_guard" "$rel：负向对照自检 · 退化副本确实去掉了护栏（破坏手法生效）"

        # 正向：helper 终止调用方 → 哨兵不出现
        out_ok="$hdir/ok.out"
        _t53_run_helper "$hfile" "$out_ok"
        txt=$(cat "$out_ok" 2>/dev/null)
        h_check_not_contains "$txt" "$_T53_SENTINEL" "$rel：读到 EOF 时 helper 必须终止调用方（哨兵不出现）"

        # 负向对照：护栏去掉 → 哨兵出现（断言「坏情况确实发生」）
        out_bad="$hdir/bad.out"
        _t53_run_helper "$dfile" "$out_bad"
        txt=$(cat "$out_bad" 2>/dev/null)
        h_check_contains "$txt" "$_T53_SENTINEL" "$rel：负向对照 · 护栏去掉后 helper 不再终止调用方（坏情况确实发生）"
    done
}

# ── 准备一个「修复前实现」的坏副本：把指定 SHA 的 lib/ 换进去 ──
_t53_prepare_pre_fix_lib() {
    local sha="$1"
    local libroot="$SBX_ROOT/t53_pre_$sha"
    _T53_LIBROOT="$libroot"
    rm -rf "$libroot"
    mkdir -p "$libroot/lib"
    local f
    for f in core.sh ui.sh health.sh rules.sh server.sh realm.sh failover.sh update.sh; do
        if ! (cd "$SBX_REPO" && git show "$sha:lib/$f" > "$libroot/lib/$f" 2>/dev/null); then
            echo "取不到 $sha:lib/$f" >&2
            return 1
        fi
    done
    return 0
}

# 在给定 lib 根下跑一次菜单入口：stdin=EOF、带 timeout 上限、输出落文件
# 用法：_t53_run_menu <libroot> <输出文件> <timeout秒>
# 输出：RC=<退出码> / BYTES=<字节数>
_t53_run_menu() {
    local libroot="$1" out="$2" tmo="$3"
    local rc=0 bytes=0
    timeout "$tmo" bash -c '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/ui.sh" >/dev/null 2>&1
        show_menu
    ' _ "$libroot" </dev/null >"$out" 2>&1 || rc=$?
    bytes=$(wc -c <"$out" 2>/dev/null | tr -d ' ')
    [ -z "$bytes" ] && bytes=0
    printf 'RC=%s\nBYTES=%s\n' "$rc" "$bytes"
}

case_T53_menu_eof_no_busy_loop() {
    h_case_begin "T53" "交互式入口在 stdin 非终端（EOF）时必须干净退出：helper 终止调用方 + 入口不忙循环、输出有上限" \
        "冻结态 lib/core.sh + 3 个独立脚本（各内置一份 helper）+ lib/ui.sh 菜单入口 + 修复前冻结点的 lib/ 副本" \
        "stdin=/dev/null 下跑 helper 契约与菜单入口（带 timeout 上限）" \
        "helper 读到 EOF 必须终止调用方（哨兵不出现）；菜单入口自己退出、退出码 0、输出有上限；修复前实现复现忙循环"

    # ── 第一层：helper 契约 ──────────────────────────────────
    _t53_helper_contract

    # ── 第二层：入口端到端 ──────────────────────────────────
    local out_new="$SBX_ROOT/t53_new.out"
    local res rc_new bytes_new
    res=$(_t53_run_menu "$SBX_RUN" "$out_new" 10)
    rc_new=$(printf '%s\n' "$res" | sed -n 's/^RC=//p' | head -1)
    bytes_new=$(printf '%s\n' "$res" | sed -n 's/^BYTES=//p' | head -1)
    h_log "当前实现：rc=$rc_new bytes=$bytes_new"

    # 腿①：必须在 timeout 上限内**自己**退出（124 = 被 timeout 杀掉 = 忙循环）
    local killed=否
    [ "$rc_new" = "124" ] && killed=是
    h_check_eq "否" "$killed" "腿①：菜单入口必须在超时上限内自己退出（不能被 timeout 杀掉）"

    # 腿③：干净退出码 0
    h_check_eq "0" "$rc_new" "腿③：读到 EOF 后干净退出（退出码 0）"

    # 腿②：输出量有上限（无界输出会灌满 tmpfs）
    h_check_le "$_T53_BYTE_LIMIT" "$bytes_new" "腿②：输出字节数有上限（无界输出 = 灌满 tmpfs 的元凶）"

    # 防空过护栏 A：输出非空（空输出 = 可能根本没跑起来）
    h_check_ge 40 "$bytes_new" "防空过护栏：输出字节数 ≥ 40（空输出 = 可能根本没跑起来）"

    # 防空过护栏 B：命中入口标志 → 证明真的走到了菜单入口
    #   ★ 入口提示语（ui_require_tty 护栏）或菜单标题**都算** ——
    #     只钉「进过入口 / 或明确拒绝进入」这个**行为**，不钉用哪种机制：
    #     「读到 EOF 干净退出」和「stdin 非终端直接拒绝进菜单」都能满足需求，
    #     把护栏钉成「必须打印入口提示语」会让「另一种同样正确的形态」误红。
    local guard=否
    grep -qaE '终端|terminal|全功能一键脚本' "$out_new" && guard=是
    h_check_eq "是" "$guard" "防空过护栏：输出命中入口标志（入口提示语或菜单标题）→ 证明真的走到了菜单入口"

    # ── 负向对照：真实修复前实现必须复现忙循环 ──────────────
    h_log "准备修复前实现：$_T53_PRE_FIX_SHA 的 lib/"
    if ! _t53_prepare_pre_fix_lib "$_T53_PRE_FIX_SHA"; then
        h_fail "取不到修复前实现 $_T53_PRE_FIX_SHA 的 lib/"
        return
    fi

    # 自检：换进去的确实是旧实现（菜单读入是裸 read、没有入口护栏）
    local old_read=0 old_guard=0
    grep -qF 'read -p "请输入选择' "$_T53_LIBROOT/lib/ui.sh" && old_read=1
    grep -qF 'ui_require_tty' "$_T53_LIBROOT/lib/ui.sh" && old_guard=1
    h_check_eq "1" "$old_read" "负向对照自检：坏副本确实是修复前实现（菜单读入是裸 read）"
    h_check_eq "0" "$old_guard" "负向对照自检：坏副本确实没有入口护栏 ui_require_tty"

    local out_old="$SBX_ROOT/t53_old.out"
    local rc_old bytes_old
    res=$(_t53_run_menu "$_T53_LIBROOT" "$out_old" 5)
    rc_old=$(printf '%s\n' "$res" | sed -n 's/^RC=//p' | head -1)
    bytes_old=$(printf '%s\n' "$res" | sed -n 's/^BYTES=//p' | head -1)
    h_log "修复前实现：rc=$rc_old bytes=$bytes_old"

    # 断言「坏情况确实发生」：被 timeout 杀掉（忙循环）+ 输出膨胀
    h_check_eq "124" "$rc_old" "负向对照：修复前实现的菜单入口被 timeout 杀掉（忙循环复现）"
    h_check_ge "$_T53_BYTE_LIMIT" "$bytes_old" "负向对照：修复前实现的输出超过上限（无界输出复现）"
}
