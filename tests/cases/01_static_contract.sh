#!/bin/bash
# 用例组 01 · 静态契约检查（只读仓库，不执行产品代码）
#
# 覆盖重点回归清单：
#   - 所有功能脚本下载地址都指向 byby5555/realm-xwPF-offline-active-standby，旧仓库名出现次数为 0
#   - 文档与实现一致性（--help / help / 路径 / 依赖表）
#   - 行尾检查：git ls-files --eol -- '*.sh' 索引全部应为 i/lf

REPO_OLD="zywe03/realm-xwPF"
REPO_NEW="byby5555/realm-xwPF-offline-active-standby"

# 仓库里所有 tracked 文本文件里出现的 URL（带文件名和行号）
_repo_urls() {
    (cd "$SBX_REPO" && git grep -n -o -E 'https?://[^ "'"'"'`)<>]+' -- '*.sh' '*.md' '*.py' '*.service' 2>/dev/null)
}

# 从 URL 里抽出 owner/repo
_url_repo() {
    printf '%s' "$1" | sed -n -E \
        -e 's|.*raw\.githubusercontent\.com/([^/]+)/([^/]+).*|\1/\2|p' \
        -e 's|.*github\.com/([^/]+)/([^/]+).*|\1/\2|p' \
        | head -1
}

case_T01_download_urls() {
    h_case_begin "T01" "下载地址一致性" \
        "仓库工作区（只读）" \
        "git grep 下载类 URL（wget/curl/raw.githubusercontent//raw/ 行）" \
        "所有下载地址指向 byby5555/realm-xwPF-offline-active-standby；违例 0 条"

    local violations="" checked=0
    local line file lineno text url repo

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        file="${line%%:*}"
        rest="${line#*:}"
        lineno="${rest%%:*}"
        text="${rest#*:}"

        # 只看"下载类"上下文：出现下载动词，或本身就是 raw / /raw/ 文件地址
        case "$text" in
            *wget*|*curl*|*"raw.githubusercontent.com"*|*"/raw/"*) ;;
            *) continue ;;
        esac

        for url in $(printf '%s' "$text" | grep -oE 'https?://[^ "'"'"'`)<>]+'); do
            repo="$(_url_repo "$url")"
            [ -z "$repo" ] && continue
            checked=$((checked + 1))
            case "$repo" in
                "$REPO_NEW") ;;
                "zhboner/realm") ;;   # 第三方上游二进制，与本仓库功能脚本分发无关
                *)
                    violations="$violations${file}:${lineno}  ${repo}  ${url}"$'\n'
                    ;;
            esac
        done
    done < <(cd "$SBX_REPO" && git grep -n -E 'wget|curl|raw\.githubusercontent\.com|/raw/' -- '*.sh' '*.md' '*.py' '*.service' 2>/dev/null)

    h_log "下载地址 URL 总数: $checked"
    if [ -n "$violations" ]; then
        h_log "违例清单:"
        while IFS= read -r v; do h_log "  - $v"; done <<< "$violations"
    fi

    local count=0
    [ -n "$violations" ] && count=$(printf '%s' "$violations" | grep -c . )
    h_check_eq "0" "$count" "下载地址指向旧仓库的条数"
}

case_T02_old_repo_name() {
    h_case_begin "T02" "旧仓库名残留" \
        "仓库工作区（只读）" \
        "git grep -n -F 'zywe03/realm-xwPF'" \
        "全仓出现次数 0"

    local hits
    hits=$(cd "$SBX_REPO" && git grep -n -F "$REPO_OLD" -- . ':(exclude)tests' 2>/dev/null)
    local count=0
    [ -n "$hits" ] && count=$(printf '%s' "$hits" | grep -c .)
    if [ -n "$hits" ]; then
        h_log "命中明细:"
        while IFS= read -r v; do h_log "  - $v"; done <<< "$hits"
    fi
    h_check_eq "0" "$count" "旧仓库名出现次数"
}

case_T03_eol() {
    h_case_begin "T03" "行尾检查" \
        "仓库工作区（只读）" \
        "git ls-files --eol -- '*.sh'" \
        "所有 .sh 索引行尾均为 i/lf"

    local out bad=0 total=0
    out=$(cd "$SBX_REPO" && git ls-files --eol -- '*.sh')
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        total=$((total + 1))
        case "$l" in
            i/lf*) ;;
            *) bad=$((bad + 1)); h_log "  非常规: $l" ;;
        esac
    done <<< "$out"
    h_log "检查 .sh 文件数: $total"
    h_check_eq "0" "$bad" "非 i/lf 的 .sh 文件数"
}

case_T04_xwpf_help_static() {
    h_case_begin "T04" "xwPF.sh --help 入口" \
        "仓库工作区（只读）" \
        "grep -- '--help' xwPF.sh lib/ui.sh" \
        "xwPF.sh 支持 --help / -h / help 并打印用法"

    local hits
    hits=$(cd "$SBX_REPO" && grep -n -- '--help' xwPF.sh lib/ui.sh lib/core.sh 2>/dev/null)
    if [ -n "$hits" ]; then
        h_log "命中:"
        while IFS= read -r v; do h_log "  - $v"; done <<< "$hits"
    fi
    local n=0
    [ -n "$hits" ] && n=$(printf '%s' "$hits" | grep -c .)
    if [ "$n" -ge 1 ]; then
        h_pass "入口侧 --help 命中 $n 处"
    else
        h_fail "xwPF.sh / lib/ui.sh 里没有任何 --help 处理分支（命中 $n 处），xwPF.sh --help 会掉进交互菜单"
    fi
}

case_T05_failover_help_vs_docs() {
    h_case_begin "T05" "xwFailover.sh help 与文档一致性" \
        "沙箱副本（LF+路径重定向）" \
        "source xwFailover.sh; main help" \
        "help 列出的每个子命令都在 docs/ 或 README 里有对应说明"

    # 行为侧：跑一遍 help，拿到实现输出的子命令
    local out=""
    out=$(
        bash -c '
            src="$1"
            tmp="$2"
            sed "s|^main \"\\\$@\"$|# neutralized|" "$src" > "$tmp"
            source "$tmp" >/dev/null 2>&1
            main help 2>&1
        ' _ "$SBX_RUN/xwFailover.sh" "$SBX_ROOT/xwFailover_nomain.sh"
    )
    h_log "=== xwFailover.sh help 输出 ==="
    while IFS= read -r l; do h_log "  $l"; done <<< "$out"

    local cmds="toggle config status start stop restart-realm help"
    local c documented=0 missing=""
    for c in $cmds; do
        if (cd "$SBX_REPO" && grep -rEl "xwFailover\.sh[[:space:]]+${c}([^A-Za-z0-9_-]|$)" docs/ README.md README_EN.md cmd/ >/dev/null 2>&1); then
            documented=$((documented + 1))
        else
            missing="$missing $c"
        fi
    done
    h_log "有文档说明的子命令: $documented / 7"
    h_log "缺文档的子命令:$missing"
    h_check_eq "7" "$documented" "help 子命令中有文档说明的数量"
}

case_T06_devtcp_fallback() {
    h_case_begin "T06" "健康检查 /dev/tcp 回退" \
        "仓库工作区（只读）" \
        "grep -n '/dev/tcp' xwFailover.sh lib/health.sh lib/core.sh" \
        "故障转移侧的 check_connectivity 在没有 nc 时走 bash /dev/tcp 回退"

    # 健康检查实现现在在 lib/health.sh（唯一真源），老版本在 xwFailover.sh 里，两边都查
    local health_hits=0 failover_hits=0 core_hits=0
    [ -f "$SBX_REPO/lib/health.sh" ] && health_hits=$(h_count '/dev/tcp' "$SBX_REPO/lib/health.sh")
    failover_hits=$(h_count '/dev/tcp' "$SBX_REPO/xwFailover.sh")
    core_hits=$(h_count '/dev/tcp' "$SBX_REPO/lib/core.sh")
    h_log "lib/health.sh 里 /dev/tcp 命中: $health_hits"
    h_log "xwFailover.sh 里 /dev/tcp 命中: $failover_hits"
    h_log "lib/core.sh  里 /dev/tcp 命中: $core_hits（证明能力在代码库里存在，不是环境限制）"

    local total=$((health_hits + failover_hits))
    if [ "$total" -ge 1 ]; then
        h_pass "健康检查实现里有 /dev/tcp 回退（共 $total 处）"
    else
        h_fail "健康检查实现（lib/health.sh / xwFailover.sh）里没有 /dev/tcp 回退（0 处）"
    fi
}

case_T07_docs_claim_missing_test() {
    h_case_begin "T07" "文档声称的测试脚本" \
        "仓库工作区（只读）" \
        "grep -rn 'test_e2e.sh' docs/ README.md" \
        "文档提到的测试脚本必须真实存在于仓库"

    local refs missing=""
    refs=$(cd "$SBX_REPO" && grep -rn 'test_e2e\.sh' docs/ README.md README_EN.md 2>/dev/null)
    if [ -n "$refs" ]; then
        h_log "文档引用:"
        while IFS= read -r v; do h_log "  - $v"; done <<< "$refs"
    else
        h_log "文档未引用 test_e2e.sh"
    fi

    # 只按文档里实际写的路径去核对，不自己发明路径
    local paths
    paths=$(printf '%s\n' "$refs" | grep -oE '`[A-Za-z0-9_./-]*test_e2e\.sh`' | tr -d '`' | sort -u)
    local p
    if [ -n "$paths" ]; then
        for p in $paths; do
            [ -f "$SBX_REPO/$p" ] || missing="$missing $p"
        done
    else
        for p in test_e2e.sh tests/test_e2e.sh; do
            [ -f "$SBX_REPO/$p" ] || missing="$missing $p"
        done
    fi
    h_log "文档引用的路径:$paths"
    h_log "缺失文件:$missing"
    h_check_eq "" "$missing" "文档引用的测试脚本缺失清单"
}

case_T08_docs_claim_missing_source() {
    h_case_begin "T08" "文档声明的唯一真源文件" \
        "仓库工作区（只读）" \
        "grep -rn 'lib/health.sh' docs/" \
        "被文档声明为「唯一真源」的 lib/health.sh 必须存在"

    local refs
    refs=$(cd "$SBX_REPO" && grep -rn 'lib/health\.sh' docs/ README.md README_EN.md 2>/dev/null)
    local n=0
    [ -n "$refs" ] && n=$(printf '%s' "$refs" | grep -c .)
    h_log "文档提到 lib/health.sh 的行数: $n"
    if [ -n "$refs" ]; then
        while IFS= read -r v; do h_log "  - $v"; done <<< "$refs"
    fi
    h_check_file "$SBX_REPO/lib/health.sh" "唯一真源 lib/health.sh"
}

case_T09_tracked_pyc() {
    h_case_begin "T09" "仓库里被跟踪的编译产物" \
        "仓库工作区（只读）" \
        "git ls-files 'cmd/__pycache__/*' '*.pyc'" \
        "仓库不跟踪 .pyc / __pycache__ 编译产物"

    local tracked
    tracked=$(cd "$SBX_REPO" && git ls-files -- 'cmd/__pycache__/*' '*.pyc')
    local n=0
    [ -n "$tracked" ] && n=$(printf '%s' "$tracked" | grep -c .)
    if [ -n "$tracked" ]; then
        while IFS= read -r v; do h_log "  被跟踪: $v"; done <<< "$tracked"
    fi
    h_check_eq "0" "$n" "被跟踪的编译产物数量"
}
