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
# failover.sh 必须在 ui.sh 之前 (ui.sh 调用 failover_proxy_menu)
# health.sh 提供连通性探测与健康检查服务，必须在 rules.sh/server.sh 之前
LIB_FILES=("core.sh" "health.sh" "rules.sh" "server.sh" "realm.sh" "failover.sh" "ui.sh")

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

    # 下载 cmd/ 守护进程源文件（xwpf-failover）
    # 这里必须刷新 cmd/ 副本：lib/failover.sh 的 daemon 版本比对以 src_dir(=INSTALL_DIR/cmd)
    # 的副本为准，副本不更新则版本比对永远判定「无变化」，守护进程永远升不了级。
    # 下载失败不阻断安装：failover_install_files 还有 GitHub raw fallback。
    local cmd_dir="${INSTALL_DIR}/cmd"
    mkdir -p "$cmd_dir"
    for f in xwpf-failover.py xwpf-failover.service; do
        if _download "$REPO_RAW_URL/cmd/$f" "$cmd_dir/$f"; then
            echo -e "  ${_GREEN}✓${_NC} cmd/$f"
        else
            echo -e "  ${_YELLOW}!${_NC} cmd/$f 下载失败（安装守护进程时会自动重试）"
        fi
    done

    # 创建快捷命令
    ln -sf "$INSTALL_DIR/xwPF.sh" "$SHORTCUT_PATH"
    echo -e "${_GREEN}✓ 快捷命令已创建: pf${_NC}"

    echo -e "${_GREEN}=== 脚本安装完成${_NC}"
    echo ""
}

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
        _SKIP_SCRIPT_UPDATE=1 smart_install
        # 安装 active/passive 主备故障转移守护（幂等：已装跳过）
        failover_install_check && failover_service_enable
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
