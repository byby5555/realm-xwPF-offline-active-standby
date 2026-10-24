#!/bin/bash
# 用例组 03 · 故障转移运行时（systemd unit / 健康检查脚本 / 主备翻转 / 下载安装）
#
# 覆盖重点回归清单：
#   - 权重 1,0,0 → 健康检查 timer 被拉起
#   - 健康检查脚本内容与 systemd unit（realm-health-check.service / .timer）的名称、路径一致
#   - 没有 nc 的环境下 check_connectivity 应走 bash /dev/tcp 回退，而不是把所有目标判为失败
#   - 所有功能脚本下载地址都指向 byby5555/realm-xwPF-offline-active-standby

_run_in_sandbox() {
    local code="$1"
    shift
    bash -c "$code" _ "$SBX_RUN" "$@" 2>&1
}

# 起一个本地监听端口（给 /dev/tcp 探测当阳性对照）
_start_listener() {
    local port="$1"
    # 本机 python3 是 WindowsApps 商店占位符，不可用；优先用真实 python
    local py=""
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
time.sleep(25)
" &
    LISTENER_PID=$!
    sleep 1.5
    return 0
}

case_T15_health_timer_start() {
    h_case_begin "T16" "主备 → 健康检查 timer 被拉起" \
        "沙箱 rules 目录 + 沙箱 xwFailover.sh" \
        "ensure_health_check_service" \
        "systemctl enable/start realm-health-check.timer 被调用"

    : > "$SBX_LOG_DIR/systemctl.log"
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    cat > "$SBX_ROOT/realm/rules/rule-1.conf" <<'EOF'
RULE_ID=1
RULE_ROLE=1
RULE_NAME=rule-test
SECURITY_LEVEL=standard
LISTEN_PORT=8080
REMOTE_HOST=10.0.0.1,10.0.0.2,10.0.0.3
REMOTE_PORT=8080
ENABLED=true
BALANCE_MODE="active-standby"
FAILOVER_ENABLED="true"
WEIGHTS="1,0,0"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF
    cp "$SBX_RUN/xwFailover.sh" "$SBX_ROOT/realm/xwFailover.sh"

    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/ui.sh" >/dev/null 2>&1
        ensure_health_check_service
        echo "RC=$?"
    ')
    rc=$?
    h_log "输出: ${out:-<空>}"
    h_log "--- systemctl 调用记录 ---"
    if [ -f "$SBX_LOG_DIR/systemctl.log" ]; then
        while IFS= read -r l; do h_log "  $l"; done < "$SBX_LOG_DIR/systemctl.log"
    fi

    local syslog=""
    [ -f "$SBX_LOG_DIR/systemctl.log" ] && syslog=$(cat "$SBX_LOG_DIR/systemctl.log")
    h_check_contains "$syslog" "enable realm-health-check.timer" "systemctl enable"
    h_check_contains "$syslog" "start realm-health-check.timer" "systemctl start"
}

case_T16_health_unit_consistency() {
    h_case_begin "T17" "健康检查脚本与 systemd unit 一致" \
        "T15 生成的沙箱产物" \
        "检查 health_check.sh / realm-health-check.service / .timer" \
        "unit 的 ExecStart 指向真实生成路径；名称、目录与脚本内变量互相一致"

    local script="$SBX_ROOT/realm/health/health_check.sh"
    local unit="$SBX_ROOT/systemd/realm-health-check.service"
    local timer="$SBX_ROOT/systemd/realm-health-check.timer"

    h_check_file "$script" "健康检查脚本"
    h_check_file "$unit" "systemd service unit"
    h_check_file "$timer" "systemd timer unit"

    h_check_file_has "$unit" "ExecStart=$script" "unit 的 ExecStart 指向真实脚本"
    h_check_file_has "$unit" "SyslogIdentifier=realm-health" "unit 的 SyslogIdentifier"
    h_check_file_has "$timer" "Requires=realm-health-check.service" "timer 的 Requires 指向同名 service"
    h_check_file_has "$timer" "OnUnitActiveSec=4sec" "timer 的检查间隔（规则里是 4 秒）"
    h_check_file_has "$script" "RULES_DIR=\"$SBX_ROOT/realm/rules\"" "脚本内 RULES_DIR"
    h_check_file_has "$script" "HEALTH_DIR=\"$SBX_ROOT/realm/health\"" "脚本内 HEALTH_DIR"

    # 生成物必须是 LF（Windows 上如果带 CRLF，systemd 执行会报错）
    if [ -f "$script" ]; then
        local crlf=0
        crlf=$(sbx_count_cr "$script")
        h_check_eq "0" "$crlf" "生成脚本里的 CR 字节数"
    fi
}

case_T17_no_nc_fallback() {
    h_case_begin "T18" "无 nc 时的连通性回退" \
        "沙箱 PATH 不含 nc + 本地监听端口" \
        "check_connectivity 127.0.0.1 <port>" \
        "没有 nc 时应走 bash /dev/tcp 回退，判定为连通"

    local port=34871
    local out rc ctrl rc_ctrl

    # 对照组 A：环境本身支持 /dev/tcp（阳性对照，排除环境问题）
    ctrl=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>&1)
    rc_ctrl=$?
    h_log "对照组 /dev/tcp（端口未监听时）rc=$rc_ctrl"

    _start_listener "$port"
    sleep 0.5

    # 阳性对照：环境支持 /dev/tcp 连到监听端口
    ctrl=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>&1)
    rc_ctrl=$?
    h_log "对照组 /dev/tcp（端口已监听时）rc=$rc_ctrl"
    if [ "$rc_ctrl" -ne 0 ]; then
        h_fail "环境对照失败：本机 /dev/tcp 连不上本地监听端口，用例无法判定"
        kill "$LISTENER_PID" 2>/dev/null
        return
    fi

    # 场景 1：PATH 里没有 nc —— 期望走 /dev/tcp 回退 → 连通
    out=$(sbx_path_without_nc; _run_in_sandbox '
        src="$1/xwFailover.sh"; tmp="/tmp/xwfo_nomain_$$.sh"
        sed "s|^main \"\\\$@\"$|# neutralized|" "$src" > "$tmp"
        source "$tmp" >/dev/null 2>&1
        check_connectivity 127.0.0.1 '"$port"' 2
        echo "RC=$?"
    ')
    rc=$?
    h_log "无 nc 时输出: ${out:-<空>}"
    h_check_contains "$out" "RC=0" "无 nc 时 check_connectivity 结果"

    # 场景 2（第二口径）：把 nc 桩放进 PATH —— 期望连通
    out=$(sbx_path_with_nc; _run_in_sandbox '
        src="$1/xwFailover.sh"; tmp="/tmp/xwfo_nomain2_$$.sh"
        sed "s|^main \"\\\$@\"$|# neutralized|" "$src" > "$tmp"
        source "$tmp" >/dev/null 2>&1
        check_connectivity 127.0.0.1 '"$port"' 2
        echo "RC=$?"
    ')
    h_log "有 nc 桩时输出: ${out:-<空>}"
    h_check_contains "$out" "RC=0" "有 nc 时 check_connectivity 结果（对照口径）"

    kill "$LISTENER_PID" 2>/dev/null
}

case_T18_active_standby_flip() {
    h_case_begin "T19" "主备权重翻转" \
        "沙箱 rules + health_status.conf" \
        "generate_endpoints_from_rules" \
        "主挂→roundrobin: 0, 1, 0；全健康→1, 0, 0；全挂→1, 0, 0（兜底）"

    local snippet='
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        generate_endpoints_from_rules
    '

    local rule="$SBX_ROOT/realm/rules/rule-1.conf"
    local health="$SBX_ROOT/realm/health/health_status.conf"

    # 场景 A：主挂
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    cat > "$rule" <<'EOF'
RULE_ID=1
RULE_ROLE=1
RULE_NAME=rule-test
SECURITY_LEVEL=standard
LISTEN_PORT=8080
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=10.0.0.1,10.0.0.2,10.0.0.3
REMOTE_PORT=8080
ENABLED=true
BALANCE_MODE="active-standby"
FAILOVER_ENABLED="true"
WEIGHTS="1,0,0"
EOF
    mkdir -p "$(dirname "$health")"
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1|failed|2|0|100|100
1|10.0.0.2|healthy|0|3|100|0
1|10.0.0.3|healthy|0|3|100|0
EOF
    local out
    out=$(_run_in_sandbox "$snippet")
    h_log "--- 场景A（主挂）输出 ---"
    while IFS= read -r l; do h_log "  $l"; done <<< "$out"
    h_check_contains "$out" "roundrobin: 0, 1, 0" "主挂时的主备权重"

    # 场景 B：全健康
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1|healthy|0|3|100|0
1|10.0.0.2|healthy|0|3|100|0
1|10.0.0.3|healthy|0|3|100|0
EOF
    out=$(_run_in_sandbox "$snippet")
    h_log "--- 场景B（全健康）输出 ---"
    while IFS= read -r l; do h_log "  $l"; done <<< "$out"
    h_check_contains "$out" "roundrobin: 1, 0, 0" "全健康时的主备权重"

    # 场景 C：全挂（兜底）
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1|failed|3|0|100|100
1|10.0.0.2|failed|3|0|100|100
1|10.0.0.3|failed|3|0|100|100
EOF
    out=$(_run_in_sandbox "$snippet")
    h_log "--- 场景C（全挂）输出 ---"
    while IFS= read -r l; do h_log "  $l"; done <<< "$out"
    h_check_contains "$out" "roundrobin: 1, 0, 0" "全挂时的兜底权重"
}

case_T19_bootstrap_offline() {
    h_case_begin "T20" "安装引导的离线下载" \
        "curl/wget 桩 + 本地镜像" \
        "_bootstrap" \
        "下载地址全部指向本 fork；xwPF.sh + 6 个 lib + 2 个 cmd 全部落盘且内容与仓库一致"

    : > "$SBX_LOG_DIR/curl.log"
    : > "$SBX_LOG_DIR/wget.log"

    local out rc
    out=$(_run_in_sandbox '
        src="$1/xwPF.sh"; tmp="/tmp/xwpf_nodispatch_$$.sh"
        sed "/^case \"\${1:-}\" in$/,\$d" "$src" > "$tmp"
        source "$tmp" >/dev/null 2>&1
        _bootstrap
        echo "RC=$?"
    ')
    rc=$?
    h_log "输出: ${out:-<空>}"
    h_log "--- curl 调用记录 ---"
    [ -f "$SBX_LOG_DIR/curl.log" ] && while IFS= read -r l; do h_log "  $l"; done < "$SBX_LOG_DIR/curl.log"

    local bad="" total=0
    if [ -f "$SBX_LOG_DIR/curl.log" ]; then
        total=$(grep -c 'resolved_url=' "$SBX_LOG_DIR/curl.log" 2>/dev/null || echo 0)
        bad=$(grep 'resolved_url=' "$SBX_LOG_DIR/curl.log" 2>/dev/null |
            grep -v 'byby5555/realm-xwPF-offline-active-standby' | grep -c . || echo 0)
    fi
    h_log "实际发起的下载 URL 数: $total"
    h_check_eq "0" "$bad" "指向非本 fork 的下载地址条数"

    local f
    for f in xwPF.sh lib/core.sh lib/rules.sh lib/server.sh lib/realm.sh lib/failover.sh lib/ui.sh cmd/xwpf-failover.py cmd/xwpf-failover.service; do
        h_check_file "$SBX_ROOT/usr.local.bin/$f" "落盘 $f"
    done

    # 内容一致性：下载下来的 xwPF.sh 应与仓库 LF 副本一致
    if [ -f "$SBX_ROOT/usr.local.bin/xwPF.sh" ]; then
        local a b
        a=$(sha256sum "$SBX_ROOT/usr.local.bin/xwPF.sh" | cut -d' ' -f1)
        b=$(sha256sum "$SBX_SRC/xwPF.sh" | cut -d' ' -f1)
        h_check_eq "$b" "$a" "下载的 xwPF.sh 与仓库副本的 sha256"
    fi
}

case_T22_crlf_install_artifact() {
    h_case_begin "T22" "CRLF 安装源的生成物行尾" \
        "仓库工作区原始文件（CRLF）+ 路径重定向" \
        "bash xwFailover.sh start（CRLF 版）" \
        "生成的 health_check.sh 不带 CR（systemd 才能正常执行）"

    # 只做路径重定向，不做去 CR —— 模拟「从 Windows 工作区打包做离线安装」
    sbx_redirect "$SBX_REPO/xwFailover.sh" "$SBX_ROOT/xwFailover_crlf.sh"
    rm -f "$SBX_ROOT/realm/health/health_check.sh"

    local out rc
    out=$(cd "$SBX_ROOT" && timeout 20 bash "$SBX_ROOT/xwFailover_crlf.sh" start 2>&1)
    rc=$?
    h_log "rc=$rc"
    h_log "--- 输出（前 12 行）---"
    printf '%s\n' "$out" | head -12 | while IFS= read -r l; do h_log "  $l"; done

    local script="$SBX_ROOT/realm/health/health_check.sh"
    if [ -f "$script" ]; then
        local cr
        cr=$(sbx_count_cr "$script")
        h_log "生成脚本 CR 字节数: $cr"
        h_check_eq "0" "$cr" "CRLF 源生成的 health_check.sh 里的 CR 字节数"
    else
        h_fail "CRLF 源连 health_check.sh 都没生成出来（脚本在 CRLF 下直接跑挂了）"
    fi
}

case_T20_xwpf_help_runtime() {
    h_case_begin "T21" "xwPF.sh --help 实际行为" \
        "沙箱 INSTALL_DIR + 假 bin" \
        "bash xwPF.sh --help" \
        "打印用法/帮助并退出，不进入交互菜单"

    # 组装一份可运行的沙箱安装目录
    mkdir -p "$SBX_ROOT/usr.local.bin/lib" "$SBX_ROOT/usr.local.bin/cmd"
    cp "$SBX_RUN/xwPF.sh" "$SBX_ROOT/usr.local.bin/xwPF.sh"
    local f
    for f in core.sh rules.sh server.sh realm.sh failover.sh ui.sh; do
        cp "$SBX_RUN/lib/$f" "$SBX_ROOT/usr.local.bin/lib/$f"
    done

    local out rc
    out=$(cd "$SBX_ROOT" && timeout 15 bash "$SBX_ROOT/usr.local.bin/xwPF.sh" --help </dev/null 2>&1)
    rc=$?
    h_log "rc=$rc"
    h_log "--- 输出（前 40 行）---"
    printf '%s\n' "$out" | head -40 | while IFS= read -r l; do h_log "  $l"; done

    if [ "$rc" = "124" ]; then
        h_fail "--help 未退出（超时），说明进入了交互菜单而不是打印帮助"
    else
        h_check_contains "$out" "用法" "--help 输出含用法说明"
        h_check_contains "$out" "Usage" "--help 输出含 Usage 说明"
    fi
}
