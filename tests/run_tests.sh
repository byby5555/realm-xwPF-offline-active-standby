#!/bin/bash
# realm-xwPF-offline-active-standby · 测试台架主入口（唯一入口）
#
# 用法：
#   bash tests/run_tests.sh                       # 跑全部用例
#   bash tests/run_tests.sh --only T01,T02        # 只跑指定用例
#   bash tests/run_tests.sh --repeat 3            # 连跑 3 轮，校验结果一致
#   bash tests/run_tests.sh --list                # 列出用例
#   bash tests/run_tests.sh --clean               # 跑完删掉沙箱
#   BASE_SHA=a9102c1 bash tests/run_tests.sh      # 指定冻结点（推荐）
#   bash tests/run_tests.sh --base-sha a9102c1    # 同上
#
# ★ 冻结点机制（第 2 轮起）
#   被测产物一律来自 `git show $BASE_SHA:<path>`，**不读工作区文件**。
#   仓库多人并行改动，工作区随时在变 —— 读工作区就会出现「第 1 轮红、后 2 轮绿」的假抖动。
#   BASE_SHA 默认取当前 HEAD；正式跑批请显式指定，报告里必须写上这个 SHA。
#   SHA 一变，旧结论全部作废，必须重跑。
#
# 退出码：全部通过 0；存在失败 非 0。
#
# 台架约定见 tests/TEST-HARNESS.md。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 台架版本：台架自身的改动会让旧报告的结论打折，改了台架就 bump
# v2.5.0：第 7 轮收尾 —— 跟随产品口径变更（健康状态 TARGET 改 host:port）
#         · T51 状态记录定位改成**格式无关**（host / host:port 都能定位）
#           —— 记录定位写死旧格式 → 产品改口径就整组用例替产品背锅
#         · T51 补「同 host 不同端口必须查不到」的负向对照
#         · 健康状态 fixture（_write_health）改写**当前格式**（host:port）
#           —— 旧格式 fixture 会让用例退化成「旧格式兼容兜底分支」，精确索引主路径无人覆盖
#         · 新增 T52：同 host 不同端口互不覆盖（写侧 + 读侧）+ 旧格式兼容 + 3 条负向对照
# v2.4.0：第 7 轮 —— 补覆盖盲区
#         · T32 条件 4 改成**形态无关**（形态 A 内嵌 / 形态 B source 真源都判过）
#         · T32 条件 5 正则收紧（只匹配肯定误导句式 + 整行否定词豁免 + 扫描范围下限护栏）
#         · 新增 T43~T47（更新中心）、T48（OCR 导入）、T49（jq 配置生成）、
#           T50（规则落盘格式）、T51（时延，原 test_latency.sh 并入）
#         · tests/test_update.sh、tests/test_latency.sh 改薄封装（消除第二入口）
#         · jq 桩扩能力：数组下标路径、-e 退出码语义、JSON 对象字面量；
#           并把 `..` 这类「会被静默误解」的语法显式判为不支持
HARNESS_VERSION="v2.5.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport)"

# shellcheck source=lib/harness.sh
. "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=lib/sandbox.sh
. "$SCRIPT_DIR/lib/sandbox.sh"

ONLY=""
REPEAT=1
CLEAN=0
LIST=0
BASE_SHA="${BASE_SHA:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            ONLY="${2:-}"
            shift 2
            ;;
        --repeat)
            REPEAT="${2:-1}"
            shift 2
            ;;
        --base-sha)
            BASE_SHA="${2:-}"
            shift 2
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --list)
            LIST=1
            shift
            ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 2
            ;;
    esac
done

# 冻结点解析与校验：SHA 不存在就直接停，不要退化成"读工作区"
if [ -z "$BASE_SHA" ]; then
    BASE_SHA="$(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null)"
fi
if ! (cd "$REPO_ROOT" && git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null); then
    echo "错误: 冻结点不存在: $BASE_SHA" >&2
    echo "      用 git log --oneline -10 查可用 SHA，或用 --base-sha 指定" >&2
    exit 2
fi
BASE_SHA="$(cd "$REPO_ROOT" && git rev-parse "$BASE_SHA" 2>/dev/null)"

# 用例登记表：编号:函数名
CASES=(
    "T01:case_T01_download_urls"
    "T02:case_T02_old_repo_name"
    "T03:case_T03_eol"
    "T04:case_T04_xwpf_help_static"
    "T05:case_T05_failover_help_vs_docs"
    "T06:case_T06_devtcp_fallback"
    "T07:case_T07_docs_claim_missing_test"
    "T08:case_T08_docs_claim_missing_source"
    "T09:case_T09_tracked_pyc"
    "T10:case_T10_weight_valid"
    "T11:case_T11_weight_all_zero"
    "T12:case_T12_weight_count_mismatch"
    "T13:case_T13_weight_range"
    "T14:case_T14_active_standby_rule_state"
    "T15:case_T15_weights_contain_zero"
    "T16:case_T16_health_timer_start"
    "T17:case_T17_health_unit_consistency"
    "T18:case_T18_no_nc_fallback"
    "T19:case_T19_active_standby_flip"
    "T20:case_T20_bootstrap_offline"
    "T21:case_T21_xwpf_help_runtime"
    "T22:case_T22_crlf_install_artifact"
    # —— 第 2 轮：从原 4 套独立脚本并入的用例 ——
    "T23:case_T23_auto_standby_multi_rule"
    "T24:case_T24_priority_primary_selection"
    "T25:case_T25_back_to_roundrobin"
    "T26:case_T26_probe_source_behavior"
    "T27:case_T27_probe_generated_copy_behavior"
    "T28:case_T28_two_probe_copies_identical"
    "T29:case_T29_active_standby_six_states"
    "T30:case_T30_exclude_mode_five_states"
    "T31:case_T31_set_u_robustness"
    "T32:case_T32_single_probe_implementation"
    "T33:case_T33_missing_optional_field_set_u"
    # —— 第 3 轮：文档源码引用一致性 ——
    "T34:case_T34_docs_source_refs"
    # —— 第 4 轮：M1/M2/M5/M7/M8 的行为回归 ——
    "T35:case_T35_rule_parse_no_exec"
    "T36:case_T36_enter_standby_clears_target_states"
    "T37:case_T37_health_start_failure_rollback"
    "T38:case_T38_prev_balance_mode_restore"
    "T39:case_T39_active_standby_confirm"
    # —— 第 5 轮：提交信息契约（声称全过必须引用唯一入口实测口径）——
    "T40:case_T40_commit_message_contract"
    # —— 第 6 轮：主备语义（只有一个主）与权重落盘索引 ——
    "T41:case_T41_weight_writeback_index"
    "T42:case_T42_priority_single_primary"
    # —— 第 7 轮：补覆盖盲区（更新中心 / OCR / jq / 规则落盘 / 时延）——
    "T43:case_T43_version_normalize_and_uptodate"
    "T44:case_T44_refuse_on_failed_verification"
    "T45:case_T45_restore_backup_robust"
    "T46:case_T46_auto_rollback_on_start_failure"
    "T47:case_T47_scripts_update_and_lock"
    # —— 第 7 轮：补覆盖盲区（OCR 导入 / jq 配置生成 / 规则落盘 / 时延）——
    "T48:case_T48_ocr_import_chain"
    "T49:case_T49_jq_config_generation"
    "T50:case_T50_rule_crud_persistence"
    "T51:case_T51_latency_merged"
    # —— 第 7 轮收尾：健康状态 TARGET 口径（host:port）——
    "T52:case_T52_health_target_scope"
)

for f in "$SCRIPT_DIR"/cases/*.sh; do
    # shellcheck source=/dev/null
    . "$f"
done

if [ "$LIST" = "1" ]; then
    for c in "${CASES[@]}"; do
        echo "${c%%:*}"
    done
    exit 0
fi

selected_cases() {
    local c
    for c in "${CASES[@]}"; do
        local id="${c%%:*}"
        if [ -z "$ONLY" ]; then
            echo "$c"
        else
            case ",$ONLY," in
                *",$id,"*) echo "$c" ;;
            esac
        fi
    done
}

banner() {
    local dirty
    dirty=$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | tr '\n' ';')
    echo "=============================================================="
    echo " realm-xwPF-offline-active-standby · 测试台架（唯一入口）"
    echo "=============================================================="
    echo "仓库        : $REPO_ROOT"
    echo "★ 冻结点    : $BASE_SHA"
    echo "  冻结点标题: $(cd "$REPO_ROOT" && git log -1 --format='%ad %s' "$BASE_SHA" 2>/dev/null)"
    echo "  当前 HEAD : $(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null)（仅供对照，不作为被测产物）"
    echo "  台架版本  : $HARNESS_VERSION"
    echo "  产物来源  : git show \$BASE_SHA:<path>（不读工作区）"
    echo "工作区改动  : ${dirty:-（干净）}"
    echo "bash        : $BASH_VERSION"
    echo "沙箱根目录  : $SBX_ROOT"
    echo "冻结态原始  : $SBX_RAW（git show 原始字节）"
    echo "LF 副本     : $SBX_SRC"
    echo "执行副本    : $SBX_RUN（= LF 副本 + 路径重定向 + root 模拟）"
    echo "假 bin      : $SBX_BIN （nc 单独放 $SBX_BIN_NC，默认不进 PATH）"
    echo "离线镜像    : $SBX_MIRROR"
    echo "桩清单      : $(cd "$REPO_ROOT/tests/shims" && ls | tr '\n' ' ')"
    echo "路径重定向  :"
    local entry
    for entry in "${SBX_PATH_MAP[@]}"; do
        echo "               ${entry%%|*}  →  \${SBX}/$(printf '%s' "${entry##*|}" | tr '.' '.')"
    done
    echo "越界残留    : $(sbx_escape_scan | wc -l | tr -d ' ') 处真实系统绝对路径（只读白名单除外）"
    sbx_escape_scan | head -8 | while IFS= read -r l; do echo "               $l"; done
    echo "=============================================================="
}

# 跑一条用例，返回 0/1，并写入结果数组
run_one() {
    local id="$1" fn="$2"
    local out rc nfail actual

    RUNNER_CASE_ID="$id"
    out=$( ( set +e; "$fn" ) 2>&1 )
    rc=$?
    printf '%s\n' "$out" > "$SBX_ROOT/cases/$id.stdout"

    nfail=0
    actual=""
    if [ -s "$SBX_ROOT/cases/$id.fails" ]; then
        nfail=$(grep -c . "$SBX_ROOT/cases/$id.fails")
        actual=$(head -1 "$SBX_ROOT/cases/$id.fails")
    elif [ -s "$SBX_ROOT/cases/$id.notes" ]; then
        actual=$(tail -1 "$SBX_ROOT/cases/$id.notes")
    else
        actual="用例没有产生任何断言记录（疑似提前退出）"
        nfail=1
    fi

    if [ "$rc" != "0" ] && [ "$nfail" = "0" ]; then
        actual="用例函数返回码 $rc；尾部输出: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
        nfail=1
    fi

    RESULT_IDS+=("$id")
    RESULT_TITLES+=("$(awk -F'\t' '{print $2}' "$SBX_ROOT/cases/$id.meta" 2>/dev/null)")
    RESULT_PREREQS+=("$(awk -F'\t' '{print $3}' "$SBX_ROOT/cases/$id.meta" 2>/dev/null)")
    RESULT_CMDS+=("$(awk -F'\t' '{print $4}' "$SBX_ROOT/cases/$id.meta" 2>/dev/null)")
    RESULT_EXPECTS+=("$(awk -F'\t' '{print $5}' "$SBX_ROOT/cases/$id.meta" 2>/dev/null)")
    RESULT_ACTUALS+=("$actual")
    if [ "$nfail" = "0" ]; then
        RESULT_VERDICTS+=("PASS")
    else
        RESULT_VERDICTS+=("FAIL")
    fi
    return 0
}

RESULT_IDS=()
RESULT_TITLES=()
RESULT_PREREQS=()
RESULT_CMDS=()
RESULT_EXPECTS=()
RESULT_ACTUALS=()
RESULT_VERDICTS=()

run_round() {
    local c id fn
    RESULT_IDS=(); RESULT_TITLES=(); RESULT_PREREQS=(); RESULT_CMDS=()
    RESULT_EXPECTS=(); RESULT_ACTUALS=(); RESULT_VERDICTS=()
    for c in $(selected_cases); do
        id="${c%%:*}"
        fn="${c##*:}"
        run_one "$id" "$fn"
    done
}

vector() {
    local i out=""
    for i in "${!RESULT_IDS[@]}"; do
        out="$out${RESULT_IDS[$i]}=${RESULT_VERDICTS[$i]};"
    done
    printf '%s' "$out"
}

print_table() {
    local i
    echo
    echo "===================== 用例结果 ====================="
    printf '%-6s %-22s %-40s %-46s %-46s %-58s %s\n' "编号" "用例" "前置" "命令" "期望" "实际" "结论"
    printf '%s\n' "------------------------------------------------------------------------------------------------------------------------"
    for i in "${!RESULT_IDS[@]}"; do
        printf '%-6s %-22s %-40s %-46s %-46s %-58s %s\n' \
            "${RESULT_IDS[$i]}" \
            "$(h_trunc "${RESULT_TITLES[$i]}" 20)" \
            "$(h_trunc "${RESULT_PREREQS[$i]}" 38)" \
            "$(h_trunc "${RESULT_CMDS[$i]}" 44)" \
            "$(h_trunc "${RESULT_EXPECTS[$i]}" 44)" \
            "$(h_trunc "${RESULT_ACTUALS[$i]}" 56)" \
            "${RESULT_VERDICTS[$i]}"
    done
    echo "===================================================="
}

main() {
    sbx_init "$REPO_ROOT"
    banner

    local round vectors="" v
    for ((round = 1; round <= REPEAT; round++)); do
        echo
        echo ">>> 第 $round/$REPEAT 轮开始"
        run_round
        v="$(vector)"
        vectors="$vectors$v"$'\n'
        print_table
    done

    # 稳定性：多轮结果必须一致
    local stable="是"
    if [ "$REPEAT" -gt 1 ]; then
        local first="" other
        first=$(printf '%s' "$vectors" | grep -v '^$' | head -1)
        while IFS= read -r other; do
            [ -z "$other" ] && continue
            [ "$other" = "$first" ] || stable="否"
        done <<< "$vectors"
        echo "各轮结果向量: $(printf '%s' "$vectors" | tr '\n' ' ')"
    fi

    local pass=0 fail=0 i
    for i in "${!RESULT_VERDICTS[@]}"; do
        if [ "${RESULT_VERDICTS[$i]}" = "PASS" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
    done

    echo
    echo "汇总: 总计 $((pass + fail)) 条，通过 $pass，失败 $fail"
    echo "多轮一致性（$REPEAT 轮）: $stable"
    echo "★ 冻结点 BASE_SHA : $BASE_SHA"
    echo "★ 台架版本        : $HARNESS_VERSION"
    echo "★ 产物指纹        : $SBX_ROOT/manifest.txt"
    echo "沙箱证据目录: $SBX_ROOT/cases"
    echo "（每个用例的 stdout / notes / fails / meta 都在 $SBX_ROOT/cases/$ID.* 里）"

    # 提交信息自查（第 2 轮是「打印告警」，第 5 轮升级为硬断言 → 见用例 T40）
    # 背景：第 1 轮出现过「另三套脚本全绿、正式入口 run_tests.sh 16/22 红」，
    # 提交信息却写成「全过」。第 2 轮把它做成打印告警 —— 但告警拦不住任何人，
    # 所以第 5 轮把同一套判定搬进用例 T40：**违规就是用例失败、门禁退出码非 0**。
    # 规则、豁免白名单与自检见 tests/cases/07_commit_message_contract.sh。
    local last_subject
    last_subject=$(cd "$REPO_ROOT" && git log -1 --format='%s' 2>/dev/null)
    echo
    echo "── 提交信息自查 ─────────────────────────────────────────"
    echo "· 本台架是**唯一入口**：bash tests/run_tests.sh"
    echo "· 提交信息若声称「全过/通过/测试通过」，必须引用本入口的输出"
    echo "  （BASE_SHA + 汇总行 / 用例总数 / 退出码），不要引用其它脚本的 PASS 计数。"
    echo "· 这条不再是告警：**用例 T40 会判红**（详见上面表格里的 T40 行）。"
    echo "· 上一条提交信息: ${last_subject:-（无）}"

    if [ "$CLEAN" = "1" ]; then
        rm -rf "$SBX_ROOT"
        echo "沙箱已清理"
    fi

    [ "$fail" -eq 0 ] || return 1
    return 0
}

main "$@"
exit $?
