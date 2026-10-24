#!/bin/bash
# 用例组 03 · 故障转移运行时（systemd unit / 健康检查脚本 / 主备翻转 / 下载安装）
#
# 覆盖重点回归清单：
#   - 权重 1,0,0 → 健康检查 timer 被拉起
#   - 健康检查脚本内容与 systemd unit（realm-health-check.service / .timer）的名称、路径一致
#   - 没有 nc 的环境下 check_connectivity 应走 bash /dev/tcp 回退，而不是把所有目标判为失败
#   - 所有功能脚本下载地址都指向 byby5555/realm-xwPF-offline-active-standby

# 公共工具在 00_common.sh（_run_in_sandbox / _make_failover_rule / _prepare_failover_runtime / _start_listener ...）

case_T16_health_timer_start() {
    h_case_begin "T16" "主备 → 健康检查 timer 被拉起" \
        "沙箱 rules 目录 + 沙箱 xwFailover.sh + lib/health.sh" \
        "ensure_health_check_service" \
        "systemctl enable/start realm-health-check.timer 被调用"

    : > "$SBX_LOG_DIR/systemctl.log"
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_failover_rule "$SBX_ROOT/realm/rules/rule-1.conf"
    _prepare_failover_runtime

    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/ui.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
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
    h_check_contains "$syslog" "enable" "systemctl 调用里有 enable"
    h_check_contains "$syslog" "realm-health-check.timer" "systemctl 调用涉及 realm-health-check.timer"
    h_check_contains "$syslog" "start" "systemctl 调用里有 start"
}

case_T17_health_unit_consistency() {
    h_case_begin "T17" "健康检查脚本与 systemd unit 一致" \
        "沙箱生成产物" \
        "检查 health_check.sh / realm-health-check.service / .timer" \
        "unit 的 ExecStart 指向真实生成路径；名称、目录与脚本内变量互相一致"

    # 独立可跑：产物不在就先生成
    if [ ! -f "$SBX_ROOT/realm/health/health_check.sh" ]; then
        rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
        _make_failover_rule "$SBX_ROOT/realm/rules/rule-1.conf"
        _prepare_failover_runtime
        bash "$SBX_ROOT/realm/xwFailover.sh" start >/dev/null 2>&1
    fi

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

case_T18_no_nc_fallback() {
    h_case_begin "T18" "无 nc 时的连通性回退" \
        "沙箱 PATH 不含 nc + 本地监听端口" \
        "check_connectivity 127.0.0.1 <port>" \
        "没有 nc 时应走 bash /dev/tcp 回退，判定为连通"

    local port=34871
    local out rc ctrl rc_ctrl

    _prepare_failover_runtime

    # 阳性对照：环境本身支持 /dev/tcp（排除环境问题）
    _start_listener "$port" || { h_fail "起不了本地监听端口，用例无法判定"; return; }
    sleep 0.5
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

case_T19_active_standby_flip() {
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

case_T20_bootstrap_offline() {
    h_case_begin "T20" "安装引导的离线下载" \
        "curl/wget 桩 + 本地镜像（= GitHub 已跟踪内容）" \
        "_bootstrap" \
        "下载地址全部指向本 fork；xwPF.sh + 全部 lib + 2 个 cmd 全部落盘且内容与仓库一致"

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
        total=$(h_count 'resolved_url=' "$SBX_LOG_DIR/curl.log")
        bad=$(grep 'resolved_url=' "$SBX_LOG_DIR/curl.log" 2>/dev/null |
            grep -v 'byby5555/realm-xwPF-offline-active-standby' | h_count_pipe '.')
    fi
    h_log "实际发起的下载 URL 数: $total"
    h_check_eq "0" "$bad" "指向非本 fork 的下载地址条数"

    # LIB_FILES 是产品自己声明的必装模块清单，逐个核对是否都下载成功
    local f
    for f in xwPF.sh lib/core.sh lib/health.sh lib/rules.sh lib/server.sh lib/realm.sh lib/failover.sh lib/ui.sh cmd/xwpf-failover.py cmd/xwpf-failover.service; do
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

case_T21_xwpf_help_runtime() {
    h_case_begin "T21" "xwPF.sh --help 实际行为" \
        "沙箱 INSTALL_DIR + 假 bin" \
        "bash xwPF.sh --help" \
        "打印用法/帮助并退出，不进入交互菜单"

    # 组装一份可运行的沙箱安装目录（lib 下的文件按仓库现状全量拷贝）
    rm -rf "$SBX_ROOT/usr.local.bin/lib"
    mkdir -p "$SBX_ROOT/usr.local.bin/lib" "$SBX_ROOT/usr.local.bin/cmd"
    cp "$SBX_RUN/xwPF.sh" "$SBX_ROOT/usr.local.bin/xwPF.sh"
    local f
    for f in "$SBX_RUN"/lib/*.sh; do
        [ -f "$f" ] || continue
        cp "$f" "$SBX_ROOT/usr.local.bin/lib/$(basename "$f")"
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

case_T22_crlf_install_artifact() {
    h_case_begin "T22" "生成物行尾归一化" \
        "仓库工作区（只读）" \
        "grep 生成 health_check.sh 的代码里有没有行尾归一化" \
        "生成 health_check.sh 前先剥掉 CR（否则 CRLF 安装源会产出 systemd 跑不了的脚本）"

    # 说明：本机是 MSYS（Windows），CR 在读文件时被运行时直接吞掉，
    # 「CRLF 脚本在 Linux 上跑挂」这个失败模式无法在本机复现 —— 改为静态核对生成端有没有做归一化。
    local f gen_src=""
    for f in lib/health.sh xwFailover.sh; do
        [ -f "$SBX_REPO/$f" ] || continue
        if grep -q 'health_check\.sh' "$SBX_REPO/$f"; then gen_src="$gen_src $f"; fi
    done
    h_log "生成 health_check.sh 的文件:${gen_src:-（没找到）}"

    local has_norm=0
    for f in $gen_src; do
        if grep -qF "tr -d" "$SBX_REPO/$f" || grep -qF 's/\r' "$SBX_REPO/$f"; then
            has_norm=1
            h_log "  $f 里发现行尾归一化片段"
        fi
    done

    if [ "$has_norm" = "1" ]; then
        h_pass "生成前有行尾归一化"
    else
        h_fail "生成 health_check.sh 前没有任何行尾归一化：从 CRLF 安装源（Windows 工作区 / 离线打包）生成出的脚本会带 CR，systemd 执行时报 command not found"
    fi
}
