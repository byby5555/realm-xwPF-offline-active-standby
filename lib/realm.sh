
# ---- 服务管理抽象层 ----
svc_start()        { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm start;   else systemctl start realm;   fi; }
svc_stop()         { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm stop;    else systemctl stop realm;    fi; }
svc_restart()      { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm restart; else systemctl restart realm; fi; }
svc_enable()       { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-update add realm default >/dev/null 2>&1; else systemctl enable realm >/dev/null 2>&1;  fi; }
svc_disable()      { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-update del realm default >/dev/null 2>&1; else systemctl disable realm >/dev/null 2>&1; fi; }
svc_daemon_reload() { [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload; }
svc_is_active() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm status >/dev/null 2>&1; return $?
    else local s=$(systemctl is-active realm 2>/dev/null); [ "$s" = "active" ]; fi
}
svc_status_text() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        if rc-service realm status >/dev/null 2>&1; then echo "active"; else echo "inactive"; fi
    else systemctl is-active realm 2>/dev/null; fi
}
svc_enabled_text() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        if rc-update show default 2>/dev/null | grep -q realm; then echo "enabled"; else echo "disabled"; fi
    else systemctl is-enabled realm 2>/dev/null; fi
}
svc_status_detail() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm status
    else systemctl status realm --no-pager -l; fi
}
svc_logs() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        echo -e "${YELLOW}OpenRC 环境，使用系统日志:${NC}"
        tail -f /var/log/messages 2>/dev/null || echo -e "${RED}日志文件不可用${NC}"
    else journalctl -u realm -f --no-pager; fi
}


# 检测虚拟化环境
detect_virtualization() {
    local virt_type="物理机"

    # 检测各种虚拟化技术
    if [ -f /proc/vz/version ]; then
        virt_type="OpenVZ"
    elif [ -d /proc/vz ]; then
        virt_type="OpenVZ容器"
    elif grep -q "lxc" /proc/1/cgroup 2>/dev/null; then
        virt_type="LXC容器"
    elif [ -f /.dockerenv ]; then
        virt_type="Docker容器"
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        local detected=$(systemd-detect-virt 2>/dev/null)
        case "$detected" in
            "kvm") virt_type="KVM虚拟机" ;;
            "qemu") virt_type="QEMU虚拟机" ;;
            "vmware") virt_type="VMware虚拟机" ;;
            "xen") virt_type="Xen虚拟机" ;;
            "lxc") virt_type="LXC容器" ;;
            "docker") virt_type="Docker容器" ;;
            "openvz") virt_type="OpenVZ容器" ;;
            "none") virt_type="物理机" ;;
            *) virt_type="未知虚拟化($detected)" ;;
        esac
    elif [ -e /proc/user_beancounters ]; then
        virt_type="OpenVZ容器"
    elif dmesg 2>/dev/null | grep -i "hypervisor detected" >/dev/null; then
        virt_type="虚拟机"
    fi

    echo "$virt_type"
}


# 统一下载函数
# 统一「下载到临时文件 → 校验 → 原子替换」：
# 禁止对已存在的目标文件做断点续传（curl -C - / wget -c 只校验 HTTP Range 的起点，
# 不校验本地内容与远端是否一致，远端变长时会把新版本追加到旧内容后面，
# 生成大小正常但内容损坏的文件）
download_from_sources() {
    local url="$1"
    local target_path="$2"
    local dl_connect_timeout="${DOWNLOAD_CONNECT_TIMEOUT:-15}"
    local tmp="${target_path}.tmp.$$"

    rm -f "${target_path}.tmp" "$tmp"

    # 全量下载（带重试）
    if curl -fL --retry 8 --retry-delay 2 --connect-timeout "$dl_connect_timeout" --max-time 0 "$url" -o "$tmp" && [ -s "$tmp" ]; then
        mv -f "$tmp" "$target_path"
        echo -e "${GREEN}✓ 下载成功${NC}" >&2
        return 0
    fi

    rm -f "$tmp"

    # wget 兜底
    if wget --tries=10 --timeout=30 -O "$tmp" "$url" && [ -s "$tmp" ]; then
        mv -f "$tmp" "$target_path"
        echo -e "${GREEN}✓ 下载成功(wget)${NC}" >&2
        return 0
    fi

    rm -f "$tmp"
    echo -e "${RED}✗ 下载失败${NC}" >&2
    return 1
}


# 获取realm最新版本号
get_latest_realm_version() {
    echo -e "${YELLOW}获取最新版本信息...${NC}" >&2

    local latest_version=$(curl -sL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "https://github.com/zhboner/realm/releases" 2>/dev/null | \
        head -2100 | \
        sed -n 's|.*releases/tag/v\([0-9.]*\).*|v\1|p' | head -1)

    if [ -z "$latest_version" ]; then
        echo -e "${YELLOW}使用当前最新版本 ${REALM_VERSION}${NC}" >&2
        latest_version="$REALM_VERSION"
    fi

    echo -e "${GREEN}✓ 检测到最新版本: ${latest_version}${NC}" >&2
    echo "$latest_version"
}

# 智能重启realm服务
restart_realm_service() {
    local was_running="$1"
    local is_update="${2:-false}"  # 是否为更新场景

    if [ "$was_running" = true ] || [ "$is_update" = true ]; then
        echo -e "${YELLOW}正在启动realm服务...${NC}"
        if svc_start >/dev/null 2>&1; then
            echo -e "${GREEN}✓ realm服务已启动${NC}"
        else
            echo -e "${YELLOW}服务启动失败，尝试重新初始化...${NC}"
            start_empty_service
        fi
    else
        # 首次安装，启动空服务完成安装
        start_empty_service
    fi
}

# 比较realm版本并询问更新
compare_and_ask_update() {
    local current_version="$1"
    local latest_version="$2"

    # 提取当前版本号进行比较
    local current_ver=$(echo "$current_version" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$current_ver" ]; then
        current_ver="v0.0.0"
    fi

    # 统一版本格式（添加v前缀）
    if [[ ! "$current_ver" =~ ^v ]]; then
        current_ver="v$current_ver"
    fi
    if [[ ! "$latest_version" =~ ^v ]]; then
        latest_version="v$latest_version"
    fi

    # 比较版本
    if [ "$current_ver" = "$latest_version" ]; then
        echo -e "${GREEN}✓ 当前版本已是最新版本${NC}"
        return 1
    else
        echo -e "${YELLOW}发现新版本: ${current_ver} → ${latest_version}${NC}"
        ui_read_default "是否更新到最新版本？(y/n) [默认: n]: " update_choice
        if [[ ! "$update_choice" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}使用现有的 realm 安装${NC}"
            return 1
        fi
        echo -e "${YELLOW}将更新到最新版本...${NC}"
        return 0
    fi
}

# 安全停止realm服务
safe_stop_realm_service() {
    local service_was_running=false

    if svc_is_active; then
        echo -e "${BLUE}检测到realm服务正在运行，正在停止服务...${NC}"
        if svc_stop >/dev/null 2>&1; then
            echo -e "${GREEN}✓ realm服务已停止${NC}"
            service_was_running=true
        else
            echo -e "${RED}✗ 停止realm服务失败，无法安全更新${NC}"
            return 1
        fi
    fi

    echo "$service_was_running"
}

# 安装 realm - 虚拟化适配
install_realm() {
    echo -e "${GREEN}正在检查 realm 安装状态...${NC}"

    

# 检测虚拟化环境并显示
    local virt_env=$(detect_virtualization)
    echo -e "${BLUE}检测到虚拟化环境: ${GREEN}${virt_env}${NC}"

    # 检查是否已安装realm
    if [ -f "${REALM_PATH}" ] && [ -x "${REALM_PATH}" ]; then
        # 检查程序完整性（基本可执行性测试）
        if ! ${REALM_PATH} --help >/dev/null 2>&1; then
            echo -e "${YELLOW}检测到 realm 文件存在但可能已损坏，将重新安装...${NC}"
        else
            # 尝试获取版本信息
            local current_version=""
            local version_output=""
            if version_output=$(${REALM_PATH} --version 2>&1); then
                current_version="$version_output"
            elif version_output=$(${REALM_PATH} -v 2>&1); then
                current_version="$version_output"
            else
                current_version="realm (版本检查失败，可能架构不匹配)"
                echo -e "${YELLOW}警告: 版本检查失败，错误信息: ${version_output}${NC}"
            fi

            echo -e "${GREEN}✓ 检测到已安装的 realm: ${current_version}${NC}"
            echo ""

            # 获取最新版本号进行比较
            LATEST_VERSION=$(get_latest_realm_version)

            # 比较版本并询问更新
            if ! compare_and_ask_update "$current_version" "$LATEST_VERSION"; then
                return 0
            fi
        fi
    else
        echo -e "${YELLOW}未检测到 realm 安装，开始下载安装...${NC}"

        # 获取最新版本号
        LATEST_VERSION=$(get_latest_realm_version)
    fi

    # 离线安装选项
    local download_file=""
    ui_read_default "离线安装realm输入完整路径(回车默认自动下载): " local_package_path
    
    if [ -n "$local_package_path" ] && [ -f "$local_package_path" ]; then
        echo -e "${GREEN}✓ 使用本地文件: $local_package_path${NC}"
        download_file="$local_package_path"
    else
        if [ -n "$local_package_path" ]; then
            echo -e "${RED}✗ 文件不存在，继续在线下载${NC}"
        fi
        
        # 架构型号 → 官方资产名（与更新中心共用 detect_realm_asset_name，不会两边对不上）
        local asset_name
        asset_name=$(detect_realm_asset_name)
        if [ -z "$asset_name" ]; then
            echo -e "${RED}不支持的CPU架构: $(uname -m)${NC}"
            echo -e "${YELLOW}支持的架构: x86_64, aarch64, armv7l${NC}"
            exit 1
        fi

        DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}/${asset_name}"
        echo -e "${BLUE}目标文件: ${asset_name}${NC}"

        local file_path="$(pwd)/realm.tar.gz"
        local sources=(
            "$DOWNLOAD_URL"
            "https://gh-proxy.com/${DOWNLOAD_URL}"
            "https://ghproxy.net/${DOWNLOAD_URL}"
            "https://mirror.ghproxy.com/${DOWNLOAD_URL}"
        )

        local download_ok=false
        local src
        for src in "${sources[@]}"; do
            echo -e "${YELLOW}尝试下载源: ${src}${NC}"
            if download_from_sources "$src" "$file_path"; then
                download_ok=true
                break
            fi
        done

        if [ "$download_ok" = true ]; then
            echo -e "${GREEN}✓ 下载成功: ${file_path}${NC}"
            download_file="$file_path"
        else
            echo -e "${RED}✗ 下载失败${NC}"
            exit 1
        fi
    fi

    # 解压安装
    echo -e "${YELLOW}正在解压安装...${NC}"

    local service_was_running=$(safe_stop_realm_service)
    if [ $? -ne 0 ]; then
        return 1
    fi

    local work_dir=$(dirname "$download_file")
    local archive_name=$(basename "$download_file")

    if (cd "$work_dir" && tar -xzf "$archive_name" && cp realm ${REALM_PATH} && chmod +x ${REALM_PATH}); then
        echo -e "${GREEN}✓ realm 安装成功${NC}"
        
        # 只删除自动下载的文件，保留用户提供的本地文件
        if [ -z "$local_package_path" ]; then
            rm -f "$download_file"
        fi
        rm -f "${work_dir}/realm"

        restart_realm_service "$service_was_running" true
    else
        echo -e "${RED}✗ 安装失败${NC}"
        exit 1
    fi
}

# 从规则生成endpoints配置（支持负载均衡合并和故障转移）
generate_endpoints_from_rules() {
    local endpoints=""
    local count=0

    if [ ! -d "$RULES_DIR" ]; then
        return 0
    fi

    # 确保规则ID排序是最优的
    reorder_rule_ids

    # 健康状态读取（直接读取健康状态文件）
    #
    # ★ TARGET 字段口径：host:port（与 docs/health-check-and-failover.md 一致）。
    #   同一个 host 上的不同端口是**不同目标**，状态互不覆盖。
    # 兼容旧格式：老文件的 TARGET 只有 host —— 按该行 RULE_ID 对应规则的 REMOTE_PORT
    #   补出端口，入**精确键** host:port。
    # ★ 认得出归属时**只**入精确键，**不**再存一份裸 host 的宽键：
    #     宽键会把「一个端口的故障」传播给同 host 的其他端口 —— 同一主备组里
    #     两个目标都是同 host 不同端口时，两个目标都读到 failed → 全挂兜底
    #     → 保持原主不切备（该切不切的静默失效）。
    #   认不出归属（规则已删）时**当无记录**：让健康检查重新探测生成精确键，
    #     比留一份会跨端口污染的宽键安全。
    declare -A health_status
    local health_status_file="${HEALTH_STATUS_FILE}"

    # 规则 ID → 远端端口（给旧格式的 TARGET 补端口用）
    declare -A rule_remote_port
    local _rf
    for _rf in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$_rf" ] && read_rule_file "$_rf"; then
            if [ "$RULE_ROLE" = "1" ] && [ -n "$RULE_ID" ] && [ -n "$REMOTE_PORT" ]; then
                rule_remote_port["$RULE_ID"]="$REMOTE_PORT"
            fi
        fi
    done

    if [ -f "$health_status_file" ]; then
        while IFS='|' read -r _row_rule_id _row_target _row_status _row_rest; do
            # 跳过注释行和空行
            [[ "$_row_rule_id" =~ ^#.*$ ]] && continue
            [[ -z "$_row_rule_id" ]] && continue
            [ -z "$_row_target" ] && continue
            [ -z "$_row_status" ] && continue

            if [[ "$_row_target" != *:* ]]; then
                # 旧格式：TARGET 只有 host → 用该行 RULE_ID 对应规则的 REMOTE_PORT 补出端口。
                # 认得出归属 → **只**入精确键 host:port（同 host 不同端口因此互不覆盖）。
                # ★ 不存裸 host 的宽键：宽键会把一个端口的故障传播给同 host 的其他端口
                #   （同一主备组里两个目标同 host 不同端口时 → 两个都判 failed →
                #    全挂兜底 → 保持原主不切备 → 该切不切的静默失效）。
                # 认不出归属（规则已删、行号式的老记录）→ **当无记录**，
                #   让健康检查下一轮重新探测、生成精确键；比留宽键安全。
                local _row_port="${rule_remote_port[$_row_rule_id]:-}"
                if [ -n "$_row_port" ]; then
                    health_status["${_row_target}:${_row_port}"]="$_row_status"
                fi
            else
                health_status["$_row_target"]="$_row_status"
            fi
        done < "$health_status_file"
    fi

    # 按监听端口分组规则
    declare -A port_groups
    declare -A port_configs
    declare -A port_weights
    declare -A port_roles

    # 第一步：收集所有启用的规则并按端口分组（不进行故障转移过滤）
    declare -A port_rule_files
    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ]; then
            if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ]; then
                local port_key="$LISTEN_PORT"

                # 存储端口配置（使用第一个规则的配置作为基准）
                if [ -z "${port_configs[$port_key]:-}" ]; then
                    # 根据角色决定默认监听IP
                    local default_listen_ip
                    if [ "$RULE_ROLE" = "2" ]; then
                        # 服务端服务器使用双栈监听
                        default_listen_ip="::"
                    else
                        # 中转服务器使用动态输入的IP
                        default_listen_ip="${NAT_LISTEN_IP:-::}"
                    fi
                    port_configs[$port_key]="$SECURITY_LEVEL|$TLS_SERVER_NAME|$TLS_CERT_PATH|$TLS_KEY_PATH|$BALANCE_MODE|${LISTEN_IP:-$default_listen_ip}|$THROUGH_IP"
                    # 存储权重配置和角色信息
                    port_weights[$port_key]="$WEIGHTS"
                    port_roles[$port_key]="$RULE_ROLE"
                elif [ "${port_roles[$port_key]:-}" != "$RULE_ROLE" ]; then
                    # 检测到同一端口有不同角色的规则，跳过此规则
                    echo -e "${YELLOW}警告: 端口 $port_key 已被角色 ${port_roles[$port_key]:-} 的规则占用，跳过角色 $RULE_ROLE 的规则${NC}" >&2
                    continue
                elif [[ "$WEIGHTS" == *","* ]] && [[ "${port_weights[$port_key]:-}" != *","* ]]; then
                    # 本规则带完整权重列表，优先用它作为端口组的权重序列
                    # （第一个启用的规则可能只存了单个权重）
                    port_weights[$port_key]="$WEIGHTS"
                fi

                # 收集目标：根据规则角色使用不同的字段
                local targets_to_add=""

                if [ "$RULE_ROLE" = "2" ]; then
                    # 服务端服务器使用FORWARD_TARGET
                    targets_to_add="$FORWARD_TARGET"
                else
                    # 中转服务器：优先使用TARGET_STATES，否则使用REMOTE_HOST
                    # 双保险：read_rule_file 已保证这两个键有值（缺失回落空串），
                    # 这里再给默认值 —— 免得解析器将来被改坏时，
                    # 「走 TARGET_STATES 还是 REMOTE_HOST」这个判定点在 set -u 下致命中断。
                    if [ "${BALANCE_MODE:-}" != "off" ] && [ -n "${TARGET_STATES:-}" ]; then
                        # 负载均衡模式且有TARGET_STATES，使用TARGET_STATES
                        targets_to_add="$TARGET_STATES"
                    else
                        # 非负载均衡模式或无TARGET_STATES，使用REMOTE_HOST:REMOTE_PORT
                        if [[ "$REMOTE_HOST" == *","* ]]; then
                            # REMOTE_HOST包含多个地址
                            IFS=',' read -ra host_list <<< "$REMOTE_HOST"
                            for host in "${host_list[@]}"; do
                                host=$(echo "$host" | xargs)  # 去除空格
                                if [ -n "$targets_to_add" ]; then
                                    targets_to_add="$targets_to_add,$host:$REMOTE_PORT"
                                else
                                    targets_to_add="$host:$REMOTE_PORT"
                                fi
                            done
                        else
                            # REMOTE_HOST是单个地址
                            targets_to_add="$REMOTE_HOST:$REMOTE_PORT"
                        fi
                    fi
                fi

                # 将目标添加到端口组（避免重复）
                if [ -n "$targets_to_add" ]; then
                    IFS=',' read -ra target_list <<< "$targets_to_add"
                    for target in "${target_list[@]}"; do
                        target=$(echo "$target" | xargs)  # 去除空格
                        if [[ "${port_groups[$port_key]:-}" != *"$target"* ]]; then
                            if [ -z "${port_groups[$port_key]:-}" ]; then
                                port_groups[$port_key]="$target"
                            else
                                port_groups[$port_key]="${port_groups[$port_key]:-},$target"
                            fi
                        fi
                    done
                fi

                # 记录规则文件以便后续检查故障转移状态
                if [ -z "${port_rule_files[$port_key]:-}" ]; then
                    port_rule_files[$port_key]="$rule_file"
                fi
            fi
        fi
    done

    # 第二步：对每个端口组应用故障转移过滤
    for port_key in "${!port_groups[@]}"; do
        # 读取该端口的负载均衡模式（port_configs 是以 '|' 分隔的字符串，第 5 个字段是 BALANCE_MODE）
        local port_balance_mode=$(echo "${port_configs[$port_key]:-}" | awk -F'|' '{print $5}')

        # 检查该端口的所有规则，只要有一个启用故障转移就应用过滤
        local failover_enabled="false"

        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ] && read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$LISTEN_PORT" = "$port_key" ]; then
                if [ "${FAILOVER_ENABLED:-false}" = "true" ]; then
                    failover_enabled="true"
                    break
                fi
            fi
        done

        if [ "$failover_enabled" = "true" ]; then
            IFS=',' read -ra all_targets <<< "${port_groups[$port_key]:-}"

            if [ "$port_balance_mode" = "active-standby" ]; then
                # 主备模式（active-standby）：保留所有目标在列表中
                # （健康检查对所有目标独立探测，不依赖权重，因此列表需保持 REMOTE_HOST 原始顺序）
                #
                # 主备优先级：按用户在「权重配置管理」里填的权重从高到低排列，
                # 权重数值大的排在前（权重表示优先级，不是分流比例）；
                # 同一时刻只有一个主承接流量，权重 0 的目标不参与主备。
                #   例："10,0" → 第一个是主、第二个是备
                #       "0,10" → 第二个是主
                # 权重相同则保持原始顺序（稳定排序）。
                # 没有有效权重信息时退化为原始顺序。
                local priority_targets=("${all_targets[@]}")

                local user_weights="${port_weights[$port_key]:-}"
                if [ -n "$user_weights" ]; then
                    IFS=',' read -ra _prio_w <<< "$user_weights"
                    if [ "${#_prio_w[@]}" -eq "${#all_targets[@]}" ]; then
                        local _has_zero=false
                        for _w in "${_prio_w[@]}"; do
                            if [ "$_w" -eq 0 ]; then
                                _has_zero=true
                            fi
                        done

                        if [ "$_has_zero" = true ]; then
                            # 稳定降序：权重大的排前面
                            for ((_pi=0; _pi<${#all_targets[@]}; _pi++)); do
                                for ((_pj=_pi+1; _pj<${#all_targets[@]}; _pj++)); do
                                    if [ "${_prio_w[$_pj]}" -gt "${_prio_w[$_pi]}" ]; then
                                        _tw="${_prio_w[$_pi]}"; _prio_w[$_pi]="${_prio_w[$_pj]}"; _prio_w[$_pj]="$_tw"
                                        _tt="${priority_targets[$_pi]}"; priority_targets[$_pi]="${priority_targets[$_pj]}"; priority_targets[$_pj]="$_tt"
                                    fi
                                done
                            done
                        fi
                    fi
                    unset _prio_w
                fi

                # 按优先级找第一个健康目标作为主
                local primary_target=""
                for _t in "${priority_targets[@]}"; do
                    # ★ 按 host:port 查状态：同 host 不同端口互不影响
                    #   查不到 = 无记录 = 视为健康（由健康检查重新探测生成精确键）
                    local _st="${health_status[$_t]:-}"
                    if [ "$_st" != "failed" ]; then
                        primary_target="$_t"
                        break
                    fi
                done

                # 重新生成 0/1 权重列表（按 all_targets 原始顺序，保证与端点顺序一一对应）
                local flipped_weights=""
                for _t in "${all_targets[@]}"; do
                    local _w=0
                    if [ "$_t" = "$primary_target" ]; then
                        _w=1
                    fi
                    if [ -n "$flipped_weights" ]; then
                        flipped_weights="$flipped_weights,$_w"
                    else
                        flipped_weights="$_w"
                    fi
                done

                # 若全部目标都故障（primary_target 为空），上面会输出全 0，
                # 即生成的 realm 配置中所有节点都没有流量——为避免完全断流，
                # 强制将优先级最高的目标置 1
                if [ -z "$primary_target" ] && [ "${#all_targets[@]}" -gt 0 ]; then
                    local _fallback="${priority_targets[0]}"
                    flipped_weights=""
                    for _t in "${all_targets[@]}"; do
                        local _w=0
                        if [ "$_t" = "$_fallback" ]; then
                            _w=1
                        fi
                        if [ -n "$flipped_weights" ]; then
                            flipped_weights="$flipped_weights,$_w"
                        else
                            flipped_weights="$_w"
                        fi
                    done
                fi

                # 主备模式：不修改 port_groups（保留所有目标），仅覆写权重
                port_weights[$port_key]="$flipped_weights"
            else
                # 原有剔除模式：从目标列表移除故障节点
                local filtered_targets=""
                local filtered_indices=()

                # 记录健康节点的索引位置
                for i in "${!all_targets[@]}"; do
                    local target="${all_targets[i]}"
                    # ★ 按 host:port 查状态：同 host 不同端口互不影响
                    #   查不到 = 无记录 = 视为健康（由健康检查重新探测生成精确键）
                    local node_status="${health_status[$target]:-}"

                    if [ "$node_status" != "failed" ]; then
                        if [ -n "$filtered_targets" ]; then
                            filtered_targets="$filtered_targets,$target"
                        else
                            filtered_targets="$target"
                        fi
                        filtered_indices+=($i)
                    fi
                done

                # 如果所有节点都故障，保留第一个节点避免服务完全中断
                if [ -z "$filtered_targets" ]; then
                    filtered_targets="${all_targets[0]}"
                    filtered_indices=(0)
                fi

                # 更新端口组为过滤后的目标
                port_groups[$port_key]="$filtered_targets"

                # 同步调整权重配置以匹配过滤后的目标数量
                local original_weights="${port_weights[$port_key]:-}"

                if [ -n "$original_weights" ]; then
                    IFS=',' read -ra weight_array <<< "$original_weights"
                    local adjusted_weights=""

                    # 只保留健康节点对应的权重
                    for index in "${filtered_indices[@]}"; do
                        if [ $index -lt ${#weight_array[@]} ]; then
                            local weight="${weight_array[index]}"
                            # 清理权重值（去除空格）
                            weight=$(echo "$weight" | tr -d ' ')
                            if [ -n "$adjusted_weights" ]; then
                                adjusted_weights="$adjusted_weights,$weight"
                            else
                                adjusted_weights="$weight"
                            fi
                        else
                            # 如果权重数组长度不足，使用默认权重1
                            if [ -n "$adjusted_weights" ]; then
                                adjusted_weights="$adjusted_weights,1"
                            else
                                adjusted_weights="1"
                            fi
                        fi
                    done

                    # 更新权重配置
                    port_weights[$port_key]="$adjusted_weights"
                fi
            fi
        fi
    done

    # 为每个端口组生成endpoint配置
    for port_key in "${!port_groups[@]}"; do
        if [ $count -gt 0 ]; then
            endpoints="$endpoints,"
        fi

        # 解析端口配置
        IFS='|' read -r security_level tls_server_name tls_cert_path tls_key_path balance_mode listen_ip through_ip <<< "${port_configs[$port_key]:-}"
        # 如果没有listen_ip字段（向后兼容），根据角色使用对应的默认值
        if [ -z "$listen_ip" ]; then
            local role="${port_roles[$port_key]:-1}"
            if [ "$role" = "2" ]; then
                # 服务端服务器使用双栈监听
                listen_ip="::"
            else
                # 中转服务器使用动态输入的IP
                listen_ip="${NAT_LISTEN_IP:-::}"
            fi
        fi

        # 如果没有through_ip字段（向后兼容），使用默认值
        if [ -z "$through_ip" ]; then
            through_ip="::"
        fi

        # 解析目标地址
        IFS=',' read -ra targets <<< "${port_groups[$port_key]:-}"
        local main_target="${targets[0]}"
        local main_host="${main_target%:*}"
        local main_port="${main_target##*:}"

        # 构建extra_remotes
        local extra_remotes=""
        if [ ${#targets[@]} -gt 1 ]; then
            for ((i=1; i<${#targets[@]}; i++)); do
                if [ -n "$extra_remotes" ]; then
                    extra_remotes="$extra_remotes, "
                fi
                extra_remotes="$extra_remotes\"${targets[i]}\""
            done
        fi

        # 生成endpoint配置
        local listen_field=""
        if validate_ip "$listen_ip"; then
            listen_field="\"listen\": \"${listen_ip}:${port_key}\""
        else
            listen_field="\"listen\": \"0.0.0.0:${port_key}\",
            \"listen_interface\": \"${listen_ip}\""
        fi

        local endpoint_config="
        {
            ${listen_field},
            \"remote\": \"${main_target}\""

        # 添加extra_remotes（如果有多个目标）
        if [ -n "$extra_remotes" ]; then
            endpoint_config="$endpoint_config,
            \"extra_remotes\": [$extra_remotes]"
        fi

        # 添加负载均衡配置（如果有多个目标且设置了负载均衡）
        if [ -n "$extra_remotes" ] && [ -n "$balance_mode" ] && [ "$balance_mode" != "off" ]; then
            # 生成权重配置
            local weight_config=""
            local rule_weights="${port_weights[$port_key]:-}"

            if [ -n "$rule_weights" ]; then
                # 使用存储的权重（已在故障转移过滤中处理）
                weight_config=$(echo "$rule_weights" | sed 's/,/, /g')
            else
                # 使用默认相等权重
                for ((i=0; i<${#targets[@]}; i++)); do
                    if [ -n "$weight_config" ]; then
                        weight_config="$weight_config, "
                    fi
                    weight_config="${weight_config}1"
                done
            fi

            # 主备模式（active-standby）映射为 roundrobin 输出给 realm
            # realm 自身不识别 active-standby，权重已经是 0/1 列表，roundrobin 即可实现"只有第一个健康节点接收流量"
            local realm_balance_mode="$balance_mode"
            if [ "$balance_mode" = "active-standby" ]; then
                realm_balance_mode="roundrobin"
            fi

            endpoint_config="$endpoint_config,
            \"balance\": \"$realm_balance_mode: $weight_config\""
        fi

        # 添加through字段（仅中转服务器）
        local role="${port_roles[$port_key]:-1}"  # 使用存储的角色，默认为中转服务器
        if [ "$role" = "1" ] && [ -n "$through_ip" ] && [ "$through_ip" != "::" ]; then
            if validate_ip "$through_ip"; then
                endpoint_config="$endpoint_config,
            \"through\": \"$through_ip\""
            else
                endpoint_config="$endpoint_config,
            \"interface\": \"$through_ip\""
            fi
        fi

        # 添加传输配置 - 使用存储的规则角色信息
        local transport_config=$(get_transport_config "$security_level" "$tls_server_name" "$tls_cert_path" "$tls_key_path" "$role" "$WS_PATH")
        if [ -n "$transport_config" ]; then
            endpoint_config="$endpoint_config,
            $transport_config"
        fi

        # 添加MPTCP网络配置 - 从对应的规则文件读取MPTCP设置
        local mptcp_config=""
        local rule_file_for_port="${port_rule_files[$port_key]:-}"

        if [ -f "$rule_file_for_port" ]; then
            # 临时保存当前变量状态
            local saved_vars=$(declare -p RULE_ID RULE_NAME MPTCP_MODE 2>/dev/null || true)

            # 读取该端口对应的规则文件
            if read_rule_file "$rule_file_for_port"; then
                local mptcp_mode="${MPTCP_MODE:-off}"
                local send_mptcp="false"
                local accept_mptcp="false"

                case "$mptcp_mode" in
                    "send")
                        send_mptcp="true"
                        ;;
                    "accept")
                        accept_mptcp="true"
                        ;;
                    "both")
                        send_mptcp="true"
                        accept_mptcp="true"
                        ;;
                esac

                # 只有在需要MPTCP时才添加network配置
                if [ "$send_mptcp" = "true" ] || [ "$accept_mptcp" = "true" ]; then
                    mptcp_config=",
            \"network\": {
                \"send_mptcp\": $send_mptcp,
                \"accept_mptcp\": $accept_mptcp
            }"
                fi
            fi

            # 恢复变量状态（如果有保存的话）
            if [ -n "$saved_vars" ]; then
                eval "$saved_vars" 2>/dev/null || true
            fi
        fi

        # 添加Proxy网络配置 - 从对应的规则文件读取Proxy设置
        local proxy_config=""
        if [ -f "$rule_file_for_port" ]; then
            # 临时保存当前变量状态
            local saved_vars=$(declare -p RULE_ID RULE_NAME PROXY_MODE 2>/dev/null || true)

            # 读取该端口对应的规则文件
            if read_rule_file "$rule_file_for_port"; then
                local proxy_mode="${PROXY_MODE:-off}"
                local send_proxy="false"
                local accept_proxy="false"
                local send_proxy_version="2"

                case "$proxy_mode" in
                    "v1_send")
                        send_proxy="true"
                        send_proxy_version="1"
                        ;;
                    "v1_accept")
                        accept_proxy="true"
                        send_proxy_version="1"
                        ;;
                    "v1_both")
                        send_proxy="true"
                        accept_proxy="true"
                        send_proxy_version="1"
                        ;;
                    "v2_send")
                        send_proxy="true"
                        send_proxy_version="2"
                        ;;
                    "v2_accept")
                        accept_proxy="true"
                        send_proxy_version="2"
                        ;;
                    "v2_both")
                        send_proxy="true"
                        accept_proxy="true"
                        send_proxy_version="2"
                        ;;
                esac

                # 只有在需要Proxy时才添加配置
                if [ "$send_proxy" = "true" ] || [ "$accept_proxy" = "true" ]; then
                    local proxy_fields=""
                    if [ "$send_proxy" = "true" ]; then
                        proxy_fields="\"send_proxy\": $send_proxy,
                \"send_proxy_version\": $send_proxy_version"
                    fi
                    if [ "$accept_proxy" = "true" ]; then
                        if [ -n "$proxy_fields" ]; then
                            proxy_fields="$proxy_fields,
                \"accept_proxy\": $accept_proxy,
                \"accept_proxy_timeout\": 5"
                        else
                            proxy_fields="\"accept_proxy\": $accept_proxy,
                \"accept_proxy_timeout\": 5"
                        fi
                    fi

                    if [ -n "$mptcp_config" ]; then
                        # 如果已有MPTCP配置，在network内添加Proxy配置
                        proxy_config=",
                $proxy_fields"
                    else
                        # 如果没有MPTCP配置，创建新的network配置
                        proxy_config=",
            \"network\": {
                $proxy_fields
            }"
                    fi
                fi
            fi

            # 恢复变量状态（如果有保存的话）
            if [ -n "$saved_vars" ]; then
                eval "$saved_vars" 2>/dev/null || true
            fi
        fi

        # 合并MPTCP和Proxy配置
        local network_config=""
        if [ -n "$mptcp_config" ] && [ -n "$proxy_config" ]; then
            # 两者都有，合并到一个network块中
            network_config=$(echo "$mptcp_config" | sed 's/}//')
            network_config="$network_config$proxy_config
            }"
        elif [ -n "$mptcp_config" ]; then
            network_config="$mptcp_config"
        elif [ -n "$proxy_config" ]; then
            network_config="$proxy_config"
        fi

        endpoint_config="$endpoint_config$network_config
        }"

        endpoints="$endpoints$endpoint_config"
        count=$((count + 1))
    done

    echo "$endpoints"
}

generate_realm_config() {
    echo -e "${YELLOW}正在生成 Realm 配置文件...${NC}"

    mkdir -p "$CONFIG_DIR"

    init_rules_dir

    # 检查是否有启用的规则
    local has_rules=false
    local enabled_count=0

    if [ -d "$RULES_DIR" ]; then
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ]; then
                    has_rules=true
                    enabled_count=$((enabled_count + 1))
                fi
            fi
        done
    fi

    if [ "$has_rules" = false ]; then
        echo -e "${BLUE}未找到启用的规则，生成空配置${NC}"
        generate_complete_config ""
        echo -e "${GREEN}✓ 空配置文件已生成${NC}"
        return 0
    fi

    # 生成基于规则的配置
    echo -e "${BLUE}找到 $enabled_count 个启用的规则，生成多规则配置${NC}"

    # 获取所有启用规则的endpoints
    local endpoints=$(generate_endpoints_from_rules)

    # 使用统一模板生成多规则配置
    generate_complete_config "$endpoints"

    echo -e "${GREEN}✓ 多规则配置文件已生成${NC}"
    echo -e "${BLUE}配置详情: $enabled_count 个启用的转发规则${NC}"

    # 显示规则摘要
    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ]; then
            if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ]; then
                # 根据规则角色使用不同的字段
                if [ "$RULE_ROLE" = "2" ]; then
                    # 服务端服务器使用FORWARD_TARGET
                    local target_host="${FORWARD_TARGET%:*}"
                    local target_port="${FORWARD_TARGET##*:}"
                    local display_target=$(smart_display_target "$target_host")
                    local display_ip="::"
                    echo -e "  ${GREEN}$RULE_NAME${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $display_target:$target_port"
                else
                    # 中转服务器使用REMOTE_HOST
                    local display_target=$(smart_display_target "$REMOTE_HOST")
                    local display_ip="${NAT_LISTEN_IP:-::}"
                    local through_display="${THROUGH_IP:-::}"
                    echo -e "  ${GREEN}$RULE_NAME${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT"
                fi
            fi
        fi
    done
}

generate_service_file() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        echo -e "${YELLOW}正在生成 OpenRC 服务文件...${NC}"
        tr -d '\r' > /etc/init.d/realm <<'SVCEOF'
#!/sbin/openrc-run
name="realm-xwpf"
command="/usr/local/bin/realm"
command_args="-c /etc/realm/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
depend() { need net; }
SVCEOF
        chmod +x /etc/init.d/realm
        echo -e "${GREEN}✓ OpenRC 服务文件已生成${NC}"
    else
        echo -e "${YELLOW}正在生成 systemd 服务文件...${NC}"
        tr -d '\r' > "$SYSTEMD_PATH" <<EOF
[Unit]
Description=realm-xwpf
After=network.target

[Service]
Type=simple
ExecStart=${REALM_PATH} -c ${CONFIG_PATH}
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

        echo -e "${GREEN}✓ systemd 服务文件已生成${NC}"
        systemctl daemon-reload
        echo -e "${GREEN}✓ systemd 服务已重新加载${NC}"
    fi
}

# 启动空服务（让脚本能识别已安装状态）
start_empty_service() {
    echo -e "${YELLOW}正在初始化配置以完成安装...${NC}"

    mkdir -p "$CONFIG_DIR"

    tr -d '\r' > "$CONFIG_PATH" <<EOF
{
    "endpoints": []
}
EOF

    generate_service_file

    svc_enable
    svc_start >/dev/null 2>&1
}

# 安装和配置流程
smart_install() {
    echo -e "${GREEN}=== xwPF Realm 一键脚本智能安装 $SCRIPT_VERSION ===${NC}"
    echo ""

    detect_system
    echo -e "${BLUE}检测到系统: ${GREEN}$OS $VER${NC}"
    echo ""

    # 安装依赖
    manage_dependencies "install"

    # 脚本更新（首次安装跳过，菜单进入则询问）
    if [ "${_SKIP_SCRIPT_UPDATE:-}" != "1" ]; then
        ui_read_default "是否更新脚本？(y/N): " update_script
        [[ "$update_script" =~ ^[Yy]$ ]] && _bootstrap
    fi

    # 下载最新的 realm 主程序
    if install_realm; then
        echo -e "${GREEN}=== 安装完成！ ===${NC}"
        echo -e "${YELLOW}输入快捷命令 ${GREEN}pf${YELLOW} 进入脚本交互界面${NC}"
    else
        echo -e "${RED}错误: realm安装失败${NC}"
        echo -e "${YELLOW}输入快捷命令 ${GREEN}pf${YELLOW} 可进入脚本交互界面${NC}"
    fi
}

# 服务管理 - 停止
service_stop() {
    echo -e "${YELLOW}正在停止 Realm 服务...${NC}"

    if svc_stop; then
        echo -e "${GREEN}✓ Realm 服务已停止${NC}"
    else
        echo -e "${RED}✗ Realm 服务停止失败${NC}"
        return 1
    fi
}

service_restart() {
    echo -e "${YELLOW}正在重启 Realm 服务...${NC}"

    # 重排序规则ID以保持最优排序
    echo -e "${BLUE}正在规则排序...${NC}"
    if reorder_rule_ids; then
        echo -e "${GREEN}✓ 规则排序优化完成${NC}"
    fi

    # 重新生成配置文件
    echo -e "${BLUE}重新生成配置文件...${NC}"
    generate_realm_config

    if svc_restart; then
        echo -e "${GREEN}✓ Realm 服务重启成功${NC}"
    else
        echo -e "${RED}✗ Realm 服务重启失败${NC}"
        svc_status_detail
        return 1
    fi
}
