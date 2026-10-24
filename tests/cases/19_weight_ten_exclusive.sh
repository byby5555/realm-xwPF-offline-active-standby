#!/bin/bash
# 用例组 19 · 权重 10 独占（主备 / 负载均衡 二选一）
#
# ★ 产品裁定（用户原话）：「一个机子是 10，那另一台机子注定就是 0」
#   → 权重 10 必须**独占**：
#       要么所有权重都在 0-9（普通负载均衡），
#       要么**恰好一个 10 且其余全是 0**（主备）。
#
# ★ 冻结态产品只校验权重范围 0-10（lib/rules.sh 的 validate_weight_input：
#   「权重值 X 超出范围，请使用 0-10 之间的数值」），**没有**独占校验
#   → 本组用例里与「必须被拒绝 / 拒绝时不落盘 / 提示说人话」相关的断言现在应当是**红的**。
#   这是**用例先行**：判定口径照矩阵一条不改，不为了让用例变绿而放松任何一条；
#   产品实现由小编补上后本组用例应直接转绿。
#
# ★ 被测入口（选「上层」是因为它同时覆盖两种实现位置）：
#   lib/rules.sh 的 configure_port_group_weights（UI 整组入口）
#     → validate_weight_input（输入校验）
#     → preview_port_group_weight_config（预览 + 确认）
#     → apply_port_group_weight_config（**写规则文件的那一层**）
#   小编把独占校验放在 validate_weight_input 或 apply_port_group_weight_config 任一处，
#   本组用例都能直接转绿。若只打写盘层（apply_port_group_weight_config），
#   小编把校验放在 UI 层时用例会替产品背锅。
#   ★ 若小编另起了一个独立入口，本文件要改的是 _n9_run_in_tree() 里那一行
#     configure_port_group_weights 调用。
#
# ★ 两条入口（矩阵第 5 条）：
#   A 整组设置权重：一次性提交整组权重串（configure_port_group_weights）
#   B 单个目标改权重：盘上已有主备组（10,0），只把目标 2 改成 5
#     → **重新拼整组**得到 10,5 再提交；判定必须落在**整组**上，
#       不能只校验被改的那一个（单看 5 是合法的 0-9 权重）。
#   产品当前**没有**「单个目标改权重」的独立入口（全仓只有 configure_port_group_weights
#   一处接受权重输入），所以 B 按「改单点后重拼整组再提交」测。
#   若小编后续新增了单目标入口，B 需要补一个驱动分支（见 T81 里的说明）。
#
# ★ 负向对照（矩阵第 7 条）：用「加独占校验之前的真实旧实现」跑**同一套判定器**，
#   必须抓到「10,5 被接受并写成负载均衡」这个坏情况。
#   sha 不写死：先查 tests/cases/00_common.sh 的 sbx_required_history_shas（key=weight10-pre），
#   清单没登记时退回 Chief 指定的 b863911；对象取不到就 h_fail 判红（**不许静默跳过**）。
#
# ★ 判定器自检（矩阵第 8 条）：判定器必须能区分「拒绝」与「接受」。
#   自检用两个**永久稳定**的输入：11,0（越界，冻结态与将来都被拒）、
#   5,5（合法负载均衡，冻结态与将来都被接受）。
#   不用 10,5 做「被拒」那一侧 —— 小编补上独占校验后 10,5 会被拒，
#   自检会跟着翻车 → 变成替产品背锅。

# ── 常量 ─────────────────────────────────────────────────────────
_N9_PORT=443
_N9_REMOTE_PORT=8080
_N9_HOSTS="10.0.0.1 10.0.0.2 10.0.0.3"

# 被测驱动代码（在指定产品树上跑一次「整组设置权重」）
#   $1=产品树目录  $2=监听端口  $3=目标串  $4=当前权重串
#   clear 被顶掉：交互清屏会把转义序列混进输出，污染「提示文本」判定
#   service_restart 被顶掉：它会调 reorder_rule_ids 重排规则文件（改字节），
#   还会去重新生成 realm 配置 —— 两者都会污染「拒绝前后文件逐字节相同」这条判定
_N9_DRIVER_CODE='
    clear(){ :; }
    source "$1/lib/core.sh" >/dev/null 2>&1
    source "$1/lib/health.sh" >/dev/null 2>&1
    source "$1/lib/rules.sh" >/dev/null 2>&1
    service_restart(){ return 0; }
    configure_port_group_weights "$2" "wg-test" "$3" "$4"
    echo "RC=$?"
'

# ── helper ───────────────────────────────────────────────────────

# 造端口组的规则文件
#   用法：_n9_make_rules <目录> <端口> <BALANCE_MODE> <FAILOVER_ENABLED> <组权重串> <目标数>
#   落盘约定跟产品一致：rule-1 存**完整**权重串，其余规则各存自己那一个值
#   ★ RULE_ID 必须连续（1..N）：不连续会触发 reorder_rule_ids 重排
#     → 旧格式状态行归属认不出 → 场景走另一条路径 → 假绿
_n9_make_rules() {
    local dir="$1" port="$2" mode="$3" failover="$4" w1="$5" n="$6"
    rm -f "$dir"/rule-*.conf
    local -a hosts=($_N9_HOSTS)
    local -a ws
    IFS=',' read -ra ws <<< "$w1"
    local i w
    for ((i=1; i<=n; i++)); do
        if [ "$i" = "1" ]; then w="$w1"; else w="${ws[$((i-1))]:-1}"; fi
        cat > "$dir/rule-$i.conf" <<EOF
RULE_ID=$i
RULE_ROLE=1
RULE_NAME="wg-$i"
SECURITY_LEVEL=none
LISTEN_PORT=$port
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=${hosts[$((i-1))]}
REMOTE_PORT=$_N9_REMOTE_PORT
ENABLED=true
BALANCE_MODE="$mode"
TARGET_STATES=""
WEIGHTS="$w"
FAILOVER_ENABLED="$failover"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="10"
RECOVERY_COOLDOWN="120"
EOF
    done
}

# 端口组的目标串（展示侧口径：host:port 逗号分隔）
_n9_targets_str() {
    local n="$1" i out=""
    local -a hosts=($_N9_HOSTS)
    for ((i=0; i<n; i++)); do
        [ -n "$out" ] && out="$out,"
        out="$out${hosts[$i]}:$_N9_REMOTE_PORT"
    done
    printf '%s' "$out"
}

# 快照：规则目录里每个规则的 sha256（连文件名一起记）
#   → 比对快照 = 比对「文件清单 + 每个文件的字节」
_n9_snapshot() {
    local dir="$1" out="$2" f
    : > "$out"
    for f in "$dir"/rule-*.conf; do
        [ -f "$f" ] || continue
        printf '%s %s\n' "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" >> "$out"
    done
}

# 清掉探测端产物（每轮重来）
#   不清的话「探测端没起来」这条断言会被上一轮的残留文件顶成恒真
_n9_clean_probe_artifacts() {
    rm -f "$SBX_ROOT/realm/health/health_check.sh" \
          "$SBX_ROOT/systemd/realm-health-check.timer" \
          "$SBX_ROOT/systemd/realm-health-check.service"
    [ -f "$SBX_LOG_DIR/systemctl.log" ] && : > "$SBX_LOG_DIR/systemctl.log"
}

# 每轮的起点：重铺规则 + 清探测端 + 拍「拒绝前」快照
_n9_reset_case() {
    local n="$1" pre="$2"
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _n9_make_rules "$SBX_ROOT/realm/rules" "$_N9_PORT" "roundrobin" "false" "$pre" "$n"
    _n9_clean_probe_artifacts
    _n9_snapshot "$SBX_ROOT/realm/rules" "$SBX_ROOT/n9_before.snap"
}

# 在指定产品树上跑一次「整组设置权重」
#   用法：_n9_run_in_tree <tree> <stdin> <端口> <目标串> <当前权重串>
#   （_run_in_sandbox 的加强版：产品树可以换 —— 负向对照要用「旧实现那棵树」）
_n9_run_in_tree() {
    local tree="$1" input="$2"
    shift 2
    printf '%s' "$input" | bash -c "$_N9_DRIVER_CODE" _ "$tree" "$@" 2>&1
}

# 取「空输入」那次的输出（= 菜单横幅 + 「未输入权重，保持原配置」）
#   ★ 缓存：横幅只跟 (产品树, 目标串, 当前权重串) 有关，跟这次输入的权重无关
#     → 同一组参数下复用，省掉一半的沙箱调用（机器上有并发跑批时很关键）
#   ★ 横幅是「输入之前」打印的，所以缓存它不会污染判定：
#     拒绝判定只看「响应文本」，响应文本来自真实那次运行。
_N9_REF_KEY=""
_N9_REF_VAL=""

_n9_get_ref() {
    local tree="$1" targets="$2" cur="$3" key="$tree|$targets|$cur"
    if [ "$_N9_REF_KEY" = "$key" ]; then
        _n9_ref="$_N9_REF_VAL"
        return 0
    fi
    _n9_ref=$(_n9_run_in_tree "$tree" $'\n\n' "$_N9_PORT" "$targets" "$cur")
    _N9_REF_KEY="$key"
    _N9_REF_VAL="$_n9_ref"
}

# 驱动一次完整场景
#   先拿参考输出（= 菜单横幅），再跑真实输入；两者之差 = 产品对这次输入的**回应**。
#   （read -p 的提示语只在 stdin 是终端时才打印，沙箱里是管道 → 提示语不在输出里，
#     所以不能用提示语做分界，只能用「两次输出的公共前缀」。）
#   全局：_n9_out（真实输出）、_n9_ref（空输入输出）
_n9_drive_ui() {
    local input="$1" targets="$2" cur="$3" tree="${4:-$SBX_RUN}"
    _n9_get_ref "$tree" "$targets" "$cur"
    _n9_out=$(_n9_run_in_tree "$tree" "$input"$'\n'"y"$'\n\n\n' "$_N9_PORT" "$targets" "$cur")
}

# 取 out 去掉「与 ref 的最长公共前缀」之后的剩余部分
#   ⚠ cmp 必须比的是**内容**：用进程替换把内容变成文件描述符，
#     直接把内容当文件名传给 cmp 会报「File name too long」→ 位置取空 → 截断错位
_n9_tail() {
    local a="$1" b="$2" pos blen
    blen=$(printf '%s' "$a" | wc -c | tr -d ' ')
    pos=$(cmp -l <(printf '%s' "$a") <(printf '%s' "$b") 2>/dev/null | head -1 | awk '{print $1}')
    [ -z "$pos" ] && pos=$((blen + 1))
    printf '%s' "$b" | tail -c +"$pos"
}

# 判定器：把一次驱动结果判成「拒绝了 / 没拒绝」
#   用法：_n9_judge <规则目录> <拒绝前快照>（前置：_n9_out / _n9_ref 已填好）
#   全局：_n9_v_unchanged / _n9_v_wrote / _n9_v_rejected / _n9_msg
_n9_judge() {
    local dir="$1" snap="$2" now="$SBX_ROOT/n9_after.snap"
    _n9_snapshot "$dir" "$now"
    if cmp -s "$snap" "$now"; then _n9_v_unchanged=yes; else _n9_v_unchanged=no; fi
    case "$_n9_out" in
        *"已更新"*) _n9_v_wrote=yes ;;
        *) _n9_v_wrote=no ;;
    esac
    _n9_msg=$(_n9_tail "$_n9_ref" "$_n9_out")
    if [ "$_n9_v_unchanged" = "yes" ] && [ "$_n9_v_wrote" = "no" ] && [ -n "$_n9_msg" ]; then
        _n9_v_rejected=yes
    else
        _n9_v_rejected=no
    fi
}

# 提示文本（去掉 ANSI 颜色、压成一行）
_n9_msg_clean() {
    local esc=$'\033'
    printf '%s' "$_n9_msg" | sed -e "s/${esc}\[[0-9;]*[a-zA-Z]//g" | tr '\n' ' '
}

# 「0」必须是**独立**数字（前后都不是数字）
#   否则 "10" 里的那个 0 就能蒙混过关 —— 这条断言就成了恒真
_n9_check_standalone_zero() {
    if printf '%s' "$1" | grep -qE '(^|[^0-9])0([^0-9]|$)'; then
        h_pass "$2 命中独立数字[0]"
    else
        h_fail "$2 未命中独立数字[0]（内容: $(printf '%s' "$1" | cut -c1-160)）"
    fi
}

# 文件不该存在
_n9_check_no_file() {
    if [ -e "$1" ]; then
        h_fail "$2 仍存在: $1"
    else
        h_pass "$2 不存在（符合预期）"
    fi
}

# 组里所有规则的 BALANCE_MODE 行
_n9_balance_modes() {
    grep -h '^BALANCE_MODE=' "$SBX_ROOT/realm/rules"/rule-*.conf 2>/dev/null | tr '\n' ' '
}

# systemctl 调用记录
_n9_systemctl_log() {
    [ -f "$SBX_LOG_DIR/systemctl.log" ] && cat "$SBX_LOG_DIR/systemctl.log"
    return 0
}

# ── 用例 ─────────────────────────────────────────────────────────

case_T77_weight10_exclusive_active_standby() {
    h_case_begin "T77" "权重 10 独占：含 0 的合法组合进主备（10,0 / 10,0,0 / 0,10 / 5,0）" \
        "沙箱 rules（端口 443，2~3 个目标）+ 沙箱 lib/rules.sh" \
        "configure_port_group_weights 443 '10,0' / '10,0,0' / '0,10' / '5,0'" \
        "每组都进主备：BALANCE_MODE=active-standby + FAILOVER_ENABLED=true + 探测端起来"

    local spec w n pre r1
    for spec in "10,0:2" "10,0,0:3" "0,10:2" "5,0:2"; do
        w="${spec%%:*}"; n="${spec##*:}"
        if [ "$n" = "2" ]; then pre="1,1"; else pre="1,1,1"; fi
        _n9_reset_case "$n" "$pre"
        _n9_drive_ui "$w" "$(_n9_targets_str "$n")" "$pre"
        r1="$SBX_ROOT/realm/rules/rule-1.conf"
        h_log "--- 权重 $w（$n 个目标）---"
        h_log "回应: $(printf '%s' "$_n9_msg" | tr '\n' ' ' | cut -c1-200)"

        h_check_file_has "$r1" 'BALANCE_MODE="active-standby"' "权重 $w → rule-1 进主备"
        h_check_file_has "$r1" 'FAILOVER_ENABLED="true"' "权重 $w → 故障转移开启"
        h_check_file_has "$r1" "WEIGHTS=\"$w\"" "权重 $w → 权重串落盘"
        h_check_file "$SBX_ROOT/realm/health/health_check.sh" "权重 $w → 探测端脚本已生成"
        h_check_file "$SBX_ROOT/systemd/realm-health-check.timer" "权重 $w → 探测端 timer 已生成"
        h_check_contains "$(_n9_systemctl_log)" "start realm-health-check.timer" \
            "权重 $w → systemctl 拉起了探测端 timer"
    done
}

case_T78_weight10_exclusive_load_balance() {
    h_case_begin "T78" "权重 10 独占：0-9 的合法组合保持负载均衡（5,5 / 1,9 / 3,3,4）" \
        "沙箱 rules（端口 443，2~3 个目标）+ 沙箱 lib/rules.sh" \
        "configure_port_group_weights 443 '5,5' / '1,9' / '3,3,4'" \
        "保持负载均衡：BALANCE_MODE=roundrobin、不得进主备、不开故障转移、不拉探测端"

    local spec w n pre r1
    for spec in "5,5:2" "1,9:2" "3,3,4:3"; do
        w="${spec%%:*}"; n="${spec##*:}"
        if [ "$n" = "2" ]; then pre="1,1"; else pre="1,1,1"; fi
        _n9_reset_case "$n" "$pre"
        _n9_drive_ui "$w" "$(_n9_targets_str "$n")" "$pre"
        r1="$SBX_ROOT/realm/rules/rule-1.conf"
        h_log "--- 权重 $w（$n 个目标）---"

        h_check_file_has "$r1" 'BALANCE_MODE="roundrobin"' "权重 $w → 保持负载均衡模式"
        h_check_not_contains "$(_n9_balance_modes)" "active-standby" "权重 $w → 不得进主备"
        h_check_file_has "$r1" 'FAILOVER_ENABLED="false"' "权重 $w → 不开故障转移"
        h_check_file_has "$r1" "WEIGHTS=\"$w\"" "权重 $w → 权重串按比例落盘"
        _n9_check_no_file "$SBX_ROOT/realm/health/health_check.sh" "权重 $w → 不生成探测端脚本"
        _n9_check_no_file "$SBX_ROOT/systemd/realm-health-check.timer" "权重 $w → 不生成探测端 timer"
        h_check_not_contains "$(_n9_systemctl_log)" "realm-health-check.timer" \
            "权重 $w → 不拉起探测端 timer"
    done
}

case_T79_weight10_must_be_rejected() {
    h_case_begin "T79" "权重 10 独占：10 与别的权重混用必须被拒绝（10,5 / 10,1 / 10,3 / 10,10）" \
        "沙箱 rules（端口 443，2 个目标，权重 1,1）+ 沙箱 lib/rules.sh" \
        "configure_port_group_weights 443 '10,5' / '10,1' / '10,3' / '10,10'" \
        "报错 + 不写盘：不得出现写盘成功标志，规则文件逐字节未变，盘上仍是旧权重"

    local spec w r1 clean
    for spec in "10,5:2" "10,1:2" "10,3:2" "10,10:2"; do
        w="${spec%%:*}"
        _n9_reset_case 2 "1,1"
        _n9_drive_ui "$w" "$(_n9_targets_str 2)" "1,1"
        _n9_judge "$SBX_ROOT/realm/rules" "$SBX_ROOT/n9_before.snap"
        r1="$SBX_ROOT/realm/rules/rule-1.conf"
        clean=$(_n9_msg_clean)
        h_log "--- 权重 $w ---"
        h_log "回应: $(printf '%s' "$clean" | cut -c1-200)"

        h_check_eq "no" "$_n9_v_wrote" "权重 $w → 不得出现「已更新 N 个规则文件」写盘标志"
        h_check_eq "yes" "$_n9_v_unchanged" "权重 $w → 规则文件逐字节未变"
        h_check_file_has "$r1" 'WEIGHTS="1,1"' "权重 $w → 盘上仍是旧权重（没被接受）"
        # 「报错」= 产品对这次输入有回应（提示非空）。
        # ★ 这里**不**要求提示里出现「权重」二字：
        #   产品的「两个 10」分支文案是「只能有一个目标拿 10」+「写法示例: 10,0 = 主备…；
        #   5,5 = 负载均衡按比例分流」—— 没有「权重」二字，但矩阵第 6 条要求的
        #   「10」+「0」都在（说人话那部分由 T82 断言），矩阵第 3 条只要求「报错 + 不写盘」。
        if [ -n "$clean" ]; then
            h_pass "权重 $w → 有拒绝提示（不是静默接受）"
        else
            h_fail "权重 $w → 没有任何拒绝提示（静默接受或静默失败）"
        fi
    done
}

case_T80_weight10_reject_leaves_no_half_write() {
    h_case_begin "T80" "权重 10 独占：拒绝时不得留下半写状态（sha256 前后比对）" \
        "沙箱 rules（端口 443，2 个目标，权重 1,1）+ 沙箱 lib/rules.sh" \
        "拒绝前后各拍一次规则文件 sha256 快照 → 比对" \
        "拒绝后每个规则文件的 sha256 与拒绝前**逐字节相同**，规则文件数量不变"

    local spec w before after hb ha
    for spec in "10,5:2" "10,1:2" "10,3:2" "10,10:2"; do
        w="${spec%%:*}"
        _n9_reset_case 2 "1,1"

        # 拒绝前的快照（独立于判定器，单独拍一次）
        before="$SBX_ROOT/n9_before_$w.snap"
        after="$SBX_ROOT/n9_after_$w.snap"
        _n9_snapshot "$SBX_ROOT/realm/rules" "$before"
        hb=$(sha256sum "$before" | cut -d' ' -f1)

        _n9_drive_ui "$w" "$(_n9_targets_str 2)" "1,1"

        _n9_snapshot "$SBX_ROOT/realm/rules" "$after"
        ha=$(sha256sum "$after" | cut -d' ' -f1)
        h_log "--- 权重 $w ---"
        h_log "拒绝前快照 sha256: $hb"
        h_log "拒绝后快照 sha256: $ha"

        h_check_eq "$hb" "$ha" "权重 $w → 拒绝前后规则文件 sha256 逐字节相同"
        h_check_eq "$(grep -c . "$before")" "$(grep -c . "$after")" \
            "权重 $w → 规则文件数量不变（没有多出/少掉规则）"
    done
}

case_T81_weight10_both_entries_rejected() {
    h_case_begin "T81" "权重 10 独占：整组设置权重 与 单个目标改权重 两条入口都要拒" \
        "沙箱 rules（端口 443，2 个目标）+ 沙箱 lib/rules.sh" \
        "A 整组提交 '10,5'；B 盘上已有 10,0 组，改单点后重拼整组 '10,5'" \
        "两条入口都被拒绝且规则文件逐字节未变；单看被改的那一个（5）本身合法"

    local r1 before after hb ha

    # ── 分支 A：整组设置权重（一次性提交整组 10,5）──
    _n9_reset_case 2 "1,1"
    before="$SBX_ROOT/n9_a_before.snap"; after="$SBX_ROOT/n9_a_after.snap"
    _n9_snapshot "$SBX_ROOT/realm/rules" "$before"
    hb=$(sha256sum "$before" | cut -d' ' -f1)
    _n9_drive_ui "10,5" "$(_n9_targets_str 2)" "1,1"
    _n9_snapshot "$SBX_ROOT/realm/rules" "$after"
    ha=$(sha256sum "$after" | cut -d' ' -f1)
    _n9_judge "$SBX_ROOT/realm/rules" "$before"
    h_log "--- 分支 A：整组设置权重 10,5 ---"
    h_check_eq "yes" "$_n9_v_rejected" "分支 A → 整组 10,5 被拒绝"
    h_check_eq "$hb" "$ha" "分支 A → 拒绝前后规则文件 sha256 逐字节相同"

    # ── 分支 B：单个目标改权重 → 重新拼整组再提交 ──
    #   盘上先有产品自己写出来的主备组：rule-1 存整串 10,0、rule-2 存自己那个 0
    #   用户只把目标 2 改成 5 → 重新拼整组 = 10,5
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _n9_make_rules "$SBX_ROOT/realm/rules" "$_N9_PORT" "active-standby" "true" "10,0" 2
    _n9_clean_probe_artifacts
    before="$SBX_ROOT/n9_b_before.snap"; after="$SBX_ROOT/n9_b_after.snap"
    _n9_snapshot "$SBX_ROOT/realm/rules" "$before"
    hb=$(sha256sum "$before" | cut -d' ' -f1)
    _n9_drive_ui "10,5" "$(_n9_targets_str 2)" "10,0"
    _n9_snapshot "$SBX_ROOT/realm/rules" "$after"
    ha=$(sha256sum "$after" | cut -d' ' -f1)
    _n9_judge "$SBX_ROOT/realm/rules" "$before"
    r1="$SBX_ROOT/realm/rules/rule-1.conf"
    h_log "--- 分支 B：单个目标改权重（目标 2：0 → 5）→ 重拼整组 10,5 ---"
    h_log "回应: $(printf '%s' "$(_n9_msg_clean)" | cut -c1-200)"
    h_check_eq "yes" "$_n9_v_rejected" "分支 B → 改单点后重拼的整组 10,5 被拒绝"
    h_check_eq "$hb" "$ha" "分支 B → 拒绝前后规则文件 sha256 逐字节相同"
    h_check_file_has "$r1" 'WEIGHTS="10,0"' "分支 B → 组权重串仍是原来的 10,0（没被半写）"
    h_check_file_has "$SBX_ROOT/realm/rules/rule-2.conf" 'WEIGHTS="0"' \
        "分支 B → 目标 2 的权重仍是 0（没被半写）"

    # ── 分支 C：单看被改的那一个（5）本身合法 ──
    #   → 拒绝只能来自「整组独占」规则，不能来自对单个值的范围校验
    local out rc
    out=$(bash -c '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        validate_weight_input "5" 1
        echo "RC=$?"
    ' _ "$SBX_RUN" 2>&1)
    rc=$(printf '%s' "$out" | grep -o 'RC=[0-9]*' | tail -1 | cut -d= -f2)
    h_log "validate_weight_input '5' 1 → rc=$rc（输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)）"
    h_check_rc "0" "$rc" "分支 C → 单看被改的那一个（权重 5）本身合法 → 拒绝只能来自整组规则"
}

case_T82_weight10_reject_message_speaks_human() {
    h_case_begin "T82" "权重 10 独占：拒绝提示要说人话（看得出怎么改）" \
        "沙箱 rules（端口 443，2 个目标，权重 1,1）+ 沙箱 lib/rules.sh" \
        "拒绝 10,5 / 10,1 / 10,3 / 10,10 时的提示文本" \
        "提示非空、同时出现「10」和**独立**的「0」（10,0=主备；0-9=负载均衡）"

    local spec w clean
    for spec in "10,5:2" "10,1:2" "10,3:2" "10,10:2"; do
        w="${spec%%:*}"
        _n9_reset_case 2 "1,1"
        _n9_drive_ui "$w" "$(_n9_targets_str 2)" "1,1"
        _n9_judge "$SBX_ROOT/realm/rules" "$SBX_ROOT/n9_before.snap"
        clean=$(_n9_msg_clean)
        h_log "--- 权重 $w ---"
        h_log "回应: $(printf '%s' "$clean" | cut -c1-200)"

        h_check_eq "yes" "$_n9_v_rejected" "权重 $w → 确实被拒绝（否则提示无从检查）"
        if [ -n "$clean" ]; then
            h_pass "权重 $w → 拒绝提示非空"
        else
            h_fail "权重 $w → 拒绝提示为空"
        fi
        h_check_contains "$clean" "10" "权重 $w → 提示里出现「10」"
        _n9_check_standalone_zero "$clean" "权重 $w → 提示里出现独立的「0」"
    done
}

case_T83_weight10_judge_selfcheck() {
    h_case_begin "T83" "判定器自检：同一套判定器必须能区分「拒绝」与「接受」" \
        "沙箱 rules（端口 443，2 个目标）+ 沙箱 lib/rules.sh" \
        "判定器分别跑 11,0（越界必拒）与 5,5（合法必收）" \
        "11,0 → 判为已拒绝且文件未变；5,5 → 判为未拒绝且文件已变"

    # ── 「拒绝」一侧：11,0 越界，冻结态与将来都必拒 ──
    _n9_reset_case 2 "1,1"
    _n9_drive_ui "11,0" "$(_n9_targets_str 2)" "1,1"
    _n9_judge "$SBX_ROOT/realm/rules" "$SBX_ROOT/n9_before.snap"
    h_log "--- 11,0（越界）---"
    h_log "回应: $(printf '%s' "$(_n9_msg_clean)" | cut -c1-200)"
    h_check_eq "yes" "$_n9_v_rejected" "11,0 → 判定器判为「已拒绝」"
    h_check_eq "yes" "$_n9_v_unchanged" "11,0 → 判定器看到文件逐字节未变"
    h_check_eq "no" "$_n9_v_wrote" "11,0 → 判定器没看到写盘成功标志"

    # ── 「接受」一侧：5,5 合法，冻结态与将来都必收 ──
    _n9_reset_case 2 "1,1"
    _n9_drive_ui "5,5" "$(_n9_targets_str 2)" "1,1"
    _n9_judge "$SBX_ROOT/realm/rules" "$SBX_ROOT/n9_before.snap"
    h_log "--- 5,5（合法负载均衡）---"
    h_check_eq "no" "$_n9_v_rejected" "5,5 → 判定器判为「未拒绝」（接受）"
    h_check_eq "no" "$_n9_v_unchanged" "5,5 → 判定器看到文件被改了"
    h_check_eq "yes" "$_n9_v_wrote" "5,5 → 判定器看到写盘成功标志"
    h_check_file_has "$SBX_ROOT/realm/rules/rule-1.conf" 'WEIGHTS="5,5"' "5,5 → 权重串确实落盘"
}

case_T84_weight10_negative_control_old_impl() {
    h_case_begin "T84" "负向对照：加独占校验之前的真实旧实现必须被判定器抓到" \
        "冻结态历史对象（加独占校验之前的 lib/rules.sh）" \
        "旧实现跑同一套判定器 + 权重 10,5" \
        "坏情况确实发生（旧实现把 10,5 接受并写成负载均衡），且判定器判为「未拒绝」"

    # sha 不写死：先查单一真源（00_common.sh 的 sbx_required_history_shas）
    local sha=""
    sha=$(sbx_history_sha weight10-pre 2>/dev/null) || sha=""
    if [ -z "$sha" ]; then
        # 清单里还没登记 → 退回 Chief 指定的「加独占校验之前」那个提交
        sha="b863911"
    fi
    h_log "负向对照用的历史实现: $sha"

    if ! git -C "$SBX_REPO" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        h_fail "负向对照取不到「加独占校验之前的真实旧实现」：历史对象 $sha 不在本地对象库"
        h_fail "→ 修法1：在 tests/cases/00_common.sh 的 sbx_required_history_shas 里登记 key=weight10-pre → $sha"
        h_fail "→ 修法2：把对象拉进本地库（git fetch --tags origin，或不用 --single-branch 重新克隆）"
        return
    fi

    # 搭一棵「旧实现」的产品树：冻结态执行副本 + 旧版 lib/rules.sh（同样做路径重定向）
    local old_run="$SBX_ROOT/n9_old_run"
    rm -rf "$old_run"
    mkdir -p "$old_run"
    cp -r "$SBX_RUN"/. "$old_run"/
    git -C "$SBX_REPO" show "${sha}:lib/rules.sh" > "$SBX_ROOT/n9_old_rules.sh"
    sbx_redirect "$SBX_ROOT/n9_old_rules.sh" "$old_run/lib/rules.sh"
    h_log "旧实现树: $old_run"

    # 同一套判定器、同一组输入，只是产品换成旧实现
    _n9_reset_case 2 "1,1"
    _n9_drive_ui "10,5" "$(_n9_targets_str 2)" "1,1" "$old_run"
    _n9_judge "$SBX_ROOT/realm/rules" "$SBX_ROOT/n9_before.snap"
    h_log "--- 旧实现 + 10,5 ---"
    h_log "回应: $(printf '%s' "$(_n9_msg_clean)" | cut -c1-200)"

    # 断言一：坏情况确实发生（不是「判定器坏了」）
    h_check_eq "no" "$_n9_v_unchanged" "旧实现确实改了规则文件（坏情况确实发生）"
    h_check_file_has "$SBX_ROOT/realm/rules/rule-1.conf" 'WEIGHTS="10,5"' \
        "旧实现把 10,5 接受并写成了负载均衡权重"
    # 断言二：判定器抓到了这个坏情况
    h_check_eq "no" "$_n9_v_rejected" "判定器抓到了「10,5 被接受」的坏情况"
}
