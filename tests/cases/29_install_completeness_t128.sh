#!/bin/bash
# 用例组 29 · 安装完整性与「静默失效」护栏（真机踩出来的三个缺陷）
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   1) **装完该有的东西都得在**：realm 二进制已存在且版本已是最新时，
#      `pf install` 也要把 service 文件 / config.json / rules 目录补齐。
#      （原实现只挂在「下载安装」那条路径上 ⇒ 二进制已在了就提前返回 ⇒
#        install 报「安装完成」但**服务根本没装**，机器看起来装好了、转发一个没跑。）
#   2) **规则写不进去不许报成功**：规则目录不存在时，重定向失败 ⇒ 规则没落盘，
#      而原实现照样打「✓ 中转配置已创建」⇒ 界面说建好了、磁盘上没有（静默失效）。
#   3) **空 TARGET_STATES 不许刷错**：`printf '%s' ""` 输出 0 字节 ⇒ awk 一条记录都没有
#      ⇒ `[ "" -lt "" ]` 报「integer expression expected」。
#
# ★ 负向对照用**修复前的真实实现**（冻结点历史对象），
#   不是合成探针 —— 这三个缺陷都是「老代码本来就这样」，历史对象是权威对照。
#
# ★ 本组踩到并写死的台架纪律（照着做，别再重犯）：
#   ① **沙箱里 lib/core.sh 的路径常量不是都能覆盖的**：
#        CONFIG_DIR="${CONFIG_DIR:-…}"     ⇒ **认**外部覆盖
#        RULES_DIR="${CONFIG_DIR}/rules"   ⇒ **不认**外部覆盖（从 CONFIG_DIR 派生）
#        SYSTEMD_PATH="/etc/systemd/system/realm.service" ⇒ 完全写死
#      ⇒ 想把规则目录指到隔离目录，必须覆盖 **CONFIG_DIR**（覆盖 RULES_DIR 会被直接盖掉
#        ⇒ 断言查的是别的目录 ⇒ 假红）；想让 unit 落在隔离目录，
#        必须在 **source 之后**再覆盖 SYSTEMD_PATH。
#   ② **负向对照必须真的跑老树**：`_run_in_sandbox` 的 `$1` 永远是冻结点的新树，
#      拿它去 source 就等于「拿新代码冒充老代码」⇒ 对照永远绿。
#      老树要用 `git show` 取出 + `sbx_redirect` 重定向（路径写死生产路径，
#      不重定向就会读真实系统目录），再单独 `bash -c` 执行。
#   ③ **被测函数必须先证明存在**（沙箱里打 FUNC_OK=1）——
#      否则「函数没加载 ⇒ 什么都没发生」会让断言恒绿（零覆盖的假绿）。
#   ④ **对照有效性自检**：老树里确实没有这次修的东西（否则老树选错时断言会一直绿）。

# ── 修复前的冻结点（负向对照锚点）────────────────────────────────
#   install-guard-pre = 整条链收进 main 后的那一笔（= 本组修复的父提交）
_T29_PRE_SHA="$(sbx_history_sha install-guard-pre 2>/dev/null || true)"
[ -n "$_T29_PRE_SHA" ] || _T29_PRE_SHA="e4ac5eb"

# 取「修复前那一版」的整份 lib/ 文件树（负向对照的被测对象）
#   ★ 必须走 sbx_redirect：老树里写死的是**生产路径**（/etc/realm、/usr/local/bin …），
#     不重定向就会读真实系统目录（Linux 上就是生产目录）⇒ 越界。
_t29_prepare_pre_tree() {
    local dest="$1" f raw
    rm -rf "$dest" 2>/dev/null
    mkdir -p "$dest" 2>/dev/null || return 1
    for f in $(cd "$SBX_REPO" && git ls-tree -r --name-only "$_T29_PRE_SHA" 2>/dev/null); do
        case "$f" in
            lib/*.sh) ;;
            *) continue ;;
        esac
        mkdir -p "$dest/$(dirname "$f")" 2>/dev/null
        raw="$dest/.raw.$$"
        (cd "$SBX_REPO" && git show "$_T29_PRE_SHA:$f" 2>/dev/null) > "$raw" || { rm -f "$raw"; return 1; }
        sbx_redirect "$raw" "$dest/$f" || { rm -f "$raw"; return 1; }
        rm -f "$raw"
    done
    [ -f "$dest/lib/core.sh" ] || return 1
    [ -f "$dest/lib/realm.sh" ] || return 1
    [ -f "$dest/lib/rules.sh" ] || return 1
    [ -f "$dest/lib/server.sh" ] || return 1
    return 0
}

# 造一个「已装 realm、但 service/config/rules 缺失」的现场
_t29_make_broken_install_site() {
    local root="$1"
    rm -rf "$root" 2>/dev/null
    mkdir -p "$root" 2>/dev/null
    # 已有的配置（有内容 ⇒ 不许被空配置覆盖）
    cat > "$root/config.json" <<'EOF'
{
    "endpoints": [
        { "listen": "0.0.0.0:19999", "remote": "127.0.0.1:19998" }
    ]
}
EOF
    # ★ 故意**不建** rules 目录（缺失态）
    # ★ service 文件用 SYSTEMD_PATH 覆盖指到本目录（见文件头纪律①）
    echo "$root"
}

# 造一个「realm 二进制已就绪、且版本号 == 最新」的替身
#   ⇒ install_realm 会走「已是最新」那条分支（= 出问题的那条路径）
#   ★ 版本号必须与 lib/core.sh 的 REALM_VERSION 一致 ⇒ compare_and_ask_update 直接
#     返回「无需更新」，**不会弹交互提示**（弹了会卡住无人值守跑批）。
_T29_REALM_STUB_VERSION="v2.9.3"
_t29_make_realm_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
    cat > "$path" <<EOF
#!/bin/bash
case "\${1:-}" in
    --version|-v) echo "$_T29_REALM_STUB_VERSION" ;;
esac
exit 0
EOF
    chmod +x "$path" 2>/dev/null
    [ -x "$path" ]
}

# 数一数目录下的规则文件个数
_t29_count_rules() {
    ls "$1"/rule-*.conf 2>/dev/null | wc -l | tr -d ' \t'
}

# ══════════════════════════════════════════════════════════════
# T128 · install 完整性：二进制已最新时也要补齐 service/config/rules
# ══════════════════════════════════════════════════════════════
case_T128_install_completeness() {
    h_case_begin "T128" "install 完整性：realm 二进制已存在且版本最新时，也必须补齐 service / config / rules" \
        "冻结态 lib/realm.sh 的 install_realm（真入口）+ 沙箱里的残缺现场（已有 config、缺 unit、缺 rules 目录）" \
        "install_realm <lib 根> <现场目录>（realm 替身版本 == 最新版本 ⇒ 走「已是最新」那条分支）" \
        "补齐后：service 文件生成 + rules 目录建起 + 已有 config.json 逐字节不变；负向对照：修复前的实现**什么都没补**"

    # ── 0. realm 替身（「二进制已就绪且版本最新」这条分支的入口条件）──
    local stub="$SBX_ROOT/usr.local.bin/realm"
    if ! _t29_make_realm_stub "$stub"; then
        h_fail "造不出 realm 替身（$stub）—— 场景不成立"
        return 1
    fi
    h_log "realm 替身: $stub（版本 $_T29_REALM_STUB_VERSION）"

    # ── 1. 新树：走真入口 install_realm ──
    local site="$SBX_ROOT/t128_site"
    _t29_make_broken_install_site "$site"
    local cfg_before
    cfg_before=$(sha256sum "$site/config.json" | cut -d' ' -f1)

    local out
    out=$(_run_in_sandbox '
        site="$2"
        export CONFIG_DIR="$site"
        source "$1/lib/core.sh"  >/dev/null
        source "$1/lib/health.sh" >/dev/null
        source "$1/lib/rules.sh" >/dev/null
        source "$1/lib/realm.sh"  >/dev/null
        # ★ core.sh 的 SYSTEMD_PATH 是**无条件赋值** ⇒ 必须 source 之后再覆盖
        SYSTEMD_PATH="$site/realm.service"
        if declare -F install_realm >/dev/null 2>&1; then
            echo "FUNC_OK=1"
        else
            echo "FUNC_MISSING=1"
        fi
        install_realm </dev/null 2>&1
        echo "RC=$?"
    ' "$site")
    h_log "install_realm 输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-240)"

    h_check_contains "$out" "FUNC_OK=1" "install_realm 确实存在于冻结态 lib/realm.sh"

    # 已有 config 逐字节不变
    local cfg_after
    cfg_after=$(sha256sum "$site/config.json" 2>/dev/null | cut -d' ' -f1)
    h_log "config sha: before=${cfg_before:0:16} after=${cfg_after:0:16}"
    h_check_eq "$cfg_before" "$cfg_after" "已有 config.json 逐字节不变（补齐**不覆盖**已有配置）"

    # service 文件生成了
    h_check_file "$site/realm.service" "补齐后 service 文件已生成"
    h_check_file_has "$site/realm.service" "ExecStart=" "service 文件内容对（含 ExecStart）"
    # rules 目录建起来了
    if [ -d "$site/rules" ]; then
        h_pass "补齐后规则目录已建起（$site/rules）"
    else
        h_fail "补齐后规则目录仍然不存在 ⇒ 规则会写不进去（而界面会报「已创建」）"
    fi

    # ── 2. 负向对照：修复前的真实实现（老树）走**同一个真入口** ──
    #   老树的 install_realm 在「已是最新」那条分支上直接返回 ⇒ 什么都不补
    local pre_tree="$SBX_ROOT/t128_pre"
    if _t29_prepare_pre_tree "$pre_tree"; then
        # ★ 对照有效性自检：老树里**确实没有**这次修的东西（否则对照选错了树）
        local pre_has_fn=0 pre_body_has=0
        grep -q 'ensure_realm_service_installed' "$pre_tree/lib/realm.sh" 2>/dev/null && pre_has_fn=1
        pre_body_has=$(awk '/^install_realm\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$pre_tree/lib/realm.sh" 2>/dev/null | grep -c 'ensure_realm_service_installed')
        h_check_eq "0" "$pre_has_fn" "对照有效性自检：修复前的 lib/realm.sh 里没有 ensure_realm_service_installed"
        h_check_eq "0" "$pre_body_has" "对照有效性自检：修复前的 install_realm 里也没调它"

        local pre_site="$SBX_ROOT/t128_pre_site"
        _t29_make_broken_install_site "$pre_site"
        local pre_out
        pre_out=$(bash -c '
            site="$2"
            export CONFIG_DIR="$site"
            source "$1/lib/core.sh"  >/dev/null
            source "$1/lib/health.sh" >/dev/null
            source "$1/lib/rules.sh" >/dev/null
            source "$1/lib/realm.sh"  >/dev/null
            SYSTEMD_PATH="$site/realm.service"
            install_realm </dev/null 2>&1
            echo "RC=$?"
        ' _ "$pre_tree" "$pre_site" 2>&1)
        h_log "修复前 install_realm 输出: $(printf '%s' "$pre_out" | tr '\n' ' ' | cut -c1-240)"
        h_log "修复前现场：service 存在=$([ -f "$pre_site/realm.service" ] && echo yes || echo no)；rules 目录存在=$([ -d "$pre_site/rules" ] && echo yes || echo no)"
        if [ -f "$pre_site/realm.service" ] || [ -d "$pre_site/rules" ]; then
            h_fail "负向对照失效：修复前的实现竟然补齐了东西（对照选错了树）"
        else
            h_pass "负向对照：修复前的实现走真入口也**什么都没补** ⇒ 上面那几条断言确实有判别力"
        fi
        rm -rf "$pre_site" 2>/dev/null
    else
        h_fail "取不到修复前实现的 lib/（sha $_T29_PRE_SHA 不可达）—— 负向对照无法执行"
    fi

    rm -rf "$site" "$pre_tree" 2>/dev/null
    # ★ 桩必须清掉：它落在沙箱的 REALM_PATH 上（$SBX_ROOT/usr.local.bin/realm），
    #   留着会让**后面的用例**以为「realm 已安装」⇒ 走不到下载路径
    #   （实测：T132 在 Linux 上就因为这个桩而走了「已安装」分支，断言全红）。
    rm -f "$stub" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════
# T129 · 规则写不进去 ⇒ 必须判红（不许报「已创建」）
# ══════════════════════════════════════════════════════════════
case_T129_rule_write_guard() {
    h_case_begin "T129" "规则写不进去时必须判红：返回非 0 + 不许打「✓ 中转配置已创建」" \
        "冻结态 lib/server.sh 的 create_single_nat_rule（规则目录缺失 / 存在 两种场景）" \
        "create_single_nat_rule <监听端口> <远端端口>（REMOTE_IP / NAT_LISTEN_IP 等由用例注入）" \
        "目录缺失 ⇒ 返回非 0、不报成功、规则没落盘；目录存在 ⇒ 成功且文件落盘；负向对照：修复前的实现必须被抓到"

    # ── 场景 A：规则目录不存在 ──
    #   ★ 覆盖 CONFIG_DIR（不是 RULES_DIR）—— core.sh 里 RULES_DIR 是从 CONFIG_DIR 派生的，
    #     覆盖 RULES_DIR 会被直接盖掉（见文件头纪律①）。
    local missing="$SBX_ROOT/t129_missing"
    rm -rf "$missing" 2>/dev/null
    mkdir -p "$missing" 2>/dev/null
    local out_a
    out_a=$(_run_in_sandbox '
        export CONFIG_DIR="$2/site"
        source "$1/lib/core.sh"  >/dev/null
        source "$1/lib/health.sh" >/dev/null
        source "$1/lib/rules.sh" >/dev/null
        source "$1/lib/server.sh" >/dev/null
        source "$1/lib/ui.sh"     >/dev/null
        # ★ core.sh 在 source 时会**无条件**把 REMOTE_IP / NAT_LISTEN_IP / NAT_THROUGH_IP /
        #   SECURITY_LEVEL / RULE_NOTE / TLS_* / WS_* 重置成空
        #   ⇒ 这几个变量必须在 source **之后**再设（source 之前设会被清掉 ⇒ 规则文件写进空值）。
        export REMOTE_IP="127.0.0.1"
        export NAT_LISTEN_IP="0.0.0.0"
        export NAT_THROUGH_IP="127.0.0.1"
        export SECURITY_LEVEL="off"
        export RULE_NOTE="t129"
        export TLS_SERVER_NAME=""
        export TLS_CERT_PATH=""
        export WS_PATH=""
        export WS_HOST=""
        if declare -F create_single_nat_rule >/dev/null 2>&1; then
            echo "FUNC_OK=1"
        else
            echo "FUNC_MISSING=1"
        fi
        create_single_nat_rule 19999 19998 2>&1
        echo "RC=$?"
    ' "$missing")
    h_log "目录缺失时的输出: $(printf '%s' "$out_a" | tr '\n' ' ' | cut -c1-220)"

    h_check_contains "$out_a" "FUNC_OK=1" "create_single_nat_rule 确实存在于冻结态 lib/server.sh"

    if printf '%s' "$out_a" | grep -q '✓ 中转配置已创建'; then
        h_fail "规则没落盘却打了「✓ 中转配置已创建」⇒ 静默失效（界面说建好了、磁盘上没有）"
    else
        h_pass "规则没落盘时**没有**报「✓ 中转配置已创建」"
    fi
    if printf '%s' "$out_a" | grep -q 'RC=0'; then
        h_fail "规则目录不存在时返回码仍是 0（调用方会以为成功了）"
    else
        h_pass "规则目录不存在时返回非 0"
    fi
    local n_miss
    n_miss=$(_t29_count_rules "$missing/site/rules")
    h_check_eq "0" "$n_miss" "规则目录不存在时磁盘上没有半吊子规则文件"

    # ── 场景 B：目录存在 ⇒ 正常创建 ──
    local okdir="$SBX_ROOT/t129_ok"
    rm -rf "$okdir" 2>/dev/null
    mkdir -p "$okdir/site/rules" 2>/dev/null
    local out_b
    out_b=$(_run_in_sandbox '
        export CONFIG_DIR="$2/site"
        source "$1/lib/core.sh"  >/dev/null
        source "$1/lib/health.sh" >/dev/null
        source "$1/lib/rules.sh" >/dev/null
        source "$1/lib/server.sh" >/dev/null
        source "$1/lib/ui.sh"     >/dev/null
        # ★ core.sh 在 source 时会**无条件**把 REMOTE_IP / NAT_LISTEN_IP / NAT_THROUGH_IP /
        #   SECURITY_LEVEL / RULE_NOTE / TLS_* / WS_* 重置成空
        #   ⇒ 这几个变量必须在 source **之后**再设（source 之前设会被清掉 ⇒ 规则文件写进空值）。
        export REMOTE_IP="127.0.0.1"
        export NAT_LISTEN_IP="0.0.0.0"
        export NAT_THROUGH_IP="127.0.0.1"
        export SECURITY_LEVEL="off"
        export RULE_NOTE="t129"
        export TLS_SERVER_NAME=""
        export TLS_CERT_PATH=""
        export WS_PATH=""
        export WS_HOST=""
        create_single_nat_rule 19999 19998 2>&1
        echo "RC=$?"
    ' "$okdir")
    h_log "目录存在时的输出: $(printf '%s' "$out_b" | tr '\n' ' ' | cut -c1-220)"

    if printf '%s' "$out_b" | grep -q '✓ 中转配置已创建'; then
        h_pass "目录存在时正常报「✓ 中转配置已创建」"
    else
        h_fail "目录存在时反而没报创建成功（正常的正向路径被误伤了）"
    fi
    if printf '%s' "$out_b" | grep -q 'RC=0'; then
        h_pass "目录存在时返回码 0"
    else
        h_fail "目录存在时返回码非 0（正向路径被误伤了）"
    fi
    local n_ok
    n_ok=$(_t29_count_rules "$okdir/site/rules")
    h_check_eq "1" "$n_ok" "规则文件真的落盘了"
    if [ "$n_ok" = "1" ]; then
        h_check_file_has "$okdir/site/rules/rule-1.conf" 'LISTEN_PORT="19999"' "规则文件内容对（监听端口写对了）"
        h_check_file_has "$okdir/site/rules/rule-1.conf" 'REMOTE_HOST="127.0.0.1"' "规则文件内容对（远端地址写对了）"
        h_check_file_has "$okdir/site/rules/rule-1.conf" 'RULE_ROLE="1"' "规则文件内容对（中转角色写对了）"
    fi

    # ── 负向对照：修复前的真实实现（不检查目录）⇒ 必须被抓到 ──
    local pre_tree="$SBX_ROOT/t129_pre"
    if _t29_prepare_pre_tree "$pre_tree"; then
        # ★ 对照有效性自检：老树里**确实没有**这次修的护栏
        local pre_has_guard=0
        grep -q '规则目录不存在' "$pre_tree/lib/server.sh" 2>/dev/null && pre_has_guard=1
        h_check_eq "0" "$pre_has_guard" "对照有效性自检：修复前的 lib/server.sh 里没有「规则目录不存在」护栏"

        local pre_out
        pre_out=$(bash -c '
            export CONFIG_DIR="$2/site"
            source "$1/lib/core.sh"  >/dev/null
            source "$1/lib/health.sh" >/dev/null
            source "$1/lib/rules.sh" >/dev/null
            source "$1/lib/server.sh" >/dev/null
            source "$1/lib/ui.sh"     >/dev/null
            # ★ 同上：这几个变量必须在 source 之后设（core.sh 在 source 时会清空它们）
            export REMOTE_IP="127.0.0.1"
            export NAT_LISTEN_IP="0.0.0.0"
            export NAT_THROUGH_IP="127.0.0.1"
            export SECURITY_LEVEL="off"
            export RULE_NOTE="t129"
            export TLS_SERVER_NAME=""
            export TLS_CERT_PATH=""
            export WS_PATH=""
            export WS_HOST=""
            create_single_nat_rule 19999 19998 2>&1
            echo "RC=$?"
        ' _ "$pre_tree" "$missing" 2>&1)
        h_log "修复前实现的输出: $(printf '%s' "$pre_out" | tr '\n' ' ' | cut -c1-220)"
        if printf '%s' "$pre_out" | grep -q '✓ 中转配置已创建'; then
            h_pass "负向对照：修复前的实现**确实报成功但没落盘** ⇒ 上面那条断言有判别力"
        else
            h_fail "负向对照失效：修复前的实现没有报成功（对照选错了）"
        fi
        # 老实现返回 0（调用方以为成功）⇒ 也必须被看到
        if printf '%s' "$pre_out" | grep -q 'RC=0'; then
            h_pass "负向对照：修复前的实现返回码是 0（静默失效的另一半）"
        else
            h_fail "负向对照失效：修复前的实现返回码不是 0（对照选错了）"
        fi
    else
        h_fail "取不到修复前实现的 lib/（sha $_T29_PRE_SHA 不可达）—— 负向对照无法执行"
    fi

    rm -rf "$missing" "$okdir" "$pre_tree" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════
# T130 · 空 TARGET_STATES 不许刷「integer expression expected」
# ══════════════════════════════════════════════════════════════
case_T130_empty_target_states_no_integer_error() {
    h_case_begin "T130" "TARGET_STATES 为空时 auto_enable_active_standby 不许刷整数比较错误" \
        "冻结态 lib/rules.sh 的 auto_enable_active_standby（规则 TARGET_STATES 空 + REMOTE_HOST 非空）" \
        "auto_enable_active_standby <端口>（规则目录在沙箱里）" \
        "输出里不得出现「integer expression expected」；负向对照：修复前实现必须出现"

    local site="$SBX_ROOT/t130_site"
    rm -rf "$site" 2>/dev/null
    mkdir -p "$site/rules" 2>/dev/null
    cat > "$site/rules/rule-1.conf" <<'EOF'
RULE_ID=1
RULE_ROLE="1"
RULE_NAME="t130"
SECURITY_LEVEL="off"
LISTEN_PORT="19999"
LISTEN_IP="0.0.0.0"
THROUGH_IP="127.0.0.1"
REMOTE_HOST="127.0.0.1"
REMOTE_PORT="19998"
TLS_SERVER_NAME=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_NOTE="t130"
ENABLED="true"
CREATED_TIME="2026-01-01 00:00:00"
BALANCE_MODE="off"
PREV_BALANCE_MODE=""
TARGET_STATES=""
WEIGHTS=""
FAILOVER_ENABLED="false"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="10"
RECOVERY_COOLDOWN="120"
PROBE_QUALITY_WINDOW="20"
MPTCP_MODE="off"
PROXY_MODE="off"
EOF

    local out
    out=$(_run_in_sandbox '
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null
        source "$1/lib/health.sh" >/dev/null
        source "$1/lib/rules.sh" >/dev/null
        if declare -F auto_enable_active_standby >/dev/null 2>&1; then
            echo "FUNC_OK=1"
        else
            echo "FUNC_MISSING=1"
        fi
        auto_enable_active_standby 19999 2>&1
        echo "RC=$?"
    ' "$site")
    h_log "输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"

    h_check_contains "$out" "FUNC_OK=1" "auto_enable_active_standby 确实存在于冻结态 lib/rules.sh"

    # ★ 报错措辞**随 bash 版本不同**（Git Bash 5.x: "integer expected"；Debian bash 5.2: "integer expression expected"）
    #   ⇒ 两种措辞都算命中，否则换个平台这条断言就静默失效（判据比平台还脆）。
    if printf '%s' "$out" | grep -qE 'integer( expression)? expected'; then
        h_fail "空 TARGET_STATES 触发了整数比较报错（日志里刷错，且比较结果是随机的）"
    else
        h_pass "空 TARGET_STATES 不再触发整数比较错误"
    fi
    # 正向：主备开关确实被打开了（不能为了不报错就不干活）
    h_check_file_has "$site/rules/rule-1.conf" 'BALANCE_MODE="active-standby"' "空 TARGET_STATES 时仍然正确进了主备模式"
    h_check_file_has "$site/rules/rule-1.conf" 'FAILOVER_ENABLED="true"' "空 TARGET_STATES 时仍然正确开了故障转移"

    # ── 负向对照：修复前的真实实现 ⇒ 必须出现那条错 ──
    local pre_tree="$SBX_ROOT/t130_pre"
    if _t29_prepare_pre_tree "$pre_tree"; then
        # ★ 对照有效性自检：老树里**确实没有**这次的空值兜底
        local pre_has_guard=0
        grep -q '_ts_count=\${_ts_count:-0}' "$pre_tree/lib/rules.sh" 2>/dev/null && pre_has_guard=1
        h_check_eq "0" "$pre_has_guard" "对照有效性自检：修复前的 lib/rules.sh 里没有空值兜底"

        local pre_site="$SBX_ROOT/t130_pre_site"
        rm -rf "$pre_site" 2>/dev/null
        mkdir -p "$pre_site/rules" 2>/dev/null
        cp "$site/rules/rule-1.conf" "$pre_site/rules/rule-1.conf" 2>/dev/null
        local pre_out
        pre_out=$(bash -c '
            export CONFIG_DIR="$2"
            source "$1/lib/core.sh"  >/dev/null
            source "$1/lib/health.sh" >/dev/null
            source "$1/lib/rules.sh" >/dev/null
            auto_enable_active_standby 19999 2>&1
            echo "RC=$?"
        ' _ "$pre_tree" "$pre_site" 2>&1)
        h_log "修复前实现的输出: $(printf '%s' "$pre_out" | tr '\n' ' ' | cut -c1-220)"
        if printf '%s' "$pre_out" | grep -qE 'integer( expression)? expected'; then
            h_pass "负向对照：修复前的实现**确实报那条错** ⇒ 上面那条断言有判别力"
        else
            h_fail "负向对照失效：修复前的实现没报那条错（对照选错了）"
        fi
        rm -rf "$pre_site" 2>/dev/null
    else
        h_fail "取不到修复前实现的 lib/（sha $_T29_PRE_SHA 不可达）—— 负向对照无法执行"
    fi

    rm -rf "$site" "$pre_tree" 2>/dev/null
}
