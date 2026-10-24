#!/bin/bash
# 用例组 05 · 文档源码引用一致性（第 3 轮新增）
#
# 背景：D-01 把 docs 里的「文件:行号」引用升级成了「文件 的 函数名」，
#   行号漂移这个病根就此消除。但**行号**本身还会漂 ——
#   只要文档里还留着 `lib/core.sh:24` 这种写法，core.sh 一改它就悄悄指错地方，
#   而且没有任何测试会发现。
#
# T34 分两层：
#   A. 函数级引用（主断言）—— **中英文两种写法都认**
#      中文「的」式：  `lib/rules.sh` 的 `auto_enable_active_standby`
#      英文所有格式：  `lib/core.sh`'s `REQUIRED_TOOLS`
#      → 该符号必须在这个文件里有定义（函数 `name()` 或变量赋值 `name=` 都算）。
#      函数改名 / 移动 / 删除 → 一律红。
#   B. 行号引用（**硬断言：必须为 0**）
#      形如 `lib/core.sh:24` → **禁止再出现**（第 3 轮起文档统一改成「文件 的 符号」）。
#      为什么从「兜底 + 漂移哨兵」收紧成硬断言：
#        旧口径只判「文件不存在 / 行号越界」→ **行号漂了但仍在文件范围内时它是绿的**，
#        而这正是 D-01 那类漂移最常见的形态（指向了无关的一行，没人发现）。
#      一旦出现就红；同时把每一处指向的行内容打进日志当**失败现场定位信息**。
#
# 防空过护栏：
#   ① 解析到的函数级引用数必须 ≥ 100（实测 212 处 / 去重 92 组）
#      —— 否则正则写坏 → 0 命中 → 「全部解析成功」的假绿；
#   ② 英文所有格形式的引用数必须 ≥ 1 —— 防止「扩了正则但其实没匹配上」这种静默退化。
#
# 判定器自检：两条新断言各有一个反例（英文写法指向不存在的符号 / 出现「文件:行号」），
#   断言的是「**坏情况确实被检出**」，不是「好情况没发生」（后者恒真，等于没断言）。

# 文档来源：冻结态里的 docs/、cmd/、根 README（中英文）
# ★ 只输出**存在**的路径：cmd/ 已在 2beb7bd 随主备池整块删掉，
#   把不存在的路径喂给 grep 会让它退出码 2（虽然匹配仍会打印，但那是运气，
#   换个 grep 变体就可能整个静默）。路径清单必须**与冻结态实际有的目录一致**。
_doc_sources() {
    local p
    for p in "$SBX_SRC/docs" "$SBX_SRC/cmd" "$SBX_SRC/README.md" "$SBX_SRC/README_EN.md"; do
        [ -e "$p" ] && printf '%s\n' "$p"
    done
}

# 符号是否在该文件里定义：函数 `name()` 或变量赋值 `name=`
_symbol_defined() {
    local file="$1" sym="$2"
    grep -qE "^[[:space:]]*(function[[:space:]]+)?${sym}[[:space:]]*\([[:space:]]*\)" "$file" 2>/dev/null && return 0
    grep -qE "^[[:space:]]*(local[[:space:]]+|export[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+-[a-zA-Z]+[[:space:]]+|typeset[[:space:]]+)?${sym}=" "$file" 2>/dev/null && return 0
    return 1
}

# 解析一批文件里的源码引用 → 每行一个匹配（**不去重**，出现处数要保留重复）
# 抽成函数是为了让**判定器自检**复用同一段解析逻辑 ——
# 自检必须走**生产代码的同一条路**，否则「自检通过」不代表真断言会红。
_t34_scan_refs() {
    local APOS="'"
    local RE="([a-zA-Z0-9_./-]+\.(sh|py))\`[[:space:]]*(${APOS}s[[:space:]]+|的)[[:space:]]*\`([a-zA-Z0-9_]+)\`"
    grep -rhoE "$RE" "$@" 2>/dev/null
}

case_T34_docs_source_refs() {
    h_case_begin "T34" "文档里的源码引用必须可解析" \
        "冻结态 $BASE_SHA（只读）" \
        "解析 \`<file>.sh|p y\` 的 \`<symbol>\` 引用（中英文两种写法）" \
        "函数级引用：符号在该文件里有定义；行号引用：必须为 0（政策：只保留函数级引用）"

    # 中英文两种写法统一成「文件 → 连接词 → 符号」，连接词都在两个反引号**之外**：
    #   `lib/rules.sh` 的 `auto_enable_active_standby`
    #   `lib/core.sh`'s `REQUIRED_TOOLS`
    # 漏掉一种写法 = 那一半文档的引用**完全不被检查**（README_EN.md 就是这一半）。
    local APOS="'"
    local RE_EN="([a-zA-Z0-9_./-]+\.(sh|py))\`${APOS}s[[:space:]]+\`([a-zA-Z0-9_]+)\`"

    # ── A. 函数级引用 ──
    # 注意三个不同的数，别混：
    #   n_occ   出现处数（实测 212）—— 用作「防空过护栏」的基数
    #   n_pairs 去重后的 (file, symbol) 组合数（实测 63）—— 逐个解析的对象
    #   n_docs  去重后的 (doc, file, symbol) 组合数（实测 92）—— 仅作参考
    local raw refs n_occ
    raw=$(_t34_scan_refs $(_doc_sources))
    n_occ=$(printf '%s\n' "$raw" | h_count_pipe '.')
    refs=$(printf '%s\n' "$raw" | sed -E 's/^([^`]+)`[^`]*`([^`]+)`$/\1|\2/' | sort -u)

    local n_total=0 n_undef=0 n_missing=0
    local undef_list="" missing_list="" file sym target
    while IFS='|' read -r file sym; do
        [ -z "$file" ] && continue
        n_total=$((n_total + 1))
        target="$SBX_SRC/$file"
        if [ ! -f "$target" ]; then
            n_missing=$((n_missing + 1))
            missing_list="$missing_list$file->$sym "
            continue
        fi
        if _symbol_defined "$target" "$sym"; then
            continue
        fi
        n_undef=$((n_undef + 1))
        undef_list="$undef_list$file->$sym "
    done <<< "$refs"

    h_log "函数级引用: 出现 $n_occ 处 / 去重 $n_total 组 (file+symbol)"
    [ -n "$missing_list" ] && h_log "指向的文件不存在: $missing_list"
    [ -n "$undef_list" ] && h_log "符号未定义: $undef_list"

    h_check_eq "0" "$n_missing" "函数级引用指向的源文件缺失数"
    h_check_eq "0" "$n_undef" "函数级引用指向的符号未定义数"
    # 防空过护栏：正则坏掉 → 0 命中 → 上面两条会假绿
    h_check_ge "100" "$n_occ" "解析到的函数级引用处数"

    # 防空过护栏②：英文所有格写法必须仍被解析到。
    #   只扩正则不加这条 → 「正则扩了但其实没匹配上」是静默退化，没人发现。
    local raw_en n_en
    raw_en=$(grep -rhoE "$RE_EN" $(_doc_sources) 2>/dev/null)
    n_en=$(printf '%s\n' "$raw_en" | h_count_pipe '.')
    h_log "其中英文所有格写法: $n_en 处"
    h_check_ge "1" "$n_en" "英文所有格式源码引用处数"

    # ── B. 剩余的行号引用（兜底 + 漂移哨兵）──
    local lnrefs
    lnrefs=$(grep -rhoE '[a-zA-Z0-9_./-]+\.(sh|py):[0-9]+(-[0-9]+)?' $(_doc_sources) 2>/dev/null | sort -u)

    local n_ln=0 n_ln_bad=0 ln_bad_list="" ln_snapshot=""
    local ref rf rl nlines
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        n_ln=$((n_ln + 1))
        rf="${ref%%:*}"
        rl="${ref#*:}"
        rl="${rl%%-*}"
        if [ ! -f "$SBX_SRC/$rf" ]; then
            n_ln_bad=$((n_ln_bad + 1))
            ln_bad_list="$ln_bad_list$ref(文件不存在) "
            continue
        fi
        nlines=$(wc -l < "$SBX_SRC/$rf" 2>/dev/null | tr -d ' ')
        if [ "$rl" -gt "$nlines" ]; then
            n_ln_bad=$((n_ln_bad + 1))
            ln_bad_list="$ln_bad_list$ref(越界,共$nlines行) "
            continue
        fi
        ln_snapshot="$ln_snapshot$ref→$(sed -n "${rl}p" "$SBX_SRC/$rf" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-52)|"
    done <<< "$lnrefs"

    h_log "行号引用（去重后）: $n_ln"
    [ -n "$ln_bad_list" ] && h_log "失效的行号引用: $ln_bad_list"
    # ★ 硬断言：文档里不允许再出现「文件:行号」。
    #   旧口径只判「文件不存在 / 行号越界」→ 行号漂了但仍在范围内时是绿的（静默漂移）。
    #   文档统一用「文件 的 符号」；再出现行号引用就红（下面的锚点快照当失败现场定位信息）。
    h_check_eq "0" "$n_ln" "文档里的行号引用处数（政策：只保留函数级引用）"
    h_check_eq "0" "$n_ln_bad" "行号引用指向的文件/行号失效数"

    # 漂移哨兵：这些引用指向的是常量与代码范围，函数级口径还没覆盖它们。
    # 打印每一处指向的行内容 —— 下次跑批对比这一行，就知道行号有没有漂。
    h_log "—— 行号锚点快照（对比上一轮即可看出漂移）——"
    local item
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        h_log "  $item"
    done <<< "$(printf '%s' "$ln_snapshot" | tr '|' '\n')"

    # ── 判定器自检（反例）：证明这两条新断言**会红** ──
    #   「怎么写都绿」的断言等于没有断言；自检复用**生产代码的同一段解析**。
    #   探针树放在沙箱里（不在冻结态文档目录内）→ 不影响上面任何计数。
    #     ① 英文所有格引用指向**不存在的符号** → A 段必须判红
    #     ② 出现「文件:行号」→ 行号引用硬断言必须触发
    #   断言的是「**坏情况确实被检出**」，不是「好情况没发生」（后者恒真）。
    local probe="$SBX_ROOT/t34_probe"
    rm -rf "$probe" 2>/dev/null; mkdir -p "$probe"
    printf '%s\n' "# T34 probe" "see \`lib/core.sh\`'s \`T34_NO_SUCH_SYMBOL_XXX\` here" > "$probe/p_en.md"
    printf '%s\n' "# T34 probe" "see \`lib/core.sh:24\` here" > "$probe/p_ln.md"

    local n_en_undef=0 n_ln_probe=0 pfile psym
    while IFS='|' read -r pfile psym; do
        [ -z "$pfile" ] && continue
        _symbol_defined "$SBX_SRC/$pfile" "$psym" || n_en_undef=$((n_en_undef + 1))
    done <<< "$(_t34_scan_refs "$probe/p_en.md" | sed -E 's/^([^`]+)`[^`]*`([^`]+)`$/\1|\2/' | sort -u)"
    n_ln_probe=$(grep -rhoE '[a-zA-Z0-9_./-]+\.(sh|py):[0-9]+(-[0-9]+)?' "$probe/p_ln.md" 2>/dev/null | h_count_pipe '.')

    h_log "反例自检：英文写法探针 → 未定义符号 $n_en_undef 条；行号探针 → 命中 $n_ln_probe 条"
    h_check_eq "1" "$n_en_undef" "反例自检：英文所有格引用指向不存在的符号 → 必须被判红"
    h_check_eq "1" "$n_ln_probe" "反例自检：出现「文件:行号」→ 行号引用硬断言必须触发"

    h_pass "函数级引用 $n_total 组全部可解析（含英文所有格 $n_en 处）；行号引用 $n_ln 处（政策要求 0）"
}
