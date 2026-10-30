#!/bin/bash
# 用例组 35 · 安装下载与卸载干净性审计（T138）
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   ① **安装的每一项下载都要到位**：xwPF.sh + 7 个 lib 模块（对着离线镜像站跑
#      产品自己的 _bootstrap），落地内容与冻结态**逐字节一致**，快捷命令 pf 已建。
#   ② **下载失败必须能被看见**：镜像里少一个文件 ⇒ 安装必须报错返回非 0，
#      不许「看起来装好了」（静默缺文件 = 运行时 command not found）。
#   ③ **安装产物齐全**：service unit、两个 timer 的 unit、探测端两个脚本、
#      config.json、rules 目录 —— 装完该有的都在。
#   ④ **卸载必须干净**：跑完卸载，安装留下的每一项都没了
#      （★ 含两个 timer 的 unit —— 原实现靠 `/etc/realm/xwFailover.sh stop` 停它们，
#        而**新装的机器上那个文件根本不存在**（主备池功能已下线，安装不再生成它）
#        ⇒ timer 停不掉、unit 还在、systemd 继续按残留 unit 触发**已被删掉**的探测脚本）；
#      同时**不误删**与本产品无关的文件。
#   ⑤ 负向对照用**真实旧实现**（历史对象 install-uninstall-pre）。
#
# ★ 沙箱纪律（照 T29 的教训）：
#   · 沙箱只重定向**路径**，不重定向**进程名** ⇒ 卸载路径里的 `pkill -x realm`
#     靠 **pgrep 桩**（tests/shims/pgrep 一律返回「没匹配到」）挡住 ⇒
#     跑批不会误杀真机上正在跑的 realm 进程。**这个桩不许去掉。**
#   · 用例共用一个沙箱根 ⇒ 自己造出来的文件必须**用完清掉**，
#     尤其落在产品会读的真实路径位置上的（$SBX_ROOT/usr.local.bin、realm、systemd…）。

# ── 修复前的冻结点（负向对照锚点）────────────────────────────────
_T138_PRE_SHA="$(sbx_history_sha install-uninstall-pre 2>/dev/null || true)"

# 取「修复前那一版」的整份 lib/ 文件树（负向对照的被测对象）
#   ★ 必须走 sbx_redirect：老树里写死的是**生产路径**，不重定向就会读真实系统目录。
_t138_prepare_pre_tree() {
    local dest="$1" f raw sha="${_T138_PRE_SHA}"
    [ -n "$sha" ] || return 1
    rm -rf "$dest" 2>/dev/null
    mkdir -p "$dest" 2>/dev/null || return 1
    for f in $(cd "$SBX_REPO" && git ls-tree -r --name-only "$sha" 2>/dev/null); do
        case "$f" in
            lib/*.sh) ;;
            *) continue ;;
        esac
        mkdir -p "$dest/$(dirname "$f")" 2>/dev/null
        raw="$dest/.raw.$$"
        (cd "$SBX_REPO" && git show "$sha:$f" 2>/dev/null) > "$raw" || { rm -f "$raw"; return 1; }
        sbx_redirect "$raw" "$dest/$f" || { rm -f "$raw"; return 1; }
        rm -f "$raw"
    done
    [ -f "$dest/lib/ui.sh" ] || return 1
    [ -f "$dest/lib/core.sh" ] || return 1
    [ -f "$dest/lib/health.sh" ] || return 1
    [ -f "$dest/lib/realm.sh" ] || return 1
    return 0
}

# 从冻结态 xwPF.sh 里取「函数定义段」（到「# 主入口」为止）
#   ★ 不能直接 source 整个 xwPF.sh —— 它的末尾是 `case "${1:-}"` 主入口，
#     source 进来会把交互菜单也跑起来。
_t138_extract_bootstrap() {
    local src="$1" out="$2"
    sed -n '1,/^# 主入口/p' "$src" > "$out" 2>/dev/null || return 1
    [ -s "$out" ] || return 1
    grep -q '^_download() {' "$out" || return 1
    grep -q '^_bootstrap() {' "$out" || return 1
    return 0
}

# 跑一次 _bootstrap（对着沙箱的离线镜像站）
_t138_run_bootstrap() {
    local defs="$1"
    bash -c '
        set -u
        source "$1"
        _bootstrap
        echo "BOOTSTRAP_RC=$?"
    ' _ "$defs" 2>&1
}

# ── 安装完成后应当存在的产物（相对沙箱根；卸载后必须**全部**消失）────
_t138_artifact_list() {
    cat <<'EOF'
usr.local.bin/realm
usr.local.bin/xwPF.sh
usr.local.bin/pf
usr.local.bin/lib
usr.local.bin/cmd
usr.local.bin/.xwpf-backup
realm
systemd/realm.service
systemd/realm-health-check.service
systemd/realm-health-check.timer
systemd/realm-fast-probe.service
systemd/realm-fast-probe.timer
var.lib.realm
var.log/xwPF
var.lock/realm-health-check.lock
var.lock/realm-fast-probe.lock
EOF
}

# 造一个「装完」的现场（沙箱里的绝对路径布局）
#   ★ 与沙箱的重定向表一一对应：
#     /usr/local/bin → usr.local.bin ｜ /etc/realm → realm ｜ /etc/systemd/system → systemd
#     /var/lib/realm → var.lib.realm ｜ /var/log → var.log ｜ /var/lock → var.lock
_t138_make_installed_site() {
    local root="$1"

    mkdir -p "$root/usr.local.bin/lib" "$root/usr.local.bin/cmd" \
             "$root/usr.local.bin/.xwpf-backup" "$root/realm/rules" "$root/realm/health" \
             "$root/systemd" "$root/var.lib.realm" "$root/var.log/xwPF" "$root/var.lock"

    printf '#!/bin/bash\necho "Realm 2.9.3"\n' > "$root/usr.local.bin/realm"
    chmod +x "$root/usr.local.bin/realm"
    printf '#!/bin/bash\n' > "$root/usr.local/bin/xwPF.sh"
    chmod +x "$root/usr.local/bin/xwPF.sh"
    cp "$SBX_SRC/lib/"*.sh "$root/usr.local.bin/lib/" 2>/dev/null
    ln -sf "$root/usr.local.bin/xwPF.sh" "$root/usr.local.bin/pf"
    printf '#!/bin/bash\n' > "$root/usr.local/bin/cmd/xwpf-failover"
    printf '#!/bin/bash\n' > "$root/usr.local/bin/.xwpf-backup/core.sh.bak"

    printf '{}\n' > "$root/realm/config.json"
    printf 'RULE_ID="1"\n' > "$root/realm/rules/rule-1.conf"
    printf '#!/bin/bash\n' > "$root/realm/health/health_check.sh"
    printf '#!/bin/bash\n' > "$root/realm/health/fast_probe.sh"
    printf 'x\n' > "$root/realm/health/health_status.conf"

    local u
    for u in realm.service realm-health-check.service realm-health-check.timer \
             realm-fast-probe.service realm-fast-probe.timer; do
        printf '[Unit]\nDescription=%s\n' "$u" > "$root/systemd/$u"
    done

    printf 'q\n' > "$root/var.lib.realm/quality_metrics.conf"
    printf 'f\n' > "$root/var.lib.realm/fast_probe.conf"
    printf 'x\n' > "$root/var.lock/realm-health-check.lock"
    printf 'x\n' > "$root/var.lock/realm-fast-probe.lock"
    printf 'log\n' > "$root/var.log/xwPF/health-regenerate.log"

    # ★ 无关文件：卸载**不许**误删（护栏：清理别把用户的东西清了）
    printf 'keep\n' > "$root/var.log/other-app.log"
    printf 'keep\n' > "$root/usr.local.bin/other-tool"
}

# 跑一次卸载（两个阶段都确认）
_t138_run_uninstall() {
    local libroot="$1"
    bash -c '
        set -u
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        source "$1/lib/realm.sh"  >/dev/null 2>&1
        source "$1/lib/ui.sh"     >/dev/null 2>&1
        if declare -F uninstall_realm >/dev/null 2>&1; then
            echo "FUNC_OK=1"
        else
            echo "FUNC_MISSING=1"
        fi
        printf "y\ny\n" | uninstall_realm
        echo "UNINSTALL_RC=$?"
    ' _ "$libroot" 2>&1
}

# ══════════════════════════════════════════════════════════════
# T138 · 安装下载齐全可见 + 卸载干净完整
# ══════════════════════════════════════════════════════════════
case_T138_install_downloads_and_uninstall_cleanliness() {
    h_case_begin "T138" "安装的每一项下载都要到位（失败必须可见）；卸载必须干净完整（不留 timer/观测数据/锁/日志）" \
        "沙箱离线镜像站（= 冻结态仓库）+ 沙箱里的「装完」现场" \
        "xwPF.sh 的 _bootstrap（真入口）/ install_realm 侧产物 / uninstall_realm（真入口，两个阶段都确认）+ 负向对照（真实旧实现）" \
        "8 个下载逐字节到位 + pf 快捷命令已建；下载失败必须报错返回非 0；安装产物齐全；卸载后安装留下的每一项都没了、且不误删无关文件；旧实现做不到"

    local root="$SBX_ROOT"
    local defs="$SBX_ROOT/t138_bootstrap_defs.sh"

    # ══ 腿 1（阳性）：每一项下载都到位，内容与冻结态逐字节一致 ══
    if ! _t138_extract_bootstrap "$SBX_RUN/xwPF.sh" "$defs"; then
        h_fail "取不到冻结态 xwPF.sh 的 _bootstrap（形态变了？）—— 本条无法执行"
        return 1
    fi

    # 先把安装目录清空（_bootstrap 是幂等安装，但要看「从零装」）
    rm -rf "$root/usr.local.bin/lib" "$root/usr.local.bin/xwPF.sh" \
           "$root/usr.local.bin/pf" "$root/usr.local.bin/cmd" 2>/dev/null
    mkdir -p "$root/usr.local.bin/lib" 2>/dev/null

    local out
    out=$(_t138_run_bootstrap "$defs")
    h_log "--- _bootstrap 输出 ---"
    printf '%s\n' "$out" | head -14 | sed 's/^/    /'

    h_check_contains "$out" "BOOTSTRAP_RC=0" "_bootstrap 返回 0（下载全部成功）"

    local f sha_got sha_want n_ok=0 n_bad=0
    for f in xwPF.sh lib/core.sh lib/health.sh lib/rules.sh lib/server.sh \
             lib/realm.sh lib/update.sh lib/ui.sh; do
        case "$f" in
            xwPF.sh) target="$root/usr.local.bin/xwPF.sh" ;;
            *)       target="$root/usr.local.bin/$f" ;;
        esac
        if [ ! -f "$target" ]; then
            h_fail "下载项缺失: $f"
            n_bad=$((n_bad + 1))
            continue
        fi
        sha_got=$(sha256sum "$target" | cut -d' ' -f1)
        sha_want=$(sha256sum "$SBX_SRC/$f" | cut -d' ' -f1)
        if [ "$sha_got" = "$sha_want" ]; then
            n_ok=$((n_ok + 1))
        else
            h_fail "下载项内容与冻结态不一致: $f"
            n_bad=$((n_bad + 1))
        fi
    done
    h_check_eq "8" "$n_ok" "8 个下载项全部到位且与冻结态逐字节一致"
    h_check_eq "0" "$n_bad" "内容不一致的下载项数"

    # 快捷命令 pf：必须存在
    #   ★ 断言只查「存在」，**不查是不是符号链接** ——
    #     MSYS2（无符号链接权限时）`ln -sf` 会退化成**拷贝** ⇒ 查 -L 在 Windows 上恒假。
    if [ -e "$root/usr.local.bin/pf" ]; then
        h_pass "快捷命令 pf 已建"
    else
        h_fail "快捷命令 pf 没建"
    fi

    # 下载地址必须指向本 fork（不许悄悄指向别人的仓库）
    local n_match=0 n_all=0
    if [ -f "$SBX_LOG_DIR/curl.log" ]; then
        n_all=$(wc -l < "$SBX_LOG_DIR/curl.log" | tr -d ' ')
        case "$n_all" in ''|*[!0-9]*) n_all=0 ;; esac
        n_match=$(grep -ac 'realm-xwPF-offline-active-standby' "$SBX_LOG_DIR/curl.log" 2>/dev/null || true)
        case "$n_match" in ''|*[!0-9]*) n_match=0 ;; esac
        h_log "下载日志共 $n_all 条，其中指向本 fork 的 $n_match 条"
        # ★ 只断言「本 fork 的条数 ≥ 下载项数」——
        #   不许断言「日志里一条别的都没有」：别的用例（更新中心）也会写进同一个日志，
        #   那些是 GitHub API 的正常请求，不是「装错了仓库」。
        h_check_ge "8" "$n_match" "8 项下载都指向本 fork（不许指向别的仓库）"
    else
        h_log "curl 日志不存在（没有下载记录）—— 跳过地址来源断言"
    fi

    # ══ 腿 2（阳性）：下载失败必须被看见，不许「看起来装好了」══
    #   镜像里拿走一个文件 ⇒ _bootstrap 必须报错并返回非 0。
    local mirror_file="$SBX_MIRROR/lib/ui.sh"
    local mirror_bak="$SBX_ROOT/t138_mirror_ui.sh.bak"
    local miss_out
    if [ -f "$mirror_file" ]; then
        mv "$mirror_file" "$mirror_bak"
        miss_out=$(_t138_run_bootstrap "$defs")
        mv "$mirror_bak" "$mirror_file"      # ★ 必须还原：镜像是**全台架共用**的
        h_log "--- 缺文件时的 _bootstrap 输出 ---"
        printf '%s\n' "$miss_out" | grep -a '下载失败' | head -3 | sed 's/^/    /'

        h_check_contains "$miss_out" "lib/ui.sh 下载失败" "少一个文件时必须点名报出下载失败"
        if printf '%s' "$miss_out" | grep -aq 'BOOTSTRAP_RC=0'; then
            h_fail "少一个下载项时 _bootstrap 仍返回 0（= 看起来装好了，实际缺文件）"
        else
            h_pass "少一个下载项时 _bootstrap 返回非 0（不会静默装成半套）"
        fi
    else
        h_fail "离线镜像里没有 lib/ui.sh —— 腿 2 的前提不成立"
    fi

    # ══ 腿 3（阳性）：安装产物齐全（真入口，不许手摆）══
    rm -rf "$root/realm" "$root/systemd" 2>/dev/null
    mkdir -p "$root/realm" "$root/systemd" 2>/dev/null
    local inst_out
    inst_out=$(_run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        source "$1/lib/realm.sh"  >/dev/null 2>&1
        # service unit（真入口）
        generate_service_file >/dev/null 2>&1
        # config.json + rules 目录（真入口）
        ensure_realm_service_installed >/dev/null 2>&1
        # 探测端两个脚本 + 两个 timer 的 unit（真入口）
        health_check_script_regenerate >/dev/null 2>&1
        fast_probe_script_regenerate >/dev/null 2>&1
        start_health_check_service >/dev/null 2>&1
        echo "INSTALL_STEPS_DONE=1"
    ' 2>&1)
    h_log "安装产物生成输出: $(printf '%s' "$inst_out" | tr '\n' ' ' | cut -c1-200)"

    h_check_contains "$inst_out" "INSTALL_STEPS_DONE=1" "安装各步骤跑完"

    local p
    for p in systemd/realm.service systemd/realm-health-check.service \
             systemd/realm-health-check.timer systemd/realm-fast-probe.service \
             systemd/realm-fast-probe.timer realm/health/health_check.sh \
             realm/health/fast_probe.sh realm/config.json; do
        if [ -f "$root/$p" ]; then
            h_pass "安装产物存在: $p"
        else
            h_fail "安装产物缺失: $p"
        fi
    done
    if [ -d "$root/realm/rules" ]; then
        h_pass "安装产物存在: realm/rules（规则目录）"
    else
        h_fail "安装产物缺失: realm/rules（规则目录）"
    fi

    # ══ 腿 4（核心阳性）：卸载必须干净，且不误删 ══
    _t138_make_installed_site "$root"

    # 卸载前先记下「现场里有哪些产物」
    local art n_art=0
    art="$(_t138_artifact_list)"

    local un_out
    un_out=$(_t138_run_uninstall "$SBX_RUN")
    h_log "--- 卸载输出（尾部）---"
    printf '%s\n' "$un_out" | tail -8 | sed 's/^/    /'

    h_check_contains "$un_out" "FUNC_OK=1" "uninstall_realm 确实存在于冻结态 lib/ui.sh"
    h_check_contains "$un_out" "完全卸载完成" "两个阶段都走完（打印「完全卸载完成」）"

    local leftover="" rel
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        n_art=$((n_art + 1))
        if [ -e "$root/$rel" ]; then
            leftover="$leftover $rel"
        fi
    done <<< "$art"
    h_log "产物清单条数: $n_art"
    if [ -n "$leftover" ]; then
        h_fail "卸载后仍有残留:$leftover"
    else
        h_pass "卸载后安装留下的每一项都没了（$n_art 项）"
    fi

    # 不误删
    if [ -f "$root/var.log/other-app.log" ]; then
        h_pass "无关文件没被误删（var.log/other-app.log 还在）"
    else
        h_fail "卸载把无关文件删了（var.log/other-app.log 没了）"
    fi
    if [ -f "$root/usr.local.bin/other-tool" ]; then
        h_pass "无关文件没被误删（usr.local.bin/other-tool 还在）"
    else
        h_fail "卸载把无关文件删了（usr.local.bin/other-tool 没了）"
    fi

    # ══ 腿 5（负向对照）：修复前的真实旧实现必须**做不到**「卸载干净」══
    local pre_tree="$SBX_ROOT/t138_pre"
    if _t138_prepare_pre_tree "$pre_tree"; then
        # 对照有效性自检：老树里确实没有这次的清理
        local pre_has=0
        grep -q 'realm-health-check.timer' "$pre_tree/lib/ui.sh" 2>/dev/null && pre_has=1
        h_check_eq "0" "$pre_has" "对照有效性自检：修复前的 lib/ui.sh 里没有 timer 的清理"

        _t138_make_installed_site "$root"
        local pre_out
        pre_out=$(_t138_run_uninstall "$pre_tree")
        h_log "--- 负向对照（旧实现）卸载后的残留 ---"
        local pre_left=""
        while IFS= read -r rel; do
            [ -z "$rel" ] && continue
            [ -e "$root/$rel" ] && pre_left="$pre_left $rel"
        done <<< "$art"
        h_log "旧实现残留:$pre_left"

        if [ -n "$pre_left" ]; then
            h_pass "负向对照：修复前的实现卸载后留下$pre_left（证明上面那条断言有判别力）"
        else
            h_fail "负向对照失效：修复前的实现也清干净了（对照选错了树）"
        fi
        # 重点：两个 timer 的 unit 必须还在（这正是用户的症状）
        if [ -f "$root/systemd/realm-health-check.timer" ] || [ -f "$root/systemd/realm-fast-probe.timer" ]; then
            h_pass "负向对照：旧实现卸载后 timer 的 unit 还在（systemd 会继续触发已删掉的探测脚本）"
        else
            h_fail "负向对照失效：旧实现把 timer 的 unit 也清了（对照选错了树）"
        fi
        rm -rf "$pre_tree" 2>/dev/null
    else
        h_fail "取不到修复前实现的 lib/（sha $_T138_PRE_SHA 不可达）—— 负向对照无法执行"
    fi

    # ── 收尾：把自己造出来的东西清干净（沙箱是共用的！）──
    rm -rf "$root/usr.local.bin/lib" "$root/usr.local.bin/xwPF.sh" \
           "$root/usr.local.bin/pf" "$root/usr.local.bin/cmd" \
           "$root/usr.local.bin/.xwpf-backup" "$root/usr.local.bin/realm" \
           "$root/realm" "$root/systemd" "$root/var.lib.realm" \
           "$root/var.log/xwPF" "$root/var.log/other-app.log" \
           "$root/usr.local.bin/other-tool" "$root/var.lock/realm-health-check.lock" \
           "$root/var.lock/realm-fast-probe.lock" "$defs" 2>/dev/null
    mkdir -p "$root/usr.local.bin/lib" "$root/usr.local.bin/cmd" "$root/realm/rules" 2>/dev/null
}
