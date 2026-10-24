#!/bin/bash

# 故障转移管理脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

RULES_DIR="/etc/realm/rules"
HEALTH_STATUS_FILE="/etc/realm/health/health_status.conf"
HEALTH_DIR="/etc/realm/health"
LOCK_FILE="/var/lock/realm-health-check.lock"

validate_int_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local field_name="$4"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}${field_name} 必须是数字${NC}"
        return 1
    fi

    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo -e "${RED}${field_name} 超出范围: ${min}-${max}${NC}"
        return 1
    fi

    return 0
}



# 健康检查逻辑统一放在 lib/health.sh（唯一真源），这里只加载不重复实现
HEALTH_LIB=""
for _hc in "/usr/local/bin/lib/health.sh" "/etc/realm/lib/health.sh" "$(dirname "$0")/lib/health.sh"; do
    if [ -f "$_hc" ]; then
        HEALTH_LIB="$_hc"
        break
    fi
done

if [ -n "$HEALTH_LIB" ]; then
    # shellcheck disable=SC1090
    . "$HEALTH_LIB"
else
    echo -e "${RED}错误: 缺少 lib/health.sh，请先执行 pf install 更新脚本${NC}" >&2
    exit 1
fi

# read_rule_file / check_connectivity 的唯一实现在 lib/health.sh。
# 装的 lib/health.sh 版本过旧时（升级前遗留），明确报错而不是让调用处报 command not found。
if ! declare -F read_rule_file >/dev/null 2>&1; then
    echo -e "${RED}错误: lib/health.sh 版本过旧（缺少 read_rule_file），请先执行 pf install 更新脚本${NC}" >&2
    exit 1
fi

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行。${NC}"
        exit 1
    fi
}

# 连通性检查

# 读取规则文件：read_rule_file 由 lib/health.sh 提供（白名单逐行解析）。
# 这里**不再**自己实现一份 ——
# 旧实现用 source "$rule_file" 解析规则文件，规则文件里的 $(...) 会被执行；
# 而生成的 health_check.sh 是以 root 跑的，等于开了一个 root 提权面。

# 查找文件路径
find_file_path() {
    local filename="$1"
    local cache_file="/tmp/realm_path_cache"
    local cache_timeout=3600

    # 常见位置直接检查
    local common_paths=(
        "/etc/realm/health/$filename"
        "/etc/realm/$filename"
        "/var/lib/realm/$filename"
        "/opt/realm/$filename"
        "/usr/local/realm/$filename"
        "/tmp/$filename"
    )

    for path in "${common_paths[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    # 缓存检查
    if [ -f "$cache_file" ]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
        if [ "$cache_age" -lt "$cache_timeout" ]; then
            local cached_path=$(grep "^$filename:" "$cache_file" 2>/dev/null | cut -d: -f2-)
            if [ -n "$cached_path" ] && [ -f "$cached_path" ]; then
                echo "$cached_path"
                return 0
            fi
        fi
    fi

    # 全局搜索
    local found_path=$(find /etc /var /opt /usr/local -name "$filename" -type f 2>/dev/null | head -1)
    if [ -n "$found_path" ]; then
        echo "$filename:$found_path" >> "$cache_file"
        echo "$found_path"
        return 0
    fi

    return 1
}

# 故障转移切换功能（按端口分组管理）
toggle_failover_mode() {
    while true; do
        clear
        echo -e "${YELLOW}=== 开启/关闭故障转移 ===${NC}"
        echo ""

        # 按端口分组收集启用负载均衡的中转服务器规则
        unset port_groups port_configs port_failover_status
        declare -A port_groups
        declare -A port_configs
        declare -A port_failover_status

        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$ENABLED" = "true" ] && [ "$BALANCE_MODE" != "off" ]; then
                    local port_key="$LISTEN_PORT"
                    # 存储端口配置（使用第一个规则的配置作为基准）
                    if [ -z "${port_configs[$port_key]:-}" ]; then
                        port_configs[$port_key]="$RULE_NAME"
                        port_failover_status[$port_key]="${FAILOVER_ENABLED:-false}"
                    fi

                    # 正确处理REMOTE_HOST中可能包含多个地址的情况
                    if [[ "$REMOTE_HOST" == *","* ]]; then
                        # 多个地址的情况
                        IFS=',' read -ra addresses <<< "$REMOTE_HOST"
                        for addr in "${addresses[@]}"; do
                            addr=$(echo "$addr" | xargs)  # 去除空格
                            local target="${addr}:${REMOTE_PORT}"
                            if [ -z "${port_groups[$port_key]:-}" ]; then
                                port_groups[$port_key]="$target"
                            else
                                port_groups[$port_key]="${port_groups[$port_key]:-},$target"
                            fi
                        done
                    else
                        # 单个地址的情况
                        local target="${REMOTE_HOST}:${REMOTE_PORT}"
                        if [ -z "${port_groups[$port_key]:-}" ]; then
                            port_groups[$port_key]="$target"
                        else
                            port_groups[$port_key]="${port_groups[$port_key]:-},$target"
                        fi
                    fi
                fi
            fi
        done

        # 显示可用的规则组
        local has_balance_rules=false
        local rule_ports=()
        local rule_names=()
        local rule_number=1

        if [ ${#port_groups[@]} -gt 0 ]; then
            for port_key in $(printf '%s\n' "${!port_groups[@]}" | sort -n); do
                IFS=',' read -ra targets <<< "${port_groups[$port_key]:-}"
                local target_count=${#targets[@]}

                # 只显示有多个目标服务器的规则组（故障转移的前提条件）
                if [ $target_count -gt 1 ]; then
                    if [ "$has_balance_rules" = false ]; then
                        has_balance_rules=true
                        echo -e "${BLUE}可配置故障转移的规则组:${NC}"
                        echo ""
                    fi

                    rule_ports+=("$port_key")
                    rule_names+=("${port_configs[$port_key]:-}")

                    # 获取故障转移状态
                    local failover_status="${port_failover_status[$port_key]:-}"
                    local status_text="关闭"
                    local status_color="${RED}"

                    if [ "$failover_status" = "true" ]; then
                        status_text="开启"
                        status_color="${GREEN}"
                    fi

                    local params
                    params=$(get_port_failover_params "$port_key")
                    IFS='|' read -r interval failure_threshold success_threshold connection_timeout recovery_cooldown <<< "$params"

                    echo -e "${GREEN}$rule_number.${NC} ${port_configs[$port_key]:-} (端口: $port_key) - $target_count个目标服务器 - 故障转移: ${status_color}$status_text${NC}"
                    echo -e "    ${BLUE}检测间隔:${NC} ${interval}s | ${BLUE}失败阈值:${NC} ${failure_threshold}次 | ${BLUE}成功阈值:${NC} ${success_threshold}次 | ${BLUE}超时:${NC} ${connection_timeout}s | ${BLUE}冷却期:${NC} ${recovery_cooldown}s"
                fi
            done
        fi

        if [ "$has_balance_rules" = false ]; then
            echo -e "${YELLOW}暂无启用负载均衡的规则组${NC}"
            echo -e "${BLUE}提示: 只有开启负载均衡才能使用故障转移功能${NC}"
            echo ""
            echo -e "${BLUE}故障转移的前提条件：${NC}"
            echo -e "${BLUE}  1. 规则类型为中转服务器${NC}"
            echo -e "${BLUE}  2. 已启用负载均衡模式（轮询/IP哈希/主备）${NC}"
            echo -e "${BLUE}  3. 有多个目标服务器${NC}"
            echo ""
            read -p "按回车键返回..."
            return
        fi

        echo ""
        echo -e "${WHITE}注意: 故障转移功能会自动检测节点健康状态并动态调整负载均衡${NC}"
        echo ""
        read -p "请输入规则编号 [1-${#rule_ports[@]}] (或按回车返回): " choice

        if [ -z "$choice" ]; then
            return
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#rule_ports[@]} ]; then
            echo -e "${RED}无效的选择，请输入 1-${#rule_ports[@]} 之间的数字${NC}"
            read -p "按回车键继续..."
            continue
        fi

        local selected_index=$((choice - 1))
        local selected_port="${rule_ports[$selected_index]:-}"
        local rule_name="${rule_names[$selected_index]:-}"

        # 切换故障转移状态
        local current_status="${port_failover_status[$selected_port]:-}"
        local new_status="true"
        local action_text="开启"
        local color="${GREEN}"

        if [ "$current_status" = "true" ]; then
            new_status="false"
            action_text="关闭"
            color="${RED}"
        fi

        # 开启时选择故障转移模式：剔除模式（原有）或 主备模式（新增）
        local failover_type="legacy"
        if [ "$new_status" = "true" ]; then
            echo ""
            echo -e "${BLUE}请选择故障转移模式:${NC}"
            echo -e "${GREEN}1.${NC} 剔除模式（原有） - 故障目标从负载均衡列表中移除"
            echo -e "${BLUE}2.${NC} 主备模式 (active-standby) - 严格主备：1 主 N 备按顺序接替，主恢复后切回主"
            echo ""
            read -p "请选择 [1-2] (默认 1): " failover_type_choice

            case "$failover_type_choice" in
                2)
                    failover_type="active-standby"
                    ;;
                *)
                    failover_type="legacy"
                    ;;
            esac
        fi

        # 直接切换状态，无需确认
        echo -e "${BLUE}正在${action_text}故障转移功能...${NC}"

        # 更新所有相关规则文件
        local updated_count=0
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$selected_port" ]; then
                    # 更新故障转移状态
                    if grep -q "^FAILOVER_ENABLED=" "$rule_file"; then
                        sed -i "s/^FAILOVER_ENABLED=.*/FAILOVER_ENABLED=\"$new_status\"/" "$rule_file"
                    else
                        echo "FAILOVER_ENABLED=\"$new_status\"" >> "$rule_file"
                    fi

                    # 主备模式：同时将该端口下所有规则的 BALANCE_MODE 设为 active-standby
                    # （保证 generate_endpoints_from_rules 走主备分支，按健康状态翻转权重）
                    if [ "$new_status" = "true" ] && [ "$failover_type" = "active-standby" ]; then
                        # 记住原来的负载均衡模式，切出主备时原样还回去
                        if [ "${BALANCE_MODE:-off}" != "active-standby" ]; then
                            local prev_mode="${BALANCE_MODE:-off}"
                            case "$prev_mode" in
                                roundrobin|iphash) ;;
                                *) prev_mode="roundrobin" ;;
                            esac
                            if grep -q "^PREV_BALANCE_MODE=" "$rule_file"; then
                                sed -i "s|^PREV_BALANCE_MODE=.*|PREV_BALANCE_MODE=\"$prev_mode\"|" "$rule_file"
                            else
                                echo "PREV_BALANCE_MODE=\"$prev_mode\"" >> "$rule_file"
                            fi
                        fi
                        if grep -q "^BALANCE_MODE=" "$rule_file"; then
                            sed -i "s/^BALANCE_MODE=.*/BALANCE_MODE=\"active-standby\"/" "$rule_file"
                        else
                            echo "BALANCE_MODE=\"active-standby\"" >> "$rule_file"
                        fi
                    fi

                    updated_count=$((updated_count + 1))
                fi
            fi
        done

        echo -e "${color}✓ 已更新 $updated_count 个规则文件的故障转移状态${NC}"

        if [ "$new_status" = "true" ] && [ "$failover_type" = "active-standby" ]; then
            echo -e "${BLUE}已选择主备模式 (active-standby): 1 主 N 备按顺序接替${NC}"
        fi

        if [ "$new_status" = "true" ]; then
            local params
            params=$(get_port_failover_params "$selected_port")
            IFS='|' read -r interval failure_threshold success_threshold connection_timeout recovery_cooldown <<< "$params"
            echo -e "${BLUE}故障转移参数:${NC}"
            echo -e "  检查间隔: ${GREEN}${interval}秒${NC}"
            echo -e "  失败阈值: ${GREEN}连续${failure_threshold}次${NC}"
            echo -e "  成功阈值: ${GREEN}连续${success_threshold}次${NC}"
            echo -e "  连接超时: ${GREEN}${connection_timeout}秒${NC}"
            echo -e "  恢复冷却: ${GREEN}${recovery_cooldown}秒${NC}"
        fi

        # 重启服务以应用更改
        echo -e "${YELLOW}正在重启服务以应用故障转移设置...${NC}"
        restart_realm_service

        # 管理健康检查服务
        if [ "$new_status" = "true" ]; then
            echo -e "${BLUE}正在启动健康检查服务...${NC}"
            start_health_check_service
        else
            # 检查是否还有其他规则启用了故障转移
            local has_other_failover=false
            for rule_file in "${RULES_DIR}"/rule-*.conf; do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file" && [ "$FAILOVER_ENABLED" = "true" ]; then
                        has_other_failover=true
                        break
                    fi
                fi
            done

            if [ "$has_other_failover" = false ]; then
                echo -e "${BLUE}正在停止健康检查服务...${NC}"
                stop_health_check_service
            fi
        fi

        echo -e "${GREEN}✓ 故障转移设置已生效${NC}"
        echo ""
        read -p "按回车键继续..."
        # 重新显示菜单以显示更新的状态
    done
}

# 健康检查服务管理

configure_failover_params() {
    clear
    echo -e "${YELLOW}=== 故障转移参数配置（按端口组） ===${NC}"
    echo ""

    unset port_groups port_configs
    declare -A port_groups
    declare -A port_configs

    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ] && read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$ENABLED" = "true" ] && [ "$BALANCE_MODE" != "off" ]; then
            local port_key="$LISTEN_PORT"
            [ -z "${port_configs[$port_key]:-}" ] && port_configs[$port_key]="$RULE_NAME"

            IFS=',' read -ra hosts <<< "$REMOTE_HOST"
            for host in "${hosts[@]}"; do
                host=$(echo "$host" | xargs)
                [ -z "$host" ] && continue
                local target="${host}:${REMOTE_PORT}"
                if [ -z "${port_groups[$port_key]:-}" ]; then
                    port_groups[$port_key]="$target"
                elif [[ ",${port_groups[$port_key]:-}," != *",${target},"* ]]; then
                    port_groups[$port_key]="${port_groups[$port_key]:-},${target}"
                fi
            done
        fi
    done

    local selectable_ports=()
    local selectable_names=()
    local idx=1

    for port_key in $(printf '%s\n' "${!port_groups[@]}" | sort -n); do
        IFS=',' read -ra targets <<< "${port_groups[$port_key]:-}"
        if [ "${#targets[@]}" -gt 1 ]; then
            selectable_ports+=("$port_key")
            selectable_names+=("${port_configs[$port_key]:-}")
            echo -e "${GREEN}${idx}.${NC} ${port_configs[$port_key]:-} (端口: $port_key)"
            idx=$((idx + 1))
        fi
    done

    if [ ${#selectable_ports[@]} -eq 0 ]; then
        echo -e "${YELLOW}暂无可配置的故障转移规则组（需中转+负载均衡+多目标）${NC}"
        return 1
    fi

    echo ""
    read -p "请选择规则编号 [1-${#selectable_ports[@]}] (回车返回): " choice
    [ -z "$choice" ] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#selectable_ports[@]} ]; then
        echo -e "${RED}无效的编号${NC}"
        return 1
    fi

    local selected_index=$((choice - 1))
    local selected_port="${selectable_ports[$selected_index]:-}"
    local selected_name="${selectable_names[$selected_index]:-}"

    local params
    params=$(get_port_failover_params "$selected_port")
    IFS='|' read -r current_interval current_failure current_success current_timeout current_cooldown <<< "$params"

    echo ""
    echo -e "${BLUE}当前规则组:${NC} ${selected_name} (端口: ${selected_port})"
    read -p "检查间隔秒数 [当前 ${current_interval}]: " input_interval
    read -p "失败阈值(连续失败次数) [当前 ${current_failure}]: " input_failure
    read -p "成功阈值(连续成功次数) [当前 ${current_success}]: " input_success
    read -p "连接超时秒数 [当前 ${current_timeout}]: " input_timeout
    read -p "恢复冷却秒数 [当前 ${current_cooldown}]: " input_cooldown

    local new_interval="${input_interval:-$current_interval}"
    local new_failure="${input_failure:-$current_failure}"
    local new_success="${input_success:-$current_success}"
    local new_timeout="${input_timeout:-$current_timeout}"
    local new_cooldown="${input_cooldown:-$current_cooldown}"

    # 参数阈值限制：超出范围直接报错并返回
    validate_int_range "$new_interval" 1 60 "检查间隔(秒)" || return 1
    validate_int_range "$new_failure" 1 10 "失败阈值(次)" || return 1
    validate_int_range "$new_success" 1 10 "成功阈值(次)" || return 1
    validate_int_range "$new_timeout" 1 10 "连接超时(秒)" || return 1
    validate_int_range "$new_cooldown" 10 3600 "恢复冷却(秒)" || return 1

    local updated_count=0
    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ] && read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$selected_port" ]; then
            if grep -q '^HEALTH_CHECK_INTERVAL=' "$rule_file"; then
                sed -i "s/^HEALTH_CHECK_INTERVAL=.*/HEALTH_CHECK_INTERVAL=\"$new_interval\"/" "$rule_file"
            else
                echo "HEALTH_CHECK_INTERVAL=\"$new_interval\"" >> "$rule_file"
            fi

            if grep -q '^FAILURE_THRESHOLD=' "$rule_file"; then
                sed -i "s/^FAILURE_THRESHOLD=.*/FAILURE_THRESHOLD=\"$new_failure\"/" "$rule_file"
            else
                echo "FAILURE_THRESHOLD=\"$new_failure\"" >> "$rule_file"
            fi

            if grep -q '^SUCCESS_THRESHOLD=' "$rule_file"; then
                sed -i "s/^SUCCESS_THRESHOLD=.*/SUCCESS_THRESHOLD=\"$new_success\"/" "$rule_file"
            else
                echo "SUCCESS_THRESHOLD=\"$new_success\"" >> "$rule_file"
            fi

            if grep -q '^CONNECTION_TIMEOUT=' "$rule_file"; then
                sed -i "s/^CONNECTION_TIMEOUT=.*/CONNECTION_TIMEOUT=\"$new_timeout\"/" "$rule_file"
            else
                echo "CONNECTION_TIMEOUT=\"$new_timeout\"" >> "$rule_file"
            fi

            if grep -q '^RECOVERY_COOLDOWN=' "$rule_file"; then
                sed -i "s/^RECOVERY_COOLDOWN=.*/RECOVERY_COOLDOWN=\"$new_cooldown\"/" "$rule_file"
            else
                echo "RECOVERY_COOLDOWN=\"$new_cooldown\"" >> "$rule_file"
            fi

            updated_count=$((updated_count + 1))
        fi
    done

    echo -e "${GREEN}✓ 已更新 $updated_count 个规则文件参数${NC}"
    echo -e "${YELLOW}正在重启Realm服务...${NC}"
    restart_realm_service

    local has_enabled_failover=false
    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ] && read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$ENABLED" = "true" ] && [ "${FAILOVER_ENABLED:-false}" = "true" ]; then
            has_enabled_failover=true
            break
        fi
    done

    if [ "$has_enabled_failover" = "true" ]; then
        echo -e "${YELLOW}正在刷新健康检查定时器（按新间隔）...${NC}"
        start_health_check_service "$(get_effective_health_check_interval)"
    fi

    return 0
}

# 停止健康检查服务

# 查看健康状态
show_health_status() {
    echo -e "${YELLOW}=== 健康状态查看 ===${NC}"
    echo ""

    # 动态查找健康状态文件
    local health_status_file=$(find_file_path "health_status.conf")

    if [ ! -f "$health_status_file" ]; then
        echo -e "${YELLOW}健康状态文件不存在${NC}"
        return
    fi

    echo -e "${BLUE}健康状态文件: ${health_status_file}${NC}"
    echo ""

    # 读取并显示健康状态
    local has_data=false
    while read -r line; do
        # 跳过注释行和空行
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        has_data=true
        IFS='|' read -r rule_target _ status fail_count success_count last_check failure_start_time <<< "$line"

        local rule_id=$(echo "$rule_target" | cut -d'|' -f1)
        local target=$(echo "$rule_target" | cut -d'|' -f2)

        # 格式化时间
        local last_check_time="未知"
        if [ "$last_check" != "0" ] && [ -n "$last_check" ]; then
            last_check_time=$(date -d "@$last_check" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
        fi

        # 状态颜色
        local status_color="${GREEN}"
        local status_text="健康"
        if [ "$status" = "failed" ]; then
            status_color="${RED}"
            status_text="故障"
        fi

        echo -e "${BLUE}规则ID: ${rule_id}${NC}"
        echo -e "  目标: ${target}"
        echo -e "  状态: ${status_color}${status_text}${NC}"
        echo -e "  失败次数: ${fail_count}"
        echo -e "  成功次数: ${success_count}"
        echo -e "  最后检查: ${last_check_time}"
        echo ""
    done < "$health_status_file"

    if [ "$has_data" = false ]; then
        echo -e "${YELLOW}暂无健康状态数据${NC}"
    fi
}

show_help() {
    echo -e "${GREEN}xwFailover.sh - Realm故障转移管理脚本${NC}"
    echo ""
    echo "用法:"
    echo "  $0 toggle [port]          # 切换故障转移状态"
    echo "  $0 config                 # 配置故障转移参数(间隔/阈值/超时/冷却)"
    echo "  $0 status                 # 查看健康状态"
    echo "  $0 start                  # 启动健康检查服务"
    echo "  $0 stop                   # 停止健康检查服务"
    echo "  $0 restart-realm          # 重启realm服务"
    echo "  $0 help                   # 显示帮助信息"
}

# 重启realm服务（调用xwPF.sh的重启接口）
restart_realm_service() {
    echo -e "${BLUE}调用主脚本的重启接口...${NC}"

    # 直接调用主脚本的重启接口
    pf --restart-service
}

# 主函数
main() {
    check_root

    case "${1:-toggle}" in
        "toggle")
            toggle_failover_mode
            ;;
        "status")
            show_health_status
            ;;
        "config")
            configure_failover_params
            ;;
        "start")
            start_health_check_service
            ;;
        "stop")
            stop_health_check_service
            ;;
        "restart-realm")
            restart_realm_service
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
