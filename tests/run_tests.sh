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
# v2.8.1：第 8 轮（续）—— T45 日志文字纠正（**台架说错了话**）
#         · 路径 bug 未修时，「恢复失败」被误归因为系统锁 → 台架写下「连 mv 也绕不过」
#         · 修好路径后实测：Windows 上 **mv（改目录项）能替换运行中的 exe**，被挡住的只有 cp
#           → 这正好证明「必须走 mv 覆盖」，文字照实改，结论只加强不放松
# v2.8.0：第 8 轮（续）—— 负向对照质量加固（Chief 的元规则）
#         · T43/T44/T47：每条负向对照加「破坏手法生效」的**正向确认**（断言注入点命中数）
#           —— 注入点没命中 → 症状不会出现 → 断言必红 → 会被误当成产品缺陷
#         · T45/T46：函数覆盖型负向对照加「覆盖确实生效」的确认
#         · T45：新增**本机可跑的等价断言**（inode 变化 = 走「替换」而不是原地 cp 覆写）
#           —— ETXTBSY 是 Linux 内核行为，非 Linux 上那条等于没测（skip ≠ 放过）
#         · 配套：每条负向对照都要在「修复前的冻结点」上验一次是红的
# v2.7.0：第 8 轮 —— T34 加固（小编 R3-D01 交付后暴露出的两个盲区）
#         · T34 行号引用从「兜底（文件缺失 / 行号越界才红）」收紧成**硬断言：必须为 0**
#           —— 旧口径下「行号漂了但仍在文件范围内」是绿的，那正是 D-01 那类静默漂移
#         · T34 解析器扩展到**英文所有格写法**（`lib/core.sh`'s `REQUIRED_TOOLS`）
#           —— 旧正则只认中文「的」式 → README_EN.md 的引用完全不被检查
#         · 配套加「英文写法命中数 ≥ 1」护栏 → 防止「正则扩了但没匹配上」的静默退化
#         · T34 补**判定器自检**（合成探针树）：两条新断言各有一个反例，
#           断言的是「坏情况确实被检出」—— 怎么写都绿的断言等于没有断言
# v2.6.0：第 7 轮收尾（续）—— 跟随产品 N1-R1（去掉裸 host 宽键兜底）
#         · T51 展示端断言改成「旧格式记录查不到就当无记录、不跨端口污染」
#           —— 旧口径「按裸 host 兜底命中」会把同 host 另一个端口的记录显示成这条目标的
#         · T52 认不出归属时改成「当无记录」→ 那条老记录不让任何目标被判故障
#         · T52 补上 N1 真正触发的形态：同一端口组内、同 host 不同端口
#           （旧格式与新格式的产出必须逐项一致 —— 兼容不是「不报错」，是「结果相同」）
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
# v2.9.0：P1 —— T32 条件 5 的判定不再依赖宿主 locale
#         · 判据正则：中文标点字符类 [^，。；、] → `.`；窗口按**字节**放大 {0,40}→{0,120}、{0,6}→{0,30}
#           （原因：`.` 在 UTF-8 下是 1 字符、C 下是 1 字节，只换正则不钉 locale 会让窗口宽度随环境差 3 倍）
#         · 扫描 grep 与豁免 grep 钉 `LC_ALL=C` → 字节语义，判定与环境解耦
#         · 新增负向对照 7（三层）：(a) 正则层两种 locale 都必须抓到真违规行
#           (b) **扫描层**同一探针在两种 ambient locale 下判定必须相同（去掉钉子就判红）
#           (c) 扫描层真违规行在两种 ambient locale 下都必须抓到
#         · 负向对照 7 必须做在扫描层：正则层是**故意**两种 locale 各跑一遍的，
#           拿它比判定会判红自己
# v2.12.0：第 11 轮 —— T54 判定器补洞 + 判定器自检 + T53 阈值改相对判据
#         · T54 判定器三处洞（组合盲区 / || 豁免面过宽 / 循环定位靠缩进+魔数）：
#           静态③「含输入读入」独立于静态②的豁免面（含 read -n / read -rt）；
#           静态②的 || 豁免改精确匹配（只放行 || VAR="" / || exit N，|| true 必须报）；
#           静态③循环定位改 do/done 词计数配对（配对失败 fail-closed 报出），
#           sleep 位置改「循环体内任意位置」（去掉「前 6 行」魔数）
#         · 新增「判定器自检」：6 个合成探针，各自独立目录，如实标注「合成探针，
#           不是历史实现」—— 判定器自身也要被负向对照覆盖，否则没人知道它判不判
#         · T54 追加不变式：ui_read_default 的调用点不得传非空默认值
#         · T53 负向对照的字节阈值改**相对判据**（bytes_old >= 20 x bytes_new，
#           绝对兜底 1024）：原绝对阈值落在实测散布中间 → 约 40% 概率假红
#           （审稿 §7.4 独立复现：同机同码连跑 5 次 = 108759 / 48246 / 34214 /
#           32460 / 82449 字节）。与速率无关的强证据 rc_old == 124 保持不动
# v2.11.0：第 10 轮 —— T54 交互读入 EOF 收口的不变式
#         · 静态四层（判据跑在冻结态 $SBX_SRC 上，不读工作区）：
#           ① UI helper 的**份数**（恰为 4：lib/core.sh + 3 个独立脚本）与**逐字一致性**
#              （sha256 相同）—— 独立脚本是独立安装单元、拿不到 lib/，
#              「一份实现」只能是「四份逐字一致的拷贝」→ 漂移必须判红
#           ② 不存在「无 EOF 处理的用户输入读入」（裸 read / 裸 read -p）
#           ③ 每个含输入读入的 while 循环都有 sleep 0.2 兜底
#           ④ 不存在裸 clear（必须走 ui_clear）
#         · 运行时层：ui_read_default 的契约 —— 读到 EOF → 取默认值 + **不终止调用方**
#           （与 ui_read_into 的「EOF 一律退出」刻意不同：安装流程里 EOF 是常态）
#         · 负向对照 (a)：静态四层用**真实修复前实现**（修复前冻结点的产品文件树）
#           跑同一套判定器 → 必须抓到违规（坏情况确实发生）
#         · 负向对照 (b)：运行时层是注入式退化（ui_read_default 新引入，修复前无等价形态）
# v2.10.0：第 9 轮 —— T53 交互菜单 EOF 忙循环护栏
#         · 第一层 · helper 契约：读到 EOF 时 helper 必须**终止调用方**（4 处实现：
#           lib/core.sh + 3 个独立脚本各内置一份）—— 判据用**哨兵**（调用后打印的
#           AFTER-CALLBACK-SENTINEL 不出现），**不能断退出码**：helper 坏掉时脚本
#           会继续往下跑、照样 rc=0 → 恒绿。这层不能省：入口的 ui_require_tty 护栏
#           会先 exit，走不到 helper —— 只测入口的话，把 helper 回退/删掉都抓不到。
#         · 第二层 · 入口端到端：菜单入口在 stdin 非终端（EOF）下必须**自己**退出：
#           不得忙循环、不得无界输出（真机事故：旧实现 5.7 小时灌满 479MB tmpfs →
#           内存+swap 耗尽 → sshd 握不上手）。三腿断言：① 超时前自己退出（≠124）
#           ② 输出字节数有上限 ③ 退出码 0
#         · 防空过护栏：输出必须命中入口标志（入口提示语**或**菜单标题 —— 两种机制都算，
#           只钉行为不钉实现）且输出非空，否则「根本没进菜单 → 立刻退出」会让三条恒绿
#         · 负向对照：helper 层用注入式退化（helper 是新引入的，修复前没有等价形态，
#           如实标注）；入口层用**真实修复前实现**（d0366b3 的 lib/）复现忙循环，
#           断言的是「坏情况确实发生」（124 + 输出膨胀），不是「坏情况没发生」
HARNESS_VERSION="v2.12.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t54-ui-eof-closure-invariants + t54-judge-selfcheck + t53-rel-threshold)"

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
    # —— 第 9 轮：交互菜单 EOF 忙循环护栏 ——
    "T53:case_T53_menu_eof_no_busy_loop"
    # —— 第 10 轮：交互读入 EOF 收口的不变式 ——
    "T54:case_T54_ui_eof_closure_invariants"
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
