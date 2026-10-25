#!/bin/bash
# 测试台架 · 用例账本与断言
#
# 一条用例一个函数。函数内部只用 h_* 断言助手记录结论：
#   h_fail  记一条失败（用例判 FAIL）
#   h_pass  记一条通过观察（最后一条会作为"实际"列）
# 用例函数本身不负责退出码，退出码由账本统一汇总。

CASE_ID=""
CASE_TITLE=""
CASE_PREREQ=""
CASE_CMD=""
CASE_EXPECT=""
CASE_NOTES=""
CASE_FAILS=""
CASE_LOG=""
CASE_META=""

# ★ 已知缺陷 / 预期红标注（审稿第 18 次修订 ⑤）
#   有些用例在**当前冻结点**上就是判红的 —— 因为产品缺陷还没修（读端组合键等）。
#   这类用例必须**显式声明**，否则整批红会被误读成「台架坏了」。
#   ★ 用法：h_case_begin 之后调用 h_case_expect_fail "<理由>"
#   ★ 为什么落文件而不是全局变量：用例函数在 run_one 的**子 shell** 里跑
#     （out=$( ( set +e; "$fn" ) 2>&1 )）⇒ 子 shell 里设的全局变量传不出来。
CASE_EXPECT_FAIL=""

h_case_expect_fail() {
    CASE_EXPECT_FAIL="1"
    printf '%s\n' "$1" > "$SBX_ROOT/cases/${CASE_ID}.expect_fail"
    h_log "★ 本条在当前冻结点预期为 FAIL（已知缺陷）：$1"
}

h_case_begin() {
    # 登记表的编号优先（RUNNER_CASE_ID 由 run_tests.sh 注入），避免用例内部编号写错导致串账
    CASE_ID="${RUNNER_CASE_ID:-$1}"
    CASE_TITLE="$2"
    CASE_PREREQ="$3"
    CASE_CMD="$4"
    CASE_EXPECT="$5"
    CASE_NOTES="$SBX_ROOT/cases/$CASE_ID.notes"
    CASE_FAILS="$SBX_ROOT/cases/$CASE_ID.fails"
    CASE_LOG="$SBX_ROOT/cases/$CASE_ID.log"
    CASE_META="$SBX_ROOT/cases/$CASE_ID.meta"
    : > "$CASE_NOTES"
    : > "$CASE_FAILS"
    : > "$CASE_LOG"
    # 上一轮若声明过「预期红」，本轮没声明 ⇒ 必须清掉（否则标注会跨轮残留）
    rm -f "$SBX_ROOT/cases/$CASE_ID.expect_fail"
    printf '%s\t%s\t%s\t%s\t%s\n' "$CASE_ID" "$CASE_TITLE" "$CASE_PREREQ" "$CASE_CMD" "$CASE_EXPECT" > "$CASE_META"
}

h_log() {
    printf '%s\n' "$*" >> "$CASE_LOG"
    printf '%s\n' "$*"
}

h_pass() {
    printf '%s\n' "$1" >> "$CASE_NOTES"
}

h_fail() {
    printf '%s\n' "$1" >> "$CASE_FAILS"
    h_log "FAIL: $1"
}

# 相等断言
h_check_eq() {
    local expected="$1" actual="$2" desc="$3"
    if [ "$expected" = "$actual" ]; then
        h_pass "$desc = $actual"
        return 0
    fi
    h_fail "$desc 期望[$expected] 实际[$actual]"
    return 1
}

# 大于等于断言（用于「防空过护栏」：命中数太少说明解析器坏了，不是结论为真）
h_check_ge() {
    local floor="$1" actual="$2" desc="$3"
    if [ "$actual" -ge "$floor" ] 2>/dev/null; then
        h_pass "$desc = $actual（≥ $floor）"
        return 0
    fi
    h_fail "$desc 期望 ≥ $floor，实际 $actual"
    return 1
}

# 小于等于断言（用于「白名单不得超过 N 条」这类上限约束）
h_check_le() {
    local ceiling="$1" actual="$2" desc="$3"
    if [ "$actual" -le "$ceiling" ] 2>/dev/null; then
        h_pass "$desc = $actual（≤ $ceiling）"
        return 0
    fi
    h_fail "$desc 期望 ≤ $ceiling，实际 $actual"
    return 1
}

# 包含断言
h_check_contains() {
    local haystack="$1" needle="$2" desc="$3"
    case "$haystack" in
        *"$needle"*)
            h_pass "$desc 命中[$needle]"
            return 0
            ;;
    esac
    h_fail "$desc 未命中[$needle]（实际内容首行: $(printf '%s' "$haystack" | head -1 | cut -c1-160)）"
    return 1
}

# 不包含断言
h_check_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    case "$haystack" in
        *"$needle"*)
            h_fail "$desc 意外命中[$needle]"
            return 1
            ;;
    esac
    h_pass "$desc 未命中[$needle]"
    return 0
}

# 返回码断言：expect 为 "0" 或 "nonzero"
h_check_rc() {
    local expect="$1" actual="$2" desc="$3"
    case "$expect" in
        0)
            if [ "$actual" -eq 0 ]; then
                h_pass "$desc 返回码 0"
                return 0
            fi
            h_fail "$desc 期望返回码 0，实际 $actual"
            return 1
            ;;
        nonzero)
            if [ "$actual" -ne 0 ]; then
                h_pass "$desc 返回码非 0（$actual）"
                return 0
            fi
            h_fail "$desc 期望返回码非 0，实际 0"
            return 1
            ;;
    esac
    h_fail "$desc 未知的返回码期望: $expect"
    return 1
}

# 文件存在断言
h_check_file() {
    local path="$1" desc="$2"
    if [ -f "$path" ]; then
        h_pass "$desc 存在 ($(basename "$path"))"
        return 0
    fi
    h_fail "$desc 缺失: $path"
    return 1
}

# 文件内容包含断言
h_check_file_has() {
    local path="$1" needle="$2" desc="$3"
    if [ ! -f "$path" ]; then
        h_fail "$desc 文件缺失: $path"
        return 1
    fi
    if grep -qF -- "$needle" "$path"; then
        h_pass "$desc 命中[$needle]"
        return 0
    fi
    h_fail "$desc 未命中[$needle] in $(basename "$path")"
    return 1
}

# 表格用：把多行压成一行、截断
h_oneline() {
    printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | cut -c1-"${2:-80}"
}

h_trunc() {
    printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | cut -c1-"${2:-80}"
}

# 干净的行数统计：grep -c 没命中时会同时输出 "0" 和退出码 1，
# 用 `|| echo 0` 会得到 "0\n0" 这种脏值，这里统一收口。
h_count() {
    local n
    n=$(grep -c "$1" "$2" 2>/dev/null)
    [ -z "$n" ] && n=0
    printf '%s' "$n"
}

# 干净的非空行计数（管道输入）
h_count_pipe() {
    local n
    n=$(grep -c "$1" 2>/dev/null)
    [ -z "$n" ] && n=0
    printf '%s' "$n"
}
