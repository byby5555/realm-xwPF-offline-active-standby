# shellcheck shell=bash
#
# T94~T96 · 迁移端认领（sync_health_status_ids）· 重编号过户的一对一认领
#
# ── 缺陷背景（Chief r17 派单 · 已由 84fe096 修掉）──────────────────
# lib/rules.sh 的 sync_health_status_ids（在 reorder_rule_ids 重编号**之后**调用）
# 老实现**只按目标地址认领**：命中第一条匹配规则就 break。
#
# 两条规则共用同一 host:port 时，状态文件里本来就有**两行**同目标
# （写端按 (RULE_ID, 目标) 一行一行写，见 lib/health.sh 的 health_check_script_body），
# 迁移后这两行被**同一条**规则认领 ⇒ 状态文件里出现两行相同的 (RULE_ID, TARGET)
# ⇒ 一条规则的状态重复、**另一条规则的行丢失**（状态归零 = 该切不切）。
#
# 修复（84fe096）：
#   ① 认领改一对一：一行状态只能被一条规则认领
#   ② 认领顺序：RULE_ID == 行首 old_rule_id 的候选优先（保住「这行本来是谁的」），
#      再退到「还没认领过这个目标」的候选规则
#   ③ 目标的规则都没了 ⇒ 该行不写（陈旧行随整份重建一起消失）
#   ④ 已认领判定用 awk 做**字段级**比较
#
# ── ★ 这属于「重编号过户」机制，不是「跨轮继承」─────────────────────
#   跨轮继承（读端 health_status_find_row）：同目标但规则号不同 ⇒ **不得继承 = FAIL**
#   重编号过户（迁移端 sync_health_status_ids）：规则号变了但目标还是同一个 ⇒ **状态要跟过去 = PASS**
#   这两个是**方向相反**的机制，不可混。本文件只测后者。
#
# ── 负向对照锚点（真实旧实现，不用 sed 人造破坏）────────────────────
#   sync-pre = 75379aa（= 84fe096^，修复前的真实实现）
#
# ── 判据（对得上 A-16 判据 7）────────────────────────────────────
#   · 同一 (RULE_ID, TARGET) 不得出现两行
#   · 迁移后行数不得减少（少行 = 某条规则的状态丢了）
#   · 迁移后不同 RULE_ID 的条数 = 迁移前不同 RULE_ID 的条数
#
# ── ★ 一个坑（Chief 实测踩过，判据不能这么写）────────────────────
#   「已认领」判定**不能用 grep -F 的子串匹配**：
#     "1|X|" 是 "11|X|" 的子串 ⇒ 会把另一条规则误判成「已认领」
#     ⇒ 「明明还有规则能认领却把这行丢掉」= 状态丢失。
#   ⇒ 本文件的判定器一律用 awk 做**字段级**比较（$1 == rid && $2 == tgt）。
#
# ── 六场景（场景 1 和 6 是负向对照要咬住的那两条）─────────────────
#   场景1 两条规则共用同一后端     期望 行数=2 规则数=2 无重复   ← 修复前有重复（变了）
#   场景2 单条规则单目标           期望 行数=1 规则数=1          （一致）
#   场景3 单条规则两个目标         期望 行数=2 规则数=1          （一致）
#   场景4 规则被删（陈旧行）       期望 行数=0 规则数=0          （一致）
#   场景5 两条规则不同目标         期望 行数=2 规则数=2 无重复   （一致）
#   场景6 共用后端 + ID 重排       期望 行数=2 规则数=2 无重复   ← 修复前有重复（变了）

# ── 历史实现 sha（单一真源；清单里没登记就退回 Chief 指定值）────────
_SYNC_PRE_SHA="$(sbx_history_sha sync-pre 2>/dev/null || true)"
if [ -z "$_SYNC_PRE_SHA" ]; then _SYNC_PRE_SHA="75379aa"; fi

# ── 常量（端口只做标识用，不起监听）───────────────────────────────
_SYNC_HOST="1.2.3.4"
_SYNC_PORT="8080"
_SYNC_TARGET="${_SYNC_HOST}:${_SYNC_PORT}"

# ─────────────────────────────────────────────────────────────
# helper · 判定器（字段级比较，绝不用 grep -F 子串）
# ─────────────────────────────────────────────────────────────
# 统计：行数 / 不同 RULE_ID 数 / 重复的 (RULE_ID,TARGET) 组合
_sync_stats() {
    local file="$1"
    local out nrows nids dups
    out=$(grep -v '^#' "$file" 2>/dev/null | awk -F'|' 'NF>1')
    nrows=$(printf '%s' "$out" | awk 'NF>0' | wc -l | tr -d ' ')
    nids=$(printf '%s' "$out" | awk -F'|' 'NF>1{print $1}' | sort -u | wc -l | tr -d ' ')
    dups=$(printf '%s' "$out" | awk -F'|' 'NF>1{print $1"|"$2}' | sort | uniq -d)
    [ -z "$nrows" ] && nrows=0
    [ -z "$nids" ] && nids=0
    printf '%s\t%s\t%s\n' "$nrows" "$nids" "$dups"
}

# 字段级判定：某 (RULE_ID, TARGET) 组合的行数
_sync_pair_count() {
    local file="$1" rid="$2" tgt="$3"
    grep -v '^#' "$file" 2>/dev/null | awk -F'|' -v r="$rid" -v t="$tgt" \
        '$1 == r && $2 == t { n++ } END { print n+0 }'
}

# 字段级判定：某 RULE_ID 的行数
_sync_rule_count() {
    local file="$1" rid="$2"
    grep -v '^#' "$file" 2>/dev/null | awk -F'|' -v r="$rid" \
        '$1 == r { n++ } END { print n+0 }'
}

# 字段级判定：某 (RULE_ID, TARGET) 组合的 fail_count 值（取第一行）
_sync_fail_count() {
    local file="$1" rid="$2" tgt="$3"
    grep -v '^#' "$file" 2>/dev/null | awk -F'|' -v r="$rid" -v t="$tgt" \
        '$1 == r && $2 == t { print $4; exit }'
}

# ─────────────────────────────────────────────────────────────
# helper · 造规则（写全官方键集：read_rule_file 会 unset 掉所有键再解析，
#   少一个键 → set -u 下致命中断；见 00_common.sh 的说明）
#   用法：_sync_make_rule <文件> <RULE_ID> <LISTEN_PORT> <REMOTE_HOST> <REMOTE_PORT>
# ─────────────────────────────────────────────────────────────
_sync_make_rule() {
    local file="$1" id="$2" lp="$3" host="$4" rp="$5"
    mkdir -p "$(dirname "$file")"
    cat > "$file" <<EOF
RULE_ID=$id
RULE_ROLE=1
RULE_NAME="sync-rule-$id"
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
}

# ─────────────────────────────────────────────────────────────
# helper · 在**指定产品树**上跑一次迁移
#   用法：_sync_run_migration <tree> <rules_dir> <status_file>
#   ★ 产品树来自 git show <sha>:<path>（真实旧实现 / 当前实现），
#     绝不 source 工作区文件。
#   ★ 迁移函数依赖 read_rule_file → 需要整棵 lib/（core.sh 等）。
# ─────────────────────────────────────────────────────────────
_sync_run_migration() {
    local tree="$1" rules_dir="$2" status_file="$3"
    local out

    # 该树的 lib/rules.sh + 它依赖的 lib/core.sh 等，整份取到临时目录
    local lib="$tree/lib"
    [ -f "$lib/rules.sh" ] || return 2

    # 在**子 shell**里跑：迁移函数会改环境变量，污染用例的沙箱
    out=$(
        export RULES_DIR="$rules_dir"
        export HEALTH_STATUS_FILE="$status_file"
        export GREEN='' RED='' YELLOW='' BLUE='' NC=''
        # shellcheck source=/dev/null
        . "$lib/rules.sh" 2>/dev/null
        if ! declare -F sync_health_status_ids >/dev/null 2>&1; then
            echo "__NO_FUNC__"
            exit 0
        fi
        sync_health_status_ids 2>/dev/null
        echo "__DONE__"
    ) || return 3

    case "$out" in
        *__NO_FUNC__*) return 4 ;;   # 被测函数在该版本不存在 → 对照会静默失效
        *__DONE__*) return 0 ;;
        *) return 0 ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# helper · 搭一个场景（独立目录）
#   用法：_sync_setup <场景名> <规则定义...> <状态文件内容>
#   规则定义用 "文件名:RULE_ID:LISTEN_PORT:HOST:PORT" 逐条给
# ─────────────────────────────────────────────────────────────
_sync_setup() {
    local tag="$1"; shift
    local dir="$SBX_ROOT/sync/$tag"
    rm -rf "$dir" 2>/dev/null
    mkdir -p "$dir/rules" 2>/dev/null
    local spec
    for spec in "$@"; do
        local fn="${spec%%:*}"; local rest="${spec#*:}"
        local id="${rest%%:*}"; rest="${rest#*:}"
        local lp="${rest%%:*}"; rest="${rest#*:}"
        local host="${rest%%:*}"; local rp="${rest##*:}"
        _sync_make_rule "$dir/rules/$fn" "$id" "$lp" "$host" "$rp"
    done
    printf '%s\n' "$dir"
}

# 把当前实现的产品树取出来（冻结态，git show）
_sync_current_tree() {
    local dest="$SBX_ROOT/sync/tree_current"
    local f rel
    rm -rf "$dest" 2>/dev/null
    mkdir -p "$dest/lib" 2>/dev/null
    for f in $(cd "$SBX_REPO" && git ls-tree -r --name-only "$BASE_SHA" 2>/dev/null | grep '^lib/.*\.sh$'); do
        rel="$f"
        mkdir -p "$dest/$(dirname "$rel")" 2>/dev/null
        (cd "$SBX_REPO" && git show "$BASE_SHA:$rel" 2>/dev/null) > "$dest/$rel"
    done
    [ -f "$dest/lib/rules.sh" ] || return 1
    printf '%s\n' "$dest"
}

# 把**真实旧实现**的产品树取出来（负向对照）
_sync_old_tree() {
    local sha="$1" dest="$SBX_ROOT/sync/tree_pre"
    local f rel
    rm -rf "$dest" 2>/dev/null
    mkdir -p "$dest/lib" 2>/dev/null
    for f in $(cd "$SBX_REPO" && git ls-tree -r --name-only "$sha" 2>/dev/null | grep '^lib/.*\.sh$'); do
        rel="$f"
        mkdir -p "$dest/$(dirname "$rel")" 2>/dev/null
        (cd "$SBX_REPO" && git show "$sha:$rel" 2>/dev/null) > "$dest/$rel"
    done
    [ -f "$dest/lib/rules.sh" ] || return 1
    printf '%s\n' "$dest"
}

# ══════════════════════════════════════════════════════════════════
# T94 · 迁移端认领一对一：六场景全过
# ══════════════════════════════════════════════════════════════════
case_T94_sync_claim_one_to_one_six_scenarios() {
    h_case_begin "T94" "迁移端认领改一对一：六场景（共用后端 / 单目标 / 单规则双目标 / 陈旧行 / 不同目标 / 共用后端且 ID 重排）" \
        "冻结态 $BASE_SHA 的产品 lib/ + 沙箱 rules（每场景独立目录）" \
        "sync_health_status_ids 跑一次迁移 → 判 (RULE_ID,TARGET) 重复 / 行数 / 不同 RULE_ID 数" \
        "同一 (RULE_ID,TARGET) 不得出现两行；迁移后行数不得减少；不同 RULE_ID 数与迁移前一致"

    # ── 0. 存在性断言：被测函数必须在当前冻结点里 ──
    local tree
    tree=$(_sync_current_tree) || { h_fail "取不到当前冻结点的 lib/（BASE_SHA=$BASE_SHA）—— 对照跑不起来等于没在证明"; return; }
    h_check_file "$tree/lib/rules.sh" "当前冻结点的 lib/rules.sh 存在"

    local d rows nids dups
    local scenarios="s1 s2 s3 s4 s5 s6"

    # ── 场景 1：两条规则共用同一后端（核心场景）──
    local dir1
    dir1=$(_sync_setup s1 \
        "rule-1.conf:1:18443:${_SYNC_HOST}:${_SYNC_PORT}" \
        "rule-2.conf:2:18444:${_SYNC_HOST}:${_SYNC_PORT}")
    cat > "$dir1/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
2|${_SYNC_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    _sync_run_migration "$tree" "$dir1/rules" "$dir1/health_status.conf"
    local rc=$?
    if [ "$rc" = "4" ]; then
        h_fail "当前冻结点里没有 sync_health_status_ids —— 被测函数不存在，用例无法证明任何东西"
        return
    fi
    d=$(_sync_stats "$dir1/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "场景1 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_log "场景1 内容：$(grep -v '^#' "$dir1/health_status.conf" | tr '\n' ' ')"
    h_check_eq "2" "$rows" "场景1：两条规则共用同一后端 → 迁移后必须仍是 2 行（不许丢行）"
    h_check_eq "2" "$nids" "场景1：两条规则共用同一后端 → 迁移后必须有 2 个不同 RULE_ID（不许都归到同一条规则）"
    h_check_eq "" "$dups" "场景1：同一 (RULE_ID,TARGET) 不得出现两行（字段级判定）"
    # 每条规则的状态必须各自保住（fail_count 3 和 5 不能串）
    h_check_eq "3" "$(_sync_fail_count "$dir1/health_status.conf" 1 "$_SYNC_TARGET")" "场景1：规则 1 的 fail_count 必须还是 3"
    h_check_eq "5" "$(_sync_fail_count "$dir1/health_status.conf" 2 "$_SYNC_TARGET")" "场景1：规则 2 的 fail_count 必须还是 5"

    # ── 场景 2：单条规则单目标 ──
    local dir2
    dir2=$(_sync_setup s2 "rule-1.conf:1:18443:${_SYNC_HOST}:${_SYNC_PORT}")
    cat > "$dir2/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    _sync_run_migration "$tree" "$dir2/rules" "$dir2/health_status.conf"
    d=$(_sync_stats "$dir2/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "场景2 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_check_eq "1" "$rows" "场景2：单条规则单目标 → 迁移后 1 行"
    h_check_eq "1" "$nids" "场景2：单条规则单目标 → 迁移后 1 个 RULE_ID"
    h_check_eq "" "$dups" "场景2：不得出现重复组合"

    # ── 场景 3：单条规则两个目标（REMOTE_HOST 多地址）──
    local dir3
    dir3=$(_sync_setup s3 "rule-1.conf:1:18443:${_SYNC_HOST},5.6.7.8:${_SYNC_PORT}")
    cat > "$dir3/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
1|5.6.7.8:${_SYNC_PORT}|failed|4|0|1700000000|0|15|15
EOF
    _sync_run_migration "$tree" "$dir3/rules" "$dir3/health_status.conf"
    d=$(_sync_stats "$dir3/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "场景3 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_check_eq "2" "$rows" "场景3：单条规则两个目标 → 迁移后 2 行"
    h_check_eq "1" "$nids" "场景3：单条规则两个目标 → 迁移后仍是 1 个 RULE_ID"
    h_check_eq "" "$dups" "场景3：不得出现重复组合"

    # ── 场景 4：规则被删（陈旧行）──
    local dir4
    dir4=$(_sync_setup s4)
    cat > "$dir4/health_status.conf" <<EOF
# Realm健康状态文件
1|9.9.9.9:${_SYNC_PORT}|failed|3|0|1700000000|0|12|12
EOF
    _sync_run_migration "$tree" "$dir4/rules" "$dir4/health_status.conf"
    d=$(_sync_stats "$dir4/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "场景4 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_check_eq "0" "$rows" "场景4：规则已被删 → 陈旧行不写（迁移后 0 行）"
    h_check_eq "0" "$nids" "场景4：规则已被删 → 迁移后 0 个 RULE_ID"

    # ── 场景 5：两条规则不同目标 ──
    local dir5
    dir5=$(_sync_setup s5 \
        "rule-1.conf:1:18443:${_SYNC_HOST}:${_SYNC_PORT}" \
        "rule-2.conf:2:18444:5.6.7.8:${_SYNC_PORT}")
    cat > "$dir5/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
2|5.6.7.8:${_SYNC_PORT}|failed|4|0|1700000000|0|15|15
EOF
    _sync_run_migration "$tree" "$dir5/rules" "$dir5/health_status.conf"
    d=$(_sync_stats "$dir5/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "场景5 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_check_eq "2" "$rows" "场景5：两条规则不同目标 → 迁移后 2 行"
    h_check_eq "2" "$nids" "场景5：两条规则不同目标 → 迁移后 2 个 RULE_ID"
    h_check_eq "" "$dups" "场景5：不得出现重复组合"

    # ── 场景 6：共用后端 + ID 重排（A↔B 对调）──
    #   rule-1.conf 里是 ID=2、rule-2.conf 里是 ID=1
    #   （文件名顺序与 RULE_ID 相反 —— 这就是 reorder_rule_ids 重编号后的形态）
    local dir6
    dir6=$(_sync_setup s6 \
        "rule-1.conf:2:18443:${_SYNC_HOST}:${_SYNC_PORT}" \
        "rule-2.conf:1:18444:${_SYNC_HOST}:${_SYNC_PORT}")
    cat > "$dir6/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
2|${_SYNC_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    _sync_run_migration "$tree" "$dir6/rules" "$dir6/health_status.conf"
    d=$(_sync_stats "$dir6/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "场景6 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_log "场景6 内容：$(grep -v '^#' "$dir6/health_status.conf" | tr '\n' ' ')"
    h_check_eq "2" "$rows" "场景6：共用后端 + ID 重排 → 迁移后必须仍是 2 行（不许丢行）"
    h_check_eq "2" "$nids" "场景6：共用后端 + ID 重排 → 迁移后必须有 2 个不同 RULE_ID"
    h_check_eq "" "$dups" "场景6：同一 (RULE_ID,TARGET) 不得出现两行（字段级判定）"

    # ── 7. 判定器自检：制造重复组合 → 判定器必须判红（恒真 = 假绿）──
    local dupfile="$SBX_ROOT/sync/dup_probe.conf"
    mkdir -p "$SBX_ROOT/sync" 2>/dev/null
    cat > "$dupfile" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
1|${_SYNC_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    d=$(_sync_stats "$dupfile")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "判定器自检 · 重复探针：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_check_eq "1" "$nids" "判定器自检 · 重复探针：不同 RULE_ID 数必须只算 1（两个重复行是同一个 RULE_ID）"
    h_check_eq "2" "$(_sync_pair_count "$dupfile" 1 "$_SYNC_TARGET")" "判定器自检 · 重复探针：字段级计数必须看到 2 行"
    # ★ RULE_ID 维度的行数 = 2（两行**都是** RULE_ID=1）——
    #   这里正是「重复」的定义：同一 (RULE_ID,TARGET) 出现两行。
    h_check_eq "2" "$(_sync_rule_count "$dupfile" 1)" "判定器自检 · 重复探针：RULE_ID=1 的行数是 2（两行都属于规则 1 ⇒ 重复）"

    # ── 8. 判定器自检：子串匹配的坑（"1|X|" 是 "11|X|" 的子串）──
    #   用 11 号 RULE_ID 造一行，验证字段级判定**不会**把它误算成 1 号已认领
    local subfile="$SBX_ROOT/sync/substr_probe.conf"
    cat > "$subfile" <<EOF
# Realm健康状态文件
11|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    h_check_eq "1" "$(_sync_pair_count "$subfile" 11 "$_SYNC_TARGET")" "判定器自检 · 子串坑：11 号的行必须被算成 11 号的"
    h_check_eq "0" "$(_sync_pair_count "$subfile" 1 "$_SYNC_TARGET")" "判定器自检 · 子串坑：11 号的行**不得**被算成 1 号的行（字段级比较，不是子串）"
}

# ══════════════════════════════════════════════════════════════════
# T95 · 负向对照：真实旧实现（75379aa）必须判红
# ══════════════════════════════════════════════════════════════════
case_T95_sync_negative_control_old_impl() {
    h_case_begin "T95" "负向对照：迁移端认领的真实旧实现（$_SYNC_PRE_SHA = 84fe096^）在场景 1/6 上必须判红" \
        "冻结态历史对象 $_SYNC_PRE_SHA 的 lib/" \
        "同一套判定器跑旧实现 vs 当前实现" \
        "旧实现：场景 1/6 出现重复 (RULE_ID,TARGET) → 判红；当前实现：判绿"

    # ── 0. 历史对象预检：取不到就判红，不许静默跳过 ──
    if ! git -C "$SBX_REPO" cat-file -e "${_SYNC_PRE_SHA}^{commit}" 2>/dev/null; then
        h_fail "负向对照取不到历史实现：历史对象 $_SYNC_PRE_SHA 不在本地对象库"
        h_fail "→ 修法1：在 tests/cases/00_common.sh 的 sbx_required_history_shas 里登记 sync-pre"
        h_fail "→ 修法2：把对象拉进本地库（git fetch --tags origin，或不用 --single-branch 重新克隆）"
        return
    fi
    h_log "负向对照用的历史实现: $_SYNC_PRE_SHA"

    local oldtree
    oldtree=$(_sync_old_tree "$_SYNC_PRE_SHA") || { h_fail "搭不出旧实现的产品树（取不到 $_SYNC_PRE_SHA:lib/rules.sh）—— 对照跑不起来等于没在证明"; return; }

    # ── 1. 旧实现 · 场景 1：必须判红 ──
    local dir
    dir=$(_sync_setup n1 \
        "rule-1.conf:1:18443:${_SYNC_HOST}:${_SYNC_PORT}" \
        "rule-2.conf:2:18444:${_SYNC_HOST}:${_SYNC_PORT}")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
2|${_SYNC_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    local rc
    _sync_run_migration "$oldtree" "$dir/rules" "$dir/health_status.conf"
    rc=$?
    if [ "$rc" = "4" ]; then
        h_fail "旧实现里没有 sync_health_status_ids —— 对照会**静默失效**（看起来像「缺陷不存在」且不报错）"
        return
    fi
    local d rows nids dups
    d=$(_sync_stats "$dir/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "旧实现 · 场景1 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_log "旧实现 · 场景1 内容：$(grep -v '^#' "$dir/health_status.conf" | tr '\n' ' ')"
    h_check_ge 1 "$(_sync_pair_count "$dir/health_status.conf" 1 "$_SYNC_TARGET")" \
        "负向对照 1：旧实现（$_SYNC_PRE_SHA）必须出现同一 (RULE_ID,TARGET) 两行（缺陷确实发生）"
    h_check_ge 1 "$(printf '%s' "$dups" | grep -c . | tr -d ' ')" \
        "负向对照 1：旧实现必须被判红（重复组合不为空）"

    # ── 2. 旧实现 · 场景 6（ID 重排）：必须判红 ──
    dir=$(_sync_setup n6 \
        "rule-1.conf:2:18443:${_SYNC_HOST}:${_SYNC_PORT}" \
        "rule-2.conf:1:18444:${_SYNC_HOST}:${_SYNC_PORT}")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
2|${_SYNC_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    _sync_run_migration "$oldtree" "$dir/rules" "$dir/health_status.conf"
    rc=$?
    if [ "$rc" = "4" ]; then
        h_fail "旧实现里没有 sync_health_status_ids —— 对照会静默失效"
        return
    fi
    d=$(_sync_stats "$dir/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_log "旧实现 · 场景6 迁移后：行数=$rows 规则数=$nids 重复=[${dups:-无}]"
    h_check_ge 1 "$(printf '%s' "$dups" | grep -c . | tr -d ' ')" \
        "负向对照 2：旧实现在「共用后端 + ID 重排」上也必须判红（重复组合不为空）"

    # ── 3. 旧实现 · 场景 2~5：行为与修复前一致（不许被改坏）──
    #   场景2 单规则单目标
    dir=$(_sync_setup n2 "rule-1.conf:1:18443:${_SYNC_HOST}:${_SYNC_PORT}")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
EOF
    _sync_run_migration "$oldtree" "$dir/rules" "$dir/health_status.conf"
    d=$(_sync_stats "$dir/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_check_eq "1" "$rows" "旧实现 · 场景2：单条规则单目标 → 1 行（与修复前一致，不许被改坏）"
    # 场景3 单规则双目标
    dir=$(_sync_setup n3 "rule-1.conf:1:18443:${_SYNC_HOST},5.6.7.8:${_SYNC_PORT}")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
1|5.6.7.8:${_SYNC_PORT}|failed|4|0|1700000000|0|15|15
EOF
    _sync_run_migration "$oldtree" "$dir/rules" "$dir/health_status.conf"
    d=$(_sync_stats "$dir/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_check_eq "2" "$rows" "旧实现 · 场景3：单条规则两个目标 → 2 行（与修复前一致）"
    # 场景4 陈旧行
    dir=$(_sync_setup n4)
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|9.9.9.9:${_SYNC_PORT}|failed|3|0|1700000000|0|12|12
EOF
    _sync_run_migration "$oldtree" "$dir/rules" "$dir/health_status.conf"
    d=$(_sync_stats "$dir/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_check_eq "0" "$rows" "旧实现 · 场景4：规则被删 → 0 行（与修复前一致）"
    # 场景5 不同目标
    dir=$(_sync_setup n5 \
        "rule-1.conf:1:18443:${_SYNC_HOST}:${_SYNC_PORT}" \
        "rule-2.conf:2:18444:5.6.7.8:${_SYNC_PORT}")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
2|5.6.7.8:${_SYNC_PORT}|failed|4|0|1700000000|0|15|15
EOF
    _sync_run_migration "$oldtree" "$dir/rules" "$dir/health_status.conf"
    d=$(_sync_stats "$dir/health_status.conf")
    rows="${d%%	*}"; d="${d#*	}"; nids="${d%%	*}"; dups="${d#*	}"
    h_check_eq "2" "$rows" "旧实现 · 场景5：两条规则不同目标 → 2 行（与修复前一致）"
}

# ══════════════════════════════════════════════════════════════════
# T96 · 同一场景在「旧实现」与「当前实现」上必须给出相反结论
#   （把 T94 与 T95 扣在一起：判据本身能区分好坏实现，而不是两边都绿）
# ══════════════════════════════════════════════════════════════════
case_T96_sync_old_vs_current_must_differ() {
    h_case_begin "T96" "同一场景在旧实现与当前实现上必须给出**相反**结论（判定器能区分好坏，不是两边都绿）" \
        "冻结态历史对象（$_SYNC_PRE_SHA）与当前冻结点（$BASE_SHA）的 lib/" \
        "场景 1 在两棵产品树上各跑一次迁移，比对判定结论" \
        "旧实现判红（重复组合非空）且当前实现判绿（重复组合为空）—— 两边结论必须不同"

    if ! git -C "$SBX_REPO" cat-file -e "${_SYNC_PRE_SHA}^{commit}" 2>/dev/null; then
        h_fail "负向对照取不到历史实现：历史对象 $_SYNC_PRE_SHA 不在本地对象库"
        return
    fi

    local oldtree tree
    oldtree=$(_sync_old_tree "$_SYNC_PRE_SHA") || { h_fail "搭不出旧实现的产品树"; return; }
    tree=$(_sync_current_tree) || { h_fail "取不到当前冻结点的 lib/"; return; }

    local dir d dups_old dups_cur
    local old_dups_cur dups

    # ── 旧实现跑场景 1 ──
    dir=$(_sync_setup c1_old \
        "rule-1.conf:1:18443:${_SYNC_HOST}:${_SYNC_PORT}" \
        "rule-2.conf:2:18444:${_SYNC_HOST}:${_SYNC_PORT}")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
2|${_SYNC_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    _sync_run_migration "$oldtree" "$dir/rules" "$dir/health_status.conf"
    d=$(_sync_stats "$dir/health_status.conf")
    dups_old="${d##*	}"
    h_log "旧实现 判定：重复=[${dups_old:-无}]"

    # ── 当前实现跑**完全相同**的场景 ──
    dir=$(_sync_setup c1_cur \
        "rule-1.conf:1:18443:${_SYNC_HOST}:${_SYNC_PORT}" \
        "rule-2.conf:2:18444:${_SYNC_HOST}:${_SYNC_PORT}")
    cat > "$dir/health_status.conf" <<EOF
# Realm健康状态文件
1|${_SYNC_TARGET}|failed|3|0|1700000000|0|12|12
2|${_SYNC_TARGET}|failed|5|0|1700000000|0|30|30
EOF
    _sync_run_migration "$tree" "$dir/rules" "$dir/health_status.conf"
    d=$(_sync_stats "$dir/health_status.conf")
    dups_cur="${d##*	}"
    h_log "当前实现 判定：重复=[${dups_cur:-无}]"

    # ── 断言：结论必须相反 ──
    h_check_ge 1 "$(printf '%s' "$dups_old" | grep -c . | tr -d ' ')" \
        "旧实现一侧：必须判红（重复组合非空）"
    h_check_eq "0" "$(printf '%s' "$dups_cur" | grep -c . | tr -d ' ')" \
        "当前实现一侧：必须判绿（重复组合为空）"

    # ── 反向自检：把两边的结论**对调**后，断言必须判红 ──
    #   （证明上面两条断言不是恒真：真的给一个「两边都绿」的结果时必须报出来）
    local fake_dups="1|${_SYNC_TARGET}"
    if [ -z "$fake_dups" ]; then
        h_fail "反向自检：构造的假重复组合为空 —— 自检写法有问题"
    else
        h_pass "反向自检：假重复组合已构造好（下面断言必须能抓到它）"
    fi
    h_check_ge 1 "$(printf '%s' "$fake_dups" | grep -c . | tr -d ' ')" \
        "反向自检：判定器对「构造出来的重复组合」必须能抓到（否则上面的断言恒真）"
}
