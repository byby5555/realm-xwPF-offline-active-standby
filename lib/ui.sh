
# 每次更新OCR脚本
download_realm_ocr_script() {
    local script_url="https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xw_realm_OCR.sh"
    local target_path="/etc/realm/xw_realm_OCR.sh"

    echo -e "${GREEN}正在下载最新realm配置识别脚本...${NC}"

    mkdir -p "$(dirname "$target_path")"

    if download_from_sources "$script_url" "$target_path"; then
        chmod +x "$target_path"
        return 0
    else
        echo -e "${RED}请检查网络连接${NC}"
        return 1
    fi
}

import_realm_config() {
    local ocr_script="/etc/realm/xw_realm_OCR.sh"

    if ! download_realm_ocr_script; then
        echo -e "${RED}无法下载配置识别脚本，功能暂时不可用${NC}"
        ui_pause "按回车键返回..."
        return 1
    fi

    bash "$ocr_script" "$RULES_DIR"

    echo ""
    ui_pause "按回车键返回..."
}


rules_management_menu() {
    while true; do
        sleep 0.2
        ui_clear
        echo -e "${GREEN}=== 转发配置管理 ===${NC}"
        echo ""

        local status=$(svc_status_text)
        if [ "$status" = "active" ]; then
            echo -e "服务状态: ${GREEN}●${NC} 运行中"
        else
            echo -e "服务状态: ${RED}●${NC} 已停止"
        fi

        local enabled_count=0
        local disabled_count=0
        if [ -d "$RULES_DIR" ]; then
            for rule_file in "${RULES_DIR}"/rule-*.conf; do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file"; then
                        if [ "$ENABLED" = "true" ]; then
                            enabled_count=$((enabled_count + 1))
                        else
                            disabled_count=$((disabled_count + 1))
                        fi
                    fi
                fi
            done
        fi

        if [ "$enabled_count" -gt 0 ] || [ "$disabled_count" -gt 0 ]; then
            local total_count=$((enabled_count + disabled_count))
            echo -e "配置模式: ${GREEN}多规则模式${NC} (${GREEN}$enabled_count${NC} 启用 / ${YELLOW}$disabled_count${NC} 禁用 / 共 $total_count 个)"

            if [ "$enabled_count" -gt 0 ]; then
                local has_relay_rules=false
                local relay_count=0
                for rule_file in "${RULES_DIR}"/rule-*.conf; do
                    if [ -f "$rule_file" ]; then
                        if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$RULE_ROLE" = "1" ]; then
                            if [ "$has_relay_rules" = false ]; then
                                echo -e "${GREEN}中转服务器:${NC}"
                                has_relay_rules=true
                            fi
                            relay_count=$((relay_count + 1))
                            local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                            local display_target=$(smart_display_target "$REMOTE_HOST")
                            local rule_display_name="$RULE_NAME"
                            local display_ip="${NAT_LISTEN_IP:-::}"
                            local through_display="${THROUGH_IP:-::}"
                            echo -e "  • ${GREEN}$rule_display_name${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT"
                            local note_display=""
                            if [ -n "$RULE_NOTE" ]; then
                                note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                            fi
                            get_rule_status_display "$security_display" "$note_display"

                        fi
                    fi
                done

                local has_exit_rules=false
                local exit_count=0
                for rule_file in "${RULES_DIR}"/rule-*.conf; do
                    if [ -f "$rule_file" ]; then
                        if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$RULE_ROLE" = "2" ]; then
                            if [ "$has_exit_rules" = false ]; then
                                if [ "$has_relay_rules" = true ]; then
                                    echo ""
                                fi
                                echo -e "${GREEN}服务端服务器 (双端Realm架构):${NC}"
                                has_exit_rules=true
                            fi
                            exit_count=$((exit_count + 1))
                            local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                            # 服务端服务器使用FORWARD_TARGET而不是REMOTE_HOST
                            local target_host="${FORWARD_TARGET%:*}"
                            local target_port="${FORWARD_TARGET##*:}"
                            local display_target=$(smart_display_target "$target_host")
                            local rule_display_name="$RULE_NAME"
                            local display_ip="::"
                            echo -e "  • ${GREEN}$rule_display_name${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $display_target:$target_port"
                            local note_display=""
                            if [ -n "$RULE_NOTE" ]; then
                                note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                            fi
                            get_rule_status_display "$security_display" "$note_display"

                        fi
                    fi
                done
            fi

            if [ "$disabled_count" -gt 0 ]; then
                echo -e "${YELLOW}禁用的规则:${NC}"
                for rule_file in "${RULES_DIR}"/rule-*.conf; do
                    if [ -f "$rule_file" ]; then
                        if read_rule_file "$rule_file" && [ "$ENABLED" = "false" ]; then
                            if [ "$RULE_ROLE" = "2" ]; then
                                local target_host="${FORWARD_TARGET%:*}"
                                local target_port="${FORWARD_TARGET##*:}"
                                local display_target=$(smart_display_target "$target_host")
                                echo -e "  • ${GRAY}$RULE_NAME${NC}: $LISTEN_PORT → $display_target:$target_port (已禁用)"
                            else
                                local display_target=$(smart_display_target "$REMOTE_HOST")
                                local through_display="${THROUGH_IP:-::}"
                                echo -e "  • ${GRAY}$RULE_NAME${NC}: $LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT (已禁用)"
                            fi
                        fi
                    fi
                done
            fi
        else
            echo -e "配置模式: ${BLUE}暂无配置${NC}"
        fi

        echo ""

        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 一键导出/导入配置"
        echo -e "${GREEN}2.${NC} 添加新配置"
        echo -e "${GREEN}3.${NC} 编辑现有规则"
        echo -e "${GREEN}4.${NC} 删除配置"
        echo -e "${GREEN}5.${NC} 启用/禁用中转规则"
        echo -e "${BLUE}6.${NC} 负载均衡管理"
        echo -e "${YELLOW}7.${NC} 开启/关闭 MPTCP"
        echo -e "${GREEN}8.${NC} 开启/关闭 Proxy Protocol"
        echo -e "${GRAY}提示: 主备 / 负载均衡 走「6. 负载均衡管理 → 权重配置管理」 权重 ${GREEN}10,0${NC} = 主备(主故障自动切备), ${GREEN}5,5${NC} = 负载均衡(按比例分流)${NC}"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""

        ui_read_into "请输入选择 [0-8]: " choice
        echo ""

        case $choice in
            1)
                while true; do
                    sleep 0.2
                    ui_clear
                    echo -e "${GREEN}=== 配置文件管理 ===${NC}"
                    echo ""
                    echo "请选择操作:"
                    echo -e "${GREEN}1.${NC} 导出配置包(包含查看配置)"
                    echo -e "${GREEN}2.${NC} 导入配置包"
                    echo -e "${GREEN}3.${NC} 识别realm配置文件并导入"
                    echo -e "${GREEN}0.${NC} 返回上级菜单"
                    echo ""
                    ui_read_into "请输入选择 [0-3]: " sub_choice
                    echo ""

                    case $sub_choice in
                        1)
                            export_config_with_view
                            ;;
                        2)
                            import_config_package
                            ;;
                        3)
                            import_realm_config
                            ;;
                        0)
                            break
                            ;;
                        *)
                            echo -e "${RED}无效选择，请重新输入${NC}"
                            ui_pause "按回车键继续..."
                            ;;
                    esac
                done
                ;;
            2)
                interactive_add_rule
                if [ $? -eq 0 ]; then
                    echo -e "${YELLOW}正在重启服务以应用新配置...${NC}"
                    service_restart
                fi
                ui_pause "按回车键继续..."
                ;;
            3)
                edit_rule_interactive
                ;;
            4)
                echo -e "${YELLOW}=== 删除配置 ===${NC}"
                echo ""
                if list_rules_with_info "management"; then
                    echo ""
                    ui_read_into "请输入要删除的规则ID(多ID使用逗号,分隔): " rule_input

                    if [ -z "$rule_input" ]; then
                        echo -e "${RED}错误: 请输入规则ID${NC}"
                    else
                        if [[ "$rule_input" == *","* ]]; then
                            batch_delete_rules "$rule_input"
                        else
                            if [[ "$rule_input" =~ ^[0-9]+$ ]]; then
                                delete_rule "$rule_input"
                            else
                                echo -e "${RED}无效的规则ID${NC}"
                            fi
                        fi

                        if [ $? -eq 0 ]; then
                            echo -e "${YELLOW}正在重启服务以应用配置更改...${NC}"
                            service_restart
                        fi
                    fi
                fi
                ui_pause "按回车键继续..."
                ;;
            5)
                echo -e "${YELLOW}=== 启用/禁用中转规则 ===${NC}"
                echo ""
                if list_rules_with_info "management"; then
                    echo ""
                    ui_read_into "请输入要切换状态的规则ID: " rule_id
                    if [[ "$rule_id" =~ ^[0-9]+$ ]]; then
                        toggle_rule "$rule_id"
                        if [ $? -eq 0 ]; then
                            echo -e "${YELLOW}正在重启服务以应用状态更改...${NC}"
                            service_restart
                        fi
                    else
                        echo -e "${RED}无效的规则ID${NC}"
                    fi
                fi
                ui_pause "按回车键继续..."
                ;;
            6)
                load_balance_management_menu
                ;;
            7)
                mptcp_management_menu
                ;;
            8)
                proxy_management_menu
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-8${NC}"
                ui_pause "按回车键继续..."
                ;;
        esac
    done
}

# 清理老机器上的主备池守护残留
# ★ 该功能已随「进程级主备池」整块下线（守护进程 / systemd unit / drop-in /
#   池配置 / 崩溃循环防护整套移除），但老机器上还留着。
#   不收拾掉 → 留下一个没人管、但还占着端口的僵尸守护（18443 / 18444 仍被监听）。
#
#   本函数**自包含**：不依赖已删除的 lib/failover.sh。
#   ★ 放在 lib/ui.sh 而不是 xwPF.sh：菜单项 8「卸载服务」直接走 uninstall_realm，
#     **不经过 xwPF.sh uninstall** —— 清理写在 xwPF.sh 里，菜单卸载时够不着。
#
#   每一步都容错：不存在就跳过；清理失败也不让卸载失败（只提示）。
#   用户的池配置（/etc/xwpf/*.json）**不删** —— 那是用户自己的东西，
#   删了没法回查 → 改名成 .disabled 留档。
_cleanup_legacy_failover_daemon() {
    local unit="/etc/systemd/system/xwpf-failover.service"
    local unit_alt="/lib/systemd/system/xwpf-failover.service"
    local dropin_dir="/etc/systemd/system/xwpf-failover.service.d"
    local daemon_bin="/usr/local/bin/xwpf-failover"
    local version_file="/usr/local/bin/.xwpf-failover-version"
    local pool_conf="/etc/xwpf/failover.json"
    local pool_state="/etc/xwpf/failover-state.json"
    local cleaned=0

    # 1) 停掉老守护服务（先 stop 再 disable：停了就不会再被拉起来）
    systemctl stop xwpf-failover >/dev/null 2>&1 || true
    systemctl disable xwpf-failover >/dev/null 2>&1 || true
    # 兜底：不在 systemd 管辖下的残留进程（它还占着 18443 / 18444）
    if pgrep -f "xwpf-failover" >/dev/null 2>&1; then
        pkill -f "xwpf-failover" >/dev/null 2>&1 || true
        sleep 1
        pkill -9 -f "xwpf-failover" >/dev/null 2>&1 || true
        cleaned=1
    fi

    # 2) 删掉老 unit 文件
    [ -f "$unit" ] && { rm -f "$unit"; cleaned=1; }
    [ -f "$unit_alt" ] && { rm -f "$unit_alt"; cleaned=1; }

    # 3) 删掉老 drop-in 目录（崩溃循环防护那几行在里面）
    [ -d "$dropin_dir" ] && { rm -rf "$dropin_dir"; cleaned=1; }

    # 4) 删掉老 daemon 二进制
    [ -f "$daemon_bin" ] && { rm -f "$daemon_bin"; cleaned=1; }
    [ -f "$version_file" ] && { rm -f "$version_file"; cleaned=1; }

    # 5) 用户的池配置 / 状态：不删，改名留档（删了用户没法回查）
    [ -f "$pool_conf" ] && { mv -f "$pool_conf" "${pool_conf}.disabled" 2>/dev/null || true; cleaned=1; }
    [ -f "$pool_state" ] && { mv -f "$pool_state" "${pool_state}.disabled" 2>/dev/null || true; cleaned=1; }

    # 6) 让 systemd 忘掉被删掉的 unit
    systemctl daemon-reload >/dev/null 2>&1 || true

    if [ "$cleaned" = "1" ]; then
        echo -e "  ${GREEN}✓${NC} 已清理主备池守护残留（老机器上的 xwpf-failover）"
    fi

    return 0
}

# 卸载函数
uninstall_realm() {
    echo -e "${RED}⚠️  警告: 即将分阶段卸载 Realm 端口转发服务${NC}"
    echo ""
    # 第 0 步：清理老机器上的主备池守护残留（这个功能已经下线，残留必须收拾干净，
    #   否则会留下一个没人管、但还占着端口的僵尸守护）
    _cleanup_legacy_failover_daemon
    echo ""

    # 第一阶段：Realm 服务和配置
    echo -e "${YELLOW}=== 第一阶段：Realm 相关全部服务和配置文件 ===${NC}"
    ui_read_into "确认删除 Realm 服务和配置？(y/n): " confirm_realm
    if [[ "$confirm_realm" =~ ^[Yy]$ ]]; then
        uninstall_realm_stage_one
        echo -e "${GREEN}✓ 第一阶段完成${NC}"
    else
        echo -e "${BLUE}第一阶段已取消${NC}"
        return 0
    fi

    echo ""
    # 第二阶段：脚本文件
    echo -e "${YELLOW}=== 第二阶段：xwPF 脚本相关全部文件 ===${NC}"
    ui_read_into "确认删除脚本文件？(y/n): " confirm_script
    if [[ "$confirm_script" =~ ^[Yy]$ ]]; then
        uninstall_script_files
        echo -e "${GREEN}🗑️  完全卸载完成${NC}"
    else
        echo -e "${BLUE}脚本文件保留，可继续使用 pf 命令${NC}"
    fi
}

# 第一阶段：清理 Realm 相关
uninstall_realm_stage_one() {
    # 停止服务
    svc_is_active && svc_stop
    [ "$(svc_enabled_text)" = "enabled" ] && svc_disable
    # 停止健康检查服务（通过xwFailover.sh）
    if [ -f "/etc/realm/xwFailover.sh" ]; then
        bash "/etc/realm/xwFailover.sh" stop >/dev/null 2>&1
    fi

    pgrep "realm" >/dev/null 2>&1 && { pkill -f "realm"; sleep 2; pkill -9 -f "realm" 2>/dev/null; }

    # 清理文件
    cleanup_files_by_paths "$REALM_PATH" "$CONFIG_DIR" "$SYSTEMD_PATH" "/etc/realm"
    [ -f "/etc/init.d/realm" ] && rm -f "/etc/init.d/realm"
    [ -f "/etc/systemd/system/realm-web.service" ] && rm -f "/etc/systemd/system/realm-web.service"
        cleanup_files_by_pattern "realm" "/var/log /tmp /var/tmp"


    # 清理系统配置
    [ -f "/etc/sysctl.d/90-enable-MPTCP.conf" ] && rm -f "/etc/sysctl.d/90-enable-MPTCP.conf"
    command -v ip >/dev/null 2>&1 && ip mptcp endpoint flush 2>/dev/null
    svc_daemon_reload
}

# 第二阶段：清理脚本文件
uninstall_script_files() {
    # 清理主脚本和模块目录
    rm -f "$INSTALL_DIR/xwPF.sh"
    [ -d "$LIB_DIR" ] && rm -rf "$LIB_DIR"

    [ -d "$INSTALL_DIR/cmd" ] && rm -rf "$INSTALL_DIR/cmd"

    # 清理 pf 快捷命令（symlink 或 wrapper）
    local exec_dirs=("/usr/local/bin" "/usr/bin" "/bin" "/opt/bin" "/root/bin")
    for dir in "${exec_dirs[@]}"; do
        [ -f "$dir/pf" ] && grep -q "xwPF" "$dir/pf" 2>/dev/null && rm -f "$dir/pf"
        [ -L "$dir/pf" ] && rm -f "$dir/pf"
    done
}

# 文件路径清理函数
cleanup_files_by_paths() {
    for path in "$@"; do
        if [ -f "$path" ]; then
            rm -f "$path"
        elif [ -d "$path" ]; then
            rm -rf "$path"
        fi
    done
}

# 文件模式清理函数
cleanup_files_by_pattern() {
    local pattern="$1"
    local search_dirs="${2:-/}"

    IFS=' ' read -ra dirs_array <<< "$search_dirs"
    for dir in "${dirs_array[@]}"; do
        [ -d "$dir" ] && find "$dir" -name "*${pattern}*" -type f 2>/dev/null | while read -r file; do
            [ -f "$file" ] && rm -f "$file"
        done &
    done
    wait
}

# 显示转发目标地址（处理本地地址和多地址）
# 显示简要状态信息（避免网络请求）
show_brief_status() {
    echo ""
    echo -e "${BLUE}=== 当前状态 ===${NC}"

    # 检查 realm 二进制文件是否存在
    if [ ! -f "${REALM_PATH}" ] || [ ! -x "${REALM_PATH}" ]; then
        echo -e " Realm状态：${RED} 未安装 ${NC}"
        echo -e "${YELLOW}请选择 1. 安装(更新)程序,脚本 ${NC}"
        return
    fi

    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${YELLOW}=== 配置缺失 ===${NC}"
        echo -e "${BLUE}Realm 已安装但配置缺失，请运行 安装配置/添加配置 来初始化配置${NC}"
        return
    fi

    # 正常状态显示
    local status=$(svc_status_text)
    if [ "$status" = "active" ]; then
        echo -e "服务状态: ${GREEN}●${NC} 运行中"
    else
        echo -e "服务状态: ${RED}●${NC} 已停止"
    fi

    # 检查是否有多规则配置
    local has_rules=false
    local enabled_count=0
    local disabled_count=0
    if [ -d "$RULES_DIR" ]; then
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file"; then
                    if [ "$ENABLED" = "true" ]; then
                        has_rules=true
                        enabled_count=$((enabled_count + 1))
                    else
                        disabled_count=$((disabled_count + 1))
                    fi
                fi
            fi
        done
    fi

    if [ "$has_rules" = true ] || [ "$disabled_count" -gt 0 ]; then
        # 多规则模式
        local total_count=$((enabled_count + disabled_count))
        echo -e "配置模式: ${GREEN}多规则模式${NC} (${GREEN}$enabled_count${NC} 启用 / ${YELLOW}$disabled_count${NC} 禁用 / 共 $total_count 个)"

        # 按服务器类型分组显示启用的规则
        if [ "$enabled_count" -gt 0 ]; then
            # 中转服务器规则
            local has_relay_rules=false
            local relay_count=0
            for rule_file in "${RULES_DIR}"/rule-*.conf; do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$RULE_ROLE" = "1" ]; then
                        if [ "$has_relay_rules" = false ]; then
                            echo -e "${GREEN}中转服务器:${NC}"
                            has_relay_rules=true
                        fi
                        relay_count=$((relay_count + 1))
                        # 显示详细的转发配置信息
                        local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                        local display_target=$(smart_display_target "$REMOTE_HOST")
                        local rule_display_name="$RULE_NAME"
                        local display_ip="${NAT_LISTEN_IP:-::}"
                        local through_display="${THROUGH_IP:-::}"
                        echo -e "  • ${GREEN}$rule_display_name${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT"
                        local note_display=""
                        if [ -n "$RULE_NOTE" ]; then
                            note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                        fi
                        # 显示状态信息
                        get_rule_status_display "$security_display" "$note_display"

                    fi
                fi
            done

            # 服务端服务器规则
            local has_exit_rules=false
            local exit_count=0
            for rule_file in "${RULES_DIR}"/rule-*.conf; do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$RULE_ROLE" = "2" ]; then
                        if [ "$has_exit_rules" = false ]; then
                            if [ "$has_relay_rules" = true ]; then
                                echo ""
                            fi
                            echo -e "${GREEN}服务端服务器 (双端Realm架构):${NC}"
                            has_exit_rules=true
                        fi
                        exit_count=$((exit_count + 1))
                        # 显示详细的转发配置信息
                        local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                        # 服务端服务器使用FORWARD_TARGET而不是REMOTE_HOST
                        local target_host="${FORWARD_TARGET%:*}"
                        local target_port="${FORWARD_TARGET##*:}"
                        local display_target=$(smart_display_target "$target_host")
                        local rule_display_name="$RULE_NAME"
                        local display_ip="::"
                        echo -e "  • ${GREEN}$rule_display_name${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $display_target:$target_port"
                        local note_display=""
                        if [ -n "$RULE_NOTE" ]; then
                            note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                        fi
                        # 显示状态信息
                        get_rule_status_display "$security_display" "$note_display"

                    fi
                fi
            done
        fi

        # 显示禁用的规则（简要）
        if [ "$disabled_count" -gt 0 ]; then
            echo -e "${YELLOW}禁用的规则:${NC}"
            for rule_file in "${RULES_DIR}"/rule-*.conf; do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file" && [ "$ENABLED" = "false" ]; then
                        # 根据规则角色使用不同的字段
                        if [ "$RULE_ROLE" = "2" ]; then
                            # 服务端服务器使用FORWARD_TARGET
                            local target_host="${FORWARD_TARGET%:*}"
                            local target_port="${FORWARD_TARGET##*:}"
                            local display_target=$(smart_display_target "$target_host")
                            echo -e "  • ${WHITE}$RULE_NAME${NC}: $LISTEN_PORT → $display_target:$target_port (已禁用)"
                        else
                            # 中转服务器使用REMOTE_HOST
                            local display_target=$(smart_display_target "$REMOTE_HOST")
                            local through_display="${THROUGH_IP:-::}"
                            echo -e "  • ${WHITE}$RULE_NAME${NC}: $LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT (已禁用)"
                        fi
                    fi
                fi
            done
        fi
    else
        echo -e "转发规则: ${YELLOW}暂无${NC} (可通过 '转发配置管理' 添加)"
    fi


    echo ""
}

# 获取安全级别显示文本
get_security_display() {
    local security_level="$1"
    local ws_path="$2"
    local tls_server_name="$3"

    case "$security_level" in
        "standard")
            echo "默认传输"
            ;;
        "ws")
            echo "ws (host: $tls_server_name) (路径: $ws_path)"
            ;;
        "tls_self")
            local display_sni="${tls_server_name:-$DEFAULT_SNI_DOMAIN}"
            echo "TLS自签证书 (SNI: $display_sni)"
            ;;
        "tls_ca")
            echo "TLS CA证书 (域名: $tls_server_name)"
            ;;
        "ws_tls_self")
            local display_sni="${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            echo "wss 自签证书 (host: $tls_server_name) (路径: $ws_path) (SNI: $display_sni)"
            ;;
        "ws_tls_ca")
            local display_sni="${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            echo "wss CA证书 (host: $tls_server_name) (路径: $ws_path) (SNI: $display_sni)"
            ;;
        "ws_"*)
            echo "$security_level (路径: $ws_path)"
            ;;
        *)
            echo "$security_level"
            ;;
    esac
}

get_gmt8_time() {
    TZ='GMT-8' date "$@"
}

# 下载故障转移管理脚本
download_failover_script() {
    local script_url="https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwFailover.sh"
    local target_path="/etc/realm/xwFailover.sh"

    echo -e "${GREEN}正在下载最新故障转移脚本...${NC}"

    mkdir -p "$(dirname "$target_path")"

    if download_from_sources "$script_url" "$target_path"; then
        chmod +x "$target_path"
        return 0
    else
        echo -e "${RED}请检查网络连接${NC}"
        return 1
    fi
}

# 下载中转网络链路测试脚本
download_speedtest_script() {
    local script_url="https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/speedtest.sh"
    local target_path="/etc/realm/speedtest.sh"

    echo -e "${GREEN}正在下载最新测速脚本...${NC}"

    mkdir -p "$(dirname "$target_path")"

    if download_from_sources "$script_url" "$target_path"; then
        chmod +x "$target_path"
        return 0
    else
        echo -e "${RED}请检查网络连接${NC}"
        return 1
    fi
}
# 中转网络链路测试菜单
speedtest_menu() {
    local speedtest_script="/etc/realm/speedtest.sh"

    if ! download_speedtest_script; then
        echo -e "${RED}无法下载测速脚本，功能暂时不可用${NC}"
        ui_pause "按回车键返回主菜单..."
        return 1
    fi

    echo -e "${BLUE}启动测速工具...${NC}"
    echo ""
    bash "$speedtest_script"

    echo ""
    ui_pause "按回车键返回主菜单..."
}

# 故障转移管理菜单（旧版 LB-mode failover，xwFailover.sh）
failover_management_menu() {
    local failover_script="/etc/realm/xwFailover.sh"

    if ! download_failover_script; then
        echo -e "${RED}无法下载故障转移脚本，功能暂时不可用${NC}"
        ui_pause "按回车键返回主菜单..."
        return 1
    fi

    while true; do
        sleep 0.2
        ui_clear
        echo -e "${YELLOW}=== 故障转移管理 (旧) ===${NC}"
        echo ""
        echo -e "${GREEN}1.${NC} 开启/关闭故障转移"
        echo -e "${BLUE}2.${NC} 参数配置（间隔/阈值/超时/冷却）"
        echo -e "${BLUE}3.${NC} 查看健康状态"
        echo -e "${YELLOW}0.${NC} 返回主菜单"
        echo ""

        ui_read_into "请输入选择 [0-3]: " failover_choice
        case "$failover_choice" in
            1)
                bash "$failover_script" toggle
                ;;
            2)
                bash "$failover_script" config
                ui_pause "按回车键继续..."
                ;;
            3)
                bash "$failover_script" status
                echo ""
                ui_pause "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-3${NC}"
                ui_pause "按回车键继续..."
                ;;
        esac
    done
}


# 端口流量狗
port_traffic_dog_menu() {
    local script_url="https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/port-traffic-dog.sh"
    local dog_script="/usr/local/bin/port-traffic-dog.sh"
    local dog_tmp="${dog_script}.tmp"

    # 每次都拉取远端版本做内容比对：
    # 旧逻辑「文件已存在就不下载」会让被自更新污染成上游版的脚本永远装不回 fork 版
    echo -e "${GREEN}正在检查端口流量狗脚本版本...${NC}"
    mkdir -p "$(dirname "$dog_script")"
    rm -f "$dog_tmp"

    if download_from_sources "$script_url" "$dog_tmp" && [ -s "$dog_tmp" ]; then
        # 内容校验：不是流量狗脚本就不替换本地文件
        if ! grep -q "端口流量狗" "$dog_tmp" 2>/dev/null; then
            echo -e "${RED}下载内容校验失败，已保留本地脚本${NC}"
            rm -f "$dog_tmp"
        elif [[ ! -f "$dog_script" ]] || ! cmp -s "$dog_tmp" "$dog_script"; then
            mv -f "$dog_tmp" "$dog_script"
            chmod +x "$dog_script"
            echo -e "${GREEN}端口流量狗脚本已更新${NC}"
        else
            rm -f "$dog_tmp"
            echo -e "${GREEN}端口流量狗脚本已是最新版本${NC}"
        fi
    else
        rm -f "$dog_tmp"
        if [[ -f "$dog_script" && -x "$dog_script" ]]; then
            # 离线环境：下载失败时使用本地已有脚本
            echo -e "${YELLOW}下载失败，使用本地已有端口流量狗脚本${NC}"
        else
            echo -e "${RED}无法下载端口流量狗脚本，请检查网络连接${NC}"
            ui_pause "按回车键返回主菜单..."
            return 1
        fi
    fi

    echo -e "${BLUE}启动端口流量狗...${NC}"
    echo ""
    bash "$dog_script"
    echo ""
    ui_pause "按回车键返回主菜单..."
}


show_menu() {
    ui_require_tty
    while true; do
        sleep 0.2
        ui_clear
        echo -e "${GREEN}=== xwPF Realm全功能一键脚本 $SCRIPT_VERSION ===${NC}"
        echo -e "${GREEN}介绍主页:${NC}https://zywe.de | ${GREEN}项目开源:${NC}https://github.com/byby5555/realm-xwPF-offline-active-standby"
        echo -e "${GREEN}一个开箱即用、轻量可靠、灵活可控的 Realm 转发管理工具${NC}"
        echo -e "${GREEN}官方realm的全部功能+故障转移 | 快捷命令: pf${NC}"

        show_brief_status

        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 安装(更新)程序,脚本"
        echo -e "${BLUE}2.${NC} 转发配置管理"
        echo -e "${GREEN}3.${NC} 重启服务"
        echo -e "${GREEN}4.${NC} 停止服务"
        echo -e "${GREEN}5.${NC} 查看日志"
        echo -e "${BLUE}6.${NC} 端口流量狗（统计端口流量）"
        echo -e "${BLUE}7.${NC} 中转网络链路测试"
        echo -e "${RED}8.${NC} 卸载服务"
        echo -e "${BLUE}9.${NC} 检查更新 / 安全更新"
        echo -e "${YELLOW}0.${NC} 退出"
        echo ""

        ui_read_into "请输入选择 [0-9]: " choice
        echo ""

        case $choice in
            1)
                smart_install
                exit 0
                ;;
            2)
                check_dependencies
                rules_management_menu
                ;;
            3)
                check_dependencies
                service_restart
                ui_pause "按回车键继续..."
                ;;
            4)
                check_dependencies
                service_stop
                ui_pause "按回车键继续..."
                ;;
            5)
                check_dependencies
                echo -e "${YELLOW}实时查看 Realm 日志 (按 Ctrl+C 返回菜单):${NC}"
                echo ""
                svc_logs
                ;;
            6)
                port_traffic_dog_menu
                ;;
            7)
                check_dependencies
                speedtest_menu
                ;;
            8)
                check_dependencies
                uninstall_realm
                ui_pause "按回车键继续..."
                ;;
            9)
                # 更新中心：查版本 + 安全更新（备份/校验/验证/回滚）
                update_center_menu
                ;;
            0)
                echo -e "${BLUE}感谢使用xwPF 网络转发管理脚本！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-9${NC}"
                ui_pause "按回车键继续..."
                ;;
        esac
    done
}

# 内置清理机制
cleanup_temp_files() {
    # 清理缓存文件（>10MB截断保留5MB）
    local cache_file="/tmp/realm_path_cache"
    if [ -f "$cache_file" ]; then
        local size=$(stat -c%s "$cache_file" 2>/dev/null || stat -f%z "$cache_file" 2>/dev/null || echo 0)
        if [ "$size" -gt 10485760 ]; then
            tail -c 5242880 "$cache_file" > "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file" 2>/dev/null
        fi
    fi

    # 清理过期标记文件（>5分钟）
    find /tmp -name "realm_config_update_needed" -mmin +5 -delete 2>/dev/null

    # 清理realm临时文件（>60分钟）
    find /tmp -name "*realm*" -type f -mmin +60 ! -path "*/realm/config*" ! -path "*/realm/rules*" -delete 2>/dev/null
}

# ---- 主逻辑 ----
main() {
    cleanup_temp_files

    detect_system

    # 检查特殊参数
    if [ "$1" = "--generate-config-only" ]; then
        # 只生成配置文件，不显示菜单
        generate_realm_config
        exit 0
    elif [ "$1" = "--restart-service" ]; then
        # 重启服务接口（供外部调用）
        service_restart
        exit $?
    elif [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ "$1" = "help" ]; then
        # 打印用法，不进入交互菜单
        show_usage
        exit 0
    fi

    check_root

    show_menu
}
