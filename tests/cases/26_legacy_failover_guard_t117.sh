#!/bin/bash
# 用例组 26 · 老机器主备池守护残留清理的护栏
#
# ★ 这组用例为什么存在（真机 103.42.31.186 实测）：
#   「主备池功能已下线」≠「老机器上那个守护没在用」。
#   那台机器的老守护**正在对外服务**：监听 0.0.0.0:18443 / 0.0.0.0:18444（**公开口**），
#   两个池（poolA / poolDirect）都在转发，realm 侧 10443/10444 端点配套。
#   而 install / 升级路径原先**无条件**调清理 ⇒ 一旦那版合入，
#   **下一次 pf install 就把这台机器正在用的公开转发口打黑，而且没有任何提示**。
#
# 契约（安装 / 卸载两条路径语义不同，这是本组用例守的东西）：
#   · 安装 / 升级路径（xwPF.sh）：守护**还在服务** ⇒ **跳过清理** + 打印迁移办法
#   · 卸载路径（xwPF.sh uninstall + 菜单 8）：**强制**清理（用户明确要拆全部）
#   · 崩溃循环残留（没有池配置却在跑）⇒ 照常清干净 —— 那**正是要清的**
#     （原始诉求：别让它每 2 秒被 systemd 拉起一次）
#
# ★ 全部在沙箱里做：
#   · 被测代码 = 冻结态（git show $BASE_SHA:...），不读工作区
#   · 夹具写在 $SBX_ROOT 下（沙箱路径重定向后的真实位置）
#   · pgrep 打桩：产品的清理流程里有一段「按命令行找残留进程并 kill」，
#     沙箱里**不许**真去杀本机任何进程 ⇒ 桩里一律「没匹配到」。
#     （这段流程不在本组用例的判定范围内；桩掉它只是消除副作用风险。）
#
# ★ 已知边界（诚实记录，不掩饰）：
#   沙箱的路径重定向表里**没有 /lib** ⇒ 产品里那个 unit_alt
#   （/lib/systemd/system/xwpf-failover.service）在沙箱副本里仍是**真实绝对路径**。
#   本组用例因此**不**对它做任何断言，也**不**在真实路径上造夹具
#   （台架的「越界残留」自检只扫 /etc|/usr|/var|/opt|/root|/sbin|/bin，漏了 /lib —— 那是台架侧的缺口）。

# ── 沙箱夹具路径（按沙箱的重定向结果落盘）─────────────────────
# ★ 必须在**运行时**解析，不能在文件被 source 时就存成变量：
#   run_tests.sh 先 source tests/cases/*.sh（第 475 行），
#   之后才在 main() 里调 sbx_init（第 836 行）建沙箱
#   ⇒ source 那一刻 $SBX_ROOT 还是**空的**
#   ⇒ 早绑定 ⇒ 夹具写到别处、断言看的是别处 ⇒ 整组用例假红
#   （本组第一版就是这么翻车的：产品行为全对，断言全指向了空路径）
_lfg_unit=""
_lfg_dropin=""
_lfg_bin=""
_lfg_ver=""
_lfg_pool=""
_lfg_pool_dis=""

_lfg_paths() {
    _lfg_unit="$SBX_ROOT/systemd/xwpf-failover.service"
    _lfg_dropin="$SBX_ROOT/systemd/xwpf-failover.service.d"
    _lfg_bin="$SBX_ROOT/usr.local.bin/xwpf-failover"
    _lfg_ver="$SBX_ROOT/usr.local.bin/.xwpf-failover-version"
    _lfg_pool="$SBX_ROOT/xwpf/failover.json"
    _lfg_pool_dis="$SBX_ROOT/xwpf/failover.json.disabled"
}

# 文件/目录是否存在（1=在，0=不在）
_lfg_exists() {
    [ -e "$1" ] && printf '1' || printf '0'
}

# 复位：把沙箱里这一组残留物清干净，回到「什么都没装」的状态
_lfg_reset() {
    [ -n "$SBX_ROOT" ] && [ -d "$SBX_ROOT" ] || return 1
    rm -f  "$_lfg_unit" \
           "$_lfg_bin" \
           "$_lfg_ver" \
           "$_lfg_pool" \
           "$_lfg_pool_dis" \
           "$SBX_ROOT/xwpf/failover-state.json" \
           "$SBX_ROOT/xwpf/failover-state.json.disabled" 2>/dev/null
    rm -rf "$_lfg_dropin" 2>/dev/null
    return 0
}

# 装出「老机器上有残留」的现场
_lfg_install_fixtures() {
    mkdir -p "$SBX_ROOT/systemd" "$SBX_ROOT/usr.local.bin" "$SBX_ROOT/xwpf" 2>/dev/null
    printf '[Unit]\nDescription=xwpf-failover\n' > "$_lfg_unit"
    mkdir -p "$_lfg_dropin" 2>/dev/null
    printf '[Service]\nRestart=always\nRestartSec=5\n' \
        > "$_lfg_dropin/10-crash-loop-guard.conf"
    printf '#!/bin/sh\nexit 1\n' > "$_lfg_bin"
    printf 'v1\n' > "$_lfg_ver"
}

# 池配置：① 还在服务的活池（含 "listen"）② 空数组（守护自己会退出）
_lfg_pool_active() {
    printf '[{"name":"poolA","listen":"0.0.0.0:18443","target":"127.0.0.1:10443"}]\n' \
        > "$_lfg_pool"
}
_lfg_pool_empty() {
    printf '[]\n' > "$_lfg_pool"
}

# pgrep 桩：沙箱里不做「按命令行找残留进程并 kill」
_lfg_install_pgrep_stub() {
    mkdir -p "$SBX_BIN" 2>/dev/null
    cat > "$SBX_BIN/pgrep" <<'STUB'
#!/bin/bash
# 桩：沙箱里不匹配任何进程（产品的残留进程清理段不在本组用例的判定范围内）
exit 1
STUB
    chmod +x "$SBX_BIN/pgrep" 2>/dev/null
}

# 在沙箱里跑**产品自己的**清理函数
# 用法：_lfg_run <default|force|env|degraded>
#   default  = 不带 force（安装 / 升级路径）
#   force    = 带 force 参数（卸载路径）
#   env      = XWPF_FORCE_LEGACY_FAILOVER_CLEAN=1（强制开关）
#   degraded = 判据被退化掉（负向对照用）
_lfg_run() {
    local mode="$1"
    _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/ui.sh" >/dev/null 2>&1
        case "$2" in
            force)    _cleanup_legacy_failover_daemon force ;;
            env)      export XWPF_FORCE_LEGACY_FAILOVER_CLEAN=1
                      _cleanup_legacy_failover_daemon ;;
            degraded) _legacy_failover_daemon_in_use() { return 1; }
                      _cleanup_legacy_failover_daemon ;;
            *)        _cleanup_legacy_failover_daemon ;;
        esac
        printf "RC=%s\n" "$?"
    ' "$mode"
}

# 取 systemctl 调用记录（桩把每次调用都记在这里）
_lfg_syslog() {
    [ -f "$SBX_LOG_DIR/systemctl.log" ] && cat "$SBX_LOG_DIR/systemctl.log"
    return 0
}


case_T117_legacy_failover_guard_serve_vs_residue() {
    h_case_begin "T117" "老机器主备池守护：还在服务就跳过，残留才清理" \
        "沙箱里的老残留现场（unit / drop-in / 二进制 / 池配置）" \
        "_cleanup_legacy_failover_daemon（产品真源，来自冻结态）" \
        "活池 ⇒ 跳过清理且一个文件都不动；无配置 / 空数组 ⇒ 清干净；env 强制 / force 参数 ⇒ 清干净"

    _lfg_paths
    _lfg_install_pgrep_stub

    # ── 场景 A：还在服务（池配置存在且含 "listen"）+ 安装路径（不带 force）
    #    ⇒ 必须跳过：一个文件都不许动，systemctl 也不许去停它
    _lfg_reset
    _lfg_install_fixtures
    _lfg_pool_active
    : > "$SBX_LOG_DIR/systemctl.log"
    local out syslog
    out=$(_lfg_run default)
    syslog=$(_lfg_syslog)
    h_log "--- 场景 A 输出 ---"
    h_log "$out"

    h_check_contains "$out" "已跳过清理" "活池 + 安装路径：提示已跳过清理"
    h_check_contains "$out" "仍在服务" "活池 + 安装路径：提示语点明守护仍在服务"
    h_check_eq "1" "$(_lfg_exists "$_lfg_unit")" "活池：unit 文件保持不动"
    h_check_eq "1" "$(_lfg_exists "$_lfg_dropin")" "活池：drop-in 目录保持不动"
    h_check_eq "1" "$(_lfg_exists "$_lfg_bin")" "活池：守护二进制保持不动"
    h_check_eq "1" "$(_lfg_exists "$_lfg_ver")" "活池：守护版本文件保持不动"
    h_check_eq "1" "$(_lfg_exists "$_lfg_pool")" "活池：用户池配置保持不动"
    h_check_eq "0" "$(_lfg_exists "$_lfg_pool_dis")" "活池：池配置没有被改名留档"
    h_check_not_contains "$syslog" "stop xwpf-failover" "活池：没有停守护服务"
    h_check_not_contains "$syslog" "disable xwpf-failover" "活池：没有禁用守护服务"

    # ── 场景 B：没有池配置（= 崩溃循环残留：守护读不到配置就 exit 1，被反复拉起）
    #    ⇒ 这才是要清的，照常清干净
    _lfg_reset
    _lfg_install_fixtures
    : > "$SBX_LOG_DIR/systemctl.log"
    out=$(_lfg_run default)
    syslog=$(_lfg_syslog)
    h_log "--- 场景 B 输出 ---"
    h_log "$out"

    h_check_contains "$out" "已清理" "无池配置：照常清理并提示"
    h_check_eq "0" "$(_lfg_exists "$_lfg_unit")" "无池配置：unit 被删"
    h_check_eq "0" "$(_lfg_exists "$_lfg_dropin")" "无池配置：drop-in 目录被删"
    h_check_eq "0" "$(_lfg_exists "$_lfg_bin")" "无池配置：守护二进制被删"
    h_check_eq "0" "$(_lfg_exists "$_lfg_ver")" "无池配置：守护版本文件被删"
    h_check_contains "$syslog" "stop xwpf-failover" "无池配置：停了守护服务"
    h_check_contains "$syslog" "disable xwpf-failover" "无池配置：禁用了守护服务"
    h_check_contains "$syslog" "daemon-reload" "无池配置：让 systemd 忘掉被删的 unit"

    # ── 场景 C：池配置是空数组 []（守护会自己退出：config must be a non-empty list）
    #    ⇒ 算不在用，照常清干净
    _lfg_reset
    _lfg_install_fixtures
    _lfg_pool_empty
    out=$(_lfg_run default)
    h_log "--- 场景 C 输出 ---"
    h_log "$out"

    h_check_eq "0" "$(_lfg_exists "$_lfg_unit")" "空数组配置：unit 被删"
    h_check_eq "0" "$(_lfg_exists "$_lfg_bin")" "空数组配置：守护二进制被删"

    # ── 场景 D：活池 + 强制开关（XWPF_FORCE_LEGACY_FAILOVER_CLEAN=1）⇒ 清干净
    _lfg_reset
    _lfg_install_fixtures
    _lfg_pool_active
    out=$(_lfg_run env)
    h_log "--- 场景 D 输出 ---"
    h_log "$out"

    h_check_eq "0" "$(_lfg_exists "$_lfg_unit")" "env 强制：unit 被删"
    h_check_eq "0" "$(_lfg_exists "$_lfg_bin")" "env 强制：守护二进制被删"
    h_check_eq "1" "$(_lfg_exists "$_lfg_pool_dis")" "env 强制：池配置改名留档（不删用户的东西）"

    # ── 场景 E：活池 + force 参数（卸载路径）⇒ 清干净
    _lfg_reset
    _lfg_install_fixtures
    _lfg_pool_active
    out=$(_lfg_run force)
    h_log "--- 场景 E 输出 ---"
    h_log "$out"

    h_check_eq "0" "$(_lfg_exists "$_lfg_unit")" "force 参数：unit 被删"
    h_check_eq "0" "$(_lfg_exists "$_lfg_bin")" "force 参数：守护二进制被删"
    h_check_eq "1" "$(_lfg_exists "$_lfg_pool_dis")" "force 参数：池配置改名留档"

    # ── 场景 F：清理不许删用户池目录里的其它东西
    _lfg_reset
    _lfg_install_fixtures
    printf '{}\n' > "$SBX_ROOT/xwpf/other-pool.json"
    out=$(_lfg_run default)
    h_check_eq "1" "$(_lfg_exists "$SBX_ROOT/xwpf/other-pool.json")" \
        "清理不删用户池目录里的其它文件"

    # ── 场景 G：调用点的语义契约（安装保守 / 卸载强制）
    #    对冻结态源码做静态核对：xwPF.sh 的安装路径不许带 force，两条卸载路径必须带 force
    local n_install n_uninstall_cli n_uninstall_menu
    n_install=$(grep -cE '_cleanup_legacy_failover_daemon[[:space:]]*$' "$SBX_SRC/xwPF.sh" 2>/dev/null)
    n_uninstall_cli=$(grep -cE '_cleanup_legacy_failover_daemon[[:space:]]+force' "$SBX_SRC/xwPF.sh" 2>/dev/null)
    n_uninstall_menu=$(grep -cE '_cleanup_legacy_failover_daemon[[:space:]]+force' "$SBX_SRC/lib/ui.sh" 2>/dev/null)
    h_check_ge "1" "$n_install" "xwPF.sh：安装路径的调用不带 force（保守）"
    h_check_ge "1" "$n_uninstall_cli" "xwPF.sh：卸载路径的调用带 force"
    h_check_ge "1" "$n_uninstall_menu" "lib/ui.sh：菜单卸载（uninstall_realm）的调用带 force"
}


case_T118_legacy_failover_guard_negative_control() {
    h_case_begin "T118" "护栏的负向对照：判据退化后，活池必须从「跳过」变「清掉」" \
        "沙箱里的活池现场 + 被退化的判据" \
        "_legacy_failover_daemon_in_use 退化为恒「不在用」后重跑清理" \
        "证明 T117 的「跳过」断言确实来自判据，不是别的原因"

    _lfg_paths
    _lfg_install_pgrep_stub

    # 判据是**本次新引入的 helper**，修复前没有等价形态 ⇒ 按台架约定用「注入式退化」
    # 做负向对照（如实标注，不假装有历史旧实现可比）。
    # 退化后：活池也被当成「不在用」⇒ 必须从「跳过」变成「清掉」。
    _lfg_reset
    _lfg_install_fixtures
    _lfg_pool_active
    : > "$SBX_LOG_DIR/systemctl.log"
    local out syslog
    out=$(_lfg_run degraded)
    syslog=$(_lfg_syslog)
    h_log "--- 负向对照输出 ---"
    h_log "$out"

    h_check_not_contains "$out" "已跳过清理" "判据退化后不再跳过（否则 T117 的断言恒绿）"
    h_check_eq "0" "$(_lfg_exists "$_lfg_unit")" "判据退化后 unit 被删（= 没有护栏时的行为）"
    h_check_eq "0" "$(_lfg_exists "$_lfg_bin")" "判据退化后守护二进制被删"
    h_check_contains "$syslog" "stop xwpf-failover" "判据退化后真的去停了守护服务"
}
