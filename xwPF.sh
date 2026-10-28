#!/bin/bash

# xwPF - Realm 端口转发管理工具
# Bootstrap 引导器 + 入口

# 安装路径
INSTALL_DIR="/usr/local/bin"
LIB_DIR="$INSTALL_DIR/lib"
SHORTCUT_PATH="/usr/local/bin/pf"

# 仓库地址
REPO_RAW_URL="https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main"

# 模块列表（加载顺序）
# health.sh 提供连通性探测与健康检查服务，必须在 rules.sh/server.sh 之前
# update.sh 提供更新中心（查版本 + 安全更新），必须在 ui.sh 之前（ui.sh 的菜单调用它）
# ★ 不含 failover.sh：「进程级主备池 + 独立守护进程」那一整套已下线。
#   留着 → lib/failover.sh 早就没了，_bootstrap 会下载失败 → 安装直接中断。
LIB_FILES=("core.sh" "health.sh" "rules.sh" "server.sh" "realm.sh" "update.sh" "ui.sh")

# 颜色
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_BLUE='\033[0;34m'
_NC='\033[0m'

# 下载函数
# 统一「下载到临时文件 → 校验 → 原子替换」：
# 禁止对已存在的目标文件做断点续传（curl -C - / wget -c 只校验 HTTP Range 的起点，
# 不校验本地内容与远端是否一致，远端变长时会把新版本追加到旧内容后面，
# 生成大小正常但内容损坏的文件，source 后直接让 pf 命令失效）
_download() {
    local url="$1" target="$2"
    local tmp="${target}.tmp.$$"

    rm -f "${target}.tmp" "$tmp"

    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$target"
        return 0
    fi

    rm -f "$tmp"

    if wget -q --tries=3 --timeout=30 -O "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$target"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

# 安装/更新脚本文件到系统（幂等）
_bootstrap() {
    echo -e "${_YELLOW}正在安装/更新脚本文件...${_NC}"

    mkdir -p "$LIB_DIR"

    # 下载入口脚本
    if _download "$REPO_RAW_URL/xwPF.sh" "$INSTALL_DIR/xwPF.sh"; then
        chmod +x "$INSTALL_DIR/xwPF.sh"
        echo -e "  ${_GREEN}✓${_NC} xwPF.sh"
    else
        echo -e "  ${_RED}✗${_NC} xwPF.sh 下载失败"
        return 1
    fi

    # 下载所有模块
    local failed=0
    for f in "${LIB_FILES[@]}"; do
        if _download "$REPO_RAW_URL/lib/$f" "$LIB_DIR/$f"; then
            echo -e "  ${_GREEN}✓${_NC} lib/$f"
        else
            echo -e "  ${_RED}✗${_NC} lib/$f 下载失败"
            failed=1
        fi
    done

    [ "$failed" -eq 1 ] && return 1

    # ★ 不再下载 cmd/xwpf-failover.*：
    #   主备池守护那一整套（cmd/xwpf-failover.py / .service）已随功能下线，
    #   装了也不会被启用 —— 老机器上的残留由 _cleanup_legacy_failover_daemon 收拾。

    # 创建快捷命令
    ln -sf "$INSTALL_DIR/xwPF.sh" "$SHORTCUT_PATH"
    echo -e "${_GREEN}✓ 快捷命令已创建: pf${_NC}"

    echo -e "${_GREEN}=== 脚本安装完成${_NC}"
    echo ""
}

# ★ 老机器上「主备池守护残留」的清理实现**只有一份**，在 lib/ui.sh 的
#   _cleanup_legacy_failover_daemon —— 菜单项 8「卸载服务」直接走 lib/ui.sh 的
#   uninstall_realm，**不经过本文件**；清理写在这里，菜单卸载时够不着。

# 加载模块
_load_libs() {
    if [ ! -d "$LIB_DIR" ] || [ ! -f "$LIB_DIR/core.sh" ]; then
        echo -e "${_RED}错误: 未找到模块目录，请先安装${_NC}"
        echo -e "${_BLUE}wget -qO- ${REPO_RAW_URL}/xwPF.sh | sudo bash -s install${_NC}"
        return 1
    fi

    for f in "${LIB_FILES[@]}"; do
        if [ -f "$LIB_DIR/$f" ]; then
            source "$LIB_DIR/$f"
        else
            echo -e "${_RED}错误: 缺少模块 $f${_NC}"
            return 1
        fi
    done
}

# 主入口
case "${1:-}" in
    install)
        [ "$(id -u)" -ne 0 ] && { echo -e "${_RED}错误: 需要 root 权限${_NC}"; exit 1; }
        _bootstrap || exit 1
        _load_libs || exit 1
        # 老机器上的主备池守护残留：产品不再安装该守护，残留必须收拾干净
        # （否则留下一个没人管、但还占着端口的僵尸守护）
        # 放在 smart_install 之前：先把守护占着的端口放掉，再让 realm 起服务。
        _cleanup_legacy_failover_daemon
        _SKIP_SCRIPT_UPDATE=1 smart_install
        # 探测超时预算：规则里写死的 3 秒抬到 10 秒（老默认值太紧 → 主备误切）
        health_migrate_connection_timeout || true
        # 重新生成健康探测端产物（唯一真源 = lib/health.sh）
        # ★ 装/升级不重新生成 → 机器上跑的是旧产物 = 探测端静默失效
        #   （日志照样打「健康检查完成」，状态文件却停在几小时前）
        # 不重启 timer：unit 是 Type=oneshot + ExecStart=<路径>，下个 tick 自然生效。
        # ★ 首次安装 = **fail fast 中断**（Chief 裁定）：
        #   装完但探测端是坏的 = 主备切换不可用 = 用户以为装好了。
        #   安装失败是**可恢复**的（重跑一次），功能坏掉是**不可见**的
        #   → 宁可中断，也不能留一个「看起来装好了」的坏机器。
        if health_check_script_regenerate; then
            echo -e "  ${_GREEN}✓${_NC} 已重新生成健康检查脚本"
        else
            echo -e ""
            echo -e "  ${_RED}✗${_NC} 重新生成健康检查脚本失败：/etc/realm/health/health_check.sh 仍是旧产物"
            echo -e "  ${_RED}  健康探测不可用 → 权重 10,0 主备的切换不可用${_NC}"
            echo -e "  ${_RED}  （探测端不再更新状态文件 → 该切不切，且界面看不出来）${_NC}"
            echo -e "  ${_YELLOW}  可执行的修复步骤：${_NC}"
            echo -e "    1) 修好上面的报错原因后，重新执行一次安装："
            echo -e "       ${_BLUE}wget -qO- ${REPO_RAW_URL}/xwPF.sh | sudo bash -s install${_NC}"
            echo -e "    2) 或手工重生成探测端脚本（需 root）："
            echo -e "       ${_BLUE}sudo bash -c 'source ${LIB_DIR}/health.sh && health_check_script_regenerate'${_NC}"
            # 写日志（写日志本身失败也不影响主流程：函数内部已吞掉所有错误）
            if declare -F health_regenerate_log_failure >/dev/null 2>&1; then
                health_regenerate_log_failure "首次安装（xwPF.sh install）：/etc/realm/health/health_check.sh 仍是旧产物" || true
            fi
            echo -e ""
            echo -e "  ${_RED}✗${_NC} 安装中断：健康探测端不可用，不能留一个坏掉的机器。"
            echo -e "  ${_YELLOW}  详细日志：/var/log/xwPF/health-regenerate.log${_NC}"
            exit 1
        fi
        # 快探测产物（**只观测**：每秒刷新菜单里的时延/丢包显示）
        #   与判定端是**两条独立的流**：它不写判定端的状态文件、不触发配置重生成
        #   ⇒ 起不来也不影响切换（这里**不** fail fast，与判定端不同）。
        if declare -F fast_probe_script_regenerate >/dev/null 2>&1 && fast_probe_script_regenerate; then
            echo -e "  ${_GREEN}✓${_NC} 已重新生成快探测脚本（只观测，不参与切换）"
        else
            echo -e "  ${_YELLOW}提示：${_NC}快探测脚本未生成（只影响菜单里的时延/丢包刷新，不影响主备切换）"
        fi
        ;;
    uninstall)
        [ "$(id -u)" -ne 0 ] && { echo -e "${_RED}错误: 需要 root 权限${_NC}"; exit 1; }
        _load_libs || exit 1
        # 老机器上的主备池守护残留：先收拾干净，再卸脚本
        #   ★ 卸载路径传 force：用户明确要拆全部 ⇒ 不受「还在服务就跳过」的保护。
        #     （只有 install / 升级路径才需要那个保护 —— 见 lib/ui.sh 的
        #      _legacy_failover_daemon_in_use）
        _cleanup_legacy_failover_daemon force
        # 完整卸载（分阶段，需要交互确认）由 lib/ui.sh 的 uninstall_realm 负责
        if declare -F uninstall_realm >/dev/null 2>&1; then
            uninstall_realm
        else
            echo -e "${_YELLOW}提示: 未找到 uninstall_realm（lib/ui.sh 未加载），只清理了主备守护残留${_NC}"
        fi
        ;;
    help|--help|-h)
        # 打印用法（与 pf --help 一致）
        _load_libs || exit 1
        main "$@"
        ;;
    *)
        _load_libs || exit 1
        main "$@"
        ;;
esac
