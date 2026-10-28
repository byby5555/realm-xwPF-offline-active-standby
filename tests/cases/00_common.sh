#!/bin/bash
# 用例组 00 · 公共工具（被 01~04 共用）
#
# 约定：
#   - 所有被测代码来自冻结态 $SBX_RUN / $SBX_SRC（= git show $BASE_SHA:<path>）
#   - 所有文件操作都在沙箱里，绝不碰真实 /etc/realm

# ── 历史对象清单（负向对照依赖的「修复前的真实旧实现」）────────────
#   ★ 单一真源：**用例**（去取旧实现）和**跑批前预检**（检查对象在不在本地库）
#     都从这里读，避免两处漂移。新增一个用历史实现的负向对照 →
#     ① 在下面加一行 ② 用例改用 sbx_history_sha <key> 取值（不要在用例里写死 sha）。
#   背景（第 9 轮 · Chief 派单 P2）：堆叠 PR 全部 squash 合并后，main 的历史里
#     **不再包含**这些旧 SHA；而 `git clone --single-branch` **不拉 tag**
#     → 对象缺失 → 负向对照取不到「修复前的真实旧实现」→ 证明力归零，
#     而且门禁会以「用例失败」的形式红，**会被误读成产品回归**。
#     → 跑批前预检（tests/run_tests.sh）用独立退出码 3 报这件事，并给出修复命令。
#   格式：<key> <sha> <说明>
sbx_required_history_shas() {
    cat <<'EOF'
t52-prefix    f730c8b  T52 负向对照：最初的健康状态实现（读侧只用裸 host 建索引）
t52-pre-n1r1  a7e23fc  T52 负向对照：TARGET 改 host:port 之后、仍留一份裸 host 宽键的那一版
t53-pre-fix   d0366b3  T53 负向对照：菜单 EOF 忙循环修复之前的实现（整份 lib/）
t54-pre-fix   a359301  T54 负向对照：交互读入 EOF 收口之前的实现（整份 lib/）
weight10-pre  b863911  T84 负向对照：加「权重 10 独占」校验之前的实现（会接受 10,5）
n4-pre        f59e389  T85/T86 负向对照：生成物装/升级不重生成 + 状态文件不原子重建的那一版
inherit-pre   9dc5b56  T87/T88 负向对照：health_status_find_row 只比对目标地址、没看 RULE_ID 的那一版
inherit-ok    f59e389  T87/T88「老实现本来是对的」：老实现用 grep 组合键（RULE_ID|地址），跑同一场景必须**不串**
n4-del        2beb7bd  删除进程级主备池整块的那一版（补历史文件时取它的父提交）
sync-pre      75379aa  T95/T96 负向对照：迁移端 sync_health_status_ids 只按目标地址认领、没改一对一的那一版（= 84fe096^）
static3-pre   b9db576  T89/T93 负向对照：加 xwpf:noninteractive-io 标记**之前**的实现（循环头行上有无标记、无 EOF 收口的读入 ⇒ 静态 3 判红）
readend-pre   63b6ec9  T114 负向对照：读端 generate_endpoints_from_rules 建 map 键**不含 RULE_ID** 的那一版（同 target 两行 ⇒ 塌缩成一行 ⇒ 双向误切）
install-guard-pre e4ac5eb  T128/T129/T130 负向对照：安装完整性与「静默失效」修复之前的那一版（install 不补齐 service/config/rules；create_single_nat_rule 不检查规则目录；空 TARGET_STATES 触发整数比较错误）
EOF
}

# 按 key 取 sha（用例用）
#   成功 → stdout 打印 sha，rc=0；清单里没有这个 key → rc=1 且 stdout 为空
sbx_history_sha() {
    local key="$1" k sha desc
    while read -r k sha desc; do
        case "$k" in ''|'#'*) continue ;; esac
        [ "$k" = "$key" ] || continue
        printf '%s\n' "$sha"
        return 0
    done < <(sbx_required_history_shas)
    return 1
}

# 在沙箱里 source 冻结态产品代码，执行一段 bash，返回输出
_run_in_sandbox() {
    local code="$1"
    shift
    bash -c "$code" _ "$SBX_RUN" "$@" 2>&1
}

# ★ 第 2 轮修正：规则 fixture 必须**写全官方键集**。
#   依据：lib/server.sh 的规则模板（a9102c1:lib/server.sh:80-113）与
#         lib/failover.sh:213-238 —— 产品自己落盘的规则文件一定包含
#         TARGET_STATES / WEIGHTS / LISTEN_IP / THROUGH_IP / WS_* / TLS_* 等全部键。
#   原因：read_rule_file（lib/health.sh:179-186）会先 unset 掉所有键再 source 规则文件。
#         fixture 少写一个键 → 该变量就变成"未定义" → set -u 下直接致命中断。
#         第 2 轮 T31 一开始就是被这个坑出来的假缺陷（见 BASELINE-round2.md 缺陷说明）。
#   纪律：fixture 只做"参数化"，不裁剪键集。
_rule_file_common() {
    cat <<EOF
RULE_ID=1
RULE_ROLE="1"
RULE_NAME="rule-test"
SECURITY_LEVEL="standard"
LISTEN_IP="0.0.0.0"
THROUGH_IP="::"
FORWARD_TARGET=""
TLS_SERVER_NAME=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_NOTE="harness fixture"
ENABLED="true"
CREATED_TIME="2026-01-01 00:00:00"
TARGET_STATES=""
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
MPTCP_MODE="off"
PROXY_MODE="off"
EOF
}

# 造一条启用故障转移的中转规则（沙箱内）
_make_failover_rule() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    {
        _rule_file_common
        cat <<EOF
LISTEN_PORT=8080
REMOTE_HOST=10.0.0.1,10.0.0.2,10.0.0.3
REMOTE_PORT=8080
BALANCE_MODE="active-standby"
FAILOVER_ENABLED="true"
WEIGHTS="1,0,0"
EOF
    } > "$file"
}

# 造一条普通的权重/主备规则（可指定主备模式、故障转移开关、权重、目标）
_make_rule() {
    local file="$1" port="${2:-8080}" mode="${3:-roundrobin}" failover="${4:-false}" weights="${5:-1,0,0}" hosts="${6:-10.0.0.1,10.0.0.2,10.0.0.3}"
    mkdir -p "$(dirname "$file")"
    {
        _rule_file_common
        cat <<EOF
LISTEN_PORT=$port
REMOTE_HOST=$hosts
REMOTE_PORT=8080
BALANCE_MODE="$mode"
FAILOVER_ENABLED="$failover"
WEIGHTS="$weights"
EOF
    } > "$file"
}

# 造一条「故意缺字段」的规则文件（用于 T33：缺可选字段时的 set -u 健壮性）
# 只保留产品读得到的最少字段，缺 TARGET_STATES / WEIGHTS 等可选键。
_make_minimal_rule() {
    local file="$1" port="${2:-8080}" mode="${3:-roundrobin}" weights="${4:-10,0}" hosts="${5:-10.0.0.1,10.0.0.2}"
    mkdir -p "$(dirname "$file")"
    cat > "$file" <<EOF
RULE_ID=1
RULE_ROLE="1"
RULE_NAME="rule-minimal"
SECURITY_LEVEL="none"
LISTEN_PORT=$port
LISTEN_IP="0.0.0.0"
THROUGH_IP="::"
REMOTE_HOST=$hosts
REMOTE_PORT=8080
ENABLED="true"
BALANCE_MODE="$mode"
WEIGHTS="$weights"
EOF
}

# 把 xwFailover.sh 和 lib/health.sh 摆到 xwFailover.sh 的加载器会找的位置
# （xwFailover.sh 依次找 /usr/local/bin/lib/health.sh、/etc/realm/lib/health.sh、$(dirname $0)/lib/health.sh）
#
# ★ lib/core.sh 也要一起摆（2026-10-26 补）：
#   探测脚本的生成物要带走「共用真源」rule_target_endpoints（它住在 lib/core.sh）。
#   真实安装时 lib/ 是**整目录**装上去的，core.sh 必然在 health.sh 旁边；
#   沙箱只摆 health.sh ⇒ 生成物缺函数 ⇒ 探测端枚举不到任何目标
#   ⇒ T06 判红（且是**假红**：产品行为是对的，是沙箱的安装布局不完整）。
#   ⇒ 这里摆齐，让沙箱布局 = 真实安装布局。
_prepare_failover_runtime() {
    mkdir -p "$SBX_ROOT/realm/lib" "$SBX_ROOT/usr.local.bin/lib"
    cp "$SBX_RUN/xwFailover.sh" "$SBX_ROOT/realm/xwFailover.sh"
    if [ -f "$SBX_RUN/lib/health.sh" ]; then
        cp "$SBX_RUN/lib/health.sh" "$SBX_ROOT/realm/lib/health.sh"
        cp "$SBX_RUN/lib/health.sh" "$SBX_ROOT/usr.local.bin/lib/health.sh"
    fi
    if [ -f "$SBX_RUN/lib/core.sh" ]; then
        cp "$SBX_RUN/lib/core.sh" "$SBX_ROOT/realm/lib/core.sh"
        cp "$SBX_RUN/lib/core.sh" "$SBX_ROOT/usr.local.bin/lib/core.sh"
    fi
}

# 把 LF 文件转成 CRLF（模拟 Windows 检出）。用 printf '\r\n' 逐行写，避开 sed 的 \r 兼容问题。
_to_crlf() {
    local src="$1" dst="$2"
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\r\n' "$line"
    done < "$src" > "$dst"
}

# 起一个本地监听端口（给 /dev/tcp 探测当阳性对照）
_start_listener() {
    local port="$1"
    # 本机 python3 是 WindowsApps 商店占位符，不可用；优先用真实 python
    local py="" c
    for c in python python3; do
        if command -v "$c" >/dev/null 2>&1 && "$c" --version >/dev/null 2>&1; then py="$c"; break; fi
    done
    if [ -z "$py" ]; then
        h_log "找不到可用的 python，无法起本地监听端口"
        return 1
    fi
    "$py" -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port))
s.listen(8)
time.sleep(30)
" &
    LISTENER_PID=$!
    sleep 1.5
    return 0
}

# 写健康状态文件
#
# ★ 口径（重要）：TARGET 字段写 **host:port**（当前生产写入口径）。
#   写成裸 host 的旧格式，用例会退化成「旧格式兼容兜底分支」——
#   读侧按精确键查不到就落回裸 host，断言照样绿，但精确索引这条主路径
#   根本没人测 → fixture 的形态本身就是断言的一部分。
#
# 用法：_write_health <文件> <端口> <host:status> ...
#   端口   = 规则的 REMOTE_PORT（必须与用例里规则的 REMOTE_PORT 一致，
#            不一致 → 精确键查不到 → 行为改变）
#   host:status = 目标地址 + 状态（healthy / failed）
#
# ★ 第 1 列 RULE_ID 的口径（2026-10-24 小编改）：**必须写「拥有该目标的规则」的 RULE_ID**。
#   写端每行的 RULE_ID 都是「归属规则」的 ID（一条规则的多个目标 ⇒ 行行相同），
#   读端按 **(RULE_ID, 目标地址) 组合键**查状态 ⇒ 这一列写错 ⇒ 精确键查不到
#   ⇒ 目标被判成「无记录 = 健康」⇒ 该切不切。
#   ★ 新格式（host:port）**同样看这一列**：lib/realm.sh 读健康状态文件时
#     建键是 "${_row_rule_id}|${_row_target}"（_row_rule_id = 文件第 1 列），
#     消费端按「端口组里该目标的归属规则|目标」查 ⇒ 两边必须对得上。
#     （曾有一版注释说「新格式不看这一列」——那是错的，会把写错的 fixture 放过去。）
#   本 helper 按**位置顺序**编号 ⇒ 只适用于「每个目标各属一条规则、
#   且规则 ID 与位置序号一致」的形态；**一条规则带多个目标**的用例
#   必须改用 _write_health_for_rule（显式给归属规则 ID）。
_write_health() {
    local file="$1" port="$2"
    shift 2
    mkdir -p "$(dirname "$file")"
    {
        echo "# Realm健康状态文件"
        local i=1 pair
        for pair in "$@"; do
            echo "${i}|${pair%%:*}:${port}|${pair##*:}|0|3|100|0"
            i=$((i + 1))
        done
    } > "$file"
}

# 写健康状态文件（**显式指定归属规则的 RULE_ID** —— 一条规则带多个目标时用这个）
#
# 用法：_write_health_for_rule <文件> <RULE_ID> <端口> <host:status> ...
#   RULE_ID = 拥有这些目标的规则的 ID（写端就是这个值，同规则的多个目标行行相同）
_write_health_for_rule() {
    local file="$1" rule_id="$2" port="$3"
    shift 3
    mkdir -p "$(dirname "$file")"
    {
        echo "# Realm健康状态文件"
        local pair
        for pair in "$@"; do
            echo "${rule_id}|${pair%%:*}:${port}|${pair##*:}|0|3|100|0"
        done
    } > "$file"
}
