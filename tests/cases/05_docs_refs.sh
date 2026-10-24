#!/bin/bash
# 用例组 05 · 文档源码引用一致性（第 3 轮新增）
#
# 背景：D-01 把 docs 里的「文件:行号」引用升级成了「文件 的 函数名」，
#   行号漂移这个病根就此消除。但**行号**本身还会漂 ——
#   只要文档里还留着 `lib/core.sh:24` 这种写法，core.sh 一改它就悄悄指错地方，
#   而且没有任何测试会发现。
#
# T34 分两层：
#   A. 函数级引用（主断言）
#      形如 `lib/rules.sh` 的 `auto_enable_active_standby` →
#      该符号必须在这个文件里有定义（函数 `name()` 或变量赋值 `name=` 都算）。
#      函数改名 / 移动 / 删除 → 一律红。
#   B. 剩余的行号引用（兜底断言 + 漂移哨兵）
#      形如 `lib/core.sh:24` → 目标文件必须存在、行号必须在范围内（客观错，客观判）。
#      另外把每一处引用指向的**那一行内容**打进日志，作为漂移哨兵：
#      下次跑批时对比这一行还是不是当初那行，「静默漂移」就变成「可见变化」。
#
# 防空过护栏：解析到的函数级引用数必须 ≥ 100（实测 212 处 / 去重 92 组）。
#   否则正则写坏 → 0 命中 → 「全部解析成功」的假绿。

# 文档来源：冻结态里的 docs/、cmd/、根 README（中英文）
_doc_sources() {
    printf '%s\n' "$SBX_SRC/docs" "$SBX_SRC/cmd" "$SBX_SRC/README.md" "$SBX_SRC/README_EN.md"
}

# 符号是否在该文件里定义：函数 `name()` 或变量赋值 `name=`
_symbol_defined() {
    local file="$1" sym="$2"
    grep -qE "^[[:space:]]*(function[[:space:]]+)?${sym}[[:space:]]*\([[:space:]]*\)" "$file" 2>/dev/null && return 0
    grep -qE "^[[:space:]]*(local[[:space:]]+|export[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+-[a-zA-Z]+[[:space:]]+|typeset[[:space:]]+)?${sym}=" "$file" 2>/dev/null && return 0
    return 1
}

case_T34_docs_source_refs() {
    h_case_begin "T34" "文档里的源码引用必须可解析" \
        "冻结态 $BASE_SHA（只读）" \
        "解析 \`<file>.sh|p y\` 的 \`<symbol>\` 引用" \
        "函数级引用：符号在该文件里有定义；行号引用：文件存在且行号未越界"

    local RE='([a-zA-Z0-9_./-]+\.(sh|py))`[[:space:]]*的[[:space:]]*`([a-zA-Z0-9_]+)`'

    # ── A. 函数级引用 ──
    # 注意三个不同的数，别混：
    #   n_occ   出现处数（实测 212）—— 用作「防空过护栏」的基数
    #   n_pairs 去重后的 (file, symbol) 组合数（实测 63）—— 逐个解析的对象
    #   n_docs  去重后的 (doc, file, symbol) 组合数（实测 92）—— 仅作参考
    local raw
    raw=$(grep -rhoE "$RE" $(_doc_sources) 2>/dev/null)
    local n_occ
    n_occ=$(printf '%s\n' "$raw" | h_count_pipe '.')
    local refs
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
    h_check_eq "0" "$n_ln_bad" "行号引用指向的文件/行号失效数"

    # 漂移哨兵：这些引用指向的是常量与代码范围，函数级口径还没覆盖它们。
    # 打印每一处指向的行内容 —— 下次跑批对比这一行，就知道行号有没有漂。
    h_log "—— 行号锚点快照（对比上一轮即可看出漂移）——"
    local item
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        h_log "  $item"
    done <<< "$(printf '%s' "$ln_snapshot" | tr '|' '\n')"

    h_pass "函数级引用 $n_total 组全部可解析；行号引用 $n_ln 处目标均存在"
}
