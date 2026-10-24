#!/bin/bash
# 用例组 00 · 公共工具（被 01~04 共用）
#
# 约定：
#   - 所有被测代码来自冻结态 $SBX_RUN / $SBX_SRC（= git show $BASE_SHA:<path>）
#   - 所有文件操作都在沙箱里，绝不碰真实 /etc/realm

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
_prepare_failover_runtime() {
    mkdir -p "$SBX_ROOT/realm/lib" "$SBX_ROOT/usr.local.bin/lib"
    cp "$SBX_RUN/xwFailover.sh" "$SBX_ROOT/realm/xwFailover.sh"
    if [ -f "$SBX_RUN/lib/health.sh" ]; then
        cp "$SBX_RUN/lib/health.sh" "$SBX_ROOT/realm/lib/health.sh"
        cp "$SBX_RUN/lib/health.sh" "$SBX_ROOT/usr.local.bin/lib/health.sh"
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
# 注：第 1 列 RULE_ID 这里按顺序编号。RULE_ID 只在**旧格式**的归属回填里被用到，
#     新格式（host:port）的读取路径不看这一列 —— 所以顺序编号不影响断言。
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
