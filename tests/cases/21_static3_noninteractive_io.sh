# shellcheck shell=bash
#
# T89~T92 · 静态 3（所有 while/until 循环里的输入读入必须 EOF 收口 + sleep 兜底）
#
# ── 背景（为什么做这个）────────────────────────────────────────────
# T54（cases/14_ui_eof_closure.sh）钉了「交互读入 EOF 收口」的不变式，
# 里面有「静态 2 / 静态 3」两层判据：
#   静态 2 = 不存在「无 EOF 处理的用户输入读入」（仓库级、逐行形态匹配）
#   静态 3 = 每个含输入读入的 while 循环都要有 sleep 0.2 兜底（循环级）
#
# 现行静态 3 判定器（_t54_loops_without_sleep）有两个硬伤：
#   ① **只扫 `while true`**：判定器里有一行 `tok(ci,"true")==0 → continue`，
#      于是 `while IFS= read -r line; do ... done` 这类循环**根本进不来**。
#   ② **「含输入读入」的判定被模糊匹配放宽过**（`grep -vE '\|\|'` 之类），
#      既可能漏判也可能误放。
#
# 产品侧已在 16 处「输入来自文件/管道/字符串、不是用户输入」的 while 循环**头行**
# 加上显式标记注释 `xwpf:noninteractive-io`（提交 ea56296），
# 这正是「把判定器放宽到所有 while/until 循环」的前提。
#
# ── 豁免契约（fail-closed，三条，别用「看起来像」放宽）──────────────
#   1) read 行带 `<<<`（herestring）⇒ 非交互，语法上确定，无需标记
#   2) read 行带 `<`（文件重定向）⇒ 非交互，无需标记
#   3) 其它 read（从循环 stdin 读）⇒ **默认按交互读处理**；
#      只有「该 read 所在行」**或**「它所属循环的**头行**」带
#      `xwpf:noninteractive-io` 才豁免
#   ⇒ 没标记 = 按交互读 = 该 while/until 循环必须有 **sleep 兜底 + EOF 收口**。
#
# ── 四条用例 ────────────────────────────────────────────────────────
#   T89  静态 3 主判据：扫**所有** while/until 循环（不再只扫 while true）
#   T90  静态 3 ⊋ 静态 2（静态 2 抓到的形态静态 3 也抓到，且严格更大）
#   T91  判定器自检 · 探针 A：无标记的 while read + 无 sleep → 必须被抓
#   T92  判定器自检 · 探针 B：带 xwpf:noninteractive-io 标记 → 必须不报
#
# ── 判定器设计（与 T54 的关系）────────────────────────────────────
#   · 沿用 T54 的形状（awk + do/done 词计数配对 + strip_comment/tok/is_read_call），
#     但**去掉** `tok(ci,"true")==0 → continue`（这是「放宽到所有 while/until」的关键）
#   · is_read_call 扩展：支持 `IFS= read` / `IFS='|' read` 这种**赋值前缀**形态
#     （T54 原版识别不了 `IFS= read` → 产品里 16 处标记循环的读入**根本看不见**
#      → 判定器会变成假绿。本文件已修，并用「标记行数 ≤ 被标记豁免的读入数」钉住）
#   · 读入归属：**最内层**循环（嵌套循环里，外层的标记不豁免内层的读入）
#   · sleep 兜底：**循环体内任意位置**的 sleep 命令（不钉死 0.2 这个字面量）
#   · EOF 收口：与静态 2 的兜底面同形（`|| VAR=""` / `|| exit N`）
#
# ── 负向对照 ────────────────────────────────────────────────────────
#   · 主负向对照用**真实旧实现**（`git show <sha>:<path>` 取的修复前冻结点 a359301）
#   · 「制造坏情况」的自检用**合成探针 / 注入式退化**（如实标注：不是历史旧实现）
#
# ── 防空过护栏 ──────────────────────────────────────────────────────
#   · 判定器跑在**冻结态**（$SBX_SRC = git show $BASE_SHA 的 LF 副本）上，不读工作区
#   · 每条「断言 X 没发生」都配一条「制造 X 发生了 → 判定器必须判红」的自检
#   · 探针各自独立目录，避免互相串扰
#
# ── 已知边界（如实标注，不藏）──────────────────────────────────────
#   静态 2 的判定器是**逐行形态匹配**，它对 herestring / 文件重定向 / 带标记的读入
#   也会命中（它不区分输入来源）——那是**过度近似**。静态 3 按契约把这类形态判为
#   「非交互」→ 两层在这类形态上的差异是**契约要求的**，不是盲区。
#   本文件用「差异必须能被非交互类完全解释」这条断言把边界钉死（T90）。

# ── 判定器 1：静态 3 记录（唯一真源，所有断言都从它出）────────────
#   记录格式（竖线分隔，便于 grep 过滤）：
#     F|<rel>|<line>|eof      读入缺 EOF 收口（违规）
#     F|<rel>|<line>|sleep    循环缺 sleep 兜底（违规）
#     I|<rel>|<line>|read     检测到的读入（含被豁免的）
#     I|<rel>|<line>|marker   因 xwpf:noninteractive-io 标记而豁免的读入
#     I|<rel>|<line>|loop     检测到的 while/until 循环头
_t89_awk_prog_file() {
    local out="$SBX_ROOT/t89_static3.awk"
    [ -n "$SBX_ROOT" ] || return 1
    if [ ! -f "$out" ]; then
        mkdir -p "$SBX_ROOT" 2>/dev/null || return 1
        cat > "$out" <<'AWKEOF'
function strip_comment(l,   t) { t = l; sub(/[ \t]+#.*/, "", t); return t }
function tok(s, w,   t, n, arr, i, c) {
    t = s; gsub(/[^A-Za-z0-9_]/, " ", t); n = split(t, arr, /[ \t]+/); c = 0
    for (i = 1; i <= n; i++) if (arr[i] == w) c++
    return c
}
# 剥掉尾部的一个或多个「赋值前缀」（IFS= / IFS="," / IFS="|" ...）：
# 值里允许 | , ' " 等字符（IFS='|' 这种必须认出来，否则产品里那 16 处
# 标记循环的读入根本不被识别 → 判定器假绿）
function strip_assign(t,   rest, lastpos, lastlen, val, off) {
    while (1) {
        if (!match(t, /[A-Za-z_][A-Za-z0-9_]*=/)) break
        # 找**最后一个**赋值前缀（位置换算成相对 t 的绝对偏移）
        rest = t; lastpos = 0; lastlen = 0; off = 0
        while (match(rest, /[A-Za-z_][A-Za-z0-9_]*=/)) {
            lastpos = off + RSTART
            lastlen = RLENGTH
            off = off + RSTART + RLENGTH
            rest = substr(rest, RSTART + RLENGTH)
        }
        val = substr(t, lastpos + lastlen)
        if (val ~ /[;&]/) break
        t = substr(t, 1, lastpos - 1)
        sub(/[ \t]+$/, "", t)
    }
    return t
}
# 「命令位置」判定：before 是 read / while 之前的文本
#   ★ 必须**先**去掉尾随空白：before 常常整段都是空格（例如行首缩进），
#     不去掉的话「行首的 read/while」会被误判成「不是命令位置」
#     → 循环头识别不到 → 判定器漏看循环 → 0 违规的假绿（实测踩过）。
function cmd_pos(before,   t) {
    t = before
    sub(/[ \t]+$/, "", t)
    if (t == "") return 1
    t = strip_assign(t)
    if (t == "") return 1
    if (t ~ /(^|[^A-Za-z0-9_])(if|then|elif|else|do|while|until|!|time|command)[[:space:]]*$/) return 1
    if (t ~ /[;&|(){}&]$/) return 1
    return 0
}
# read 在命令位置才是「输入读入」（grep read file 之类是别的命令的参数 → 不算）
#
# ★★ awk 陷阱（踩过，代价是一轮 5 分钟超时）★★
#   RSTART / RLENGTH 是 awk 的**全局**变量：任何一次 match / sub / gsub / `~` 都会改写它们。
#   本函数在 match 之后会调用 cmd_pos → strip_assign（内部还有 match/sub），
#   若直接用 RSTART/RLENGTH 切片，`substr(s, RSTART+RLENGTH)` 会拿到**被改写后**的值
#   → 切片不前进 → **死循环**（判定器会把整棵树跑挂）。
#   ⇒ 必须在 match 之后**立刻**把位置取到局部变量，再用局部变量切片。
#   （T54 的 _t54_loops_without_sleep 的 is_read_call 也有同样的隐患，
#     它在 match 与 substr 之间调了 sub()；本文件不改动 T54，只在这里规避。）
function is_read_call(l,   s, before, mp, ml) {
    s = l; sub(/^[ \t]+/, "", s)
    if (s ~ /^#/) return 0
    while (match(s, /read[ \t]/)) {
        mp = RSTART; ml = RLENGTH
        before = substr(s, 1, mp - 1)
        if (before !~ /[A-Za-z0-9_]$/) { if (cmd_pos(before)) return 1 }
        s = substr(s, mp + ml)
    }
    return 0
}
function is_loop_kw(l, kw,   s, before, mp, ml) {
    s = l
    while (match(s, kw "[ \t]")) {
        mp = RSTART; ml = RLENGTH
        before = substr(s, 1, mp - 1)
        if (before !~ /[A-Za-z0-9_]$/) { if (cmd_pos(before)) return 1 }
        s = substr(s, mp + ml)
    }
    return 0
}
function has_marker(l) { return (l ~ /xwpf:noninteractive-io/) }
function is_herestring(l) { return (l ~ /<<</) }
function is_redirect(l) { return (l ~ /</) }
# EOF 收口：与静态 2 的兜底面同形（显式置空 / 显式终止）
function eof_closed(l) {
    if (l ~ /\|\|[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*["']["']/) return 1
    if (l ~ /\|\|[[:space:]]*exit[[:space:]]+[0-9]/) return 1
    return 0
}
# sleep 兜底：循环体内任意位置的 sleep 命令（不钉死时长字面量）
function has_sleep(l) { return (l ~ /(^|[;&|(){}[:space:]])sleep[[:space:]]/) }
{ line[NR] = $0 }
END {
    nloop = 0
    for (i = 1; i <= NR; i++) {
        ci = strip_comment(line[i])
        if (!is_loop_kw(ci, "while") && !is_loop_kw(ci, "until")) continue
        if (tok(ci, "do") == 0) continue
        depth = tok(ci, "do") - tok(ci, "done")
        end = 0
        for (j = i + 1; j <= NR; j++) {
            cj = strip_comment(line[j])
            depth += tok(cj, "do") - tok(cj, "done")
            if (depth <= 0) { end = j; break }
        }
        nloop++
        hd[nloop] = i; en[nloop] = end
        printf "I|%s|%d|loop\n", REL, i
    }
    # 父循环：覆盖 head[L] 且 head 最大的那个
    for (a = 1; a <= nloop; a++) {
        par[a] = 0
        for (b = 1; b <= nloop; b++) {
            if (b == a) continue
            if (hd[b] < hd[a] && en[b] >= hd[a]) {
                if (par[a] == 0 || hd[b] > hd[par[a]]) par[a] = b
            }
        }
    }
    # 逐行找读入，归属到**最内层**循环
    for (r = 1; r <= NR; r++) {
        if (!is_read_call(line[r])) continue
        printf "I|%s|%d|read\n", REL, r
        owner = 0
        for (a = 1; a <= nloop; a++) {
            if (hd[a] <= r && r <= en[a]) {
                if (owner == 0 || hd[a] > hd[owner]) owner = a
            }
        }
        rl = line[r]
        # 豁免契约 1/2：herestring / 文件重定向 → 语法上确定的非交互
        if (is_herestring(rl)) continue
        if (is_redirect(rl)) continue
        # 豁免契约 3：read 所在行带标记
        if (has_marker(rl)) { printf "I|%s|%d|marker\n", REL, r; continue }
        # 循环外的读入：静态 2 独家覆盖（静态 3 按契约只管循环）
        if (owner == 0) continue
        # 豁免契约 3：所属循环的头行带标记
        if (has_marker(line[hd[owner]])) { printf "I|%s|%d|marker\n", REL, r; continue }
        # 没标记 = 按交互读 = 必须 EOF 收口
        if (!eof_closed(rl)) printf "F|%s|%d|eof\n", REL, r
    }
    # sleep 兜底：每个循环只报一次
    for (a = 1; a <= nloop; a++) {
        need = 0
        for (r = hd[a] + 1; r < en[a]; r++) {
            if (!is_read_call(line[r])) continue
            rl = line[r]
            if (is_herestring(rl)) continue
            if (is_redirect(rl)) continue
            if (has_marker(rl)) continue
            if (has_marker(line[hd[a]])) continue
            inner = 0
            for (b = 1; b <= nloop; b++) {
                if (b == a) continue
                if (par[b] == a && hd[b] <= r && r <= en[b]) { inner = 1; break }
            }
            if (inner) continue
            need = 1
            break
        }
        if (!need) continue
        slp = 0
        for (r = hd[a] + 1; r < en[a]; r++) {
            if (has_sleep(strip_comment(line[r]))) { slp = 1; break }
        }
        if (!slp) printf "F|%s|%d|sleep\n", REL, hd[a]
    }
}
AWKEOF
    fi
    printf '%s' "$out"
}

# 跑一遍判定器，输出记录
_t89_records() {
    local root="$1" f rel prog
    [ -d "$root" ] || return 0
    prog=$(_t89_awk_prog_file) || return 0
    [ -f "$prog" ] || return 0
    for f in $(find "$root" -name '*.sh' -type f 2>/dev/null | grep -v '/tests/' | grep -v '/reports/' | sort); do
        rel="${f#$root/}"
        awk -v REL="$rel" -f "$prog" "$f" 2>/dev/null
    done
    return 0
}

# 违规记录（eof / sleep）
_t89_findings() { _t89_records "$1" | grep '^F|' || true; }
# 静态 3 在「读入行」上抓到的集合（rel:line，与静态 2 的命中格式对齐）
_t89_eof_lines() { _t89_records "$1" | grep '^F|.*|eof$' | cut -d'|' -f2,3 | tr '|' ':' | sort -u || true; }
_t89_count() { local n; n=$(grep -c . 2>/dev/null); [ -z "$n" ] && n=0; printf '%s' "$n"; }
_t89_findings_count() { _t89_findings "$1" | _t89_count; }
_t89_eof_count() { _t89_eof_lines "$1" | _t89_count; }
_t89_marker_count() { _t89_records "$1" | grep '^I|.*|marker$' | _t89_count; }
_t89_read_count() { _t89_records "$1" | grep '^I|.*|read$' | _t89_count; }
_t89_loop_count() { _t89_records "$1" | grep '^I|.*|loop$' | _t89_count; }

# 静态 2（真实现：T54 的判定器）→ rel:line:content
#   ★ 存在性断言在用例里做；这里找不到函数时返回空（不静默假装跑过）
_t89_static2_hits() {
    local root="$1" out
    declare -F _t54_bare_reads >/dev/null 2>&1 || return 0
    # ★ 不要写成 `out=$(...) || return 0`：
    #   _t54_bare_reads 的退出码是**管道末端 grep/sort 的退出码**，
    #   「某一支 grep 没命中」时它会返回非 0 —— 于是 `|| return 0` 把
    #   **已经取到的输出整个丢掉**（实测：静态 2 明明命中了 read -p，
    #   包装函数却返回空）⇒ 集合对比全部退化成 0 ⇒ 断言恒绿。
    #   ⇒ 只取输出，不拿退出码当成败。
    out=$(_t54_bare_reads "$root" 2>/dev/null)
    [ -n "$out" ] || return 0
    printf '%s\n' "$out" | sed "s|^${root}/||"
}

# 静态 2 命中行里，属于「非交互类」（herestring / 文件重定向 / 带标记）的行
#   → 静态 3 按契约不判它们（契约边界，见文件头「已知边界」）
_t89_static2_noninteractive_lines() {
    local root="$1"
    _t89_static2_hits "$root" | while IFS= read -r l; do
        [ -z "$l" ] && continue
        case "$l" in
            *'<<<'*|*'<'*) printf '%s\n' "$l" ;;
            *'xwpf:noninteractive-io'*) printf '%s\n' "$l" ;;
        esac
    done
}

# 取一条命中记录的内容部分（第 3 字段起）
_t89_hit_content() {
    local l="$1"
    printf '%s' "$l" | cut -d: -f3-
}

# 造一条探针（各自独立目录）
_t89_make_probe() {
    local dir="$1" body="$2"
    rm -rf "$dir" 2>/dev/null
    mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s\n' "$body" > "$dir/probe.sh" 2>/dev/null || return 1
    return 0
}

# 取真实旧实现的产品文件树（只用 git show <sha>:<path>）
_t89_prepare_tree() {
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

# ══════════════════════════════════════════════════════════════════
# T89 · 静态 3 主判据
# ══════════════════════════════════════════════════════════════════
case_T89_static3_noninteractive_io_invariant() {
    h_case_begin "T89" "静态 3：所有 while/until 循环里的输入读入必须 EOF 收口 + sleep 兜底（豁免仅限 herestring / 文件重定向 / xwpf:noninteractive-io 标记）" \
        "冻结态 $BASE_SHA 的产品文件（$SBX_SRC）+ 修复前冻结点的真实旧实现（负向对照）+ 合成探针（判定器自检）" \
        "静态 3 判定器（扫全部 while/until 循环；豁免仅限 herestring / 文件重定向 / xwpf:noninteractive-io 标记）" \
        "产品当前形态下静态 3 违规数为 0；判定器在产品树上看得到循环与读入、标记豁免路径被走到；同一套判定器跑修复前的真实旧实现必须判红；注入坏循环后必须判红"

    # ── 1. 主判据：产品当前形态下静态 3 违规 = 0 ──
    local findings n
    findings=$(_t89_findings "$SBX_SRC")
    n=$(printf '%s' "$findings" | _t89_count)
    h_check_eq "0" "$n" "产品当前形态下静态 3 的违规条数（含所有 while/until 循环）"
    if [ -n "$findings" ]; then
        while IFS= read -r l; do
            [ -z "$l" ] && continue
            h_log "  违规: $l"
        done <<< "$findings"
    fi

    # ── 2. 防空过护栏：判定器在产品树上看得到东西（不是死代码）──
    #   ★ 这条护栏是踩过坑之后加的：判定器一度只看得到 1 个循环（漏看其余），
    #     而「违规数 = 0」照样是绿的 —— **没有护栏的 0 违规就是假绿**。
    #     这里用两条**关系**（不是钉死字面量）把「判定器确实看见了」钉住：
    #       ① 判定器识别到的循环数 ≥ 产品里「带标记的循环头」数（独立 grep 数出来的）
    #       ② 被标记豁免的读入数 ≥ 带标记的行数（每个标记都得真的豁免掉读入）
    local loops reads markers marked_lines marked_loop_heads
    loops=$(_t89_loop_count "$SBX_SRC")
    reads=$(_t89_read_count "$SBX_SRC")
    markers=$(_t89_marker_count "$SBX_SRC")
    marked_lines=$(grep -rn --include='*.sh' -F 'xwpf:noninteractive-io' "$SBX_SRC" 2>/dev/null | grep -v '/tests/' | grep -v '/reports/' | _t89_count)
    marked_loop_heads=$(grep -rn --include='*.sh' -F 'xwpf:noninteractive-io' "$SBX_SRC" 2>/dev/null | grep -v '/tests/' | grep -v '/reports/' | grep -cE '(^|[^A-Za-z0-9_])(while|until)[[:space:]]')
    h_check_ge 1 "$loops" "防空过护栏：判定器在产品树上识别到的 while/until 循环数"
    h_check_ge 1 "$reads" "防空过护栏：判定器在产品树上识别到的输入读入数"
    h_check_ge 1 "$marked_lines" "防空过护栏：产品树里 xwpf:noninteractive-io 标记的行数"
    h_check_ge "$marked_loop_heads" "$loops" "防空过护栏：判定器识别到的循环数 ≥ 产品里带标记的循环头数（判定器没漏看循环）"
    h_check_ge "$marked_lines" "$markers" "标记行数 ≤ 被标记豁免的读入数（每个标记都必须真的豁免掉读入）"

    # ── 3. 负向对照：修复前的**真实旧实现**跑同一套判定器 → 必须判红 ──
    #   ★ 锚点是「加 xwpf:noninteractive-io 标记**之前**」的那一版（static3-pre = b9db576 = ea56296^）。
    #     为什么不能用 t54-pre-fix（a359301）：
    #       那一版的交互读（read -p）**全在循环外**（if 条件里），
    #       而静态 3 按契约**只管循环内**的读入 ⇒ 那棵树上静态 3 违规 = 0
    #       ⇒ 用它做负向对照会得到「期望 ≥1、实际 0」的**假红**。
    #     static3-pre 那版有 `while IFS='|' read -r ... ; do` 这种
    #     **循环头行上、无标记、无 EOF 收口**的读入 ⇒ 静态 3 必须判红 ✔
    local pre_sha
    pre_sha=$(sbx_history_sha static3-pre 2>/dev/null || true)
    [ -n "$pre_sha" ] || pre_sha="b9db576"
    h_check_eq "yes" "$(cd "$SBX_REPO" && git cat-file -e "$pre_sha^{commit}" 2>/dev/null && echo yes || echo no)" \
        "负向对照自检 · 修复前冻结点 $pre_sha 在本克隆里可达（对象缺失时对照会静默失效）"
    local pre_tree="$SBX_ROOT/t89_pre_fix"
    if _t89_prepare_tree "$pre_sha" "$pre_tree"; then
        # 自检：换进来的确实是修复前形态（那时还没有 xwpf:noninteractive-io 标记）
        local pre_markers
        pre_markers=$(grep -rl --include='*.sh' -F 'xwpf:noninteractive-io' "$pre_tree" 2>/dev/null | _t89_count)
        h_check_eq "0" "$pre_markers" "负向对照自检 · 修复前实现里还没有 xwpf:noninteractive-io 标记"
        local pre_findings pre_n
        pre_findings=$(_t89_findings "$pre_tree")
        pre_n=$(printf '%s' "$pre_findings" | _t89_count)
        h_log "修复前实现：静态 3 违规 $pre_n 处"
        if [ -n "$pre_findings" ]; then
            while IFS= read -r l; do
                [ -z "$l" ] && continue
                h_log "  违规: $l"
            done <<< "$pre_findings"
        fi
        h_check_ge 1 "$pre_n" "负向对照 · 修复前的真实旧实现存在「缺 EOF 收口 / 缺 sleep 兜底」的读入循环（坏情况确实发生）"
    else
        h_fail "取不到修复前实现 $pre_sha 的产品文件树（负向对照无法执行）"
    fi

    # ── 4. 判定器自检（注入式退化，如实标注：不是历史旧实现）─────────
    #   在冻结态产品树的**副本**里注入一条「无标记 + 无 sleep」的 while read 循环，
    #   同一套判定器必须判红 → 证明「产品形态下 0 违规」不是因为判定器瞎了。
    local deg_tree="$SBX_ROOT/t89_degraded"
    rm -rf "$deg_tree" 2>/dev/null
    mkdir -p "$deg_tree" 2>/dev/null
    local f rel
    for f in $(find "$SBX_SRC" -name '*.sh' -type f 2>/dev/null | grep -v '/tests/' | grep -v '/reports/'); do
        rel="${f#$SBX_SRC/}"
        mkdir -p "$deg_tree/$(dirname "$rel")" 2>/dev/null
        cp "$f" "$deg_tree/$rel" 2>/dev/null || true
    done
    mkdir -p "$deg_tree/lib" 2>/dev/null
    cat > "$deg_tree/lib/t89_injected_bad.sh" <<'EOF'
# ★ 注入式退化（不是历史旧实现）：无标记 + 无 sleep 的交互读循环
while read -r __t89_line; do
    echo "$__t89_line"
done
EOF
    local deg_n
    deg_n=$(_t89_findings_count "$deg_tree")
    h_log "注入坏循环后的产品树：静态 3 违规 $deg_n 处"
    h_check_ge 1 "$deg_n" "判定器自检 · 注入「无标记 + 无 sleep」的 while read 后必须判红（证明产品形态下的 0 违规不是假绿）"

    # ── 5. 负向对照的对照项：产品形态下同一个注入位置放**带标记**的循环 → 不该报 ──
    local ok_tree="$SBX_ROOT/t89_degraded_marked"
    rm -rf "$ok_tree" 2>/dev/null
    mkdir -p "$ok_tree/lib" 2>/dev/null
    cat > "$ok_tree/lib/t89_injected_marked.sh" <<'EOF'
# ★ 注入式退化（不是历史旧实现）：带 xwpf:noninteractive-io 标记的同类循环
while read -r __t89_line; do   # xwpf:noninteractive-io（输入来自文件）
    echo "$__t89_line"
done
EOF
    local ok_n
    ok_n=$(_t89_findings_count "$ok_tree")
    h_check_eq "0" "$ok_n" "判定器自检 · 同样的循环加上 xwpf:noninteractive-io 标记后不得报（豁免面确实生效）"
}

# ══════════════════════════════════════════════════════════════════
# T90 · 静态 3 ⊋ 静态 2
# ══════════════════════════════════════════════════════════════════
case_T90_static3_covers_static2() {
    h_case_begin "T90" "静态 3 覆盖静态 2（静态 2 判违规的形态，静态 3 必须也判违规）" \
        "冻结态 $BASE_SHA 的产品文件（$SBX_SRC）+ 每种形态各一个独立目录的合成探针" \
        "真实静态 2 判定器（cases/14 的 _t54_bare_reads）与静态 3 判定器跑同一批探针，比对两者抓到的集合" \
        "静态 2 抓到的每一种形态，静态 3 都抓到（集合包含）；静态 3 抓到的集合严格更大（真超集）；两层都放行的形态不被误报；两层的差异必须能被「非交互类」完全解释"

    # ── 0. 存在性断言：静态 2 判定器必须真的在（不存在时对照会静默失效）──
    h_check_eq "yes" "$(declare -F _t54_bare_reads >/dev/null 2>&1 && echo yes || echo no)" \
        "静态 2 判定器（_t54_bare_reads）必须存在且可用（不存在时本用例的对照会静默失效）"

    # ── 0b. 包装函数自身的自检（防空过）：_t89_static2_hits 必须真能取到输出 ──
    #   ★ 这里踩过一个真坑：包装函数原本写成
    #       out=$(_t54_bare_reads "$root" 2>/dev/null) || return 0
    #     而 _t54_bare_reads 的退出码是**管道末端 grep/sort 的退出码**
    #     （某支 grep 没命中就非 0）⇒ `|| return 0` 把**已经取到的输出整个丢掉**
    #     ⇒ 静态 2 明明命中了 read -p，包装函数却返回空
    #     ⇒ 后面所有「集合包含 / 真超集」断言全部退化成 0 ⇒ **恒绿**。
    #   ⇒ 这条自检直接喂一个静态 2 认识的形态，断言包装函数确实取到了东西。
    local wdir="$SBX_ROOT/t90_wrapper_check"
    rm -rf "$wdir" 2>/dev/null
    mkdir -p "$wdir" 2>/dev/null
    printf '%s\n' 'while true; do' '    read -p "继续?" ans' '    sleep 0.2' 'done' \
        > "$wdir/probe.sh" 2>/dev/null
    local w_raw w_wrap
    w_raw=$(_t54_bare_reads "$wdir" 2>/dev/null)
    w_wrap=$(_t89_static2_hits "$wdir")
    h_log "包装自检：静态 2 原始输出 $(printf '%s' "$w_raw" | grep -c . | tr -d ' ') 行 / 包装后 $(printf '%s' "$w_wrap" | grep -c . | tr -d ' ') 行"
    h_check_ge 1 "$(printf '%s' "$w_raw" | grep -c . | tr -d ' ')" \
        "包装自检 · 前置：静态 2 原始判定器在这个形态上必须真的命中（确认形态选对了）"
    h_check_ge 1 "$(printf '%s' "$w_wrap" | grep -c . | tr -d ' ')" \
        "包装自检：_t89_static2_hits 必须真能取到静态 2 的输出（取不到 ⇒ 下面所有集合断言恒绿）"
    h_check_eq "$(printf '%s' "$w_raw" | grep -c . | tr -d ' ')" "$(printf '%s' "$w_wrap" | grep -c . | tr -d ' ')" \
        "包装自检：包装后与原始判定的命中条数必须一致（不得丢行）"

    local pdir="$SBX_ROOT/t90_probes"
    rm -rf "$pdir" 2>/dev/null
    mkdir -p "$pdir" 2>/dev/null

    # 每种形态一个**独立目录**（避免互相串扰）
    #  f_read_p        静态 2 违规形态：read -p 且无 EOF 处理
    #  f_or_true       静态 2 违规形态：read -p ... || true（伪兜底）
    #  f_bare          静态 2 违规形态：裸 read VAR
    #  f_read_r        静态 2 **漏掉**的形态：read -r VAR
    #  f_read_n        静态 2 豁免掉的形态：read -n（老盲区）
    #  f_eof_ok        两层都应放行：read -p ... || VAR="" + sleep
    #  f_exit_ok       两层都应放行：read -p ... || exit N + sleep
    #  f_herestring    静态 2 命中但静态 3 按契约豁免（herestring）→ 边界，自检用
    local form
    for form in f_read_p f_or_true f_bare f_read_r f_read_n f_eof_ok f_exit_ok f_herestring; do
        mkdir -p "$pdir/$form" 2>/dev/null
    done
    _t89_make_probe "$pdir/f_read_p" 'while true; do
    read -p "继续?" x
    echo "$x"
done'
    _t89_make_probe "$pdir/f_or_true" 'while true; do
    read -p "继续?" x || true
    echo "$x"
done'
    _t89_make_probe "$pdir/f_bare" 'while true; do
    read x
    echo "$x"
done'
    _t89_make_probe "$pdir/f_read_r" 'while true; do
    read -r x
    echo "$x"
done'
    _t89_make_probe "$pdir/f_read_n" 'while true; do
    read -n 1 -s x
    echo "$x"
done'
    _t89_make_probe "$pdir/f_eof_ok" 'while true; do
    sleep 0.2
    read -p "继续?" x || x=""
    echo "$x"
done'
    _t89_make_probe "$pdir/f_exit_ok" 'while true; do
    sleep 0.2
    read -p "继续?" x || exit 0
    echo "$x"
done'
    _t89_make_probe "$pdir/f_herestring" 'while true; do
    sleep 0.2
    read -p "继续?" x <<< "$DEF"
    echo "$x"
done'

    # ── 1. 逐形态：静态 2 抓到的，静态 3 必须也抓到 ──
    local s2 s3 s2n s3n missing
    local forms_violated="f_read_p f_or_true f_bare"
    for form in $forms_violated; do
        s2=$(_t89_static2_hits "$pdir/$form")
        s3=$(_t89_eof_lines "$pdir/$form")
        s2n=$(printf '%s' "$s2" | _t89_count)
        s3n=$(printf '%s' "$s3" | _t89_count)
        h_log "形态 $form：静态 2 命中 $s2n 处 / 静态 3 在读入行上命中 $s3n 处"
        # ★ 把两个集合的**内容**也打出来（不只是条数）：
        #   条数相等但集合不同时，只看条数根本看不出差在哪 ⇒ 必须能自诊断。
        h_log "形态 $form · 静态 2 命中集合：$(printf '%s' "$s2" | tr '\n' ' ')"
        h_log "形态 $form · 静态 3 命中集合：$(printf '%s' "$s3" | tr '\n' ' ')"
        h_check_ge 1 "$s2n" "形态 $form：静态 2 必须命中（确认这个形态确实是静态 2 的违规形态）"
        h_check_ge 1 "$s3n" "形态 $form：静态 3 也必须命中（静态 2 抓到的，静态 3 不能放过）"
        # 集合包含：静态 2 的命中行必须逐行出现在静态 3 的命中行里
        missing=""
        while IFS= read -r l; do
            [ -z "$l" ] && continue
            local key="${l%%:*}"
            local rest="${l#*:}"
            key="${key}:${rest%%:*}"
            if ! printf '%s\n' "$s3" | grep -qxF "$key"; then
                missing="$missing$key "
            fi
        done <<< "$s2"
        h_check_eq "" "$missing" "形态 $form：静态 2 的命中行必须逐行出现在静态 3 的命中行里（集合包含）"
    done

    # ── 2. 静态 3 必须比静态 2 **严格更大**（真超集，不是相等也不是更小）──
    #   形态 f_read_r / f_read_n 是静态 2 漏掉或豁免掉的，静态 3 必须抓到
    local total_s2=0 total_s3=0
    for form in $forms_violated f_read_r f_read_n; do
        s2n=$(_t89_static2_hits "$pdir/$form" | _t89_count)
        s3n=$(_t89_eof_lines "$pdir/$form" | _t89_count)
        total_s2=$((total_s2 + s2n))
        total_s3=$((total_s3 + s3n))
    done
    h_log "探针集合合计：静态 2 命中 $total_s2 处 / 静态 3 命中 $total_s3 处"
    h_check_ge "$total_s2" "$total_s3" "静态 3 在读入行上抓到的集合 ⊇ 静态 2 抓到的集合"
    h_check_ge 1 "$total_s3" "静态 3 在读入行上抓到的集合 ≠ 空（防空过护栏）"
    if [ "$total_s3" -le "$total_s2" ]; then
        h_fail "静态 3 必须是静态 2 的真超集：静态 3 命中 $total_s3 处 ≤ 静态 2 命中 $total_s2 处"
    else
        h_pass "静态 3 是静态 2 的真超集（$total_s3 > $total_s2）"
    fi

    # ── 3. 静态 2 漏掉 / 豁免掉的形态，静态 3 必须抓到 ──
    for form in f_read_r f_read_n; do
        s2n=$(_t89_static2_hits "$pdir/$form" | _t89_count)
        s3n=$(_t89_eof_lines "$pdir/$form" | _t89_count)
        h_log "形态 $form：静态 2 命中 $s2n 处 / 静态 3 命中 $s3n 处"
        h_check_eq "0" "$s2n" "形态 $form：静态 2 确实不命中它（静态 2 的盲区形态）"
        h_check_ge 1 "$s3n" "形态 $form：静态 3 必须抓到它（两层之间不许有盲区）"
    done

    # ── 4. 两层都该放行的形态：不得被任一层误报 ──
    for form in f_eof_ok f_exit_ok; do
        s2n=$(_t89_static2_hits "$pdir/$form" | _t89_count)
        s3n=$(_t89_findings_count "$pdir/$form")
        h_log "形态 $form：静态 2 命中 $s2n 处 / 静态 3 违规 $s3n 处"
        h_check_eq "0" "$s2n" "形态 $form：静态 2 放行（显式 EOF 兜底）"
        h_check_eq "0" "$s3n" "形态 $form：静态 3 也放行（显式 EOF 兜底 + sleep 兜底）"
    done

    # ── 5. 自检：包含关系这条断言本身必须能判红 ──
    #   herestring 形态：静态 2 会命中（它是逐行形态匹配，不区分输入来源），
    #   静态 3 按契约豁免 → 包含关系**必须**报出缺失行。
    #   这条自检证明「包含关系断言」不是恒真，同时把契约边界如实钉住。
    s2=$(_t89_static2_hits "$pdir/f_herestring")
    s3=$(_t89_eof_lines "$pdir/f_herestring")
    s2n=$(printf '%s' "$s2" | _t89_count)
    s3n=$(printf '%s' "$s3" | _t89_count)
    h_log "形态 f_herestring：静态 2 命中 $s2n 处 / 静态 3 命中 $s3n 处"
    h_check_ge 1 "$s2n" "自检 · herestring 形态确实被静态 2 命中（静态 2 是逐行形态匹配）"
    h_check_eq "0" "$s3n" "自检 · herestring 形态按豁免契约被静态 3 放过"
    missing=""
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        local key2="${l%%:*}"
        local rest2="${l#*:}"
        key2="${key2}:${rest2%%:*}"
        if ! printf '%s\n' "$s3" | grep -qxF "$key2"; then
            missing="$missing$key2 "
        fi
    done <<< "$s2"
    h_check_ge 1 "$(printf '%s' "$missing" | _t89_count)" \
        "自检 · 包含关系断言在 herestring 形态上**必须报红**（证明「静态 2 ⊆ 静态 3」这条断言不是恒真）"

    # ── 6. 产品树：两层都不许有命中，且两层的差异必须能被「非交互类」完全解释 ──
    local p_s2 p_s3 p_s2n p_s3n p_diff p_unexplained
    p_s2=$(_t89_static2_hits "$SBX_SRC")
    p_s3=$(_t89_eof_lines "$SBX_SRC")
    p_s2n=$(printf '%s' "$p_s2" | _t89_count)
    p_s3n=$(printf '%s' "$p_s3" | _t89_count)
    p_diff=""
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        local key3="${l%%:*}"
        local rest3="${l#*:}"
        key3="${key3}:${rest3%%:*}"
        if ! printf '%s\n' "$p_s3" | grep -qxF "$key3"; then
            p_diff="$p_diff$key3 "
        fi
    done <<< "$p_s2"
    h_check_eq "0" "$p_s2n" "产品树：静态 2 的命中数"
    h_check_eq "0" "$p_s3n" "产品树：静态 3 在读入行上的命中数"
    h_check_eq "" "$p_diff" "产品树：静态 2 与静态 3 的命中集合无差异"

    # 差异必须能被「非交互类」完全解释（herestring / 文件重定向 / 带标记）
    p_unexplained=""
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        local key4="${l%%:*}"
        local rest4="${l#*:}"
        key4="${key4}:${rest4%%:*}"
        if ! printf '%s\n' "$p_diff" | grep -qF "$key4"; then
            p_unexplained="$p_unexplained$key4 "
        fi
    done <<< "$(_t89_static2_noninteractive_lines "$SBX_SRC")"
    h_check_eq "" "$p_unexplained" "产品树：两层差异必须能被「非交互类」完全解释（不存在解释不了的盲区）"
}

# ══════════════════════════════════════════════════════════════════
# T91 · 判定器自检：探针 A（无标记的 while read + 无 sleep）必须被抓
# ══════════════════════════════════════════════════════════════════
case_T91_static3_probe_unmarked_read_is_caught() {
    h_case_begin "T91" "判定器自检：探针 A（无标记的 while read 从 stdin + 无 sleep）必须被抓" \
        "合成探针（各自独立目录，不是历史旧实现）" \
        "静态 3 判定器跑探针 A（无标记 + 无 sleep 的 while read 循环）" \
        "探针 A 必须被静态 3 判红（fail-closed 成立）；探针形态必须确实是「无标记 + 无 sleep」；同形态但 EOF 收口且有 sleep 的对照循环不得被报"

    local pdir="$SBX_ROOT/t91_probes"
    rm -rf "$pdir" 2>/dev/null
    mkdir -p "$pdir" 2>/dev/null

    # ── 探针 A（独立目录）：无标记 + 无 sleep 的 while read ──
    local pa="$pdir/a_unmarked"
    _t89_make_probe "$pa" 'while read -r line; do
    echo "$line"
done'
    # 自检：坏情况确实被制造出来了（形态自检，防止探针写歪导致恒绿）
    h_check_file "$pa/probe.sh" "探针 A 的文件存在"
    h_check_file_has "$pa/probe.sh" "while read" "自检 · 探针 A 确实是一个 while read 循环"
    if grep -qF 'xwpf:noninteractive-io' "$pa/probe.sh" 2>/dev/null; then
        h_fail "自检 · 探针 A 不得带 xwpf:noninteractive-io 标记（否则就不是「无标记」形态了）"
    else
        h_pass "自检 · 探针 A 确实没有 xwpf:noninteractive-io 标记"
    fi
    if grep -qE '(^|[;&|(){}[:space:]])sleep[[:space:]]' "$pa/probe.sh" 2>/dev/null; then
        h_fail "自检 · 探针 A 不得含 sleep（否则就不是「无 sleep 兜底」形态了）"
    else
        h_pass "自检 · 探针 A 确实没有 sleep 兜底"
    fi

    # ── 主断言：探针 A 必须被抓 ──
    local hits n
    hits=$(_t89_findings "$pa")
    n=$(printf '%s' "$hits" | _t89_count)
    h_log "探针 A 判定结果: $(printf '%s' "$hits" | tr '\n' ' ')"
    h_check_ge 1 "$n" "探针 A（无标记的 while read + 无 sleep）必须被静态 3 抓到"

    # 抓到的必须是「读入行」这一类违规（EOF 收口缺失），不能是别的噪声
    local eofn
    eofn=$(_t89_eof_lines "$pa" | _t89_count)
    h_check_ge 1 "$eofn" "探针 A 必须被判为「读入缺 EOF 收口」"

    # ── 对照：同样的循环，EOF 已收口且有 sleep 兜底 → 不得被报 ──
    #   （证明判定器的结论取决于形态，而不是「什么都报」的常量）
    #   ★ 对照探针的**头行读入也要 EOF 收口**：头行的 read 同样是循环 stdin 上的
    #     读入，不收口就照样是交互读 → 判定器报它是**对的**（实测踩过）。
    local pc="$pdir/a_control_ok"
    _t89_make_probe "$pc" 'while read -r line || line=""; do
    sleep 0.2
    read -r line2 || line2=""
    echo "$line2"
done'
    local cn
    cn=$(_t89_findings_count "$pc")
    h_check_eq "0" "$cn" "对照 · 同样形态但已 EOF 收口且有 sleep 兜底的循环不得被报（判定器不是无脑全报）"
}

# ══════════════════════════════════════════════════════════════════
# T92 · 判定器自检：探针 B（带 xwpf:noninteractive-io 标记）必须不报
# ══════════════════════════════════════════════════════════════════
case_T92_static3_probe_marked_read_is_not_reported() {
    h_case_begin "T92" "判定器自检：探针 B（带 xwpf:noninteractive-io 标记的 while read）必须不报" \
        "合成探针（各自独立目录，不是历史旧实现）" \
        "静态 3 判定器跑探针 B（带 xwpf:noninteractive-io 标记的 while read 循环）与两个「去掉标记」的对照探针" \
        "探针 B 必须不报（豁免面确实生效）；探针 B 确实带上了标记；去掉标记的同一循环必须被判红；标记落在别的行时也必须判红（fail-closed）"

    local pdir="$SBX_ROOT/t92_probes"
    rm -rf "$pdir" 2>/dev/null
    mkdir -p "$pdir" 2>/dev/null

    # ── 探针 B（独立目录）：带标记的 while read（同样没有 sleep）──
    local pb="$pdir/b_marked"
    _t89_make_probe "$pb" 'while read -r line; do   # xwpf:noninteractive-io（输入来自文件）
    echo "$line"
done'
    h_check_file "$pb/probe.sh" "探针 B 的文件存在"
    h_check_file_has "$pb/probe.sh" "xwpf:noninteractive-io" "防空过护栏 · 探针 B 确实带上了 xwpf:noninteractive-io 标记"
    h_check_file_has "$pb/probe.sh" "while read" "防空过护栏 · 探针 B 确实是一个 while read 循环"

    # ── 主断言：探针 B 不得被报 ──
    local hits n
    hits=$(_t89_findings "$pb")
    n=$(printf '%s' "$hits" | _t89_count)
    h_log "探针 B 判定结果: $(printf '%s' "$hits" | tr '\n' ' ')"
    h_check_eq "0" "$n" "探针 B（带 xwpf:noninteractive-io 标记的 while read）不得被静态 3 报出"

    # ── 自检 1：同一循环**去掉标记** → 必须判红（证明「不报」是因为标记，不是因为判定器瞎）──
    local pu="$pdir/b_unmarked"
    _t89_make_probe "$pu" 'while read -r line; do
    echo "$line"
done'
    local un
    un=$(_t89_findings_count "$pu")
    h_log "去掉标记的对照探针：静态 3 违规 $un 处"
    h_check_ge 1 "$un" "自检 · 同一循环去掉 xwpf:noninteractive-io 标记后必须被判红（证明探针 B 的「不报」来自标记）"

    # ── 自检 2：标记落在**别的行**（既不是读入行、也不是循环头行）→ 必须判红（fail-closed）──
    local pe="$pdir/b_marker_elsewhere"
    _t89_make_probe "$pe" '# xwpf:noninteractive-io
while read -r line; do
    echo "$line"
done'
    local en
    en=$(_t89_findings_count "$pe")
    h_log "标记落在独立注释行的对照探针：静态 3 违规 $en 处"
    h_check_ge 1 "$en" "自检 · 标记只在独立注释行时必须判红（fail-closed：标记必须落在读入行或循环头行）"

    # ── 自检 3：标记落在**读入行**（不是头行）→ 必须不报（豁免面的另一条腿）──
    local pr="$pdir/b_marker_on_read_line"
    _t89_make_probe "$pr" 'while true; do
    read -r line   # xwpf:noninteractive-io（输入来自文件）
    echo "$line"
done'
    local rn
    rn=$(_t89_findings_count "$pr")
    h_check_eq "0" "$rn" "自检 · 标记落在读入行（而不是循环头行）时不得被报（豁免面的另一条腿确实生效）"
}

# ══════════════════════════════════════════════════════════════════
# T93 · Chief 给的 10 条探针矩阵（逐条对账，判定器口径的完整证明）
# ══════════════════════════════════════════════════════════════════
#   Chief（产品侧自测）给了 10 条探针 + 期望，本用例逐条跑同一套判定器，
#   证明「静态 3 的口径」与产品侧的自测口径**一致**。
#
#   ★ 口径约定（Chief 指定）：**口径 A（字面契约）**
#     只在**读所在行**认 `<<<` / `<`；循环头行的读一律靠**显式标记**豁免。
#     判定器**不推理**「循环的 stdin 从哪来」——
#     所以 `done <<< "$p"` / `done < "$f"` 这类「stdin 来自重定向」的循环，
#     在口径 A 下**仍判违规**（读行没有 `<<<`、头行没有标记）。
#   ★ 为什么不能是口径 B（Chief 实测过，会自相矛盾）：
#     口径 B 会把「循环 stdin 被重定向」也算豁免 ⇒ 循环层判豁免、
#     但**裸读入层**（静态 2）不认这个豁免 ⇒ 同一个循环头行读被两层判出不同结论
#     ⇒ 两层自相矛盾。本文件坚持口径 A ⇒ 两层用同一套豁免面 ⇒ 不会打架。
#
#   ★ 探针 I（循环外的裸 read）**静态 3 按契约不管**（静态 3 只管循环内的读入）
#     ⇒ 它的期望是「**静态 2** 必须抓到」；静态 3 抓不到它是**契约要求**，不是盲区。
#     本用例用真静态 2 判定器（_t54_bare_reads）来验这一条。
case_T93_static3_probe_matrix_vs_chief_contract() {
    h_case_begin "T93" "静态 3 判定器探针矩阵：Chief 的 10 条探针逐条对账（口径 A 字面契约）" \
        "合成探针（每条一个独立目录）+ 真静态 2 判定器（cases/14 的 _t54_bare_reads）" \
        "同一套静态 3 判定器跑 10 条探针，逐条对照 Chief 给的期望" \
        "A/B/D/E/H/I/J 必须抓到（B 走裸读入层、I 只走静态 2）；C/F/G 必须不报；两条不得报的被豁免形态不得误报"

    local pdir="$SBX_ROOT/t93_probes"
    rm -rf "$pdir" 2>/dev/null
    mkdir -p "$pdir" 2>/dev/null

    # ── 存在性断言：静态 2 判定器必须在（探针 B/I 要用它）──
    h_check_eq "yes" "$(declare -F _t54_bare_reads >/dev/null 2>&1 && echo yes || echo no)" \
        "静态 2 判定器（_t54_bare_reads）必须存在（探针 B/I 的对照要用它；不存在 → 对照静默失效）"

    # 探针 A：无标记的 while read + 无 sleep → 必须抓到（循环层）
    _t89_make_probe "$pdir/A" 'while read -r line; do
    echo "$line"
done'
    # 探针 B：while true + read + sleep 0.2 → 循环层有 sleep 不报 sleep，
    #         但读入缺 EOF 收口 ⇒ 循环层必报；
    #         裸读入层（静态 2）也必报 ⇒ 用静态 2 认识的形态（read -p）
    _t89_make_probe "$pdir/B" 'while true; do
    read -p "继续?" ans
    sleep 0.2
done'
    # 探针 C：头行带标记 → 不得报
    _t89_make_probe "$pdir/C" 'while read -r line; do   # xwpf:noninteractive-io（输入来自文件）
    echo "$line"
done'
    # 探针 D：done <<< "$p" 供 stdin、未标记 → **口径 A 下必须抓到**
    _t89_make_probe "$pdir/D" 'while read -r line; do
    echo "$line"
done <<< "$p"'
    # 探针 E：while [ -n "$x" ]（**非 while true**）+ 未标记 read → 必须抓到
    _t89_make_probe "$pdir/E" 'x=1
while [ -n "$x" ]; do
    read -r ans
    x=""
done'
    # 探针 F：标记写在循环头行 → 不得报
    _t89_make_probe "$pdir/F" 'while read -r line; do   # xwpf:noninteractive-io（输入来自文件）
    echo "$line"
done'
    # 探针 G：IFS=',' read -ra arr <<< "$x" → 不得报（herestring 豁免）
    _t89_make_probe "$pdir/G" 'IFS="," read -ra arr <<< "$x"
echo "${arr[0]}"'
    # 探针 H：until [ -n "$x" ] + 未标记 read → 必须抓到
    _t89_make_probe "$pdir/H" 'x=1
until [ -z "$x" ]; do
    read -r ans
    x=""
done'
    # 探针 I：循环外的裸 read → 静态 2 必须抓到（静态 3 按契约不管循环外的读）
    #   ★ 用静态 2 认识的形态（独占一行的 `read VAR`）；
    #     `read -r ans` 不在静态 2 的识别式里（它的盲区，见 T90 的 f_read_r 形态）
    _t89_make_probe "$pdir/I" 'read ans
echo "$ans"'
    # 探针 J：done < "$f" 供 stdin、未标记 → 口径 A 下必须抓到（同 D）
    _t89_make_probe "$pdir/J" 'while read -r line; do
    echo "$line"
done < "$f"'

    # ── 逐条探针的存在性 + 形态自检（防止探针写歪导致恒绿）──
    local p
    for p in A B C D E F G H I J; do
        h_check_file "$pdir/$p/probe.sh" "探针 $p 的文件存在"
    done
    h_check_file_has "$pdir/E/probe.sh" "while [ -n" "探针 E 确实是非 while true 的 while 循环（放宽到所有 while 的证明）"
    h_check_file_has "$pdir/H/probe.sh" "until" "探针 H 确实是 until 循环（放宽到 until 的证明）"
    h_check_file_has "$pdir/D/probe.sh" 'done <<<' "探针 D 确实由 done <<< 供 stdin（口径 A 的关键形态）"
    h_check_file_has "$pdir/J/probe.sh" 'done <' "探针 J 确实由 done < 供 stdin（口径 A 的关键形态）"

    # ── 期望「必须抓到」的 6 条（A/B/D/E/H/J）──
    for p in A B D E H J; do
        local n eofn
        n=$(_t89_findings_count "$pdir/$p")
        eofn=$(_t89_eof_lines "$pdir/$p" | _t89_count)
        h_log "探针 $p：静态 3 违规 $n 处（读入行命中 $eofn 处）"
        h_check_ge 1 "$n" "探针 $p：静态 3 必须抓到（Chief 口径：这条形态是违规）"
    done

    # ── 期望「不得报」的 3 条（C/F/G）──
    for p in C F G; do
        local n
        n=$(_t89_findings_count "$pdir/$p")
        h_log "探针 $p：静态 3 违规 $n 处"
        h_check_eq "0" "$n" "探针 $p：静态 3 不得报（Chief 口径：这条形态被豁免）"
    done

    # ── 探针 I：静态 3 按契约不管循环外的读；**静态 2** 必须抓到 ──
    #   ★ 这一条是「两层各有一条腿」的证明：
    #     静态 3 只管循环内 ⇒ 抓不到 I 是**契约要求**；
    #     但静态 2 管全仓 ⇒ 必须抓到 I ⇒ 两层合起来没有盲区。
    local i_s3 i_s2
    i_s3=$(_t89_findings_count "$pdir/I")
    i_s2=$(_t89_static2_hits "$pdir/I" | _t89_count)
    h_log "探针 I：静态 3 违规 $i_s3 处 / 静态 2 命中 $i_s2 处"
    h_check_eq "0" "$i_s3" "探针 I：静态 3 按契约不管循环外的读入（静态 3 只管循环内）"
    h_check_ge 1 "$i_s2" "探针 I：静态 2 必须抓到循环外的裸 read（两层合起来没有盲区）"

    # ── 探针 B：两层**都**必须抓到（裸读入层也有腿）──
    #   Chief 的坑 2：「只实现了循环层、没实现裸读入层 ⇒ 第二层没腿」
    local b_s3 b_s2
    b_s3=$(_t89_findings_count "$pdir/B")
    b_s2=$(_t89_static2_hits "$pdir/B" | _t89_count)
    h_log "探针 B：静态 3 违规 $b_s3 处 / 静态 2 命中 $b_s2 处"
    h_check_ge 1 "$b_s3" "探针 B：静态 3（循环层）必须抓到"
    h_check_ge 1 "$b_s2" "探针 B：静态 2（裸读入层）也必须抓到（两层都有腿，不是只有一层）"

    # ── 口径 A 的自洽性：同一个探针在**两层**上的结论不许打架 ──
    #   Chief 实测过口径 B 下会出现「循环层豁免 / 裸读入层命中」的自相矛盾。
    #   口径 A 下 D/J 这种「stdin 来自 done 行重定向」的循环：
    #     静态 3 **判违规**（读行没 <<<、头行没标记）
    #   ★ 但「静态 3 判违规 ⇒ 静态 2 也必须命中」**不是普遍成立**：
    #     静态 2 的识别式只认 `read -p` 和「独占一行的裸 read VAR」两种形态，
    #     `read -r ans` 是它的**盲区**（Chief 的坑 1 同源）。
    #     ⇒ 所以这里只对「静态 2 认识的形态」（探针 B）断言两层不打架，
    #       其余探针只断言静态 3 自己的结论（这才是静态 3 的责任范围）。
    #   ★ 静态 2 的盲区本身由 T90 的 f_read_r 形态单独钉住（静态 2 命中 0、静态 3 必须抓到）。
    local p s3n s2n
    for p in A B D E H J; do
        s3n=$(_t89_findings_count "$pdir/$p")
        s2n=$(_t89_static2_hits "$pdir/$p" | _t89_count)
        h_log "探针 $p：静态 3 违规 $s3n 处 / 静态 2 命中 $s2n 处（口径自洽性对账）"
    done
    # 只有探针 B 用的是静态 2 认识的形态（read -p）⇒ 两层都必须命中，不许打架
    s3n=$(_t89_findings_count "$pdir/B")
    s2n=$(_t89_static2_hits "$pdir/B" | _t89_count)
    h_check_ge 1 "$s3n" "口径自洽性：探针 B（静态 2 认识的形态）静态 3 必须判违规"
    h_check_ge 1 "$s2n" "口径自洽性：探针 B 静态 2 也必须命中（两层对同一形态不许给出相反结论）"

    # ★ 静态 2 的盲区必须被如实钉住（不是缺陷，是边界）：
    #   探针 A/D/E/H/J 用的是 `read -r` ⇒ 静态 2 **命中 0**（它的盲区），
    #   而静态 3 **必须抓到** ⇒ 这正是「静态 3 ⊋ 静态 2」的证据。
    for p in A D E H J; do
        s2n=$(_t89_static2_hits "$pdir/$p" | _t89_count)
        s3n=$(_t89_findings_count "$pdir/$p")
        h_log "探针 $p：静态 2 命中 $s2n 处（read -r 是静态 2 的盲区）/ 静态 3 违规 $s3n 处"
        h_check_eq "0" "$s2n" "探针 $p：静态 2 确实不命中 read -r 形态（静态 2 的已知盲区，如实钉住）"
        h_check_ge 1 "$s3n" "探针 $p：静态 3 必须抓到它（静态 3 ⊋ 静态 2 的直接证据）"
    done
}
