#!/bin/bash
# 用例组 07 · 提交信息契约（第 5 轮新增）
#
# 背景：第 1 轮出现过「另三套脚本全绿、正式入口 run_tests.sh 16/22 红」，
# 提交信息却写「全过」。第 2 轮把这件事做成了**打印告警**（跑批末尾提示），
# 但告警拦不住任何人 —— 第 5 轮把它升级为**可失败的硬断言**（T40）。
#
# ★ 判定规则（对最近 N 条提交信息，N = $COMMIT_CHECK_N，默认 20，锚定 BASE_SHA）
#   1) 命中「声称全过」词表 → 才进入判定；没命中一律放行
#      （不要求每个提交都报测试结果，只要求「声称了」的必须站得住）
#   2) 声称全过的提交必须同时给出：
#      a) 唯一入口引用：出现 run_tests.sh
#      b) 实测口径：BASE_SHA（7~40 位十六进制）/ 汇总行 / 用例总数 / 退出码（任一即可）
#      缺 a 或缺 b → **违规**（用例失败），并打印：哪条提交、命中了哪个词、缺了什么
#   3) 旧格式容忍：a、b 都在但缺 BASE_SHA → 判过，只记一条提示。
#      历史提交里确实存在「只写『22 条通过』没写 SHA」的合法旧格式，不追溯重写历史。
#   4) 自动豁免：该提交的树里还没有 tests/run_tests.sh（唯一入口当时尚不存在）
#      → 不追溯要求（台架是在这些提交之后才有的）
#   5) 过渡白名单：tests/commit-msg-exemptions.txt，最多 3 条，每条必须写明理由。
#
# ★ 反例自检：用例内构造**内存里的**假提交信息（**不产生任何真实提交**），
#   确认这套判定抓得住坏消息、放得过好消息 —— 规则本身也要被测。
#   这是「怎么写都绿」的断言防护：没有自检的判定器 = 没人知道它到底判不判。

# 「声称全过」词表
#   - 全过 / 全部通过 / 全通过 / 都通过 / 全绿 / 测试通过 / 用例通过 / 断言全过 / 场景全过
#   - 「失败 0」也算（汇总行「总计 N 条，通过 N，失败 0」就是全过的另一种写法）
#   - 「N/M 通过」「N 条…通过」也算（只写用例总数的旧格式）
#   - all tests passed / tests passed
CM_CLAIM_RE='全过|全部通过|全通过|都通过|全绿|测试通过|用例通过|断言全过|场景全过|失败[[:space:]]*0|[0-9]+[[:space:]]*/[[:space:]]*[0-9]+[[:space:]]*通过|[0-9]+[[:space:]]*条[^，。；]{0,6}通过|all[[:space:]-]+tests?[[:space:]-]+passed|tests?[[:space:]-]+passed'

CM_EXEMPT_FILE=""     # 白名单文件路径
CM_EXEMPT_LIST=""     # 每行 "<sha>|<理由>"
CM_EXEMPT_COUNT=0     # 白名单条目数
CM_EXEMPT_NOREASON=0  # 没写理由的条目数
CM_EXEMPT_NOTFOUND=0  # 仓库里解析不到的条目数

# _cm_evaluate <提交信息>
#   输出 "<状态>|<明细>"
#   NOCLAIM 未声称全过 → 放行
#   OK      声称全过，且引用唯一入口 + 给出实测口径（含冻结点 SHA）
#   OLD     声称全过，引用唯一入口 + 给出实测口径，但缺冻结点 SHA（旧格式，容忍）
#   BAD     声称全过，但缺唯一入口 或 缺实测口径 → 违规
_cm_evaluate() {
    local msg="$1"
    local claim="" has_entry=0 has_sha=0 has_summary=0 has_count=0 has_exit=0 caliber=0 missing=""

    claim=$(printf '%s\n' "$msg" | grep -oE "$CM_CLAIM_RE" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -z "$claim" ] && { printf 'NOCLAIM|未声称全过'; return 0; }

    printf '%s' "$msg" | grep -q 'run_tests\.sh' && has_entry=1
    printf '%s' "$msg" | grep -qE '\b[0-9a-f]{7,40}\b' && has_sha=1
    printf '%s' "$msg" | grep -qE '汇总|总计' && has_summary=1
    printf '%s' "$msg" | grep -qE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+|[0-9]+[[:space:]]*条' && has_count=1
    printf '%s' "$msg" | grep -qiE 'exit( code)?[ ]*0|退出码[ ]*[:=]?[ ]*0' && has_exit=1
    if [ "$has_sha" = 1 ] || [ "$has_summary" = 1 ] || [ "$has_count" = 1 ] || [ "$has_exit" = 1 ]; then
        caliber=1
    fi

    [ "$has_entry" = 1 ] || missing="缺唯一入口引用 tests/run_tests.sh"
    if [ "$caliber" = 0 ]; then
        [ -n "$missing" ] && missing="$missing；"
        missing="${missing}缺实测口径（BASE_SHA / 汇总行 / 用例总数 / 退出码）"
    fi

    if [ "$has_entry" = 1 ] && [ "$caliber" = 1 ]; then
        if [ "$has_sha" = 1 ]; then
            printf 'OK|引用唯一入口+含冻结点SHA｜claim=[%s]' "$claim"
        else
            printf 'OLD|引用唯一入口+口径但缺冻结点SHA（旧格式，容忍）｜claim=[%s]' "$claim"
        fi
        return 0
    fi
    printf 'BAD|%s｜claim=[%s]' "$missing" "$claim"
}

# 该提交的树里有没有唯一入口（台架本身是后加的，早期提交没有 → 不追溯要求）
_cm_has_entry() {
    git cat-file -e "$1:tests/run_tests.sh" 2>/dev/null
}

# 读白名单：格式 "<sha>|<理由>"，空行与 # 开头为注释
_cm_load_exemptions() {
    CM_EXEMPT_FILE="$SBX_REPO/tests/commit-msg-exemptions.txt"
    CM_EXEMPT_LIST=""
    CM_EXEMPT_COUNT=0
    CM_EXEMPT_NOREASON=0
    CM_EXEMPT_NOTFOUND=0
    [ -f "$CM_EXEMPT_FILE" ] || return 0

    local line sha reason
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        sha="${line%%|*}"
        reason="${line#*|}"
        sha="$(printf '%s' "$sha" | tr -d '[:space:]')"
        reason="$(printf '%s' "$reason" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        # 没写 "|" 或者理由为空 → 理由缺失
        if [ "$reason" = "$line" ] || [ -z "$reason" ]; then
            CM_EXEMPT_NOREASON=$((CM_EXEMPT_NOREASON + 1))
            continue
        fi
        CM_EXEMPT_LIST="$CM_EXEMPT_LIST$sha|$reason"$'\n'
        CM_EXEMPT_COUNT=$((CM_EXEMPT_COUNT + 1))
        # 白名单里的 sha 必须能在仓库里解析到提交（写错 sha = 豁免根本没生效）
        git cat-file -e "$sha^{commit}" 2>/dev/null || CM_EXEMPT_NOTFOUND=$((CM_EXEMPT_NOTFOUND + 1))
    done < "$CM_EXEMPT_FILE"
}

# 该 sha 是否在白名单里（按前缀匹配，短 sha 也能命中）
_cm_is_exempt() {
    local sha="$1" line ex
    [ -z "$CM_EXEMPT_LIST" ] && return 1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ex="${line%%|*}"
        [ -z "$ex" ] && continue
        case "$sha" in
            "$ex"*) return 0 ;;
        esac
    done <<< "$CM_EXEMPT_LIST"
    return 1
}

_cm_exempt_reason() {
    local sha="$1" line ex
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ex="${line%%|*}"
        case "$sha" in
            "$ex"*) printf '%s' "${line#*|}"; return 0 ;;
        esac
    done <<< "$CM_EXEMPT_LIST"
    return 1
}

# ── 用例总数一致性（Chief 10/24 派单）────────────────────────────
#   规则：提交信息里**引用了**「总计 N 条」时，N 必须等于**该冻结点** `--list`
#   的实际条数。引用错条数 = 拿旧台架的数字冒充新台架的结果 → 判红。
#
#   ★ 作用域：只对**候选范围最后一笔**（= BASE_SHA 那一笔）生效，
#     不回溯历史 —— 历史提交当时的条数与今天不同，回溯会把历史全判红。
#   ★ 「该冻结点的实际条数」怎么算：
#     从冻结态 `git show <sha>:tests/run_tests.sh` 的 **CASES 登记表**数条目
#     —— 这与 `--list` 打印的条数是同一个来源（stdout 每条登记 ID 一行）。
#     不去 checkout 旧树、也不跑旧台架（那会改工作区 / 触发副作用）。
#   ★ 不声明条数的提交信息：不判红（没有可核对的东西），但记一条提示。
#
# 从提交信息里抽出「用例总数」的声明值
# 用法：_cm_claimed_case_count <提交信息>
# 输出：单个数字 / 空串（没声明）/ "AMBIG:<数字列表>"（声明了多个不同数字）
_cm_claimed_case_count() {
    local msg="$1" nums
    nums=$(printf '%s\n' "$msg" \
        | grep -aoE '(总计|用例总数[^0-9]{0,8})[[:space:]]*[0-9]+[[:space:]]*条|[0-9]+[[:space:]]*条用例' \
        | grep -aoE '[0-9]+' | sort -u | tr '\n' ' ')
    nums=$(printf '%s' "$nums" | tr -s ' ' | sed 's/^ //; s/ $//')
    case "$nums" in
        '') printf '' ;;
        *' '*) printf 'AMBIG:%s' "$nums" ;;
        *) printf '%s' "$nums" ;;
    esac
}

# 该冻结点的实际用例条数（CASES 登记表条目数）
_cm_frozen_case_count() {
    local sha="$1" raw n
    raw=$(cd "$SBX_REPO" && git show "$sha:tests/run_tests.sh" 2>/dev/null)
    [ -z "$raw" ] && { printf ''; return 0; }
    n=$(printf '%s\n' "$raw" | grep -cE '^[[:space:]]*"T[0-9]{2}:case_')
    printf '%s' "$n"
}

case_T40_commit_message_contract() {
    h_case_begin "T40" "提交信息声称全过必须引用唯一入口实测口径" \
        "仓库提交历史（扫描窗口 \$COMMIT_CHECK_N，默认 20 条，锚定 BASE_SHA）" \
        "git log -N --format=%B <BASE_SHA> → 命中「声称全过」词表后校验引用" \
        "声称全过的提交必须引用 tests/run_tests.sh + 实测口径（BASE_SHA/汇总行/用例总数/退出码）；违规 0 条"

    local n="${COMMIT_CHECK_N:-20}"
    case "$n" in
        ''|*[!0-9]*) n=20 ;;
    esac
    [ "$n" -lt 1 ] && n=20
    h_log "扫描窗口: 最近 $n 条提交（环境变量 COMMIT_CHECK_N 可调）"

    # ── 白名单：上限 3 条，每条必须写明理由，每条 sha 必须能解析 ──
    _cm_load_exemptions
    h_log "白名单文件: $CM_EXEMPT_FILE（条目 $CM_EXEMPT_COUNT 条）"
    if [ "$CM_EXEMPT_COUNT" -gt 0 ]; then
        local wline
        while IFS= read -r wline; do
            [ -z "$wline" ] && continue
            h_log "  豁免: ${wline%%|*} ← ${wline#*|}"
        done <<< "$CM_EXEMPT_LIST"
    fi
    h_check_le 3 "$CM_EXEMPT_COUNT" "过渡白名单条目数（上限 3 条）"
    h_check_eq "0" "$CM_EXEMPT_NOREASON" "白名单里没写豁免理由的条目数"
    h_check_eq "0" "$CM_EXEMPT_NOTFOUND" "白名单里解析不到提交的 sha 条数"

    # ── 反例自检：内存里的假提交信息，不产生任何真实提交 ──
    local sc_msg sc_res sc_status sc_detail
    local sc_bad_noclaim_ok=0 sc_bad_nocaliber=0 sc_bad_otherentry=0
    local sc_good_noclaim_ok=0 sc_good_full_ok=0 sc_good_exit_ok=0

    # (1) 声称全过、什么都不引用 → 必须抓
    sc_msg="fix(x): 修好了某个行为

测试全过"
    sc_res=$(_cm_evaluate "$sc_msg"); sc_status="${sc_res%%|*}"
    [ "$sc_status" = "BAD" ] && sc_bad_noclaim_ok=1
    h_check_eq "BAD" "$sc_status" "反例自检①：只写「测试全过」不引用任何口径 → 判定为违规"

    # (2) 引用了唯一入口、但没给任何实测口径 → 必须抓
    sc_msg="fix(x): 修好了某个行为

测试全过（bash tests/run_tests.sh）"
    sc_res=$(_cm_evaluate "$sc_msg"); sc_status="${sc_res%%|*}"; sc_detail="${sc_res#*|}"
    [ "$sc_status" = "BAD" ] && sc_bad_nocaliber=1
    h_check_eq "BAD" "$sc_status" "反例自检②：引用唯一入口但无实测口径 → 判定为违规"
    h_check_contains "$sc_detail" "实测口径" "反例自检②的缺失项写对了"

    # (3) 引用了**别的**脚本的 PASS 计数 → 必须抓（第 1 轮的事故原型）
    sc_msg="fix(x): 修好了某个行为

验证：tests/test_latency.sh 33 项断言全过"
    sc_res=$(_cm_evaluate "$sc_msg"); sc_status="${sc_res%%|*}"
    [ "$sc_status" = "BAD" ] && sc_bad_otherentry=1
    h_check_eq "BAD" "$sc_status" "反例自检③：引用非唯一入口的 PASS 计数 → 判定为违规"

    # (4) 没有声称 → 必须放行
    sc_msg="feat(x): 新增一个功能，未触及测试逻辑"
    sc_res=$(_cm_evaluate "$sc_msg"); sc_status="${sc_res%%|*}"
    [ "$sc_status" = "NOCLAIM" ] && sc_good_noclaim_ok=1
    h_check_eq "NOCLAIM" "$sc_status" "反例自检④：未声称全过 → 放行"

    # (5) 完整口径（唯一入口 + 冻结点 SHA + 汇总行）→ 必须放行
    sc_msg="fix(x): 修好了某个行为

测试全过
自测：tests/run_tests.sh @60070e8
汇总: 总计 40 条，通过 40，失败 0"
    sc_res=$(_cm_evaluate "$sc_msg"); sc_status="${sc_res%%|*}"
    [ "$sc_status" = "OK" ] && sc_good_full_ok=1
    h_check_eq "OK" "$sc_status" "反例自检⑤：唯一入口+冻结点SHA+汇总行 → 放行"

    # (6) 只有冻结点 SHA + 退出码（没有汇总行）→ 也必须放行
    sc_msg="fix(x): 修好了某个行为

测试全过；自测：tests/run_tests.sh @60070e8；退出码 0"
    sc_res=$(_cm_evaluate "$sc_msg"); sc_status="${sc_res%%|*}"
    [ "$sc_status" = "OK" ] && sc_good_exit_ok=1
    h_check_eq "OK" "$sc_status" "反例自检⑥：唯一入口+冻结点SHA+退出码 → 放行"

    # 自检本身也做一次「抓到/放过」的计数护栏（防空过）
    local sc_caught=$((sc_bad_noclaim_ok + sc_bad_nocaliber + sc_bad_otherentry))
    local sc_passed=$((sc_good_noclaim_ok + sc_good_full_ok + sc_good_exit_ok))
    h_check_eq "3" "$sc_caught" "反例自检：应抓住的坏提交信息条数"
    h_check_eq "3" "$sc_passed" "反例自检：应放过的好提交信息条数"

    # ── 真数据：扫描提交历史 ──
    local sha short subj msg verdict status detail
    local scanned=0 noclaim=0 claims=0 okclaim=0 oldfmt=0 autoexempt=0 exempted=0 bad=0
    local badlist="" used_exempt=""
    while IFS= read -r sha; do
        [ -z "$sha" ] && continue
        scanned=$((scanned + 1))
        short=$(printf '%s' "$sha" | cut -c1-8)
        subj=$(git log -1 --format='%s' "$sha" 2>/dev/null)
        msg=$(git log -1 --format='%B' "$sha" 2>/dev/null | tr -d '\r')
        [ -z "$msg" ] && continue

        verdict=$(_cm_evaluate "$msg")
        status="${verdict%%|*}"
        detail="${verdict#*|}"

        if [ "$status" = "NOCLAIM" ]; then
            noclaim=$((noclaim + 1))
            continue
        fi

        claims=$((claims + 1))

        # 自动豁免：唯一入口在该提交的树里还不存在 → 不追溯要求
        if ! _cm_has_entry "$sha"; then
            autoexempt=$((autoexempt + 1))
            h_log "自动豁免（唯一入口当时不存在）: $short $subj"
            continue
        fi

        case "$status" in
            OK)
                okclaim=$((okclaim + 1))
                h_log "合规: $short $subj"
                ;;
            OLD)
                oldfmt=$((oldfmt + 1))
                h_log "旧格式（容忍，仅提示 · 建议补冻结点 SHA）: $short $subj"
                ;;
            BAD)
                if _cm_is_exempt "$sha"; then
                    exempted=$((exempted + 1))
                    used_exempt="$used_exempt$(printf '%s' "$sha" | cut -c1-8) "
                    h_log "白名单豁免: $short $subj | $detail | 理由: $(_cm_exempt_reason "$sha")"
                else
                    bad=$((bad + 1))
                    badlist="$badlist  - $short $subj"$'\n'"      $detail"$'\n'
                fi
                ;;
        esac
    done < <(git log -"$n" --format='%H' "$BASE_SHA" 2>/dev/null)

    h_log "扫描 $scanned 条：未声称 $noclaim，声称全过 $claims（合规 $okclaim，旧格式 $oldfmt，自动豁免 $autoexempt，白名单豁免 $exempted，违规 $bad）"

    # 失效的白名单条目提示：扫描窗口会随历史往前滑，历史提交滑出窗口后，
    # 对应条目就成了「占着额度不干活」—— 提示删掉，把额度留给真正需要的条目。
    if [ -n "$CM_EXEMPT_LIST" ]; then
        local wline wexa used=0
        while IFS= read -r wline; do
            [ -z "$wline" ] && continue
            wexa="${wline%%|*}"
            case "$used_exempt" in
                *"$(printf '%s' "$wexa" | cut -c1-8) "*) used=1 ;;
            esac
            if [ "$used" = "0" ]; then
                h_log "白名单条目本轮未被用到（对应提交已滑出扫描窗口或已合规）：${wexa%%|*} ← 建议删掉，把额度留给真正需要的条目"
            fi
            used=0
        done <<< "$CM_EXEMPT_LIST"
    fi

    if [ -n "$badlist" ]; then
        h_log "违规明细（哪条提交 / 命中了哪个词 / 缺了什么）:"
        while IFS= read -r l; do h_log "$l"; done <<< "$badlist"
        h_log "补法：提交信息里写清「自测 tests/run_tests.sh @<BASE_SHA>」+「汇总: 总计 N 条，通过 N，失败 0」（或退出码）"
    fi

    h_check_eq "0" "$bad" "声称全过却没引用唯一入口实测口径的提交数"

    # ── 用例总数一致性（Chief 10/24 派单）──────────────────────
    #   规则：候选范围**最后一笔**（= BASE_SHA 那一笔）的提交信息里若引用了
    #   「总计 N 条」，N 必须等于**该冻结点** `--list` 的实际条数。
    #   引用错条数 = 拿旧台架的数字冒充新台架的结果 → 判红。
    #   ★ 不回溯历史：历史提交当时的条数与今天不同，回溯会把历史全判红。
    local tip_msg tip_claimed actual_n
    tip_msg=$(git log -1 --format='%B' "$BASE_SHA" 2>/dev/null | tr -d '\r')
    tip_claimed=$(_cm_claimed_case_count "$tip_msg")
    actual_n=$(_cm_frozen_case_count "$BASE_SHA")
    if [ -z "$actual_n" ]; then
        h_fail "取不到该冻结点的用例条数（$BASE_SHA 的 tests/run_tests.sh 读不出来）—— 判据无法成立"
    elif [ -z "$tip_claimed" ]; then
        h_log "候选最后一笔没有引用「用例总数」→ 本条不适用（引用时必须与 --list 实测条数一致）"
    elif [ "${tip_claimed#AMBIG:}" != "$tip_claimed" ]; then
        h_fail "候选最后一笔引用了多个不同的用例总数（$tip_claimed）—— 口径不自洽"
    else
        h_log "候选最后一笔引用「总计 ${tip_claimed} 条」；该冻结点 --list 实际 ${actual_n} 条"
        h_check_eq "$actual_n" "$tip_claimed" "候选最后一笔引用的用例总数 == 该冻结点 --list 的实际条数"
    fi

    # 判定器自检（负向对照）：声明一个错的条数 → 必须能被判红
    local selfchk selfdiff
    selfchk=$(_cm_claimed_case_count "自测：汇总: 总计 999 条，通过 999，失败 0")
    h_check_eq "999" "$selfchk" "判定器自检：能从提交信息里抽出声明的用例总数"
    if [ -n "$actual_n" ]; then
        selfdiff=$([ "$selfchk" != "$actual_n" ] && echo 1 || echo 0)
        h_check_eq "1" "$selfdiff" "判定器自检：条数不符（999 vs 实际 $actual_n）必须能判红"
    fi

    # 扫描窗口本身要有效（防止 BASE_SHA 不存在之类导致 0 条扫描假绿）
    h_check_ge 1 "$scanned" "实际扫描到的提交条数"
}
