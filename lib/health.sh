# 健康检查共用逻辑（唯一真源）
#
# pf 主脚本（权重含 0 自动进主备）与故障转移脚本 xwFailover.sh 共用同一份实现：
#   1. 连通性探测：TCP 握手探测（不是 ping）
#   2. 健康状态文件位置
#   3. 健康检查服务（systemd timer）的生成与启停
#
# 生成的 /etc/realm/health/health_check.sh 是一份**独立可执行**的脚本
# （systemd 直接调用它，不能依赖 pf 的安装目录），
# 所以它的探测逻辑在下面 health_check_script_body 里另有一份内联副本，
# 改动 check_connectivity 时两处必须同步。

CONFIG_DIR="${CONFIG_DIR:-/etc/realm}"
HEALTH_DIR="${HEALTH_DIR:-${CONFIG_DIR}/health}"
HEALTH_STATUS_FILE="${HEALTH_STATUS_FILE:-${HEALTH_DIR}/health_status.conf}"
HEALTH_LOCK_FILE="${HEALTH_LOCK_FILE:-/var/lock/realm-health-check.lock}"

# 校验正整数，非法时回退默认值（不报错）
validate_positive_int() {
    local value="$1"
    local default_value="$2"

    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
        echo "$value"
    else
        echo "$default_value"
    fi
}

# 连通性探测（TCP 握手，不是 ping）
# 优先 netcat（需支持 -z 探测模式；busybox nc 不支持），
# 没有 nc（或 nc 不支持 -z）时回退 bash 内置 /dev/tcp
check_connectivity() {
    local target="$1"
    local port="$2"
    local timeout="${3:-3}"

    # 方式1: netcat（需支持 -z 探测模式；busybox nc 不支持，不能用）
    if command -v nc >/dev/null 2>&1; then
        if nc -h 2>&1 | grep -q -- '-z' 2>/dev/null; then
            nc -z -w "$timeout" "$target" "$port" >/dev/null 2>&1
            return $?
        fi
    fi

    # 方式2: bash 内置 /dev/tcp（很多精简 VPS 没装 netcat，
    # 缺 nc 时若直接判失败，会把所有目标误判成故障，导致永远不切换）
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout" bash -c "exec 3<>/dev/tcp/${target}/${port}" >/dev/null 2>&1
        local _cc_rc=$?
        # timeout 杀进程时退出码是 124，同样视为不可达，统一归一化成 0/1
        if [ "$_cc_rc" -eq 0 ]; then
            return 0
        fi
        return 1
    fi

    return 1
}

# 取当前时间（微秒）
# 优先 bash 5 的 EPOCHREALTIME（不 fork，更快）；回退 date +%s%N
# （GNU coreutils 支持；busybox date 不支持 %N，会返回字面量 N，此时判定为不可用）
now_us() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local t="${EPOCHREALTIME}"
        t="${t/[.,]/}"
        case "$t" in
            ''|*[!0-9]*) return 1 ;;
        esac
        echo "$t"
        return 0
    fi

    local t
    t=$(date +%s%N 2>/dev/null)
    case "$t" in
        ''|*N*) return 1 ;;
    esac
    echo "$t"
    return 0
}

# 连通性探测 + 耗时（毫秒）
# 耗时写进全局 PROBE_LATENCY_MS（取不到时间戳就留空）
# 返回值语义与 check_connectivity 相同：0 通 / 1 不通
PROBE_LATENCY_MS=""
probe_with_latency() {
    local target="$1"
    local port="$2"
    local timeout="${3:-3}"
    local t0="" t1="" rc=0

    t0=$(now_us) || t0=""
    if check_connectivity "$target" "$port" "$timeout"; then
        rc=0
    else
        rc=1
    fi
    t1=$(now_us) || t1=""

    PROBE_LATENCY_MS=""
    if [ -n "$t0" ] && [ -n "$t1" ] && [ "$t1" -ge "$t0" ]; then
        PROBE_LATENCY_MS=$(( (t1 - t0) / 1000 ))
    fi
    return $rc
}

# 读取目标在健康状态文件里的整行记录
# 输出格式与状态文件一致（字段以 | 分隔），取不到返回 1
get_health_status_record() {
    local host="$1"
    local status_file="${HEALTH_STATUS_FILE}"
    local line=""

    [ -f "$status_file" ] || return 1
    line=$(grep -F "|${host}|" "$status_file" 2>/dev/null | head -1)
    [ -n "$line" ] || return 1
    echo "$line"
}

# 把时延历史（逗号分隔的样本）算成平均毫秒数
latency_avg_ms() {
    local hist="$1"
    [ -n "$hist" ] || return 1

    local sum=0 n=0 v
    local IFS=','
    for v in $hist; do
        case "$v" in
            ''|*[!0-9]*) continue ;;
        esac
        sum=$((sum + v))
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || return 1
    echo $((sum / n))
}

# 格式化时延展示：最近一次 + 最近若干次平均
format_latency_display() {
    local latency_ms="$1"
    local hist="$2"

    if [ -z "$latency_ms" ]; then
        echo "-"
        return 0
    fi

    local avg
    if avg=$(latency_avg_ms "$hist"); then
        echo "${latency_ms}ms (均 ${avg}ms)"
    else
        echo "${latency_ms}ms"
    fi
}

get_port_failover_params() {
    local port="$1"

    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ] && read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$port" ]; then
            local interval=$(validate_positive_int "${HEALTH_CHECK_INTERVAL:-4}" 4)
            local failure_threshold=$(validate_positive_int "${FAILURE_THRESHOLD:-2}" 2)
            local success_threshold=$(validate_positive_int "${SUCCESS_THRESHOLD:-2}" 2)
            local connection_timeout=$(validate_positive_int "${CONNECTION_TIMEOUT:-3}" 3)
            local recovery_cooldown=$(validate_positive_int "${RECOVERY_COOLDOWN:-120}" 120)
            echo "${interval}|${failure_threshold}|${success_threshold}|${connection_timeout}|${recovery_cooldown}"
            return 0
        fi
    done

    echo "4|2|2|3|120"
}

get_effective_health_check_interval() {
    local min_interval=""

    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ] && read_rule_file "$rule_file"; then
            if [ "$RULE_ROLE" = "1" ] && [ "$ENABLED" = "true" ] && [ "${FAILOVER_ENABLED:-false}" = "true" ]; then
                local interval=$(validate_positive_int "${HEALTH_CHECK_INTERVAL:-4}" 4)
                if [ -z "$min_interval" ] || [ "$interval" -lt "$min_interval" ]; then
                    min_interval="$interval"
                fi
            fi
        fi
    done

    echo "${min_interval:-4}"
}

# 生成健康检查脚本（独立可执行，systemd 直接调用）
health_check_script_body() {
    cat << 'EOF' | tr -d '\r'
#!/bin/bash

# 健康检查脚本
HEALTH_DIR="/etc/realm/health"
RULES_DIR="/etc/realm/rules"
LOCK_FILE="/var/lock/realm-health-check.lock"

# 查找健康状态文件
HEALTH_STATUS_FILE=""
for path in "/etc/realm/health/health_status.conf" "/etc/realm/health_status.conf" "/var/lib/realm/health_status.conf"; do
    if [ -f "$path" ]; then
        HEALTH_STATUS_FILE="$path"
        break
    fi
done

# 如果找不到，使用默认路径
if [ -z "$HEALTH_STATUS_FILE" ]; then
    HEALTH_STATUS_FILE="$HEALTH_DIR/health_status.conf"
fi

# 内置清理：清理状态文件（>5MB按行截断保留2000行）
if [ -f "$HEALTH_STATUS_FILE" ]; then
    file_size=$(stat -c%s "$HEALTH_STATUS_FILE" 2>/dev/null || echo 0)
    if [ "$file_size" -gt 5242880 ]; then
        tail -n 2000 "$HEALTH_STATUS_FILE" > "$HEALTH_STATUS_FILE.tmp" 2>/dev/null
        mv "$HEALTH_STATUS_FILE.tmp" "$HEALTH_STATUS_FILE" 2>/dev/null
    fi
fi

# 内置清理：清理journal日志（保留7天，每小时整点执行）
current_minute=$(date +%M)
if [ "$current_minute" = "00" ]; then
    journalctl --vacuum-time=7d >/dev/null 2>&1
fi

# 获取文件锁
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 健康检查已在运行中，跳过本次检查"
    exit 0
fi

# 健康检查函数（统一使用check_connectivity）
check_connectivity() {
    local target="$1"
    local port="$2"
    local timeout="${3:-3}"

    # 方式1: netcat（需支持 -z 探测模式；busybox nc 不支持，不能用）
    if command -v nc >/dev/null 2>&1; then
        if nc -h 2>&1 | grep -q -- '-z' 2>/dev/null; then
            nc -z -w "$timeout" "$target" "$port" >/dev/null 2>&1
            return $?
        fi
    fi

    # 方式2: bash 内置 /dev/tcp（很多精简 VPS 没装 netcat，
    # 缺 nc 时若直接判失败，会把所有目标误判成故障，导致永远不切换）
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout" bash -c "exec 3<>/dev/tcp/${target}/${port}" >/dev/null 2>&1
        local _cc_rc=$?
        # timeout 杀进程时退出码是 124，同样视为不可达，统一归一化成 0/1
        if [ "$_cc_rc" -eq 0 ]; then
            return 0
        fi
        return 1
    fi

    return 1
}

# 取当前时间（微秒）
# 优先 bash 5 的 EPOCHREALTIME（不 fork，更快）；回退 date +%s%N
# （GNU coreutils 支持；busybox date 不支持 %N，会返回字面量 N，此时判定为不可用）
now_us() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local t="${EPOCHREALTIME}"
        t="${t/[.,]/}"
        case "$t" in
            ''|*[!0-9]*) return 1 ;;
        esac
        echo "$t"
        return 0
    fi

    local t
    t=$(date +%s%N 2>/dev/null)
    case "$t" in
        ''|*N*) return 1 ;;
    esac
    echo "$t"
    return 0
}

# 连通性探测 + 耗时（毫秒）
# 耗时写进全局 PROBE_LATENCY_MS（取不到时间戳就留空）
# 返回值语义与 check_connectivity 相同：0 通 / 1 不通
PROBE_LATENCY_MS=""
probe_with_latency() {
    local target="$1"
    local port="$2"
    local timeout="${3:-3}"
    local t0="" t1="" rc=0

    t0=$(now_us) || t0=""
    if check_connectivity "$target" "$port" "$timeout"; then
        rc=0
    else
        rc=1
    fi
    t1=$(now_us) || t1=""

    PROBE_LATENCY_MS=""
    if [ -n "$t0" ] && [ -n "$t1" ] && [ "$t1" -ge "$t0" ]; then
        PROBE_LATENCY_MS=$(( (t1 - t0) / 1000 ))
    fi
    return $rc
}

# 读取目标在健康状态文件里的整行记录
# 输出格式与状态文件一致（字段以 | 分隔），取不到返回 1
get_health_status_record() {
    local host="$1"
    local status_file="${HEALTH_STATUS_FILE}"
    local line=""

    [ -f "$status_file" ] || return 1
    line=$(grep -F "|${host}|" "$status_file" 2>/dev/null | head -1)
    [ -n "$line" ] || return 1
    echo "$line"
}

# 把时延历史（逗号分隔的样本）算成平均毫秒数
latency_avg_ms() {
    local hist="$1"
    [ -n "$hist" ] || return 1

    local sum=0 n=0 v
    local IFS=','
    for v in $hist; do
        case "$v" in
            ''|*[!0-9]*) continue ;;
        esac
        sum=$((sum + v))
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || return 1
    echo $((sum / n))
}

# 格式化时延展示：最近一次 + 最近若干次平均
format_latency_display() {
    local latency_ms="$1"
    local hist="$2"

    if [ -z "$latency_ms" ]; then
        echo "-"
        return 0
    fi

    local avg
    if avg=$(latency_avg_ms "$hist"); then
        echo "${latency_ms}ms (均 ${avg}ms)"
    else
        echo "${latency_ms}ms"
    fi
}

# 健康检查脚本专用的读取规则文件函数
read_rule_file_for_health_check() {
    local rule_file="$1"
    if [ ! -f "$rule_file" ]; then
        return 1
    fi

    # 清空所有变量
    unset RULE_ID RULE_NAME RULE_ROLE LISTEN_PORT LISTEN_IP THROUGH_IP REMOTE_HOST REMOTE_PORT
    unset FORWARD_TARGET SECURITY_LEVEL
    unset TLS_SERVER_NAME TLS_CERT_PATH TLS_KEY_PATH WS_PATH WS_HOST
    unset ENABLED BALANCE_MODE FAILOVER_ENABLED HEALTH_CHECK_INTERVAL
    unset FAILURE_THRESHOLD SUCCESS_THRESHOLD CONNECTION_TIMEOUT RECOVERY_COOLDOWN
    unset TARGET_STATES WEIGHTS CREATED_TIME

    source "$rule_file"
    return 0
}


# 初始化健康状态文件
if [ ! -f "$HEALTH_STATUS_FILE" ]; then
    echo "# Realm健康状态文件" > "$HEALTH_STATUS_FILE"
    echo "# 格式: RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY" >> "$HEALTH_STATUS_FILE"
fi

# 检查所有启用故障转移的规则
config_changed=false
current_time=$(date +%s)

for rule_file in "${RULES_DIR}"/rule-*.conf; do
    if [ ! -f "$rule_file" ]; then
        continue
    fi

    if ! read_rule_file_for_health_check "$rule_file"; then
        continue
    fi

    # 只检查启用故障转移的中转规则
    if [ "$RULE_ROLE" != "1" ] || [ "$ENABLED" != "true" ] || [ "$FAILOVER_ENABLED" != "true" ]; then
        continue
    fi

    # 处理REMOTE_HOST中的多个地址
    IFS=',' read -ra targets <<< "$REMOTE_HOST"
    for target in "${targets[@]}"; do
        target=$(echo "$target" | xargs)  # 去除空格
        target_key="${RULE_ID}|${target}"

        # 获取当前状态
        status_line=$(grep "^${target_key}|" "$HEALTH_STATUS_FILE" 2>/dev/null)
        if [ -n "$status_line" ]; then
            IFS='|' read -r _ _ status fail_count success_count last_check failure_start_time latency_ms latency_hist <<< "$status_line"
            # 兼容旧格式（没有failure_start_time字段）
            if [ -z "$failure_start_time" ]; then
                failure_start_time="$last_check"
            fi
        else
            status="healthy"
            fail_count=0
            success_count=2
            last_check=0
            failure_start_time=0
            latency_ms=""
            latency_hist=""
        fi

        # 执行健康检查
        if probe_with_latency "$target" "$REMOTE_PORT" "${CONNECTION_TIMEOUT:-3}"; then
            # 检查成功
            success_count=$((success_count + 1))
            fail_count=0

            # 如果之前是故障状态，检查是否可以恢复
            if [ "$status" = "failed" ] && [ "$success_count" -ge "${SUCCESS_THRESHOLD:-2}" ]; then
                # 检查冷却期（基于故障开始时间）
                cooldown_period="${RECOVERY_COOLDOWN:-120}"
                if [ $((current_time - failure_start_time)) -ge "$cooldown_period" ]; then
                    status="healthy"
                    config_changed=true
                    failure_start_time=0  # 重置故障开始时间
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [RECOVERY] 目标 $target:$REMOTE_PORT 已恢复健康"
                fi
            fi
        else
            # 检查失败
            fail_count=$((fail_count + 1))
            success_count=0

            # 如果连续失败达到阈值，标记为故障
            if [ "$status" = "healthy" ] && [ "$fail_count" -ge "${FAILURE_THRESHOLD:-2}" ]; then
                status="failed"
                config_changed=true
                failure_start_time="$current_time"  # 记录故障开始时间
                echo "$(date '+%Y-%m-%d %H:%M:%S') [FAILURE] 目标 $target:$REMOTE_PORT 检测失败，标记为故障"
            fi
        fi

        # 时延历史：保留最近 5 次样本（用于算平均值，避免单次抖动误导）
        if [ -n "$PROBE_LATENCY_MS" ]; then
            latency_ms="$PROBE_LATENCY_MS"
            _lat_hist=()
            IFS=',' read -ra _lat_hist <<< "$latency_hist"
            _lat_hist+=("$latency_ms")
            if [ "${#_lat_hist[@]}" -gt 5 ]; then
                _lat_hist=("${_lat_hist[@]: -5}")
            fi
            latency_hist=$(IFS=','; echo "${_lat_hist[*]}")
        else
            latency_ms=""
        fi

        # 更新状态文件（包含故障开始时间与时延）
        grep -v "^${target_key}|" "$HEALTH_STATUS_FILE" > "$HEALTH_STATUS_FILE.tmp" 2>/dev/null || true
        echo "${target_key}|${status}|${fail_count}|${success_count}|${current_time}|${failure_start_time}|${latency_ms}|${latency_hist}" >> "$HEALTH_STATUS_FILE.tmp"
        mv "$HEALTH_STATUS_FILE.tmp" "$HEALTH_STATUS_FILE"
    done
done

# 如果配置有变化，调用xwPF.sh重启接口
if [ "$config_changed" = true ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 检测到节点状态变化，正在更新配置..."

    # 直接调用主脚本的重启接口
    pf --restart-service >/dev/null 2>&1

    echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 配置更新完成"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 健康检查完成"
EOF
}

start_health_check_service() {
    local health_dir="/etc/realm/health"
    local health_script="/etc/realm/health/health_check.sh"
    local health_timer="/etc/systemd/system/realm-health-check.timer"
    local health_service="/etc/systemd/system/realm-health-check.service"

    local effective_interval="${1:-$(get_effective_health_check_interval)}"

    # 创建健康检查目录
    mkdir -p "$health_dir"


    health_check_script_body > "$health_script"
    chmod +x "$health_script"

    # 创建systemd服务文件
    tr -d '\r' > "$health_service" << EOF
[Unit]
Description=Realm Health Check Service
After=network.target

[Service]
Type=oneshot
ExecStart=$health_script
User=root
WorkingDirectory=/etc/realm
StandardOutput=journal
StandardError=journal
SyslogIdentifier=realm-health

[Install]
WantedBy=multi-user.target
EOF

    # 创建systemd定时器
    tr -d '\r' > "$health_timer" << EOF
[Unit]
Description=Realm Health Check Timer
Requires=realm-health-check.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=${effective_interval}sec
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 启用并启动定时器
    systemctl daemon-reload
    systemctl enable realm-health-check.timer >/dev/null 2>&1
    systemctl start realm-health-check.timer >/dev/null 2>&1

    echo -e "${GREEN}✓ 健康检查服务已启动 (检查间隔: ${effective_interval}s)${NC}"
}

stop_health_check_service() {
    # 停止并禁用健康检查服务
    systemctl stop realm-health-check.timer >/dev/null 2>&1
    systemctl disable realm-health-check.timer >/dev/null 2>&1
    systemctl stop realm-health-check.service >/dev/null 2>&1
    systemctl disable realm-health-check.service >/dev/null 2>&1

    # 删除服务文件
    rm -f "/etc/systemd/system/realm-health-check.timer"
    rm -f "/etc/systemd/system/realm-health-check.service"
    rm -f "/etc/realm/health/health_check.sh"

    systemctl daemon-reload

    echo -e "${GREEN}✓ 健康检查服务已停止${NC}"
}
