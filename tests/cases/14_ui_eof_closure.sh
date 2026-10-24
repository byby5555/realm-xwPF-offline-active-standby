# shellcheck shell=bash
#
# T54 · 交互读入 EOF 收口的不变式
#
# ── 背景 ──────────────────────────────────────────────────────────
# N1 真机事故的根因是「菜单读入在 stdin 是 EOF 时不终止调用方」：
#   read 立刻返回非 0 → 变量为空 → case 不匹配 → 回到 while 顶部 →
#   无限重绘 + 忙循环 + 无界输出 → /tmp（tmpfs）被灌满 → 内存+swap 耗尽 →
#   sshd 握不上手，整机被压垮。
# 主路径已由 100976c 修掉（ui_read_into + ui_require_tty），
# 但仓库里还散着一批「看起来没事」的裸读入、没有 sleep 兜底的菜单循环、
# 没有 TERM 保护的 clear —— 只要有人再加一处，这台机器会再次被拖死。
#
# 本用例把「收口后的形态」钉成不变式：
#   【静态 1】UI helper 的**份数**与**逐字一致性**
#     · ui_read_into / ui_pause / ui_read_default / ui_require_tty / ui_clear
#       各 4 份，文件集合恰为 {lib/core.sh, xwFailover.sh,
#       port-traffic-dog.sh, speedtest.sh}
#     · 四份 helper 块**逐字一致**（sha256 相同）
#       ★ 为什么是「4 份一致」而不是「1 份」：那 3 个是**独立安装单元**
#         （用户只下载单个脚本到 /usr/local/bin 就能用），拿不到 lib/，
#         让它们 source core.sh 会毁掉「单文件可运行」这个产品属性。
#         所以「一份实现」只能是「四份逐字一致的拷贝」——
#         **份数与一致性必须被钉死**，任何漂移都要判红。
#   【静态 2】不存在「无 EOF 处理的用户输入读入」
#   【静态 3】每个含输入读入的 while 循环都有 sleep 0.2 兜底
#   【静态 4】不存在裸 clear（必须走 ui_clear）
#   【运行时】ui_read_default 的契约：读到 EOF → 取默认值 + **不终止调用方**
#     （与 ui_read_into 的「EOF 一律干净退出」刻意不同：
#       安装流程 xwPF.sh install 在无人值守下 EOF 是常态，
#       当成错误打断会变成「静默空跑」——退出码 0 但什么都没装）
#   【判定器自检】判定器自己必须有牙齿（见第六节）
#
# ── 负向对照 ──────────────────────────────────────────────────────
#   (a) 静态四层：用**真实修复前实现**（修复前冻结点的产品文件）跑同一套
#       判定器 → 必须抓到违规（断言「坏情况确实发生」）
#   (b) 运行时层：ui_read_default 是本次新引入的，修复前没有等价形态
#       → 注入式退化（如实标注：不是历史实现）
#   (c) 判定器自检：用**合成探针**证明判定器的豁免面没有漏
#       （如实标注：是合成探针，不是历史实现）
#
# ── 防空过护栏 ─────────────────────────────────────────────────────
#   · helper 份数不是「≥ 1」而是「恰为 4 且文件集合精确匹配」
#   · 判定器跑在**冻结态**（$SBX_SRC = git show $BASE_SHA 的 LF 副本）上，
#     不读工作区；tests/ 与 reports/ 按路径排除
#   · 运行时层的判定用**值**（VALUE=[默认]）而不是退出码：
#     helper 坏掉时脚本会继续往下跑、照样 rc=0 → 恒绿
#   · 判定器自检的每个探针**各自独立目录**，避免互相串扰
#
# ── 第 10 轮修订（据审稿 reports/round9-t54-precheck.md 的实测发现）──
#   1) 静态 3 的「含输入读入」判定**独立于静态 2 的豁免面**：
#      原来 `read -n 1 -s` 被静态 2 豁免、静态 3 又不认它 → **两层都不抓**，
#      而 `read -n` 在 EOF 时同样立刻返回非 0 → 变量为空 → 回到循环顶 →
#      正是 N1 的形态。现在静态 3 只要看到循环体里有任何 read 调用就要求
#      sleep 兜底（判定器之间**不能互相放过**）。
#   2) 静态 2 的 `||` 豁免改成**按形态精确匹配**：
#      原来 `grep -vE '\|\|'` 是「含 || 就放过」→ `read ... || true`
#      （什么也没兜）能从两层判据下完整溜过去。现在只放行
#      `|| VAR=""` / `|| VAR=''`（显式兜底）与 `|| exit N`（显式终止）。
#   3) 静态 3 的循环定位从「同缩进的第一个 done」改成 **do/done 词计数配对**
#      （bash 里天然配平，不受缩进与 `done || true` 尾串影响），
#      配对失败**一律报出来**（fail-closed，不允许静默漏掉整个循环）。
#   4) 静态 3 的 sleep 位置从「循环体前 6 行」魔数改成
#      **循环体内任意位置**（魔数会被「sleep 挪到第 7 行」误报）。
#
# 修复前冻结点（本次「交互读入 EOF 收口」之前的最后一个提交）
_T54_PRE_FIX_SHA="a359301"

# 含 UI helper 的 4 个文件
_T54_HELPER_HOSTS="lib/core.sh xwFailover.sh port-traffic-dog.sh speedtest.sh"

# 被钉住份数的 5 个 helper
_T54_HELPERS="ui_read_into ui_pause ui_read_default ui_require_tty ui_clear"

# ── 判定器 1：抽 UI helper 块（从块标记到 ui_clear 的收尾 }）────────
_t54_extract_block() {
    [ -f "$1" ] || return 0
    awk '
        /^# === 交互菜单读入：stdin EOF 安全/ {ins=1}
        ins {print}
        ins && /^ui_clear\(\) \{/ {c=1}
        c && /^\}$/ {exit}
    ' "$1"
}

# ── 判定器 2：整棵树里某 helper 的定义文件（相对路径，空格分隔，已排序）──
_t54_helper_files() {
    local root="$1" fn="$2"
    grep -rl --include='*.sh' "^${fn}() {" "$root" 2>/dev/null \
        | grep -v '/tests/' | grep -v '/reports/' \
        | sed "s|^${root}/||" | sort | tr '\n' ' '
}

# ── 判定器 3：「无 EOF 处理的用户输入读入」──────────────────────────
#   允许的形态（逐条列举，不靠模糊匹配）：
#     · helper 内部：read -r -p "$__prompt" / read -p "$1"
#     · 显式兜底：read ... || VAR=""（含 read -rt 超时形态）
#     · 显式终止：read ... || exit N
#     · 单键读：read -n 1 -s（无提示）—— ★ 循环内由静态 3 单独兜住
#     · 管道读：while read / IFS= read
#   ★ 豁免是「按形态精确匹配」，不是「含 || 就放过」：
#     `read ... || true` 什么也没兜 → 必须报出来。
_t54_bare_reads() {
    local root="$1"
    {
        grep -rn --include='*.sh' -E '(^|[;&|(){}[:space:]])read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-p[[:space:]]' "$root" 2>/dev/null
        grep -rn --include='*.sh' -E '^[[:space:]]*read[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*$' "$root" 2>/dev/null
    } | grep -v '/tests/' | grep -v '/reports/' \
      | grep -vE 'read -r -p "\$__prompt"' \
      | grep -vE 'read -p "\$1"' \
      | grep -vE 'read -n ' \
      | grep -vE "\|\|[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*['\"]['\"]" \
      | grep -vE '\|\|[[:space:]]*exit[[:space:]]+[0-9]' \
      | sort
}

# ── 判定器 4：裸 clear ────────────────────────────────────────────
_t54_bare_clear() {
    local root="$1"
    grep -rn --include='*.sh' -E '^[[:space:]]*clear[[:space:]]*$' "$root" 2>/dev/null \
        | grep -v '/tests/' | grep -v '/reports/' | sort
}

# ── 判定器 5：含输入读入、但循环体没有 sleep 0.2 的 while 循环 ──
#   ★ 与静态 3（判定器 3）**独立**：
#     「含输入读入」的判定只看「循环体里有没有 read 调用」，
#     不看静态 2 的豁免面 —— 两层判据不能互相放过。
#   ★ 循环定位用 do/done **词计数配对**（bash 里天然配平）：
#     不受缩进差异、`done || true` 尾串影响；
#     配对失败（找不到配对的 done）→ **一律报出来**（fail-closed）。
#   ★ sleep 位置：**循环体内任意位置**即可（不用「前 6 行」魔数）。
_t54_loops_without_sleep() {
    local root="$1" f rel
    for f in $(find "$root" -name '*.sh' -type f 2>/dev/null | grep -v '/tests/' | grep -v '/reports/' | sort); do
        rel="${f#$root/}"
        awk -v REL="$rel" '
        function strip_comment(l,   t) {
            t = l
            sub(/[ \t]+#.*/, "", t)
            return t
        }
        function tok(s, w,   t, n, arr, i, c) {
            t = s
            gsub(/[^A-Za-z0-9_]/, " ", t)
            n = split(t, arr, /[ \t]+/)
            c = 0
            for (i = 1; i <= n; i++) if (arr[i] == w) c++
            return c
        }
        # 「read 在命令位置」判定：read 前一个词必须是分隔符或控制关键字，
        # 否则那是别的命令的参数（如 `grep read file`）→ 不算输入读入。
        function is_read_call(l,   s, tmp, last) {
            s = l
            sub(/^[ \t]+/, "", s)
            if (s ~ /^#/) return 0
            while (match(s, /(^|[^A-Za-z0-9_])read[ \t]/)) {
                tmp = substr(s, 1, RSTART - 1)
                sub(/[ \t]+$/, "", tmp)
                if (tmp == "") return 1
                last = tmp
                if (sub(/^.*[^A-Za-z0-9_]/, "", last) == 0) last = tmp
                if (last ~ /^(if|then|elif|else|do|while|until|!|time|command|IFS|;|&&|\|\||\||&|\(|\{)$/) return 1
                s = substr(s, RSTART + RLENGTH)
            }
            return 0
        }
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                ci = strip_comment(line[i])
                if (tok(ci, "while") == 0) continue
                if (tok(ci, "true") == 0) continue
                if (tok(ci, "do") == 0) continue
                depth = tok(ci, "do") - tok(ci, "done")
                end = 0
                for (j = i + 1; j <= NR; j++) {
                    cj = strip_comment(line[j])
                    depth += tok(cj, "do") - tok(cj, "done")
                    if (depth <= 0) { end = j; break }
                }
                if (end == 0) { printf "%s:%d\n", REL, i; continue }
                hasin = 0
                for (k = i + 1; k < end; k++) if (is_read_call(line[k])) { hasin = 1; break }
                if (!hasin) continue
                hasslp = 0
                for (k = i + 1; k <= end; k++) {
                    c = strip_comment(line[k])
                    if (c ~ /sleep[[:space:]]+0\.2/) { hasslp = 1; break }
                }
                if (!hasslp) printf "%s:%d\n", REL, i
            }
        }
        ' "$f"
    done
}

# ── 判定器 7：ui_read_default 的调用点**是否传了非空默认值** ─────────
#   ★ 为什么钉这条（据审稿 reports/round9-n1-menu-eof-verification.md 的提醒）：
#     ui_read_default 在 EOF 时**不退出**，而是取默认值并返回 1。
#     若某个调用点传了非空默认值（例如 "y"），EOF 就会从
#     「取默认（否）」变成「**自动确认**」—— 无人值守场景下等于替用户
#     做了决定。当前全部调用点都只传 2 个参数（提示语 + 变量名），
#     这条不变式把它钉死，防止将来有人顺手加了第三个参数。
_t54_default_with_nonempty_default() {
    local root="$1"
    {
        # 第三个参数是**非空字符串**
        grep -rn --include='*.sh' -E 'ui_read_default[[:space:]]+"[^"]*"[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+"[^"]+"' "$root" 2>/dev/null
        # 第三个参数是**未加引号的变量/字面量**
        grep -rn --include='*.sh' -E 'ui_read_default[[:space:]]+"[^"]*"[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+[^[:space:]";&|)]' "$root" 2>/dev/null
    } | grep -v '/tests/' | grep -v '/reports/' \
      | grep -vE ':[[:space:]]*#' \
      | sort -u
}

# ── 判定器 6：ui_read_default 的实现（单独抽，便于退化）──────────
_t54_extract_default() {
    awk '
        /^ui_read_default\(\) *\{/ {inside=1}
        inside {print}
        inside && /^\} *$/ {exit}
    ' "$1"
}

# 退化副本：把「读到 EOF 就取默认值」的兜底去掉
_t54_degrade_default() {
    awk '
        /^ui_read_default\(\) *\{/ {inside=1}
        inside {
            if ($0 ~ /^ *if ! read .*; then *$/) { print "    read -r -p \"$__prompt\" __val || true"; next }
            if ($0 ~ /^ *printf -v "\$__name" .*__default/) { next }
            if ($0 ~ /^ *return 1 *$/) { next }
            if ($0 ~ /^ *fi *$/) { next }
            if ($0 ~ /^ *#/) { next }
            print
        }
        inside && /^\} *$/ {exit}
    ' "$1"
}

# 跑一次 ui_read_default 契约：EOF 下必须「取默认值 + 不终止调用方」
_t54_run_default() {
    local helper="$1" out="$2"
    timeout 10 bash -c '
        source "$1"
        ui_read_default "T54-PROMPT" __t54_v "T54DEFAULT"
        echo "AFTER-CALLBACK-SENTINEL"
        echo "VALUE=[$__t54_v]"
    ' _ "$helper" </dev/null >"$out" 2>&1 || true
}

# ── 负向对照素材：真实修复前实现的产品文件树 ──────────────────────
_t54_prepare_pre_fix_tree() {
    local sha="$1" dest="$2" f rel
    rm -rf "$dest" 2>/dev/null
    mkdir -p "$dest" 2>/dev/null || return 1
    for f in $(cd "$SBX_REPO" && git ls-tree -r --name-only "$sha" 2>/dev/null); do
        case "$f" in
            lib/*.sh|notifications/*.sh|port-traffic-dog.sh|speedtest.sh|xwFailover.sh|xw_realm_OCR.sh) ;;
            *) continue ;;
        esac
        rel="$f"
        mkdir -p "$dest/$(dirname "$rel")" 2>/dev/null
        (cd "$SBX_REPO" && git show "$sha:$rel" 2>/dev/null) > "$dest/$rel" || return 1
    done
    [ -f "$dest/lib/core.sh" ] || return 1
    return 0
}

# ── 判定器自检素材：合成探针（各自独立目录）──────────────────────
#   ★ 如实标注：**合成探针，不是历史实现**。
#     它的作用是证明「判定器自己有牙齿」——判定器的豁免面/定位逻辑
#     本身就是需要被负向对照覆盖的对象。
_t54_make_probe() {
    local dir="$1" name="$2" body="$3"
    mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s\n' "$body" > "$dir/probe.sh" 2>/dev/null || return 1
    return 0
}

_t54_count() {
    printf '%s' "$1" | grep -c . || true
}

case_T54_ui_eof_closure_invariants() {
    h_case_begin "T54" "交互读入 EOF 收口的不变式：helper 份数与逐字一致 / 无裸读入 / 循环 sleep 兜底 / clear 保护 / ui_read_default 的 EOF 契约 / 判定器自检" \
        "冻结态 $BASE_SHA 的产品文件（$SBX_SRC）+ 修复前冻结点 $_T54_PRE_FIX_SHA 的产品文件树（负向对照）+ 合成探针（判定器自检）" \
        "静态四层判定器 + ui_read_default 运行时契约（哨兵 + 值）+ 判定器自检" \
        "helper 各 4 份且四份逐字一致；无裸读入；含输入读入的 while 循环都有 sleep 0.2；无裸 clear；EOF 时 ui_read_default 取默认值且不终止调用方；修复前实现跑同一套判定器必须抓到违规；判定器自检必须证明豁免面没有漏"

    # ══ 第一层 · helper 份数与逐字一致性 ══════════════════════════
    local fn files expect_files cnt h
    expect_files=$(printf '%s\n' $_T54_HELPER_HOSTS | sort | tr '\n' ' ')
    for fn in $_T54_HELPERS; do
        files=$(_t54_helper_files "$SBX_SRC" "$fn")
        cnt=$(printf '%s' "$files" | wc -w | tr -d ' ')
        h_check_eq "4" "$cnt" "helper $fn 的实现份数（lib/core.sh + 3 个独立脚本各带一份）"
        h_check_eq "$expect_files" "$files" "helper $fn 的实现文件集合必须精确等于 4 个宿主"
    done

    local sha_first="" sha_cur="" rel
    for rel in $_T54_HELPER_HOSTS; do
        sha_cur=$(_t54_extract_block "$SBX_SRC/$rel" | sha256sum | cut -d' ' -f1)
        if [ -z "$sha_first" ]; then
            sha_first="$sha_cur"
        else
            h_check_eq "$sha_first" "$sha_cur" "helper 块逐字一致：$rel 与第一份的 sha256 相同"
        fi
    done
    # 防空过护栏：抽出来的块非空（抽不到东西时 sha256 会全体相同 → 恒绿）
    local blk_bytes=0
    blk_bytes=$(_t54_extract_block "$SBX_SRC/lib/core.sh" | wc -c | tr -d ' ')
    h_check_ge 500 "$blk_bytes" "防空过护栏：抽出的 helper 块非空（抽不到东西会让一致性断言恒绿）"

    # ══ 第二层 · 无「无 EOF 处理的用户输入读入」 ══════════════════
    local bare
    bare=$(_t54_bare_reads "$SBX_SRC")
    h_check_eq "0" "$(_t54_count "$bare")" "无 EOF 处理的用户输入读入（裸 read / 裸 read -p）条数"
    if [ -n "$bare" ]; then
        while IFS= read -r l; do
            [ -z "$l" ] && continue
            h_log "  违规: ${l#$SBX_SRC/}"
        done <<< "$bare"
    fi

    # ══ 第三层 · 含输入读入的 while 循环都要有 sleep 0.2 ══════════
    local nosleep
    nosleep=$(_t54_loops_without_sleep "$SBX_SRC")
    h_check_eq "0" "$(_t54_count "$nosleep")" "含输入读入却没有 sleep 0.2 兜底的 while 循环数"
    if [ -n "$nosleep" ]; then
        while IFS= read -r l; do
            [ -z "$l" ] && continue
            h_log "  缺兜底: $l"
        done <<< "$nosleep"
    fi

    # ══ 第四层 · 无裸 clear ══════════════════════════════════════
    local bareclear
    bareclear=$(_t54_bare_clear "$SBX_SRC")
    h_check_eq "0" "$(_t54_count "$bareclear")" "裸 clear（未走 ui_clear）条数"

    # ══ 第五层 · ui_read_default 的 EOF 契约 ═════════════════════
    local hdir="$SBX_ROOT/t54"
    mkdir -p "$hdir"
    local hfile="$hdir/ui_read_default.sh"
    local dfile="$hdir/ui_read_default.degraded.sh"
    _t54_extract_default "$SBX_SRC/lib/core.sh" > "$hfile"
    _t54_degrade_default "$SBX_SRC/lib/core.sh" > "$dfile"

    # 防空过护栏：抽出来的实现非空 + 含函数头
    local dbytes=0
    dbytes=$(wc -c < "$hfile" 2>/dev/null | tr -d ' ')
    [ -z "$dbytes" ] && dbytes=0
    h_check_ge 60 "$dbytes" "防空过护栏：抽出的 ui_read_default 非空"
    h_check_file_has "$hfile" "ui_read_default()" "防空过护栏：抽出的实现含函数定义"

    # 正向：EOF → 取默认值 + 不终止调用方
    local out_ok="$hdir/ok.out"
    _t54_run_default "$hfile" "$out_ok"
    local txt_ok
    txt_ok=$(cat "$out_ok" 2>/dev/null)
    h_log "当前实现输出: $(printf '%s' "$txt_ok" | tr '\n' ' ' | cut -c1-200)"
    h_check_contains "$txt_ok" "AFTER-CALLBACK-SENTINEL" "读到 EOF 时 ui_read_default **不终止调用方**（哨兵出现）"
    h_check_contains "$txt_ok" "VALUE=[T54DEFAULT]" "读到 EOF 时 ui_read_default 取默认值（不是空串）"

    # 负向对照（注入式退化）：兜底去掉 → 默认值丢失（坏情况确实发生）
    local deg_pattern="printf -v \"\$__name\" '%s' \"\$__default\""
    local deg_ok=否
    grep -qF "$deg_pattern" "$dfile" && deg_ok=是
    h_check_eq "否" "$deg_ok" "负向对照自检 · 退化副本确实去掉了「取默认值」的兜底（破坏手法生效）"

    local out_bad="$hdir/bad.out"
    _t54_run_default "$dfile" "$out_bad"
    local txt_bad
    txt_bad=$(cat "$out_bad" 2>/dev/null)
    h_log "退化副本输出: $(printf '%s' "$txt_bad" | tr '\n' ' ' | cut -c1-200)"
    h_check_not_contains "$txt_bad" "VALUE=[T54DEFAULT]" "负向对照 · 兜底去掉后 EOF 不再取默认值（坏情况确实发生）"

    # ── 第五层附：调用点不得传非空默认值（否则 EOF = 自动确认）────────
    local nonempty_def
    nonempty_def=$(_t54_default_with_nonempty_default "$SBX_SRC")
    h_check_eq "0" "$(_t54_count "$nonempty_def")" "ui_read_default 的调用点传了非空默认值的条数（传了就等于 EOF 自动确认）"
    if [ -n "$nonempty_def" ]; then
        while IFS= read -r l; do
            [ -z "$l" ] && continue
            h_log "  违规: ${l#$SBX_SRC/}"
        done <<< "$nonempty_def"
    fi

    # ══ 负向对照 (a) · 真实修复前实现跑同一套判定器 → 必须抓到违规 ══
    h_log "准备修复前实现: $_T54_PRE_FIX_SHA 的产品文件树"
    local pre_tree="$SBX_ROOT/t54_pre_fix"
    if ! _t54_prepare_pre_fix_tree "$_T54_PRE_FIX_SHA" "$pre_tree"; then
        h_fail "取不到修复前实现 $_T54_PRE_FIX_SHA 的产品文件树（该 sha 在本克隆里不可达？）"
        return
    fi

    # 自检：换进来的确实是修复前形态（ui_read_default / ui_clear 还不存在）
    local pre_default=0 pre_clear=0
    grep -rqF 'ui_read_default() {' "$pre_tree" 2>/dev/null && pre_default=1
    grep -rqF 'ui_clear() {' "$pre_tree" 2>/dev/null && pre_clear=1
    h_check_eq "0" "$pre_default" "负向对照自检 · 修复前实现里确实还没有 ui_read_default"
    h_check_eq "0" "$pre_clear" "负向对照自检 · 修复前实现里确实还没有 ui_clear"

    local pre_bare pre_clear_hits pre_nosleep
    pre_bare=$(_t54_bare_reads "$pre_tree")
    pre_clear_hits=$(_t54_bare_clear "$pre_tree")
    pre_nosleep=$(_t54_loops_without_sleep "$pre_tree")
    h_log "修复前实现：裸读入 $(_t54_count "$pre_bare") 处 / 裸 clear $(_t54_count "$pre_clear_hits") 处 / 缺 sleep 兜底 $(_t54_count "$pre_nosleep") 处"

    h_check_ge 1 "$(_t54_count "$pre_bare")" "负向对照 · 修复前实现存在「无 EOF 处理的用户输入读入」（坏情况确实发生）"
    h_check_ge 1 "$(_t54_count "$pre_clear_hits")" "负向对照 · 修复前实现存在裸 clear（坏情况确实发生）"
    h_check_ge 1 "$(_t54_count "$pre_nosleep")" "负向对照 · 修复前实现存在没有 sleep 兜底的输入循环（坏情况确实发生）"

    # helper 份数：修复前 ui_read_default / ui_clear 一份都没有 → 份数断言会红
    local pre_files pre_cnt
    pre_files=$(_t54_helper_files "$pre_tree" "ui_read_default")
    pre_cnt=$(printf '%s' "$pre_files" | wc -w | tr -d ' ')
    h_check_eq "0" "$pre_cnt" "负向对照 · 修复前实现里 ui_read_default 的份数为 0（份数不变式在修复前会红）"

    # ══ 第六层 · 判定器自检（合成探针）══════════════════════════
    #   判定器的豁免面与定位逻辑**本身就是需要被覆盖的对象**：
    #   判定器自己漏了，断言就会恒绿 —— 所以用合成探针把「判定器抓得到」
    #   这件事本身钉死。
    h_log "判定器自检：合成探针（不是历史实现）"
    local pdir="$SBX_ROOT/t54_probe"
    rm -rf "$pdir" 2>/dev/null
    mkdir -p "$pdir" 2>/dev/null

    # 探针 1：read -n 单键读在 while true 里 → 静态 3 必须抓到
    #   （旧判定器：静态 2 豁免 read -n、静态 3 又不认 read -n → 两层都不抓）
    local p1="$pdir/p1_read_n_in_loop"
    _t54_make_probe "$p1" p1 'while true; do
    read -n 1 -s x
    echo "$x"
done'
    local p1_hit
    p1_hit=$(_t54_loops_without_sleep "$p1")
    h_log "探针 1（read -n 在 while true 里）→ 静态 3 抓到 $(_t54_count "$p1_hit") 处"
    h_check_ge 1 "$(_t54_count "$p1_hit")" "判定器自检 · 静态 3 必须抓到「循环内 read -n 单键读」（组合盲区已闭合）"

    # 探针 2：合规形态（sleep 兜底 + read -p）→ 静态 3 必须不报
    local p2="$pdir/p2_sleep_ok"
    _t54_make_probe "$p2" p2 'while true; do
    sleep 0.2
    read -p "继续?" x
    echo "$x"
done'
    local p2_hit
    p2_hit=$(_t54_loops_without_sleep "$p2")
    h_check_eq "0" "$(_t54_count "$p2_hit")" "判定器自检 · 静态 3 对「sleep 0.2 兜底 + read」不得误报"

    # 探针 3：read ... || true（什么也没兜）→ 静态 2 必须抓到
    local p3="$pdir/p3_or_true"
    _t54_make_probe "$p3" p3 'read -p "继续?" x || true
echo "$x"'
    local p3_hit
    p3_hit=$(_t54_bare_reads "$p3")
    h_log "探针 3（read ... || true）→ 静态 2 抓到 $(_t54_count "$p3_hit") 处"
    h_check_ge 1 "$(_t54_count "$p3_hit")" "判定器自检 · 静态 2 必须抓到「read ... || true」（|| 豁免面已收紧）"

    # 探针 4：read ... || VAR=""（显式兜底）→ 静态 2 必须放行
    local p4="$pdir/p4_or_var_empty"
    _t54_make_probe "$p4" p4 'read -p "继续?" x || x=""
echo "$x"'
    local p4_hit
    p4_hit=$(_t54_bare_reads "$p4")
    h_check_eq "0" "$(_t54_count "$p4_hit")" "判定器自检 · 静态 2 必须放行「read ... || VAR=\"\"」（显式兜底）"

    # 探针 5：done 带尾串（done || true）→ 循环定位不得失效
    local p5="$pdir/p5_done_with_tail"
    _t54_make_probe "$p5" p5 'while true; do
    sleep 0.2
    read -p "继续?" x || true
done || true'
    local p5_hit
    p5_hit=$(_t54_loops_without_sleep "$p5")
    h_check_eq "0" "$(_t54_count "$p5_hit")" "判定器自检 · 静态 3 对「done || true」不得把整个循环漏掉"

    # 探针 6：read 是别的命令的参数（grep read file）→ 不得当成输入读入
    local p6="$pdir/p6_read_as_argument"
    _t54_make_probe "$p6" p6 'while true; do
    sleep 0.2
    grep read /etc/passwd
done'
    local p6_hit
    p6_hit=$(_t54_loops_without_sleep "$p6")
    h_check_eq "0" "$(_t54_count "$p6_hit")" "判定器自检 · 静态 3 不得把「read 作为别的命令的参数」当成输入读入"
}
