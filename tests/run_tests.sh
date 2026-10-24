#!/bin/bash
# realm-xwPF-offline-active-standby · 测试台架主入口
#
# 用法：
#   bash tests/run_tests.sh                 # 跑全部用例
#   bash tests/run_tests.sh --only T01,T02  # 只跑指定用例
#   bash tests/run_tests.sh --repeat 3      # 连跑 3 轮，校验结果一致
#   bash tests/run_tests.sh --list          # 列出用例
#   bash tests/run_tests.sh --clean         # 跑完删掉沙箱
#
# 退出码：全部通过 0；存在失败 非 0。
#
# 台架约定见 tests/README.md。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/harness.sh
. "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=lib/sandbox.sh
. "$SCRIPT_DIR/lib/sandbox.sh"

ONLY=""
REPEAT=1
CLEAN=0
LIST=0

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
        --clean)
            CLEAN=1
            shift
            ;;
        --list)
            LIST=1
            shift
            ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 2
            ;;
    esac
done

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
    local commit dirty
    commit=$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null)
    dirty=$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | tr '\n' ';')
    echo "=============================================================="
    echo " realm-xwPF-offline-active-standby · 测试台架"
    echo "=============================================================="
    echo "仓库        : $REPO_ROOT"
    echo "被测提交    : $commit"
    echo "工作区改动  : ${dirty:-（干净）}"
    echo "bash        : $BASH_VERSION"
    echo "沙箱根目录  : $SBX_ROOT"
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
    echo "沙箱证据目录: $SBX_ROOT/cases"
    echo "（每个用例的 stdout / notes / fails / meta 都在 $SBX_ROOT/cases/$ID.* 里）"

    if [ "$CLEAN" = "1" ]; then
        rm -rf "$SBX_ROOT"
        echo "沙箱已清理"
    fi

    [ "$fail" -eq 0 ] || return 1
    return 0
}

main "$@"
exit $?
