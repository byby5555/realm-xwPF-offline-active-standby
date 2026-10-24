#!/bin/bash

SCRIPT_VERSION="v2.2.1"
REALM_VERSION="v2.9.3"

NAT_LISTEN_PORT=""
NAT_LISTEN_IP=""
NAT_THROUGH_IP="::"
REMOTE_IP=""
REMOTE_PORT=""
EXIT_LISTEN_PORT=""
FORWARD_TARGET=""

SECURITY_LEVEL=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
TLS_SERVER_NAME=""
WS_PATH=""
WS_HOST=""

RULE_ID=""
RULE_NAME=""

REQUIRED_TOOLS=("curl" "wget" "tar" "grep" "cut" "bc" "jq" "openssl" "python3")

# 系统标识（由 detect_system 设置）
DISTRO=""        # debian | alpine | centos
PKG_MGR=""       # apt-get | apk | yum/dnf
INIT_SYSTEM=""   # systemd | openrc

# 通用的字段初始化函数
init_rule_field() {
    local field_name="$1"
    local default_value="$2"

    if [ ! -d "$RULES_DIR" ]; then
        return 0
    fi

    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ]; then
            if ! grep -q "^${field_name}=" "$rule_file"; then
                echo "${field_name}=\"${default_value}\"" >> "$rule_file"
            fi
        fi
    done
}

# 通用的服务重启函数
restart_and_confirm() {
    local operation_name="$1"
    local batch_mode="$2"

    if [ "$batch_mode" != "batch" ]; then
        echo -e "${YELLOW}正在重启服务以应用${operation_name}...${NC}"
        if service_restart; then
            echo -e "${GREEN}✓ 服务重启成功，${operation_name}已生效${NC}"
            return 0
        else
            echo -e "${RED}✗ 服务重启失败，请检查配置${NC}"
            return 1
        fi
    fi
    return 0
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

REALM_PATH="${REALM_PATH:-/usr/local/bin/realm}"
CONFIG_DIR="${CONFIG_DIR:-/etc/realm}"
CONFIG_PATH="${CONFIG_DIR}/config.json"
SYSTEMD_PATH="/etc/systemd/system/realm.service"
RULES_DIR="${CONFIG_DIR}/rules"
# 安装目录（xwPF.sh 会先定义 INSTALL_DIR，这里给默认值，测试可注入）
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
LIB_DIR="${LIB_DIR:-${INSTALL_DIR}/lib}"
# 健康状态文件：故障转移的探测结果落盘处（主备切换据此翻转权重）
# 用变量统一，避免各处硬编码路径不一致（lib/rules.sh 之前引用过未定义的 $HEALTH_STATUS_FILE）
HEALTH_STATUS_FILE="${HEALTH_STATUS_FILE:-${CONFIG_DIR}/health/health_status.conf}"

# 默认tls和host域名（加密解密需要相同SNI）
DEFAULT_SNI_DOMAIN="www.tesla.com"

# 网络超时配置
SHORT_CONNECT_TIMEOUT=5
SHORT_MAX_TIMEOUT=7

get_local_server_ip() {
    local local_ip
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$local_ip" ]; then
        echo "$local_ip"
        return 0
    fi

    local_ip=$(ip route get 1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    echo "${local_ip:-127.0.0.1}"
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# === 交互菜单读入：stdin EOF 安全（无人值守场合的硬要求）===
# ★ 交互菜单若直接用 `read`，在 stdin 是 EOF 时（管道 / 后台 / cron / systemd /
#   无人值守执行 / 终端关闭）`read` 会立刻返回非 0 → 变量为空 → case 不匹配 →
#   回到 while 顶部 → 无限重绘 + 忙循环 + 无界输出。
#   实机后果：/tmp 是 tmpfs，无界输出灌满它 → 内存+swap 耗尽 → sshd 握不上手。
#   修法：菜单读入统一走下面几个 helper，读到 EOF 绝不回到菜单循环顶部。
#
# ★ 三种读入语义（按「EOF 之后该做什么」区分，别混用）：
#   ui_read_into    —— 菜单读入。EOF → 立刻干净退出（退出码 0）。
#   ui_pause        —— 「按回车键继续」类。EOF → 立刻干净退出（退出码 0）。
#   ui_read_default —— 一次性询问。EOF → **不退出**，取默认值并返回 1
#                      （给安装流程等可能被无人值守触发的路径用：那里 EOF 是常态，
#                        当成错误把流程打断会变成「静默空跑」）。
#
# ★ 本块在 lib/core.sh 与 3 个独立脚本（xwFailover.sh / port-traffic-dog.sh /
#   speedtest.sh）里各有一份。独立脚本是**独立安装单元**、拿不到 lib/，
#   所以「一份实现」只能是「四份逐字一致的拷贝」——
#   台架把「份数 == 4 且四份逐字一致」钉成不变式，任何漂移都判红。
#
# 用法：ui_read_into "提示语" 变量名   —— 把读到的内容放进指定变量
ui_read_into() {
    local __prompt="$1" __name="$2" __val
    if ! read -r -p "$__prompt" __val; then
        # EOF / 读失败：干净退出，不回菜单循环
        exit 0
    fi
    printf -v "$__name" '%s' "$__val"
}

# 用法：ui_pause "提示语"   —— 「按回车键继续 / 返回」类读入
ui_pause() {
    read -p "$1" || exit 0
}

# 用法：ui_read_default "提示语" 变量名 [默认值]
#   读到 EOF 时把变量置成默认值（缺省空串）并返回 1，由调用方决定分支。
ui_read_default() {
    local __prompt="$1" __name="$2" __default="${3:-}" __val=""
    if ! read -r -p "$__prompt" __val; then
        printf -v "$__name" '%s' "$__default"
        return 1
    fi
    printf -v "$__name" '%s' "$__val"
    return 0
}

# 用法：ui_require_tty   —— 菜单入口护栏：stdin 不是终端就不进菜单
ui_require_tty() {
    if [ ! -t 0 ]; then
        echo -e "${YELLOW}检测到标准输入不是终端（管道 / 后台 / 无人值守执行），已退出交互菜单。${NC}"
        echo "Interactive menu requires a terminal on stdin; exiting."
        exit 0
    fi
}

# 用法：ui_clear   —— 清屏。TERM 没设时 `clear` 会往 stderr 吐
#   "TERM environment variable not set." 并返回非 0（无人值守时输出更难看），
#   所以自己兜底：TERM 正常用 clear，缺失或 dumb 用 ANSI 序列。
ui_clear() {
    if [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; then
        clear 2>/dev/null || printf '\033[H\033[2J'
    else
        printf '\033[H\033[2J'
    fi
}


# 打印用法说明（--help / -h / help）
show_usage() {
    echo -e "${GREEN}用法:${NC} pf [命令]"
    echo -e "${WHITE}Usage:${NC} pf [command]"
    echo ""
    echo -e "  ${GREEN}install${NC}                  安装/更新脚本（等价于 bash xwPF.sh install）"
    echo -e "  ${GREEN}--restart-service${NC}        仅重启 realm 服务（供健康检查调用）"
    echo -e "  ${GREEN}--generate-config-only${NC}   仅重新生成配置文件，不进入菜单"
    echo -e "  ${GREEN}--help, -h, help${NC}         显示本帮助"
    echo ""
    echo "不带参数进入交互菜单。"
    echo "Run without arguments to enter the interactive menu."
}


# 生成network配置
generate_network_config() {
    local config_file="/etc/realm/config.json"
    local base_network='{
        "no_tcp": false,
        "use_udp": true
    }'

    if [ -f "$config_file" ]; then
        local existing_proxy=$(jq -r '.network | {send_proxy, send_proxy_version, accept_proxy, accept_proxy_timeout} | to_entries | map(select(.value != null)) | from_entries' "$config_file" 2>/dev/null || echo "{}")
        if [ -n "$existing_proxy" ] && [ "$existing_proxy" != "{}" ] && [ "$existing_proxy" != "null" ]; then
            echo "$base_network" | jq ". + $existing_proxy" 2>/dev/null || echo "$base_network"
            return
        fi
    fi

    echo "$base_network"
}

# 校验 realm 配置文件的形态（A-17 护栏）
#
# ★ 为什么必须有这道护栏（Chief 真机 103 实测）：
#   config.json 里 "remote" 写成**数组**、或 "balance" **不带权重**
#   ⇒ realm 直接 panic（realm_lb 的 balancer.rs）
#   ⇒ 不是只断那一个 endpoint，是**所有 endpoint 全断**（全站断流）。
# ★ 判据（A-17 判据 1）：
#   1) 每个 endpoint 的 remote 必须是 **string**（不是数组）
#   2) extra_remotes 必须是 **array**（元素都是 string）
#   3) balance 必须是 string，且形如 "策略: 权重1, 权重2"（**必须带 ": 权重"**）
#   4) balance 的权重个数 == 目标数（remote 1 个 + extra_remotes 元素数）
# ★ fail-closed：形态不合法 ⇒ 调用方**不写**（保留原配置）并报错。
#   宁可配置不更新，也不能写出让 realm 崩掉的配置。
# ★ 失败原因打到 stdout（调用方转成醒目报错）；成功时 stdout 为空。
realm_config_shape_validate() {
    local config_file="$1"

    [ -f "$config_file" ] || { echo "配置文件不存在: $config_file"; return 0; }
    if ! command -v jq >/dev/null 2>&1; then
        # ★ jq 不可用 ⇒ **不拦**（这台机器本来就跑不了 realm）。
        #   真正的拦截在构造期（lib/realm.sh 的形态自检，纯 bash，处处能跑）。
        echo "jq 不可用，跳过配置形态校验"
        return 0
    fi

    local problems
    problems=$(jq -r 'if (.endpoints | type) != "array" then ["endpoints 必须是数组"]
else
  [ .endpoints[] |
      if (.remote | type) != "string" then "remote 必须是 string"
      elif (.remote | length) == 0 then "remote 不能为空"
      elif ((.extra_remotes // []) | type) != "array" then "extra_remotes 必须是数组"
      elif ((((.extra_remotes // []) | map(type) | unique) - ["string"]) | length) > 0) then "extra_remotes 的元素必须是 string"
      elif (has("balance") and (.balance != null)) then
        (if (.balance | type) != "string" then "balance 必须是 string"
         elif ((.balance | test("^[A-Za-z][A-Za-z0-9_-]*: *[0-9]+(, *[0-9]+)*$")) | not) then "balance 必须形如 策略: 权重1, 权重2"
         elif ((.balance | split(":")[1] | split(",") | map(gsub("^ +| +$"; "")) | length) != (1 + ((.extra_remotes // []) | length))) then "balance 的权重个数与目标数不一致"
         else null end)
      else null end
  ]
end
| map(select(. != null))
| join("；")' "$config_file" 2>/dev/null)
    if [ $? -ne 0 ]; then
        # ★ jq 自己没跑起来（台架的 jq 桩能力不足 / 过滤器不支持 / 文件坏了）
        #   ⇒ **不拦**，只提示。
        #   拦在这里 = 「校验器跑不了」变成「配置写不进去」—— 那是更糟的故障。
        echo "jq 未能完成形态校验（跳过）"
        return 0
    fi
    problems=$(printf '%s' "$problems" | tr -d '\r')
    if [ -z "$problems" ]; then
        return 0
    fi
    echo "$problems"
    return 1
}

generate_complete_config() {
    local endpoints="$1"
    local config_path="${2:-$CONFIG_PATH}"

    local network_config=$(generate_network_config)
    if [ -z "$network_config" ]; then
        network_config='{"no_tcp": false, "use_udp": true}'
    fi

    # ★ 先写临时文件 → 校验形态 → 通过才原子替换（A-17 护栏）
    #   形态不合法 ⇒ 删掉临时文件、**保留原配置**、返回非 0。
    #   原来直接 > 覆盖写：坏配置会立刻落盘 ⇒ realm 重启后 panic ⇒ 全站断流。
    local tmp_config="${config_path}.tmp.$$"
    tr -d '\r' > "$tmp_config" <<EOF
{
    "network": $network_config,
    "endpoints": [$endpoints
    ]
}
EOF

    local problem
    problem=$(realm_config_shape_validate "$tmp_config")
    if [ $? -ne 0 ]; then
        rm -f "$tmp_config" 2>/dev/null
        echo -e "${RED}✗ 配置形态校验失败：本次不写入（保留原配置）${NC}" >&2
        [ -n "$problem" ] && echo -e "${RED}  原因：${problem}${NC}" >&2
        return 1
    fi

    if ! mv -f "$tmp_config" "$config_path" 2>/dev/null; then
        rm -f "$tmp_config" 2>/dev/null
        echo -e "${RED}✗ 配置文件写入失败${NC}" >&2
        return 1
    fi
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行。${NC}"
        exit 1
    fi
}

# 检测系统类型（支持 Debian/Ubuntu、Alpine、CentOS/RHEL）
detect_system() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}错误: 无法识别系统（缺少 /etc/os-release）${NC}"
        exit 1
    fi
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID

    case "$ID" in
        debian|ubuntu)
            DISTRO="debian" ;;
        alpine)
            DISTRO="alpine" ;;
        centos|rhel|rocky|almalinux|fedora)
            DISTRO="centos" ;;
        *)
            echo -e "${RED}错误: 不支持的系统: $ID${NC}"
            echo -e "${YELLOW}当前支持: Debian/Ubuntu, Alpine, CentOS/RHEL${NC}"
            exit 1 ;;
    esac

    # 包管理器
    if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
    elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
    else
        echo -e "${RED}错误: 未找到支持的包管理器${NC}"
        exit 1
    fi

    # init 系统
    if command -v systemctl >/dev/null 2>&1; then INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_SYSTEM="openrc"
    else
        echo -e "${RED}错误: 未找到支持的 init 系统${NC}"
        exit 1
    fi
}

# 按当前 CPU 架构与 libc 推导 realm 官方 release 的安装包名（资产名）
# 架构「型号」迭代时只改这一处：安装与更新共用同一份映射，不会对不上
#   x86_64  → realm-x86_64-unknown-linux-{gnu|musl}.tar.gz
#   aarch64 → realm-aarch64-unknown-linux-{gnu|musl}.tar.gz
#   armv7   → realm-armv7-unknown-linux-{gnueabihf|musleabihf}.tar.gz
# 取不到映射时返回空（调用方负责报错）
detect_realm_asset_name() {
    local arch libc_suffix="gnu"
    arch=$(uname -m 2>/dev/null)

    # Alpine 用 musl，其余用 gnu
    if [ -f /etc/alpine-release ]; then
        libc_suffix="musl"
    fi

    case "$arch" in
        x86_64|amd64)
            echo "realm-x86_64-unknown-linux-${libc_suffix}.tar.gz"
            ;;
        aarch64|arm64)
            echo "realm-aarch64-unknown-linux-${libc_suffix}.tar.gz"
            ;;
        armv7l|armv6l|arm)
            if [ "$libc_suffix" = "musl" ]; then
                echo "realm-armv7-unknown-linux-musleabihf.tar.gz"
            else
                echo "realm-armv7-unknown-linux-gnueabihf.tar.gz"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# 统一包安装分发
_pkg_install() {
    case "$PKG_MGR" in
        apt-get)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y "$@" >/dev/null 2>&1 ;;
        apk)
            apk add --no-cache "$@" >/dev/null 2>&1 ;;
        yum|dnf)
            $PKG_MGR install -y "$@" >/dev/null 2>&1 ;;
    esac
    for tool in "$@"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} $tool 安装成功"
        else
            echo -e "${RED}✗${NC} $tool 安装失败"
        fi
    done
}

manage_dependencies() {
    local mode="$1"
    local missing_tools=()

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        elif [ "$mode" = "install" ]; then
            echo -e "${GREEN}✓${NC} $tool 已安装"
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        if [ "$mode" = "check" ]; then
            echo -e "${RED}错误: 缺少必备工具: ${missing_tools[*]}${NC}"
            echo -e "${YELLOW}请先选择菜单选项1进行安装，或手动运行安装命令:${NC}"
            echo -e "${BLUE}curl -fsSL https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwPF.sh | sudo bash -s install${NC}"
            exit 1
        elif [ "$mode" = "install" ]; then
            echo -e "${YELLOW}需要安装以下工具: ${missing_tools[*]}${NC}"
            echo -e "${BLUE}使用 $PKG_MGR 安装依赖,下载中...${NC}"
            _pkg_install "${missing_tools[@]}"
        fi
    elif [ "$mode" = "install" ]; then
        echo -e "${GREEN}所有必备工具已安装完成${NC}"
    fi

    [ "$mode" = "install" ] && echo ""
}

check_dependencies() {
    manage_dependencies "check"
}

# 获取本机公网IP
get_public_ip() {
    local ip_type="$1"
    local ip=""
    local curl_opts=""

    [ "$ip_type" = "ipv6" ] && curl_opts="-6"

    ip=$(curl -s --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT $curl_opts https://ipinfo.io/ip 2>/dev/null | tr -d '\n\r ')
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]]; then
        echo "$ip"
        return 0
    fi

    ip=$(curl -s --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT $curl_opts https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "ip=" | cut -d'=' -f2 | tr -d '\n\r ')
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]]; then
        echo "$ip"
        return 0
    fi

    echo ""
}

smart_display_target() {
    local target="$1"

    # 处理多地址情况
    if [[ "$target" == *","* ]]; then
        # 分割多地址
        IFS=',' read -ra addresses <<< "$target"
        local display_addresses=()

        for addr in "${addresses[@]}"; do
            addr=$(echo "$addr" | xargs)  # 去除空格
            local display_addr="$addr"

            if [[ "$addr" == "127.0.0.1" ]] || [[ "$addr" == "localhost" ]]; then
                # IPv4本地地址时显示IPv4公网IP
                local public_ipv4=$(get_public_ip ipv4)
                if [ -n "$public_ipv4" ]; then
                    display_addr="$public_ipv4"
                fi
            elif [[ "$addr" == "::1" ]]; then
                # IPv6本地地址时显示IPv6公网IP
                local public_ipv6=$(get_public_ip ipv6)
                if [ -n "$public_ipv6" ]; then
                    display_addr="$public_ipv6"
                fi
            fi

            display_addresses+=("$display_addr")
        done

        # 重新组合地址
        local result=""
        for i in "${!display_addresses[@]}"; do
            if [ $i -gt 0 ]; then
                result="$result,"
            fi
            result="$result${display_addresses[i]}"
        done
        echo "$result"
    else
        # 单地址处理
        if [[ "$target" == "127.0.0.1" ]] || [[ "$target" == "localhost" ]]; then
            # IPv4本地地址时显示IPv4公网IP
            local public_ipv4=$(get_public_ip ipv4)
            if [ -n "$public_ipv4" ]; then
                echo "$public_ipv4"
            else
                echo "$target"
            fi
        elif [[ "$target" == "::1" ]]; then
            # IPv6本地地址时显示IPv6公网IP
            local public_ipv6=$(get_public_ip ipv6)
            if [ -n "$public_ipv6" ]; then
                echo "$public_ipv6"
            else
                echo "$target"
            fi
        else
            echo "$target"
        fi
    fi
}
# 支持realm单端口多规则复用，避免误报端口冲突
check_port_usage() {
    local port="$1"
    [ -z "$port" ] && return 0

    local output=$(ss -tulnp 2>/dev/null | grep ":${port} ")
    [ -z "$output" ] && return 0

    if echo "$output" | grep -q "realm"; then
        echo -e "${GREEN}✓ 端口 $port 已被realm服务占用，支持单端口中转多服务端配置${NC}"
        return 1
    fi

    echo -e "${YELLOW}警告: 端口 $port 已被其他服务占用${NC}"
    echo -e "${BLUE}占用进程信息:${NC}"
    echo "$output" | sed 's/^/  /'

    ui_read_default "是否继续配置？(y/n): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "配置已取消"; exit 1; }
    return 0
}

# 连通性探测 check_connectivity 已移入 lib/health.sh（与故障转移共用同一份实现，
# 优先 nc，缺 nc 时回退 bash /dev/tcp）——health.sh 在本文件之后加载。

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_ports() {
    local input="${1// /}"
    [ -z "$input" ] && return 1

    IFS=',' read -ra ports <<< "$input"
    for p in "${ports[@]}"; do
        validate_port "$p" || return 1
    done
}

validate_ip() {
    local ip="$1"

    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [ "$i" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi

    if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *":"* ]]; then
        return 0
    fi
    return 1
}

validate_target_address() {
    local target="$1"

    if [ -z "$target" ]; then
        return 1
    fi

    if [[ "$target" == *","* ]]; then
        IFS=',' read -ra ADDRESSES <<< "$target"
        for addr in "${ADDRESSES[@]}"; do
            addr=$(echo "$addr" | xargs)
            if ! validate_single_address "$addr"; then
                return 1
            fi
        done
        return 0
    else
        validate_single_address "$target"
    fi
}

validate_single_address() {
    local addr="$1"

    if validate_ip "$addr"; then
        return 0
    fi

    if [[ "$addr" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || [[ "$addr" == "localhost" ]]; then
        return 0
    fi

    return 1
}

# 根据角色和安全级别生成对应的传输配置，确保客户端和服务端配置匹配 1=中转服务器(客户端), 2=出口服务器(服务端)
get_transport_config() {
    local security_level="$1"
    local server_name="$2"
    local cert_path="$3"
    local key_path="$4"
    local role="$5"
    local ws_path="$6"

    case "$security_level" in
        "standard")
            echo ""
            ;;
        "ws")
            local ws_path_param="${ws_path:-/ws}"
            local ws_host_param="${server_name:-$DEFAULT_SNI_DOMAIN}"
            if [ "$role" = "1" ]; then
                echo '"remote_transport": "ws;host='$ws_host_param';path='$ws_path_param'"'
            elif [ "$role" = "2" ]; then
                echo '"listen_transport": "ws;host='$ws_host_param';path='$ws_path_param'"'
            fi
            ;;
        "tls_self")
            local sni_name="${server_name:-$DEFAULT_SNI_DOMAIN}"
            if [ "$role" = "1" ]; then
                echo '"remote_transport": "tls;sni='$sni_name';insecure"'
            elif [ "$role" = "2" ]; then
                echo '"listen_transport": "tls;servername='$sni_name'"'
            fi
            ;;
        "tls_ca")
            if [ "$role" = "1" ]; then
                local sni_name="${server_name:-$DEFAULT_SNI_DOMAIN}"
                echo '"remote_transport": "tls;sni='$sni_name'"'
            elif [ "$role" = "2" ]; then
                if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
                    echo '"listen_transport": "tls;cert='$cert_path';key='$key_path'"'
                else
                    echo ""
                fi
            fi
            ;;
        "ws_tls_self")
            local ws_host_param="${server_name:-$DEFAULT_SNI_DOMAIN}"
            local ws_path_param="${ws_path:-/ws}"
            local sni_name="${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            if [ "$role" = "1" ]; then
                echo '"remote_transport": "ws;host='$ws_host_param';path='$ws_path_param';tls;sni='$sni_name';insecure"'
            elif [ "$role" = "2" ]; then
                echo '"listen_transport": "ws;host='$ws_host_param';path='$ws_path_param';tls;servername='$sni_name'"'
            fi
            ;;
        "ws_tls_ca")
            local ws_host_param="${server_name:-$DEFAULT_SNI_DOMAIN}"
            local ws_path_param="${ws_path:-/ws}"
            local sni_name="${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            if [ "$role" = "1" ]; then
                echo '"remote_transport": "ws;host='$ws_host_param';path='$ws_path_param';tls;sni='$sni_name'"'
            elif [ "$role" = "2" ]; then
                if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
                    echo '"listen_transport": "ws;host='$ws_host_param';path='$ws_path_param';tls;cert='$cert_path';key='$key_path'"'
                else
                    echo ""
                fi
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}
