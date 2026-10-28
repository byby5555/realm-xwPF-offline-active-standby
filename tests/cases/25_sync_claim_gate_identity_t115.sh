# shellcheck shell=bash
#
# T115 / T116 · 迁移端认领：Chief 新裁定「身份优先 + 候选门槛」
#
# ── 裁定原文（Chief）───────────────────────────────────────────
#   ① 认领顺序：**先按组合键 old_rule_id + 目标地址**认领
#   ② 再退到「还没认领过这个目标」的候选规则
#   ③ 候选规则必须 **ROLE=1 + ENABLED=true + FAILOVER_ENABLED=true**
#      （没开故障转移的规则不许认领状态行）
#
# ── 为什么这条裁定必须有测试 ─────────────────────────────────
#   认领写错的后果是**状态归零 = 该切不切的静默失效**：
#     被监控规则的失败状态被别的规则抢走 ⇒ 监控规则看起来「健康」⇒ 永远不切。
#   这类缺陷**不报任何错**：日志照打、退出码 0、界面照常显示「已连接」。
#
# ── 与 cases/22（T94~T96）的分工（不重复、不越界）─────────────
#   cases/22 测的是「**一对一认领**」（84fe096 修的那条）：同一 (RULE_ID,TARGET)
#     不得出现两行、迁移后不得丢行。
#   ★ 但 T94~T96 的六场景里**每一条规则都满足 ROLE=1+ENABLED=true+
#     FAILOVER_ENABLED=true** ⇒ **门槛失效时测不出来**（六场景照样全绿）；
#     且场景 6 只数「行数 / 规则数 / 重复」，**没数行归谁** ⇒
#     「身份优先」被换成「纯文件顺序回退」也测不出来。
#   ⇒ 本文件补的正是这两个缺口：**候选门槛**（B/C/D）+ **身份优先**（A）
#     + **回退腿**（E/F）。cases/22 **一个字都不改**（只读复用它的 helper）。
#
# ── 负向对照锚点（真实旧实现，不用 sed 人造破坏）───────────────
#   sync-pre = 75379aa（= 84fe096^，修复前的真实实现）
#   老实现的认领只有**一道 ROLE=1 门槛**、没有身份优先、没有「已认领」判定
#   ⇒ T115 的 A/B/C/D/F 五个判别力场景在老实现上必须给出**相反**结论。
#
# ── 六个场景（A~F）────────────────────────────────────────────
#   A 身份优先：两条规则同目标、**文件顺序与 RULE_ID 相反**（= 重编号后的形态）
#     期望 RULE_ID=1 拿 fail3、RULE_ID=2 拿 fail5
#     （若实现只按文件顺序回退 ⇒ 两行都归 RULE_ID=2 ⇒ 有判别力）
#   B 门槛 · FAILOVER_ENABLED=false 的规则不得认领
#   C 门槛 · ENABLED=false 的规则不得认领
#   D 门槛 · RULE_ROLE=2 的规则不得认领（带 FORWARD_TARGET —— 老实现会走它）
#   E 回退腿：行首 old_rule_id 没有任何身份候选（老规则号已消失）→ 状态跟到未认领候选
#   F 回退腿必须挑**未认领**的候选（已认领过的那个不能再拿第二行）
#
# ── ★ 场景 E 与老实现**同结论**（老实现也是「第一个匹配就 break」）⇒
#   E 是**回归护栏**（防回退腿被改坏），不是判别力场景；
#   判别力由 A/B/C/D/F 承担（负向对照见 T116）。
#
# ── 复用的 helper（在 cases/22 里定义，同一个 shell 内可见；**只读复用**）────
#   _sync_run_migration / _sync_current_tree / _sync_old_tree
#   _sync_pair_count / _sync_fail_count

# ─────────────────────────────────────────────────────────────
# 历史实现 sha（单一真源；清单里没登记就退回 Chief 指定值）
# ─────────────────────────────────────────────────────────────
_GATE_PRE_SHA="$(sbx_history_sha sync-pre 2>/dev/null || true)"
if [ -z "$_GATE_PRE_SHA" ]; then _GATE_PRE_SHA="75379aa"; fi

# 目标地址（只做标识用，不起监听）
_GATE_TARGET="1.2.3.4:8080"

# ─────────────────────────────────────────────────────────────
# helper · 写一条规则文件（**本文件自带的夹具**，不改 cases/22）
#   用法：_gate_make_rule <文件> <RULE_ID> <LISTEN_PORT> <REMOTE_HOST> <REMOTE_PORT> [覆盖键=值;覆盖键2=值2]
#   ★ 规则文件必须写**全官方键集**：read_rule_file 会把白名单里每个键
#     重新赋值（没写的键回落成空串）⇒ 少写不致命，但写全才能保证
#     「不测的东西」确实是被测的那一项。
#   ★ 覆盖行用「后写覆盖先写」：read_rule_file 是白名单逐行解析，
#     同名键后出现的值覆盖先出现的（lib/health.sh 的 _rule_vals[$_k]="$_v"）。
#   ★ 覆盖键之间用 ';' 分隔（键值里不会出现分号）。
# ─────────────────────────────────────────────────────────────
_gate_make_rule() {
    local file="$1" id="$2" lp="$3" host="$4" rp="$5" extra="${6:-}"
    mkdir -p "$(dirname "$file")" 2>/dev/null
    cat > "$file" <<EOF
RULE_ID=$id
RULE_ROLE=1
RULE_NAME="gate-rule-$id"
SECURITY_LEVEL=none
LISTEN_PORT=$lp
LISTEN_IP=0.0.0.0
THROUGH_IP=:::
REMOTE_HOST=$host
REMOTE_PORT=$rp
ENABLED=true
BALANCE_MODE="active-standby"
TARGET_STATES=""
WEIGHTS="10,0"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="10"
RECOVERY_COOLDOWN="120"
EOF
    if [ -n "$extra" ]; then
        local _oldifs="$IFS"
        local _kv
        IFS=';'
        for _kv in $extra; do
            [ -n "$_kv" ] || continue
            printf '%s\n' "$_kv" >> "$file"
        done
        IFS="$_oldifs"
    fi
}

# ─────────────────────────────────────────────────────────────
# helper · 搭场景（可覆盖规则键）
#   规则定义 = "文件名:RULE_ID:LISTEN_PORT:HOST:PORT|覆盖键=值;覆盖键2=值2"
#   ★ 用 '|' 分隔覆盖段（host:port 里已经有 ':'）。
# ─────────────────────────────────────────────────────────────
_gate_setup() {
    local tag="$1"; shift
    local dir="$SBX_ROOT/sync/$tag"
    rm -rf "$dir" 2>/dev/null
    mkdir -p "$dir/rules" 2>/dev/null
    local spec head extra rest fn id lp host rp
    for spec in "$@"; do
        head="$spec"
        extra=""
        case "$head" in
            *'|'*) extra="${head#*|}"; head="${head%%|*}" ;;
        esac
        fn="${head%%:*}"; rest="${head#*:}"
        id="${rest%%:*}"; rest="${rest#*:}"
        lp="${rest%%:*}"; rest="${rest#*:}"
        host="${rest%%:*}"; rp="${rest##*:}"
        _gate_make_rule "$dir/rules/$fn" "$id" "$lp" "$host" "$rp" "$extra"
    done
    printf '%s\n' "$dir"
}

# ─────────────────────────────────────────────────────────────
# helper · 单项统计（**不拆 Tab** —— 拆 Tab 太容易写错）
# ─────────────────────────────────────────────────────────────
_gate_rows() {
    grep -v '^#' "$1" 2>/dev/null | awk -F'|' 'NF>1' | awk 'NF>0' | wc -l | tr -d ' '
}
_gate_ids() {
    grep -v '^#' "$1" 2>/dev/null | awk -F'|' 'NF>1{print $1}' | sort -u | wc -l | tr -d ' '
}
_gate_dups() {
    grep -v '^#' "$1" 2>/dev/null | awk -F'|' 'NF>1{print $1"|"$2}' | sort | uniq -d
}

# ─────────────────────────────────────────────────────────────
# helper · 跑一次迁移并回显**归属摘要**
#   格式：行数|RULE_ID=1的行数|RULE_ID=1的fail_count|RULE_ID=2的行数|RULE_ID=2的fail_count
#   fail_count 取不到时写 '-'（空串会破坏字段分隔）。
# ─────────────────────────────────────────────────────────────
_gate_probe() {
    local tree="$1" rules_dir="$2" status_file="$3"
    local rows c1 f1 c2 f2
    _sync_run_migration "$tree" "$rules_dir" "$status_file" >/dev/null 2>&1
    rows=$(_gate_rows "$status_file")
    c1=$(_sync_pair_count "$status_file" 1 "$_GATE_TARGET")
    f1=$(_sync_fail_count "$status_file" 1 "$_GATE_TARGET"); [ -n "$f1" ] || f1="-"
    c2=$(_sync_pair_count "$status_file" 2 "$_GATE_TARGET")
    f2=$(_sync_fail_count "$status_file" 2 "$_GATE_TARGET"); [ -n "$f2" ] || f2="-"
    printf '%s|%s|%s|%s|%s' "$rows" "$c1" "$f1" "$c2" "$f2"
}

# ─────────────────────────────────────────────────────────────
# helper · 两个归属摘要是否不同（1=不同，0=相同）
# ─────────────────────────────────────────────────────────────
_gate_differs() {
    if [ "$1" != "$2" ]; then echo 1; else echo 0; fi
}

# ══════════════════════════════════════════════════════════════════
# T115 · 迁移端认领：身份优先 + 候选门槛（六场景）
# ══════════════════════════════════════════════════════════════════
case_T115_sync_claim_identity_priority_and_candidate_gate() {
    h_case_begin "T115" "迁移端认领「身份优先 + 候选门槛」：六场景（身份优先 / FAILOVER_ENABLED 门槛 / ENABLED 门槛 / ROLE 门槛 / 回退腿 / 回退腿挑未认领）" \
        "冻结态 $BASE_SHA 的产品 lib/ + 沙箱 rules（每场景独立目录）" \
        "跑一次 sync_health_status_ids 迁移 → 判行归属（RULE_ID↔fail_count 映射）、行数、重复组合" \
        "身份按 (old_rule_id,目标) 优先；候选必须 ROLE=1+ENABLED=true+FAILOVER_ENABLED=true；回退只挑未认领候选"

    local tree
    tree=$(_sync_current_tree) || { h_fail "取不到当前冻结点的 lib/（BASE_SHA=$BASE_SHA）—— 对照跑不起来等于没在证明"; return; }
    h_check_file "$tree/lib/rules.sh" "当前冻结点的 lib/rules.sh 存在"

    local dir rows nids dups

    # ── 场景 A：身份优先（文件顺序与 RULE_ID 相反 = 重编号后的形态）──
    dir=$(_gate_setup a \
        "rule-1.conf:2:18443:1.2.3.4:8080" \
        "rule-2.conf:1:18444:1.2.3.4:8080")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
2|${_GATE_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    _sync_run_migration "$tree" "$dir/rules" "$dir/health_status.conf"
    rows=$(_gate_rows "$dir/health_status.conf")
    nids=$(_gate_ids "$dir/health_status.conf")
    dups=$(_gate_dups "$dir/health_status.conf")
    h_log "场景A 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_log "场景A 内容：$(grep -v '^#' "$dir/health_status.conf" | tr '\n' ' ')"
    h_check_eq "2" "$rows" "场景A：两条规则同目标 → 迁移后必须 2 行（不许丢行）"
    h_check_eq "2" "$nids" "场景A：两条规则同目标 → 迁移后必须 2 个不同 RULE_ID"
    h_check_eq "" "$dups" "场景A：不得出现重复 (RULE_ID,TARGET)"
    h_check_eq "3" "$(_sync_fail_count "$dir/health_status.conf" 1 "$_GATE_TARGET")" \
        "场景A：★身份优先 —— 行首 old_rule_id=1 的行必须仍归 RULE_ID=1（fail_count=3），不许被文件顺序更靠前的 RULE_ID=2 抢走"
    h_check_eq "5" "$(_sync_fail_count "$dir/health_status.conf" 2 "$_GATE_TARGET")" \
        "场景A：★身份优先 —— 行首 old_rule_id=2 的行必须仍归 RULE_ID=2（fail_count=5）"

    # ── 场景 B：门槛 · FAILOVER_ENABLED=false 的规则不得认领 ──
    #   行首 old_rule_id=99（**没有任何身份候选**）⇒ 只能靠回退腿 ⇒
    #   门槛失效时会被「文件顺序更靠前」的 RULE_ID=1 抢走 ⇒ 有判别力。
    dir=$(_gate_setup b \
        "rule-1.conf:1:18443:1.2.3.4:8080|FAILOVER_ENABLED=false" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
99|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    _sync_run_migration "$tree" "$dir/rules" "$dir/health_status.conf"
    rows=$(_gate_rows "$dir/health_status.conf")
    h_log "场景B 迁移后：行数=$rows 内容=$(grep -v '^#' "$dir/health_status.conf" | tr '\n' ' ')"
    h_check_eq "1" "$rows" "场景B：迁移后必须仍是 1 行（不许丢行）"
    h_check_eq "0" "$(_sync_pair_count "$dir/health_status.conf" 1 "$_GATE_TARGET")" \
        "场景B：★没开故障转移（FAILOVER_ENABLED=false）的规则不得认领状态行"
    h_check_eq "1" "$(_sync_pair_count "$dir/health_status.conf" 2 "$_GATE_TARGET")" \
        "场景B：★这一行必须归被监控的 RULE_ID=2（ENABLED=true + FAILOVER_ENABLED=true）"

    # ── 场景 C：门槛 · ENABLED=false 的规则不得认领 ──
    dir=$(_gate_setup c \
        "rule-1.conf:1:18443:1.2.3.4:8080|ENABLED=false" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
99|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    _sync_run_migration "$tree" "$dir/rules" "$dir/health_status.conf"
    rows=$(_gate_rows "$dir/health_status.conf")
    h_log "场景C 迁移后：行数=$rows 内容=$(grep -v '^#' "$dir/health_status.conf" | tr '\n' ' ')"
    h_check_eq "1" "$rows" "场景C：迁移后必须仍是 1 行（不许丢行）"
    h_check_eq "0" "$(_sync_pair_count "$dir/health_status.conf" 1 "$_GATE_TARGET")" \
        "场景C：★已停用（ENABLED=false）的规则不得认领状态行"
    h_check_eq "1" "$(_sync_pair_count "$dir/health_status.conf" 2 "$_GATE_TARGET")" \
        "场景C：★这一行必须归被监控的 RULE_ID=2"

    # ── 场景 D：门槛 · RULE_ROLE=2 的规则不得认领 ──
    #   老实现对 ROLE≠1 会走 FORWARD_TARGET 匹配分支并认领这一行 ⇒ 老实现判红。
    dir=$(_gate_setup d \
        "rule-1.conf:1:18443:1.2.3.4:8080|RULE_ROLE=2;FORWARD_TARGET=${_GATE_TARGET}" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
99|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    _sync_run_migration "$tree" "$dir/rules" "$dir/health_status.conf"
    rows=$(_gate_rows "$dir/health_status.conf")
    h_log "场景D 迁移后：行数=$rows 内容=$(grep -v '^#' "$dir/health_status.conf" | tr '\n' ' ')"
    h_check_eq "1" "$rows" "场景D：迁移后必须仍是 1 行（不许丢行）"
    h_check_eq "0" "$(_sync_pair_count "$dir/health_status.conf" 1 "$_GATE_TARGET")" \
        "场景D：★角色 2（服务端服务器）不被健康检查监控，不得认领状态行"
    h_check_eq "1" "$(_sync_pair_count "$dir/health_status.conf" 2 "$_GATE_TARGET")" \
        "场景D：★这一行必须归被监控的 RULE_ID=2"

    # ── 场景 E：回退腿（老规则号已消失）──
    dir=$(_gate_setup e \
        "rule-1.conf:1:18443:1.2.3.4:8080" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
99|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    _sync_run_migration "$tree" "$dir/rules" "$dir/health_status.conf"
    h_log "场景E 迁移后：行数=$(_gate_rows "$dir/health_status.conf") 内容=$(grep -v '^#' "$dir/health_status.conf" | tr '\n' ' ')"
    h_check_eq "1" "$(_gate_rows "$dir/health_status.conf")" \
        "场景E：回退腿 —— 老规则号消失后这一行必须跟到某条规则（不许丢行）"
    h_check_eq "1" "$(_sync_pair_count "$dir/health_status.conf" 1 "$_GATE_TARGET")" \
        "场景E：回退腿 —— 行必须归到未认领的候选（这里是 RULE_ID=1）"
    h_check_eq "3" "$(_sync_fail_count "$dir/health_status.conf" 1 "$_GATE_TARGET")" \
        "场景E：回退腿 —— 跟过去的行必须**原样保留** fail_count=3（不许归零）"

    # ── 场景 F：回退腿必须挑「未认领」的候选 ──
    #   第 1 行 old_rule_id=1 → 身份优先归 RULE_ID=1；
    #   第 2 行 old_rule_id=99 → 只能回退，而 (1,目标) 已被认领 ⇒ 必须挑 RULE_ID=2。
    #   若「已认领」判定失效 ⇒ 第 2 行也归 RULE_ID=1 ⇒ 出现重复 (RULE_ID,TARGET) ⇒ 判红。
    dir=$(_gate_setup f \
        "rule-1.conf:1:18443:1.2.3.4:8080" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
99|${_GATE_TARGET}|failed|7|0|1700000000|0|40|40
EOF
    _sync_run_migration "$tree" "$dir/rules" "$dir/health_status.conf"
    rows=$(_gate_rows "$dir/health_status.conf")
    dups=$(_gate_dups "$dir/health_status.conf")
    h_log "场景F 迁移后：行数=$rows 重复=[${dups:-无}] 内容=$(grep -v '^#' "$dir/health_status.conf" | tr '\n' ' ')"
    h_check_eq "2" "$rows" "场景F：两行 → 迁移后必须 2 行"
    h_check_eq "1" "$(_sync_pair_count "$dir/health_status.conf" 1 "$_GATE_TARGET")" \
        "场景F：★RULE_ID=1 只许拿 1 行（已认领过的 (RULE_ID,目标) 不得再被认领）"
    h_check_eq "1" "$(_sync_pair_count "$dir/health_status.conf" 2 "$_GATE_TARGET")" \
        "场景F：★第 2 行必须落到还没认领过的 RULE_ID=2"
    h_check_eq "" "$dups" "场景F：不得出现重复 (RULE_ID,TARGET)"
    h_check_eq "3" "$(_sync_fail_count "$dir/health_status.conf" 1 "$_GATE_TARGET")" \
        "场景F：RULE_ID=1 拿的必须是 fail_count=3 那一行"
    h_check_eq "7" "$(_sync_fail_count "$dir/health_status.conf" 2 "$_GATE_TARGET")" \
        "场景F：RULE_ID=2 拿的必须是 fail_count=7 那一行"

    # ── 判定器自检：断言必须「有牙齿」（否则上面几条恒真 = 假绿）──
    local probe="$SBX_ROOT/sync/gate_probe.conf"
    mkdir -p "$SBX_ROOT/sync" 2>/dev/null
    cat > "$probe" <<EOF
# Realm健康状态文件
1|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    h_check_eq "1" "$(_sync_pair_count "$probe" 1 "$_GATE_TARGET")" \
        "判定器自检：造出「RULE_ID=1 占了一行」时，判定器必须数到 1 行（否则上面的「不得认领」断言恒真）"
    cat > "$probe" <<EOF
# Realm健康状态文件
1|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
1|${_GATE_TARGET}|failed|7|0|1700000000|0|40|40
EOF
    h_check_eq "2" "$(_sync_pair_count "$probe" 1 "$_GATE_TARGET")" \
        "判定器自检：造出「RULE_ID=1 占两行」时，字段级计数必须数到 2（否则场景F 的断言恒真）"
    h_check_eq "1|${_GATE_TARGET}" "$(_gate_dups "$probe")" \
        "判定器自检：造出重复组合时，重复判定器必须抓到（否则场景F 的「无重复」断言恒真）"
}

# ══════════════════════════════════════════════════════════════════
# T116 · 负向对照：真实旧实现（75379aa）在 A/B/C/D/F 上必须给出**相反**结论
#
#   老实现（84fe096^）的三处缺陷正好被 T115 的五个判别力场景咬住：
#     ① 没有身份优先        → 场景A：两行都归同一条规则（重复组合）
#     ② 门槛只有 ROLE=1     → 场景B/C/D：被禁规则抢走被监控规则的行
#     ③ 没有「已认领」判定  → 场景F：第 2 行也归 RULE_ID=1（重复组合）
#
#   ★ 老实现的门槛里**没有** ENABLED / FAILOVER_ENABLED ⇒ B/C 一定判红；
#     D 靠 ROLE≠1 的 FORWARD_TARGET 分支 ⇒ 也判红。
#   ★ 结论相反的形态是**结构性相反**（行归属不同 / 出现重复），
#     不是靠行数差异 —— 行数两边都是 2，用行数当判据会两边都绿。
# ══════════════════════════════════════════════════════════════════
case_T116_sync_gate_and_identity_negative_control_old_impl() {
    h_case_begin "T116" "负向对照：真实旧实现（$_GATE_PRE_SHA）在场景 A/B/C/D/F 上必须给出与当前实现**相反**的结论" \
        "冻结态历史对象 $_GATE_PRE_SHA 的 lib/（真实旧实现，不用 sed 人造破坏）" \
        "同一套场景与判定器跑旧实现 vs 当前实现，比对**归属摘要**" \
        "旧实现：身份不优先 + 门槛只有 ROLE=1 + 无已认领判定 ⇒ A/B/C/D/F 全部判红"

    if ! git -C "$SBX_REPO" cat-file -e "${_GATE_PRE_SHA}^{commit}" 2>/dev/null; then
        h_fail "负向对照取不到历史实现：历史对象 $_GATE_PRE_SHA 不在本地对象库"
        h_fail "→ 修法1：在 tests/cases/00_common.sh 的 sbx_required_history_shas 里登记 sync-pre"
        h_fail "→ 修法2：把对象拉进本地库（git fetch --tags origin，或不用 --single-branch 重新克隆）"
        return
    fi
    h_log "负向对照用的历史实现: $_GATE_PRE_SHA"

    local oldtree tree
    oldtree=$(_sync_old_tree "$_GATE_PRE_SHA") || { h_fail "搭不出旧实现的产品树（取不到 $_GATE_PRE_SHA:lib/rules.sh）—— 对照跑不起来等于没在证明"; return; }
    tree=$(_sync_current_tree) || { h_fail "取不到当前冻结点的 lib/"; return; }

    local dir_o dir_c st old cur

    # ── 场景 A：身份优先 ──
    st="$SBX_ROOT/sync/st_a.conf"
    mkdir -p "$SBX_ROOT/sync" 2>/dev/null
    cat > "$st" <<EOF
# Realm健康状态文件
1|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
2|${_GATE_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    dir_o=$(_gate_setup na_old \
        "rule-1.conf:2:18443:1.2.3.4:8080" \
        "rule-2.conf:1:18444:1.2.3.4:8080")
    dir_c=$(_gate_setup na_cur \
        "rule-1.conf:2:18443:1.2.3.4:8080" \
        "rule-2.conf:1:18444:1.2.3.4:8080")
    cp -f "$st" "$dir_o/health_status.conf"
    cp -f "$st" "$dir_c/health_status.conf"
    old=$(_gate_probe "$oldtree" "$dir_o/rules" "$dir_o/health_status.conf")
    cur=$(_gate_probe "$tree" "$dir_c/rules" "$dir_c/health_status.conf")
    h_log "场景A 旧实现归属摘要: $old"
    h_log "场景A 当前实现归属摘要: $cur"
    h_check_eq "2|0|-|2|3" "$old" \
        "负向对照 A：旧实现（$_GATE_PRE_SHA）两行都归 RULE_ID=2（RULE_ID=1 一行都没拿到）⇒ 身份优先缺失"
    h_check_eq "2|1|3|1|5" "$cur" \
        "场景A（当前实现）：RULE_ID=1 拿 fail_count=3、RULE_ID=2 拿 fail_count=5 ⇒ 身份优先生效"

    # ── 场景 B：门槛 · FAILOVER_ENABLED=false ──
    st="$SBX_ROOT/sync/st_b.conf"
    cat > "$st" <<EOF
# Realm健康状态文件
99|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    dir_o=$(_gate_setup nb_old \
        "rule-1.conf:1:18443:1.2.3.4:8080|FAILOVER_ENABLED=false" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    dir_c=$(_gate_setup nb_cur \
        "rule-1.conf:1:18443:1.2.3.4:8080|FAILOVER_ENABLED=false" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cp -f "$st" "$dir_o/health_status.conf"
    cp -f "$st" "$dir_c/health_status.conf"
    old=$(_gate_probe "$oldtree" "$dir_o/rules" "$dir_o/health_status.conf")
    cur=$(_gate_probe "$tree" "$dir_c/rules" "$dir_c/health_status.conf")
    h_log "场景B 旧实现归属摘要: $old"
    h_log "场景B 当前实现归属摘要: $cur"
    h_check_eq "1|1|3|0|-" "$old" \
        "负向对照 B：旧实现让 FAILOVER_ENABLED=false 的 RULE_ID=1 抢走了状态行 ⇒ 门槛缺失"
    h_check_eq "1|0|-|1|3" "$cur" \
        "场景B（当前实现）：没开故障转移的 RULE_ID=1 不得认领，行归 RULE_ID=2"

    # ── 场景 C：门槛 · ENABLED=false ──
    st="$SBX_ROOT/sync/st_c.conf"
    cat > "$st" <<EOF
# Realm健康状态文件
99|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    dir_o=$(_gate_setup nc_old \
        "rule-1.conf:1:18443:1.2.3.4:8080|ENABLED=false" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    dir_c=$(_gate_setup nc_cur \
        "rule-1.conf:1:18443:1.2.3.4:8080|ENABLED=false" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cp -f "$st" "$dir_o/health_status.conf"
    cp -f "$st" "$dir_c/health_status.conf"
    old=$(_gate_probe "$oldtree" "$dir_o/rules" "$dir_o/health_status.conf")
    cur=$(_gate_probe "$tree" "$dir_c/rules" "$dir_c/health_status.conf")
    h_log "场景C 旧实现归属摘要: $old"
    h_log "场景C 当前实现归属摘要: $cur"
    h_check_eq "1|1|3|0|-" "$old" \
        "负向对照 C：旧实现让 ENABLED=false 的 RULE_ID=1 抢走了状态行 ⇒ 门槛缺失"
    h_check_eq "1|0|-|1|3" "$cur" \
        "场景C（当前实现）：已停用的 RULE_ID=1 不得认领，行归 RULE_ID=2"

    # ── 场景 D：门槛 · RULE_ROLE=2 ──
    st="$SBX_ROOT/sync/st_d.conf"
    cat > "$st" <<EOF
# Realm健康状态文件
99|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    dir_o=$(_gate_setup nd_old \
        "rule-1.conf:1:18443:1.2.3.4:8080|RULE_ROLE=2;FORWARD_TARGET=${_GATE_TARGET}" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    dir_c=$(_gate_setup nd_cur \
        "rule-1.conf:1:18443:1.2.3.4:8080|RULE_ROLE=2;FORWARD_TARGET=${_GATE_TARGET}" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cp -f "$st" "$dir_o/health_status.conf"
    cp -f "$st" "$dir_c/health_status.conf"
    old=$(_gate_probe "$oldtree" "$dir_o/rules" "$dir_o/health_status.conf")
    cur=$(_gate_probe "$tree" "$dir_c/rules" "$dir_c/health_status.conf")
    h_log "场景D 旧实现归属摘要: $old"
    h_log "场景D 当前实现归属摘要: $cur"
    h_check_eq "1|1|3|0|-" "$old" \
        "负向对照 D：旧实现让角色 2 的 RULE_ID=1 抢走了状态行 ⇒ 门槛缺失"
    h_check_eq "1|0|-|1|3" "$cur" \
        "场景D（当前实现）：角色 2 不被健康检查监控，不得认领，行归 RULE_ID=2"

    # ── 场景 F：回退腿必须挑未认领的候选 ──
    st="$SBX_ROOT/sync/st_f.conf"
    cat > "$st" <<EOF
# Realm健康状态文件
1|${_GATE_TARGET}|failed|3|0|1700000000|0|12|12
99|${_GATE_TARGET}|failed|7|0|1700000000|0|40|40
EOF
    dir_o=$(_gate_setup nf_old \
        "rule-1.conf:1:18443:1.2.3.4:8080" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    dir_c=$(_gate_setup nf_cur \
        "rule-1.conf:1:18443:1.2.3.4:8080" \
        "rule-2.conf:2:18444:1.2.3.4:8080")
    cp -f "$st" "$dir_o/health_status.conf"
    cp -f "$st" "$dir_c/health_status.conf"
    old=$(_gate_probe "$oldtree" "$dir_o/rules" "$dir_o/health_status.conf")
    cur=$(_gate_probe "$tree" "$dir_c/rules" "$dir_c/health_status.conf")
    h_log "场景F 旧实现归属摘要: $old"
    h_log "场景F 当前实现归属摘要: $cur"
    h_check_eq "2|2|3|0|-" "$old" \
        "负向对照 F：旧实现两行都归 RULE_ID=1（没有已认领判定）⇒ 重复组合"
    h_check_eq "2|1|3|1|7" "$cur" \
        "场景F（当前实现）：第 2 行落到还没认领过的 RULE_ID=2"

    # ── 反向自检：把旧实现侧的结论换成「与当前实现相同」后，判定必须判「相同」 ──
    #   （证明上面用的是**结论比对**，不是恒真：真的给一个「两边一致」的结果时必须报出来）
    local fake_same="$cur"
    h_check_eq "0" "$(_gate_differs "$fake_same" "$cur")" \
        "反向自检：把旧实现侧结论换成与当前实现相同后，判定必须判「相同」（否则上面的判别力是恒真）"
    h_check_eq "1" "$(_gate_differs "$old" "$cur")" \
        "反向自检：真实的两侧结论必须被判「不同」（与上一条一起证明判定器有牙齿）"
}
