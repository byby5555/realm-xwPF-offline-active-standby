#!/bin/bash
# ---- 更新中心 ----
#
# 目标：上游版本 / 架构型号迭代后，脚本里能查版本、能安全更新。
#
# 「安全更新」的五条纪律（每条都对应一个真实会出事的地方）：
#   1) 先下载到 staging，全部校验通过才动现有文件
#      → 下载中途失败时，现有文件一个字节都没被碰过
#   2) 更新前备份（带版本号 + 时间戳）→ 出问题能回滚
#   3) sha256 校验（GitHub release asset 的 digest）
#      → 挡掉下载损坏 / 被劫持的安装包
#   4) 更新后验证（新文件能执行、版本号符合预期、服务能起来）
#      → 验证不过自动回滚，并把服务恢复到更新前的状态
#   5) 失败不 exit 整个脚本 → 回到菜单，用户还能继续操作
#
# 已知边界：
#   - 脚本包更新会替换**正在运行的** xwPF.sh。bash 是按需读取脚本文件的，
#     替换后必须退出当前进程（由 update_center_menu 负责 exit），
#     否则会读到错乱的内容。

# ---- 可注入的配置（测试用同名变量覆盖）----
UPDATE_REPO_RAW_URL="${UPDATE_REPO_RAW_URL:-https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main}"
UPDATE_GITHUB_API="${UPDATE_GITHUB_API:-https://api.github.com}"
UPDATE_REALM_REPO="${UPDATE_REALM_REPO:-zhboner/realm}"
UPDATE_REALM_DOWNLOAD_BASE="${UPDATE_REALM_DOWNLOAD_BASE:-https://github.com}"
UPDATE_BACKUP_DIR="${UPDATE_BACKUP_DIR:-/usr/local/bin/.xwpf-backup}"
UPDATE_LOCK_DIR="${UPDATE_LOCK_DIR:-/var/lock/xwpf-update.lock}"
UPDATE_STAGING_ROOT="${UPDATE_STAGING_ROOT:-/tmp/xwpf-update}"
UPDATE_KEEP_BACKUPS="${UPDATE_KEEP_BACKUPS:-5}"

# 脚本包文件清单（xwPF.sh 单独处理）
UPDATE_LIB_FILES=("core.sh" "health.sh" "rules.sh" "server.sh" "realm.sh" "failover.sh" "ui.sh" "update.sh")
UPDATE_CMD_FILES=("xwpf-failover.py" "xwpf-failover.service")

# ============================================================
# 基础工具
# ============================================================

# 下载到指定路径（临时文件 → 原子替换）
update_download_to() {
    local url="$1"
    local target="$2"
    local tmp="${target}.tmp.$$"

    rm -f "$tmp"
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

# 计算文件 sha256
update_sha256_of() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
    else
        echo ""
    fi
}

# 归一化版本号：去掉前导 v/V
#
# 为什么必须有这一步：
#   GitHub release 的 tag 带 v（v2.9.6），而 realm 二进制 --version 输出的是
#   "Realm 2.9.6 [brutal][proxy]..."（不带 v）。直接做字符串比较会得出
#   「期望 v2.9.6，实际 2.9.6」的假不一致 —— 更新会被无谓地拒绝，
#   「已是最新」也永远判不出来。
#   老的安装路径 compare_and_ask_update 早就做了同样的归一化，这里必须对齐。
update_norm_version() {
    local v="$1"
    [ -n "$v" ] || return 0
    v="${v#v}"
    v="${v#V}"
    echo "$v"
}

# 当前 realm 版本号（纯版本号，如 2.9.3；取不到返回空）
update_realm_current_version() {
    local out=""
    [ -x "$REALM_PATH" ] || return 1
    out=$("$REALM_PATH" --version 2>&1 | head -1)
    if [ -z "$out" ]; then
        out=$("$REALM_PATH" -v 2>&1 | head -1)
    fi
    echo "$out" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# 当前 realm 版本描述（整行，给人看）
update_realm_current_desc() {
    local out=""
    [ -x "$REALM_PATH" ] || { echo "未安装"; return 1; }
    out=$("$REALM_PATH" --version 2>&1 | head -1)
    if [ -z "$out" ]; then
        out=$("$REALM_PATH" -v 2>&1 | head -1)
    fi
    echo "${out:-未知}"
}

# 上游最新 release 的 tag（取不到返回空）
update_realm_latest_tag() {
    local json=""

    if command -v jq >/dev/null 2>&1; then
        json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
            "${UPDATE_GITHUB_API}/repos/${UPDATE_REALM_REPO}/releases/latest" 2>/dev/null)
        if [ -n "$json" ]; then
            echo "$json" | jq -r '.tag_name // empty' 2>/dev/null | head -1
            return 0
        fi
    fi

    # 兜底：解析 releases 页面（拿不到 digest 时用）
    local v
    v=$(curl -sL --connect-timeout 10 --max-time 30 \
        "https://github.com/${UPDATE_REALM_REPO}/releases" 2>/dev/null | \
        head -2100 | sed -n 's|.*releases/tag/v\([0-9.]*\).*|v\1|p' | head -1)
    echo "$v"
}

# 上游某个资产的 sha256（取不到返回空 = 不做哈希校验）
update_realm_asset_digest() {
    local asset_name="$1"
    local json=""

    command -v jq >/dev/null 2>&1 || return 1
    json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        "${UPDATE_GITHUB_API}/repos/${UPDATE_REALM_REPO}/releases/latest" 2>/dev/null)
    [ -n "$json" ] || return 1

    local digest
    digest=$(echo "$json" | jq -r --arg n "$asset_name" \
        '.assets[]? | select(.name==$n) | .digest // empty' 2>/dev/null | head -1)
    [ -n "$digest" ] || return 1
    digest="${digest#sha256:}"
    echo "$digest"
}

# 远端脚本包的版本号（取 core.sh 里的 SCRIPT_VERSION）
update_scripts_latest_version() {
    local tmp
    tmp="${UPDATE_STAGING_ROOT}/.version.$$"
    mkdir -p "$UPDATE_STAGING_ROOT" 2>/dev/null
    if update_download_to "${UPDATE_REPO_RAW_URL}/lib/core.sh" "$tmp"; then
        grep -oE '^SCRIPT_VERSION="[^"]+"' "$tmp" 2>/dev/null | head -1 | sed 's/.*="//; s/"$//'
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# ============================================================
# 锁 / 备份 / 回滚
# ============================================================

# 取更新锁（mkdir 是原子的；进程没了留下的是陈旧锁，会自动清理）
update_lock_acquire() {
    if mkdir "$UPDATE_LOCK_DIR" 2>/dev/null; then
        echo $$ > "$UPDATE_LOCK_DIR/pid" 2>/dev/null
        return 0
    fi

    local pid=""
    pid=$(cat "$UPDATE_LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        echo -e "${RED}另一个更新进程正在运行 (PID $pid)${NC}" >&2
        return 1
    fi

    # 陈旧锁（上次进程被 kill 留下的）
    rm -f "$UPDATE_LOCK_DIR/pid" 2>/dev/null
    rmdir "$UPDATE_LOCK_DIR" 2>/dev/null
    if mkdir "$UPDATE_LOCK_DIR" 2>/dev/null; then
        echo $$ > "$UPDATE_LOCK_DIR/pid" 2>/dev/null
        return 0
    fi
    return 1
}

update_lock_release() {
    rm -f "$UPDATE_LOCK_DIR/pid" 2>/dev/null
    rmdir "$UPDATE_LOCK_DIR" 2>/dev/null
    return 0
}

# 创建备份目录（名字带标签 + 时间戳）
update_backup_dir_create() {
    local label="$1"
    local ts dir
    ts=$(date +%Y%m%d-%H%M%S)
    dir="${UPDATE_BACKUP_DIR}/${label}-${ts}"
    mkdir -p "$dir" 2>/dev/null || return 1
    echo "$dir"
}

# 备份单个文件（保留原始绝对路径结构）
update_backup_file() {
    local src="$1"
    local dir="$2"
    [ -f "$src" ] || return 0
    local rel
    rel=$(echo "$src" | sed "s|^/||")
    mkdir -p "${dir}/$(dirname "$rel")" 2>/dev/null
    cp -p "$src" "${dir}/${rel}" 2>/dev/null
}

# 从备份恢复（恢复到原始绝对路径）
update_restore_backup() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    local f rel
    while IFS= read -r f; do
        rel="${f#$dir/}"
        cp -p "$f" "/${rel}" 2>/dev/null
    done < <(find "$dir" -type f 2>/dev/null)
    return 0
}

# 清理旧备份，只保留最近 N 个
update_prune_backups() {
    [ -d "$UPDATE_BACKUP_DIR" ] || return 0
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        rm -rf "$d" 2>/dev/null
    done < <(ls -1dt "${UPDATE_BACKUP_DIR}"/*/ 2>/dev/null | tail -n +$((UPDATE_KEEP_BACKUPS + 1)))
    return 0
}

# ============================================================
# 安全更新：realm 主程序
# ============================================================

safe_update_realm() {
    echo -e "${BLUE}=== 安全更新 realm 主程序 ===${NC}"
    echo ""

    if ! update_lock_acquire; then
        return 1
    fi

    local staging="${UPDATE_STAGING_ROOT}/realm.$$"
    local backup=""
    local service_was_running=false

    rm -rf "$staging" 2>/dev/null
    mkdir -p "$staging" 2>/dev/null

    # 1) 当前状态
    local current_desc current_ver
    current_desc=$(update_realm_current_desc)
    current_ver=$(update_realm_current_version)
    echo -e "  当前版本: ${GREEN}${current_desc}${NC}"

    # 2) 架构型号（资产名）—— 架构迭代时只改 detect_realm_asset_name
    local asset
    asset=$(detect_realm_asset_name)
    if [ -z "$asset" ]; then
        echo -e "${RED}✗ 当前 CPU 架构没有对应的官方安装包${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi
    echo -e "  架构型号: ${GREEN}${asset}${NC}"

    # 3) 上游最新版本
    local tag
    tag=$(update_realm_latest_tag)
    if [ -z "$tag" ]; then
        echo -e "${RED}✗ 获取上游最新版本失败（检查网络）${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi
    echo -e "  最新版本: ${GREEN}${tag}${NC}"

    # 4) 已是最新
    if [ -n "$current_ver" ] && [ "$(update_norm_version "$current_ver")" = "$(update_norm_version "$tag")" ]; then
        echo -e "${GREEN}✓ 当前已是最新版本${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 0
    fi

    # 5) 确认
    local ans=""
    read -p "  是否更新到 ${tag}？(y/n) [默认: n]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}已取消，现有版本未改动${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 0
    fi

    # 6) 下载（临时文件 → 原子替换，失败不碰现有安装）
    local dl_url tarball
    dl_url="${UPDATE_REALM_DOWNLOAD_BASE}/${UPDATE_REALM_REPO}/releases/download/${tag}/${asset}"
    tarball="${staging}/${asset}"

    local sources=(
        "$dl_url"
        "https://gh-proxy.com/${dl_url}"
        "https://ghproxy.net/${dl_url}"
        "https://mirror.ghproxy.com/${dl_url}"
    )
    local ok=false src
    for src in "${sources[@]}"; do
        echo -e "${YELLOW}  下载: ${src}${NC}"
        if download_from_sources "$src" "$tarball"; then
            ok=true
            break
        fi
    done
    if [ "$ok" != true ]; then
        echo -e "${RED}✗ 下载失败，现有版本未改动${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi

    # 7) sha256 校验
    local digest
    digest=$(update_realm_asset_digest "$asset")
    if [ -n "$digest" ]; then
        local got
        got=$(update_sha256_of "$tarball")
        if [ "$got" != "$digest" ]; then
            echo -e "${RED}✗ sha256 校验不通过，拒绝安装${NC}"
            echo -e "    期望: ${digest}"
            echo -e "    实际: ${got:-（无法计算）}"
            rm -rf "$staging" 2>/dev/null
            update_lock_release
            return 1
        fi
        echo -e "${GREEN}  ✓ sha256 校验通过${NC}"
    else
        echo -e "${YELLOW}  ! 上游未提供 sha256（取不到 digest），跳过哈希校验${NC}"
    fi

    # 8) 解压 + 新二进制自检
    if ! (cd "$staging" && tar -xzf "$tarball" 2>/dev/null); then
        echo -e "${RED}✗ 解压失败，现有版本未改动${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi
    if [ ! -f "${staging}/realm" ]; then
        echo -e "${RED}✗ 压缩包里没有 realm 可执行文件${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi

    chmod +x "${staging}/realm" 2>/dev/null
    local new_desc="" new_ver=""
    new_desc=$("${staging}/realm" --version 2>&1 | head -1)
    new_ver=$(echo "$new_desc" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    # 注意：不能只看「输出是否为空」——
    # bash 执行一个坏文件（比如架构不匹配）会打印 "command not found"，
    # 输出非空但根本不是有效程序。必须从输出里**解析出版本号**才算自检通过。
    if [ -z "$new_ver" ]; then
        echo -e "${RED}✗ 新二进制无法执行或不是有效程序（架构不匹配 / 文件损坏），放弃更新${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi
    if [ -n "$tag" ] && [ "$(update_norm_version "$new_ver")" != "$(update_norm_version "$tag")" ]; then
        echo -e "${RED}✗ 新二进制版本与目标不符（期望 ${tag}，实际 ${new_ver}），放弃更新${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi
    echo -e "${GREEN}  ✓ 新二进制自检通过: ${new_desc}${NC}"

    # 9) 备份旧版本
    backup=$(update_backup_dir_create "realm")
    if [ -f "$REALM_PATH" ]; then
        update_backup_file "$REALM_PATH" "$backup"
        echo -e "${BLUE}  已备份旧版本: ${backup}${NC}"
    fi

    # 10) 停服务（记住之前是否在跑）
    if svc_is_active; then
        service_was_running=true
        svc_stop >/dev/null 2>&1
    fi

    # 11) 替换
    if ! mv -f "${staging}/realm" "$REALM_PATH" 2>/dev/null; then
        echo -e "${RED}✗ 替换失败${NC}"
        update_restore_backup "$backup"
        [ "$service_was_running" = true ] && svc_start >/dev/null 2>&1
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi
    chmod +x "$REALM_PATH" 2>/dev/null

    # 12) 启动 + 验证
    if [ "$service_was_running" = true ]; then
        svc_start >/dev/null 2>&1
        sleep 1
        if ! svc_is_active; then
            echo -e "${RED}✗ 新版本启动失败，自动回滚到旧版本${NC}"
            update_restore_backup "$backup"
            chmod +x "$REALM_PATH" 2>/dev/null
            svc_start >/dev/null 2>&1
            rm -rf "$staging" 2>/dev/null
            update_lock_release
            return 1
        fi
    fi

    rm -rf "$staging" 2>/dev/null
    update_prune_backups
    update_lock_release

    echo ""
    echo -e "${GREEN}✓ realm 主程序已更新到 ${tag}${NC}"
    return 0
}

# ============================================================
# 安全更新：脚本包（xwPF.sh + lib/*.sh + cmd/*）
# ============================================================

safe_update_scripts() {
    echo -e "${BLUE}=== 安全更新脚本包 ===${NC}"
    echo ""

    if ! update_lock_acquire; then
        return 1
    fi

    local staging="${UPDATE_STAGING_ROOT}/scripts.$$"
    local backup=""

    rm -rf "$staging" 2>/dev/null
    mkdir -p "${staging}/lib" "${staging}/cmd" 2>/dev/null

    # 1) 全部下载到 staging（一个都成功前，现有文件一个都不动）
    local failed=0 f
    if ! update_download_to "${UPDATE_REPO_RAW_URL}/xwPF.sh" "${staging}/xwPF.sh"; then
        echo -e "${RED}✗ 下载 xwPF.sh 失败，现有文件未改动${NC}"
        failed=1
    fi
    for f in "${UPDATE_LIB_FILES[@]}"; do
        if ! update_download_to "${UPDATE_REPO_RAW_URL}/lib/$f" "${staging}/lib/$f"; then
            echo -e "${RED}✗ 下载 lib/$f 失败，现有文件未改动${NC}"
            failed=1
        fi
    done
    # cmd/ 是守护进程源文件，失败不阻断（安装守护进程时会自动重试）
    for f in "${UPDATE_CMD_FILES[@]}"; do
        update_download_to "${UPDATE_REPO_RAW_URL}/cmd/$f" "${staging}/cmd/$f" || true
    done

    if [ "$failed" = "1" ]; then
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi

    # 2) 语法校验（全部通过才允许替换）
    for f in "${staging}/xwPF.sh" "${staging}"/lib/*.sh; do
        [ -f "$f" ] || continue
        if ! bash -n "$f" 2>/dev/null; then
            echo -e "${RED}✗ 语法检查失败: $(basename "$f")，现有文件未改动${NC}"
            rm -rf "$staging" 2>/dev/null
            update_lock_release
            return 1
        fi
    done

    # 3) 版本比对
    local remote_ver local_ver
    remote_ver=$(grep -oE '^SCRIPT_VERSION="[^"]+"' "${staging}/lib/core.sh" 2>/dev/null | head -1 | sed 's/.*="//; s/"$//')
    local_ver=$(grep -oE '^SCRIPT_VERSION="[^"]+"' "${LIB_DIR}/core.sh" 2>/dev/null | head -1 | sed 's/.*="//; s/"$//')
    echo -e "  当前脚本版本: ${GREEN}${local_ver:-未知}${NC}"
    echo -e "  最新脚本版本: ${GREEN}${remote_ver:-未知}${NC}"

    if [ -n "$remote_ver" ] && [ "$(update_norm_version "$remote_ver")" = "$(update_norm_version "$local_ver")" ]; then
        echo -e "${GREEN}✓ 脚本包已是最新版本${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 0
    fi

    local ans=""
    read -p "  是否更新脚本包？(y/n) [默认: n]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}已取消，现有文件未改动${NC}"
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 0
    fi

    # 4) 备份
    backup=$(update_backup_dir_create "scripts")
    update_backup_file "${INSTALL_DIR}/xwPF.sh" "$backup"
    for f in "${UPDATE_LIB_FILES[@]}"; do
        update_backup_file "${LIB_DIR}/$f" "$backup"
    done
    for f in "${UPDATE_CMD_FILES[@]}"; do
        update_backup_file "${INSTALL_DIR}/cmd/$f" "$backup"
    done
    echo -e "${BLUE}  已备份旧脚本: ${backup}${NC}"

    # 5) 替换（入口脚本 xwPF.sh 最后换：当前进程正在运行它）
    mkdir -p "$LIB_DIR" "${INSTALL_DIR}/cmd" 2>/dev/null
    for f in "${UPDATE_LIB_FILES[@]}"; do
        [ -f "${staging}/lib/$f" ] && mv -f "${staging}/lib/$f" "${LIB_DIR}/$f"
    done
    for f in "${UPDATE_CMD_FILES[@]}"; do
        [ -f "${staging}/cmd/$f" ] && mv -f "${staging}/cmd/$f" "${INSTALL_DIR}/cmd/$f"
    done
    mv -f "${staging}/xwPF.sh" "${INSTALL_DIR}/xwPF.sh" 2>/dev/null
    chmod +x "${INSTALL_DIR}/xwPF.sh" 2>/dev/null

    # 6) 验证
    if ! "${INSTALL_DIR}/xwPF.sh" --help >/dev/null 2>&1; then
        echo -e "${RED}✗ 新脚本自检失败，自动回滚到旧脚本${NC}"
        update_restore_backup "$backup"
        chmod +x "${INSTALL_DIR}/xwPF.sh" 2>/dev/null
        rm -rf "$staging" 2>/dev/null
        update_lock_release
        return 1
    fi

    rm -rf "$staging" 2>/dev/null
    update_prune_backups
    update_lock_release

    echo ""
    echo -e "${GREEN}✓ 脚本包已更新${NC}"
    echo -e "${YELLOW}  注意: 当前进程还在运行旧脚本，重新运行 pf 后生效${NC}"
    return 0
}

# ============================================================
# 版本一览 + 菜单
# ============================================================

# 打印版本对照表
update_status_display() {
    local current_ver latest_ver current_desc remote_ver local_ver asset

    echo -e "${GREEN}=== 版本对照 ===${NC}"

    # realm 主程序
    current_desc=$(update_realm_current_desc)
    current_ver=$(update_realm_current_version)
    latest_ver=$(update_realm_latest_tag)
    asset=$(detect_realm_asset_name)
    local cur_n latest_n
    cur_n=$(update_norm_version "$current_ver")
    latest_n=$(update_norm_version "$latest_ver")
    if [ -n "$cur_n" ] && [ -n "$latest_n" ] && [ "$cur_n" = "$latest_n" ]; then
        echo -e "  ${GREEN}realm 主程序${NC}  ${cur_n}  ${GREEN}(已是最新)${NC}"
    else
        echo -e "  ${GREEN}realm 主程序${NC}  ${cur_n:-未知} → ${latest_n:-未知}"
    fi
    [ -n "$asset" ] && echo -e "    ${BLUE}架构型号: ${asset}${NC}"

    # 脚本包
    local_ver=$(grep -oE '^SCRIPT_VERSION="[^"]+"' "${LIB_DIR}/core.sh" 2>/dev/null | head -1 | sed 's/.*="//; s/"$//')
    remote_ver=$(update_scripts_latest_version)
    local local_n remote_n
    local_n=$(update_norm_version "$local_ver")
    remote_n=$(update_norm_version "$remote_ver")
    if [ -n "$remote_n" ] && [ "$remote_n" = "$local_n" ]; then
        echo -e "  ${GREEN}脚本包${NC}       ${local_n:-未知}  ${GREEN}(已是最新)${NC}"
    else
        echo -e "  ${GREEN}脚本包${NC}       ${local_n:-未知} → ${remote_n:-未知}"
    fi

    return 0
}

# 更新中心菜单
update_center_menu() {
    while true; do
        clear
        update_status_display
        echo ""
        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 全部安全更新（脚本包 + realm 主程序）"
        echo -e "${BLUE}2.${NC} 只更新 realm 主程序"
        echo -e "${BLUE}3.${NC} 只更新脚本包"
        echo -e "${YELLOW}4.${NC} 重新检查版本"
        echo -e "${RED}0.${NC} 返回主菜单"
        echo ""

        local choice=""
        read -p "请输入选择 [0-4]: " choice
        echo ""

        case "$choice" in
            1)
                safe_update_scripts
                if [ $? -eq 0 ]; then
                    safe_update_realm
                fi
                read -p "按回车键返回..." 
                ;;
            2)
                safe_update_realm
                read -p "按回车键返回..."
                ;;
            3)
                if safe_update_scripts; then
                    echo ""
                    echo -e "${YELLOW}脚本包已更新，重新运行 pf 后生效${NC}"
                    update_lock_release
                    exit 0
                fi
                read -p "按回车键返回..."
                ;;
            4)
                update_status_display
                read -p "按回车键返回..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-4${NC}"
                read -p "按回车键继续..."
                ;;
        esac
    done
}
