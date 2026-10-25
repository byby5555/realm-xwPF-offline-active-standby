#!/bin/bash
# 用例组 24 · T114 读端「同 target 两行塌缩」
#
# ── 这条守什么 ────────────────────────────────────────────────
#   读端 lib/realm.sh 的 generate_endpoints_from_rules 读健康状态文件时，
#   建的 map 键**必须带 RULE_ID**（组合键 = RULE_ID|目标）：
#       health_status["${_row_rule_id}|${_row_target}"]="$_row_status"
#   ⇒ **两条规则共用同一个后端 host:port** 时，状态文件里该 target 有两行
#     （写端按「归属规则|目标」各写一行），读端必须**各读各的**：
#       · 真挂了的那条规则**要切**（该切不切 = 最危险的静默失效）
#       · 明明健康的那条规则**不能被拖着切**（不该切却切）
#   ★ 组合键那笔修复（63fc923）落在读端 lib/realm.sh：
#     修复前建键只有目标地址 ⇒ 同一后端两行**塌成一行**（后写覆盖先写）
#     ⇒ 两条规则读到同一个 status ⇒ 双向误切。
#
# ── 当前冻结点的形态（2026-10-25 实测）────────────────────────
#   读端**已修**（组合键）⇒ 本条是**回归用例**，预期**绿**。
#   ★ 曾有一版把本条标成「预期红（已知缺陷未修）」—— 那是**标反了**：
#     台架的 h_case_expect_fail 机制当场判红提醒「声明预期红却判绿了」。
#     本条**不得**再声明 h_case_expect_fail；缺陷若将来复现，本条会**自己变红**。
#
# ── 断言纪律（审稿第 18 次修订）────────────────────────────────
#   ① 钉「**主位 ↔ 备位**」这个关系（主位权重 = 0 ⇔ 已切到备位），
#      **不钉** "roundrobin: 1, 0" 这类字面量。
#   ② **多组对照**：只让一个变量不同（该 target 有没有第二行 / 那行是什么 status）
#      ⇒ 差异**只能**来自读端塌缩。
#   ③ 判据落在**产出物**上（generate_endpoints_from_rules 的输出里那个 endpoint
#      的权重序列第一个权重），不是「脚本退出码就算过」。
#   ④ **抽取失败要和「值真的不存在」区分开**：提取不到时打印明确标记
#      `«提取失败»`，并且这种提取失败**必须判红**（不能长得像结论 ⇒ 假阴性）。
#   ⑤ **负向对照**：同一套场景、同一套判定器，跑修复前的**真实旧实现**
#      （readend-pre = 63b6ec9，读端建键不含 RULE_ID）必须**判红**
#      ⇒ 证明坏情况确实发生、这条用例有牙齿。
#
# ── 场景（照审稿 A-16.3 的复现脚本）──────────────────────────
#   rule-1  监听 18443  目标 1.2.3.4(主)+5.6.7.8(备)   FAILURE_THRESHOLD=2
#   rule-2  监听 18444  目标 1.2.3.4(主)+9.10.11.12(备) FAILURE_THRESHOLD=5
#   ★ 两条规则**共用主目标 1.2.3.4:8080**
#
# ── 复用（跨用例组复用同族 helper，避免同一段逻辑写两遍）────────
#   _n8_gen_with   (cases/18) 读端跑 generate_endpoints_from_rules
#   _n8_weights    (cases/18) 从产出物里取「目标=权重」映射
#   两个都在 tests/cases/*.sh 被 source 之后才运行 ⇒ 字典序 18 < 24 ⇒ 可用。

# ── 造两条规则（各一个端口组，共用主目标 1.2.3.4:8080）────────────
#   ★ 规则必须写全官方键集：read_rule_file 会 unset 掉所有键再解析，
#     少一个键 → set -u 下致命中断（见 00_common.sh 的说明）。
_t114_make_rules() {
    local dir="$1"
    rm -f "$dir"/rule-*.conf 2>/dev/null
    mkdir -p "$dir"
    cat > "$dir/rule-1.conf" <<'EOF'
RULE_ID=1
RULE_ROLE=1
RULE_NAME=t114-rule-1
SECURITY_LEVEL=none
LISTEN_PORT=18443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=1.2.3.4,5.6.7.8
REMOTE_PORT=8080
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
    cat > "$dir/rule-2.conf" <<'EOF'
RULE_ID=2
RULE_ROLE=1
RULE_NAME=t114-rule-2
SECURITY_LEVEL=none
LISTEN_PORT=18444
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=1.2.3.4,9.10.11.12
REMOTE_PORT=8080
ENABLED=true
BALANCE_MODE="active-standby"
TARGET_STATES=""
WEIGHTS="10,0"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="5"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="10"
RECOVERY_COOLDOWN="120"
EOF
}

# 取真实旧实现的 lib/ 文件树（只用 git show <sha>:<path>）
#   用法：_t114_prepare_tree <sha> <dest>
#   ★ 老树的 lib/rules.sh 用 BASH_SOURCE 相对路径引 health.sh ⇒ 整棵树自包含，
#     可以独立执行（负向对照要真的把老读端跑起来，不是只 grep 文本）。
#   ★★ 必须走**沙箱同一条路径重定向**（sbx_redirect）：
#     老树里写死的是**生产路径**（/etc/realm/rules 等），不重定向的话：
#       ① 它去读真实系统目录 —— Linux 上就是生产目录 ⇒ **越界**；
#       ② 读不到沙箱里的 fixture ⇒ 读端**静默返回空** ⇒ 对照静默失效
#          （实测：不重定向时老实现输出 0 行、退出码 0，看不出任何异常）。
_t114_prepare_tree() {
    local sha="$1" dest="$2" f raw
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
    [ -f "$dest/lib/core.sh" ] || return 1
    [ -f "$dest/lib/realm.sh" ] || return 1
    return 0
}

# 某监听口的**主位权重**（balance 权重序列的第一个 = 主位）
#   用法：_t114_primary_weight <lib 根> <监听端口>
#   ★ 提取不到 ⇒ 打印明确标记 «提取失败» 并返回 1（**不返回 0、也不返回空**）
#     —— 返回空会让「提取不到」长得像「值就是 0」⇒ 假阴性。
_t114_primary_weight() {
    local libroot="$1" lp="$2" out pair first w
    out=$(_n8_gen_with "$libroot")
    pair=$(_n8_weights "$out" "$lp")
    if [ -z "$pair" ]; then
        printf '«提取失败»'
        return 1
    fi
    first="${pair%% *}"
    case "$first" in
        *=*) w="${first##*=}" ;;
        *)   w="" ;;
    esac
    if [ -z "$w" ]; then
        printf '«提取失败»'
        return 1
    fi
    printf '%s' "$w"
    return 0
}

# 判定器：主位权重必须是 0（= 已切到备位）
#   用法：_t114_judge_switched <实测主位权重> <描述>
_t114_judge_switched() {
    local w="$1" desc="$2"
    if [ "$w" = "«提取失败»" ]; then
        printf 'FAIL\t%s：主位权重**提取失败**（«提取失败»）—— 不能当成「没切」，必须判红\n' "$desc"
        return 1
    fi
    if [ "$w" = "0" ]; then
        printf 'PASS\t%s：主位权重 = 0（已切到备位）\n' "$desc"
        return 0
    fi
    printf 'FAIL\t%s：主位权重 = %s（≠0 ⇒ 还在主位）\n' "$desc" "$w"
    return 1
}

# 判定器：主位权重必须 ≠ 0（= 还在主位，没被拖着切）
_t114_judge_not_switched() {
    local w="$1" desc="$2"
    if [ "$w" = "«提取失败»" ]; then
        printf 'FAIL\t%s：主位权重**提取失败**（«提取失败»）—— 不能当成「没切」，必须判红\n' "$desc"
        return 1
    fi
    if [ "$w" = "0" ]; then
        printf 'FAIL\t%s：主位权重 = 0（被拖到备位了）\n' "$desc"
        return 1
    fi
    printf 'PASS\t%s：主位权重 = %s（≠0 ⇒ 还在主位）\n' "$desc" "$w"
    return 0
}

# ─────────────────────────────────────────────────────────────
# T114 · 读端同 target 两行塌缩
# ─────────────────────────────────────────────────────────────
case_T114_readend_collapse_same_target_two_rows() {
    h_case_begin "T114" "读端「同 target 两行塌缩」：两条规则共用同一后端时必须各读各的 status" \
        "沙箱 rules（两条规则共用主目标 1.2.3.4:8080，阈值不同）+ 健康状态文件（3 组对照）+ 修复前的真实旧实现（负向对照）" \
        "跑读端 generate_endpoints_from_rules（不跑探测）" \
        "同 target 有第二行时两条规则不得互相吃对方的 status：该切的切、不该切的不切；同一套判定器跑修复前实现必须判红"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local j w43 w44
    mkdir -p "$rules" "$(dirname "$health")"

    # 读端要读这两个变量（_n8_gen_with 在子 shell 里跑 ⇒ 必须 export）
    export RULES_DIR="$rules"
    export HEALTH_STATUS_FILE="$health"

    _t114_make_rules "$rules"

    # ── 抽取器自检：先证明「提取失败」与「值真的不存在」分得开 ──
    #   一个不存在的监听口 ⇒ 必须返回 «提取失败»，而**不是** 0。
    w43=$(_t114_primary_weight "$SBX_RUN" 19999)
    h_log "抽取器自检 · 不存在的端口 19999 → $w43"
    h_check_eq "«提取失败»" "$w43" "抽取器自检：端口不存在时必须返回明确标记 «提取失败»（不能返回 0 —— 0 长得像「值就是 0」）"

    # ── 组 G2 · 对照组：该 target 只有一行（failed）────────────────
    #   该行归规则1 所有 ⇒ 规则1 该切且切了（主位权重 = 0）；
    #   规则2 根本没有这条记录 ⇒ 不该被它拖着切。
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|1.2.3.4:8080|failed|3|0|1700000000|1700000000|0|0
1|5.6.7.8:8080|healthy|0|3|1700000000|0|0|0
EOF
    w43=$(_t114_primary_weight "$SBX_RUN" 18443)
    w44=$(_t114_primary_weight "$SBX_RUN" 18444)
    h_log "G2 对照组（只有一行 failed）· 18443 主位权重=$w43 · 18444 主位权重=$w44"

    j=$(_t114_judge_switched "$w43" "G2 · 规则1 的主真挂了")
    h_log "G2 · 18443 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "G2 对照组：规则1 的主是 failed ⇒ 必须切到备位（主位权重 = 0）—— 这条证明读端确实按 status 决定切换"

    # ── 组 G3 · 正控：该 target 只有一行（healthy）─────────────────
    #   ⇒ 两条规则都不该切 ⇒ 两个主位权重都必须 ≠ 0。
    #   ★ 这条是**判定器有牙齿**的证明：它把「能读出 0」和「能读出非 0」区分开
    #     —— 提取器坏了（恒返回 0 / 恒返回空）时，这两条会一起露馅。
    cat > "$health" <<'EOF'
# Realm健康状态文件
2|1.2.3.4:8080|healthy|0|3|1700000000|0|0|0
2|9.10.11.12:8080|healthy|0|3|1700000000|0|0|0
EOF
    w43=$(_t114_primary_weight "$SBX_RUN" 18443)
    w44=$(_t114_primary_weight "$SBX_RUN" 18444)
    h_log "G3 正控（只有一行 healthy）· 18443 主位权重=$w43 · 18444 主位权重=$w44"

    j=$(_t114_judge_not_switched "$w43" "G3 · 规则1 的主是 healthy")
    h_log "G3 · 18443 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "G3 正控：该 target 唯一一行是 healthy ⇒ 规则1 不该被切（主位权重 ≠ 0）"
    j=$(_t114_judge_not_switched "$w44" "G3 · 规则2 的主是 healthy")
    h_log "G3 · 18444 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "G3 正控：规则2 同样不该被切（主位权重 ≠ 0）"

    # ── 组 G1 · 实验组：同 target 两行、status 不同 ────────────────
    #   ★ 这是本条的**主判据**：两组之间唯一的变量是「该 target 有没有第二行」
    #     ⇒ 差异**只能**来自读端塌缩。
    #   期望（读端按 (RULE_ID, 目标) 取时）：
    #     18443（规则1 的主真挂了）      ⇒ 该切且切了 ⇒ 主位权重 = 0
    #     18444（规则2 的主其实健康）    ⇒ 不该切        ⇒ 主位权重 ≠ 0
    #   缺陷态（键不含 RULE_ID，后读覆盖先读）：
    #     该 target 的 map 被后读的 healthy 覆盖 ⇒ 规则1 读到 healthy ⇒ **不切**
    #     ⇒ 18443 主位权重 ≠ 0 ⇒ **判红**（这就是缺陷复现）
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|1.2.3.4:8080|failed|3|0|1700000000|1700000000|0|0
1|5.6.7.8:8080|healthy|0|3|1700000000|0|0|0
2|1.2.3.4:8080|healthy|0|3|1700000000|0|0|0
2|9.10.11.12:8080|healthy|0|3|1700000000|0|0|0
EOF
    w43=$(_t114_primary_weight "$SBX_RUN" 18443)
    w44=$(_t114_primary_weight "$SBX_RUN" 18444)
    h_log "G1 实验组（同 target 两行、status 不同）· 18443 主位权重=$w43 · 18444 主位权重=$w44"

    j=$(_t114_judge_switched "$w43" "G1 · 规则1 的主真挂了")
    h_log "G1 · 18443 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "G1 实验组：规则1 的主真挂了 ⇒ 必须切到备位（主位权重 = 0）—— 不成立即读端塌缩（该切不切）"

    j=$(_t114_judge_not_switched "$w44" "G1 · 规则2 的主其实健康")
    h_log "G1 · 18444 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "G1 实验组：规则2 的主其实健康 ⇒ 不该被规则1 的 failed 拖着切（主位权重 ≠ 0）—— 不成立即读端塌缩（不该切却切）"

    # ══════════════════════════════════════════════════════════
    # 负向对照 · 同一套场景、同一套判定器，跑**修复前的真实旧实现**
    #   锚点：readend-pre = 63b6ec9（读端建 map 键**不含 RULE_ID** 的那一版）
    #   ★ 为什么必须做这一段：G1/G2/G3 全绿，只能证明「当前实现没坏」，
    #     证不了「这条断言真的有牙齿」—— 提取器恒返回 0 也能让 G1 绿。
    #     ⇒ 必须让**已知会坏的老实现**在同一场景下判红。
    #   ★ 方向：老实现下同 target 两行塌成一行（后读覆盖先读）⇒ 规则1 读到
    #     healthy ⇒ 不切 ⇒ 与主判据的期望**正好相反**（这就是「坏情况确实发生」）。
    # ══════════════════════════════════════════════════════════
    local pre_sha pre_tree pre_w43
    pre_sha=$(sbx_history_sha readend-pre 2>/dev/null || true)
    [ -n "$pre_sha" ] || pre_sha="63b6ec9"
    h_log "负向对照 · 修复前冻结点 = $pre_sha"
    h_check_eq "yes" "$(cd "$SBX_REPO" && git cat-file -e "$pre_sha^{commit}" 2>/dev/null && echo yes || echo no)" \
        "负向对照自检 · 修复前冻结点 $pre_sha 在本克隆里可达（对象缺失时对照会静默失效）"

    pre_tree="$SBX_ROOT/t114_readend_pre"
    if _t114_prepare_tree "$pre_sha" "$pre_tree"; then
        # 形态自检：换进来的确实是**缺陷版**（建键不含 RULE_ID）
        local pre_combo pre_plain
        pre_combo=$(grep -cF 'health_status["${_row_rule_id}|' "$pre_tree/lib/realm.sh" 2>/dev/null || true)
        pre_plain=$(grep -cF 'health_status["$_row_target"]' "$pre_tree/lib/realm.sh" 2>/dev/null || true)
        h_log "负向对照自检 · 老树建键形态：组合键 $pre_combo 处 / 裸目标键 $pre_plain 处"
        h_check_eq "0" "$pre_combo" "负向对照自检 · 修复前实现的建键**不含** RULE_ID（组合键出现次数必须为 0）"
        h_check_ge "1" "$pre_plain" "负向对照自检 · 修复前实现确实按裸目标地址建键（否则锚点选错，对照会失效）"

        # 同一套场景、同一套判定器，跑老实现 ⇒ 必须判红（没切 ⇒ 该切不切）
        pre_w43=$(_t114_primary_weight "$pre_tree" 18443)
        h_log "负向对照 · 老实现下 18443 主位权重=$pre_w43（当前实现=$w43）"
        j=$(_t114_judge_not_switched "$pre_w43" "负向对照 · 修复前实现")
        h_log "负向对照 · 18443 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
        h_check_contains "$j" "PASS" "负向对照：修复前的真实旧实现（同 target 两行塌缩）必须**不切**（主位权重 ≠ 0）—— 证明这条用例真的有牙齿（坏情况确实发生）"

        # ★ 差异对照：老实现与当前实现的结果必须**不一样**
        #   （一样 ⇒ 说明老实现也判绿了 ⇒ 锚点选错或对照根本没跑 ⇒ 判红）
        local diff_ne
        diff_ne=$([ "$w43" != "$pre_w43" ] && echo 1 || echo 0)
        h_check_eq "1" "$diff_ne" "负向对照差异对照：修复前实现的主位权重必须与当前实现不同（当前=$w43 / 老实现=$pre_w43）"
    else
        h_fail "负向对照失败：没能从 $pre_sha 取出老实现的 lib 树 ⇒ 对照静默失效（锚点不可达或该树没有 lib/）"
        return 1
    fi
}
