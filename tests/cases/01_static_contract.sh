#!/bin/bash
# 用例组 01 · 静态契约检查
#
# ★ 第 2 轮：所有静态检查一律读**冻结态**（$SBX_SRC = git show $BASE_SHA:<path> 的 LF 副本），
#   绝不读工作区文件 —— 仓库多人并行改动，读工作区会得到不可复现的结论。
#
# 覆盖重点回归清单：
#   - 所有功能脚本下载地址都指向 byby5555/realm-xwPF-offline-active-standby，旧仓库名出现次数为 0
#   - 文档与实现一致性（--help / help / 路径 / 依赖表）
#   - 行尾检查：冻结态的 .sh 提交内容必须是 LF

REPO_OLD="zywe03/realm-xwPF"
REPO_NEW="byby5555/realm-xwPF-offline-active-standby"
# 注意：不要在这里把路径快照成变量 —— 用例文件是在沙箱建好**之前**被 source 的，
# 那时 $SBX_SRC 还是空的，快照下来会变成假绿（读不到任何文件 → 0 命中 → 判过）。
# 一律在用例函数体内直接用 "$SBX_SRC"。

# 从 URL 里抽出 owner/repo
_url_repo() {
    printf '%s' "$1" | sed -n -E \
        -e 's|.*raw\.githubusercontent\.com/([^/]+)/([^/]+).*|\1/\2|p' \
        -e 's|.*github\.com/([^/]+)/([^/]+).*|\1/\2|p' \
        | head -1
}

case_T01_download_urls() {
    h_case_begin "T01" "下载地址一致性" \
        "冻结态 $BASE_SHA（只读）" \
        "grep 下载类 URL（wget/curl/raw.githubusercontent//raw/ 行）" \
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
                    violations="$violations${file#$SBX_SRC/}:${lineno}  ${repo}  ${url}"$'\n'
                    ;;
            esac
        done
    done < <(grep -rnE 'wget|curl|raw\.githubusercontent\.com|/raw/' "$SBX_SRC" \
                --include='*.sh' --include='*.md' --include='*.py' --include='*.service' \
                --exclude-dir=tests 2>/dev/null)

    h_log "下载地址 URL 总数: $checked"
    if [ -n "$violations" ]; then
        h_log "违例清单:"
        while IFS= read -r v; do h_log "  - $v"; done <<< "$violations"
    fi

    local count=0
    [ -n "$violations" ] && count=$(printf '%s' "$violations" | grep -c .)
    h_check_eq "0" "$count" "下载地址指向旧仓库的条数"
}

case_T02_old_repo_name() {
    h_case_begin "T02" "旧仓库名残留" \
        "冻结态 $BASE_SHA（只读）" \
        "grep -F 'zywe03/realm-xwPF'" \
        "产品与用户可见文档里出现次数 0（台架自身 tests/ 与审查报告 reports/ 除外）"

    # ★ 第 5 轮：把「自指风险」显式化（这条用例自己就含被禁字符串）。
    #
    #   断言文件自身含有被禁字符串是**正常**的 —— 断言就得写出它要禁的东西
    #   （本文件的 REPO_OLD 定义 + 说明文字里就有它）。
    #   但**统计必须排除断言自身**（--exclude-dir=tests），
    #   否则将来只要改动本文件的逻辑（哪怕只改一句注释、换一个变量名），
    #   统计就会把自己数进去 → 出现跟产品无关的**自指假红**。
    #
    # ★ 第 7 轮：排除范围从 tests/ 扩到 **tests/ + reports/**，理由三条：
    #   1) 不变式本身是「**产品代码与面向用户的文档**里不得再出现旧仓库名」——
    #      用户实际拿到的输出（lib/ cmd/ docs/ README 脚本）里不能有指向旧仓库的链接。
    #   2) `tests/` 是台架自身、`reports/` 是审查报告 —— 两者都是**过程产物**，不是产品交付物。
    #      审稿要在报告里说明「旧仓库名出现在哪」，**就必须引用它**；
    #      不引用反而写不清问题（与 tests/ 的自指是同一类）。
    #   3) **URL 层面的覆盖没有丢**：T01（下载地址一致性）**不排除 reports/**，
    #      仍然全树扫 .sh/.md/.py/.service 里的下载 URL；
    #      报告里若残留指向旧仓库的下载链接，T01 照样判红。
    #      T02 只是不再查「纯文字提及」—— 报告里用文字提到旧仓库名不是产品缺陷。
    #
    #   所以这里给四条断言，把「排除 tests/ 与 reports/」变成**可验证的**：
    #     1) 排除 tests/ 与 reports/ 后命中 0 条   → 产品与用户可见文档干净
    #     2) 全树命中中落在 tests/ 与 reports/ 之外的 0 条
    #                                              → 证明排除没掩盖任何外部残留
    #     3) 冻结树里 tests/ 内命中 ≥ 1             → 证明排除 tests/ 是必要的（不是多余的）
    #     4) 冻结树里 reports/ 内命中 ≥ 1           → 证明排除 reports/ 是必要的（同上）

    local hits_prod hits_all hits_tests hits_reports tmp
    local count_prod=0 count_tests=0 count_reports=0 count_outside=0

    # 统计口径：排除 tests/（断言自身所在目录）与 reports/（审查报告目录）
    hits_prod=$(grep -rnF "$REPO_OLD" "$SBX_SRC" --exclude-dir=tests --exclude-dir=reports 2>/dev/null)
    # 全树命中（不排除任何目录）—— 用来核对「排除到底盖住了什么」
    hits_all=$(grep -rnF "$REPO_OLD" "$SBX_SRC" 2>/dev/null)
    # tests/ 目录内的命中
    hits_tests=$(grep -rnF "$REPO_OLD" "$SBX_SRC/tests" 2>/dev/null)
    # reports/ 目录内的命中
    hits_reports=$(grep -rnF "$REPO_OLD" "$SBX_SRC/reports" 2>/dev/null)

    [ -n "$hits_prod" ] && count_prod=$(printf '%s' "$hits_prod" | grep -c .)
    [ -n "$hits_tests" ] && count_tests=$(printf '%s' "$hits_tests" | grep -c .)
    [ -n "$hits_reports" ] && count_reports=$(printf '%s' "$hits_reports" | grep -c .)
    if [ -n "$hits_all" ]; then
        # 路径形如 <沙箱>/src/tests/README.md:45:xxx → 目录成分里有 tests/ 的算 tests/ 内
        tmp=$(printf '%s\n' "$hits_all" | grep -vE '(^|/)tests/' | grep -vE '(^|/)reports/')
        [ -n "$tmp" ] && count_outside=$(printf '%s' "$tmp" | grep -c .)
    fi

    if [ -n "$hits_prod" ]; then
        h_log "命中明细（排除 tests/ 与 reports/ 后）:"
        while IFS= read -r v; do h_log "  - ${v#$SBX_SRC/}"; done <<< "$hits_prod"
    fi
    if [ -n "$hits_all" ]; then
        h_log "全树命中（含 tests/ 与 reports/ 自身）共 $(printf '%s' "$hits_all" | grep -c .) 处：tests/ 内 $count_tests 处、reports/ 内 $count_reports 处、两者之外 $count_outside 处"
        while IFS= read -r v; do h_log "  · ${v#$SBX_SRC/}"; done <<< "$hits_all"
    fi

    h_check_eq "0" "$count_prod" "旧仓库名出现次数（排除 tests/ 与 reports/ 自身）"
    h_check_eq "0" "$count_outside" "全树命中中落在 tests/ 与 reports/ 之外的条数（证明排除没掩盖外部残留）"

    if [ -f "$SBX_SRC/tests/cases/01_static_contract.sh" ]; then
        h_check_ge 1 "$count_tests" "tests/ 内命中数（断言自身含被禁字符串 → 排除 tests/ 是必要的）"
    else
        h_log "冻结点没有 tests/cases/01_static_contract.sh（老冻结点）→ 「断言自身含被禁字符串」这一条不适用"
        h_pass "断言自身含被禁字符串的检查不适用（冻结点无 tests/cases/01_static_contract.sh）"
    fi

    # reports/ 的排除同样要「必要性」可验证 —— 否则它就是个没必要的放宽
    if [ ! -d "$SBX_SRC/reports" ]; then
        h_log "冻结点没有 reports/ 目录（老冻结点）→ 「排除 reports/ 是必要的」这一条不适用"
        h_pass "reports/ 排除的必要性检查不适用（冻结点无 reports/ 目录）"
    elif [ "$count_reports" = "0" ]; then
        h_log "冻结树的 reports/ 里没有旧仓库名命中 → 这条排除当前用不上（记一条提示，不判红）"
        h_pass "reports/ 内命中数 = 0 → 排除 reports/ 当前用不上（不判红，但如实记一条）"
    else
        h_check_ge 1 "$count_reports" "reports/ 内命中数（审查报告必须引用旧仓库名才能说明问题 → 排除 reports/ 是必要的）"
    fi

    # ── 负向对照：同一套计数口径必须「该抓的抓、该放的放」──
    # 用**合成探针树**（不碰冻结态、不碰仓库）：
    #   · lib/ 下的命中 → 必须被算成「产品命中」（证明排除没有过度）
    #   · reports/ 下的命中 → 必须被算成「已排除」
    #   · tests/ 下的命中 → 必须被算成「已排除」
    local probe="$SBX_ROOT/t02_probe"
    rm -rf "$probe"
    mkdir -p "$probe/lib" "$probe/reports" "$probe/tests"
    printf 'x %s\n' "$REPO_OLD" > "$probe/lib/product.sh"
    printf 'x %s\n' "$REPO_OLD" > "$probe/reports/review.md"
    printf 'x %s\n' "$REPO_OLD" > "$probe/tests/case.sh"
    local p_prod p_all p_tests p_reports p_outside
    p_prod=$(grep -rnF "$REPO_OLD" "$probe" --exclude-dir=tests --exclude-dir=reports 2>/dev/null)
    p_all=$(grep -rnF "$REPO_OLD" "$probe" 2>/dev/null)
    p_tests=$(grep -rnF "$REPO_OLD" "$probe/tests" 2>/dev/null)
    p_reports=$(grep -rnF "$REPO_OLD" "$probe/reports" 2>/dev/null)
    p_outside=$(printf '%s\n' "$p_all" | grep -vE '(^|/)tests/' | grep -vE '(^|/)reports/')
    local np_prod=0 np_tests=0 np_reports=0 np_outside=0
    [ -n "$p_prod" ] && np_prod=$(printf '%s' "$p_prod" | grep -c .)
    [ -n "$p_tests" ] && np_tests=$(printf '%s' "$p_tests" | grep -c .)
    [ -n "$p_reports" ] && np_reports=$(printf '%s' "$p_reports" | grep -c .)
    [ -n "$p_outside" ] && np_outside=$(printf '%s' "$p_outside" | grep -c .)
    h_log "负向对照（合成探针树）: prod=$np_prod outside=$np_outside tests=$np_tests reports=$np_reports"
    h_check_eq "1" "$np_prod" "负向对照：lib/ 下的命中必须被算成产品命中（排除没有过度）"
    h_check_eq "1" "$np_outside" "负向对照：lib/ 下的命中必须被算成「两者之外」（排除没掩盖）"
    h_check_eq "1" "$np_tests" "负向对照：tests/ 下的命中必须被算成已排除"
    h_check_eq "1" "$np_reports" "负向对照：reports/ 下的命中必须被算成已排除"
}

case_T03_eol() {
    h_case_begin "T03" "行尾检查（提交态）" \
        "冻结态原始字节 $SBX_RAW" \
        "od 数字节数每个 .sh 的 CR" \
        "提交态的 .sh 必须是 LF（CR 字节数为 0）"

    local rel bad=0 total=0 crlist=""
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        case "$rel" in
            *.sh) ;;
            *) continue ;;
        esac
        [ -f "$SBX_RAW/$rel" ] || continue
        total=$((total + 1))
        local cr
        cr=$(sbx_count_cr "$SBX_RAW/$rel")
        if [ "$cr" != "0" ]; then
            bad=$((bad + 1))
            crlist="$crlist$rel($cr CR) "
        fi
    done < <(git ls-tree -r --name-only "$BASE_SHA")

    h_log "检查 .sh 文件数: $total"
    [ -n "$crlist" ] && h_log "含 CR 的文件: $crlist"
    h_check_eq "0" "$bad" "提交态含 CR 的 .sh 文件数"
}

case_T04_xwpf_help_static() {
    h_case_begin "T04" "xwPF.sh --help 入口" \
        "冻结态 $BASE_SHA（只读）" \
        "grep -- '--help' xwPF.sh lib/ui.sh" \
        "xwPF.sh 支持 --help / -h / help 并打印用法"

    local hits
    hits=$(grep -n -- '--help' "$SBX_SRC/xwPF.sh" "$SBX_SRC/lib/ui.sh" "$SBX_SRC/lib/core.sh" 2>/dev/null)
    if [ -n "$hits" ]; then
        h_log "命中:"
        while IFS= read -r v; do h_log "  - ${v#$SBX_SRC/}"; done <<< "$hits"
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

    # 文档侧：冻结态的 docs/ 与 README
    local cmds="toggle config status start stop restart-realm help"
    local c documented=0 missing=""
    for c in $cmds; do
        if grep -rEl "xwFailover\.sh[[:space:]]+${c}([^A-Za-z0-9_-]|$)" "$SBX_SRC/docs" "$SBX_SRC/README.md" "$SBX_SRC/README_EN.md" "$SBX_SRC/cmd" >/dev/null 2>&1; then
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
    h_case_begin "T06" "无 nc 时的健康检查（端到端行为）" \
        "沙箱 + 本地监听端口 + PATH 不含 nc" \
        "运行生成的 health_check.sh" \
        "没有 nc 时靠 bash /dev/tcp 仍能探测出 healthy（行为断言，不钉实现位置）"

    # 端到端：生成健康检查脚本 → 无 nc 环境跑一次 → 看健康状态文件
    _prepare_failover_runtime
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_failover_rule "$SBX_ROOT/realm/rules/rule-1.conf"
    bash "$SBX_ROOT/realm/xwFailover.sh" start >/dev/null 2>&1

    local script="$SBX_ROOT/realm/health/health_check.sh"
    if [ ! -f "$script" ]; then
        h_fail "健康检查脚本没生成出来，无法做行为断言"
        return
    fi

    # 造一条指向本地监听端口的目标
    local port=34873
    _start_listener "$port" || { h_fail "起不了本地监听端口，用例无法判定"; return; }
    sleep 0.5

    cat > "$SBX_ROOT/realm/rules/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=probe-test
SECURITY_LEVEL=standard
LISTEN_PORT=8080
REMOTE_HOST=127.0.0.1
REMOTE_PORT=$port
ENABLED=true
BALANCE_MODE="roundrobin"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="1"
SUCCESS_THRESHOLD="1"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF
    rm -f "$SBX_ROOT/realm/health/health_status.conf"

    local out
    out=$(sbx_path_without_nc; timeout 30 bash "$script" 2>&1)
    h_log "健康检查输出: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    kill "$LISTENER_PID" 2>/dev/null

    local status=""
    [ -f "$SBX_ROOT/realm/health/health_status.conf" ] && status=$(cat "$SBX_ROOT/realm/health/health_status.conf")
    h_log "健康状态文件: ${status:-（未生成）}"
    h_check_contains "$status" "healthy" "无 nc 时探测结果写入健康状态文件"
}

case_T07_docs_claim_missing_test() {
    h_case_begin "T07" "文档声称的测试脚本" \
        "冻结态 $BASE_SHA（只读）" \
        "grep -rn 'test_e2e.sh' docs/ README.md" \
        "文档提到的测试脚本必须真实存在于同一棵树里"

    local refs missing="" paths=""
    refs=$(grep -rn 'test_e2e\.sh' "$SBX_SRC/docs" "$SBX_SRC/README.md" "$SBX_SRC/README_EN.md" 2>/dev/null)
    if [ -n "$refs" ]; then
        h_log "文档引用:"
        while IFS= read -r v; do h_log "  - ${v#$SBX_SRC/}"; done <<< "$refs"
    else
        h_log "文档未引用任何测试脚本 → 无声明可核对（不判失败）"
    fi

    # 只按文档里实际写的路径去核对（反引号包裹的相对路径）
    paths=$(printf '%s\n' "$refs" | grep -oE '`[A-Za-z0-9_./-]*test_e2e\.sh`' | tr -d '`' | sort -u)
    local p
    if [ -n "$paths" ]; then
        for p in $paths; do
            [ -f "$SBX_SRC/$p" ] || missing="$missing $p"
        done
    fi
    h_log "文档引用的路径:${paths:-（无）}"
    h_log "缺失文件:${missing:-（无）}"
    h_check_eq "" "$missing" "文档引用的测试脚本缺失清单"
}

case_T08_docs_claim_missing_source() {
    h_case_begin "T08" "文档声明的唯一真源" \
        "冻结态 $BASE_SHA（只读）" \
        "grep -rn 'lib/health.sh' docs/" \
        "被文档声明为「唯一真源」的 lib/health.sh 必须存在于同一棵树里"

    local refs
    refs=$(grep -rn 'lib/health\.sh' "$SBX_SRC/docs" "$SBX_SRC/README.md" "$SBX_SRC/README_EN.md" 2>/dev/null)
    local n=0
    [ -n "$refs" ] && n=$(printf '%s' "$refs" | grep -c .)
    h_log "文档提到 lib/health.sh 的行数: $n"
    h_check_file "$SBX_SRC/lib/health.sh" "唯一真源 lib/health.sh"
}

case_T09_tracked_pyc() {
    h_case_begin "T09" "仓库里被跟踪的编译产物" \
        "冻结态 $BASE_SHA（只读）" \
        "git ls-tree -r $BASE_SHA -- '*.pyc'" \
        "仓库不跟踪 .pyc / __pycache__ 编译产物"

    local tracked
    tracked=$(git ls-tree -r --name-only "$BASE_SHA" | grep -E '\.pyc$|__pycache__' || true)
    local n=0
    [ -n "$tracked" ] && n=$(printf '%s' "$tracked" | grep -c .)
    if [ -n "$tracked" ]; then
        while IFS= read -r v; do h_log "  被跟踪: $v"; done <<< "$tracked"
    fi
    h_check_eq "0" "$n" "被跟踪的编译产物数量"
}
