#!/bin/bash
# 用例组 12 · 健康状态 TARGET 口径（host:port）（第 7 轮收尾新增）
#
# 背景（产品改动 a7e23fc + bfc99d3，Chief 派单 N1 / N1-R1）：
#   健康状态文件第 2 字段 TARGET，从「裸 host」改成「host:port」。
#   同一个 host 上跑不同端口的目标，状态必须互不影响 ——
#   否则 A 组（端口 111）的故障会被 B 组（端口 222）的健康记录盖掉 →
#   该切不切（故障转移静默失效，流量压在已故障的主机上）。
#
#   a7e23fc：写入侧改按 host:port 落盘 + 读取侧按 host:port 建精确索引
#   bfc99d3（N1-R1）：**去掉裸 host 宽键兜底** —— 旧格式行认得出归属时只入精确键；
#                     认不出归属时**当无记录**（不再留一份会跨端口污染的宽键）
#
# 覆盖：
#   T52 健康状态 TARGET 口径：
#     ① 写侧：同 host 不同端口 → 状态文件里是两条**独立**记录（TARGET = host:port）
#     ② 读侧·跨端口组隔离：A 组的故障不被 B 组的健康盖掉
#     ③ 读侧·**同一端口组内、同 host 不同端口**（N1 缺陷真正触发的形态）：
#        旧格式输入与新格式输入的产出**必须逐项一致**
#     ④ 兼容：旧格式（TARGET 只有裸 host）——
#        归属认得出 → 按 RULE_ID 补出端口；归属认不出 → 当无记录（不判故障）
#
# ★ 第 11 轮（Chief 派单）：探测超时预算 3s -> 10s（与 cases/11_latency.sh 同源）。
#   判据上界同步放宽在 cases/11_latency.sh（时延那档）；本文件只判「记录归属」，不判时延。
# ★ fixture 的 CONNECTION_TIMEOUT **保持 3 不动**（Chief 复核口径）：
#   本文件里的 heredoc 规则是**测试夹具（输入）**，不是产品生成的规则文件 ——
#   产品把默认预算改成 10 不影响夹具；改夹具会改掉夹具语义（可能连带打乱别的断言）。
#   产品默认值那一侧的**真断言**在 cases/02_weight_active_standby.sh（读产品生成的 $rule）。
#
# ★ fixture 口径：健康状态 fixture 一律写**当前格式**（host:port）。
#   写成裸 host 的旧格式，用例会退化成「旧格式兼容兜底分支」，
#   精确索引这条主路径就没人测 —— fixture 的形态本身就是断言的一部分。
#
# ★ 负向对照的取舍：
#   「同 host 不同端口互相覆盖」这个症状，在**修复后的实现上不可达**
#   （精确键一定先命中）—— 想复现它，只能把读侧换回**修复前的真实实现**。
#   所以负向对照用的是 git 里的历史实现（不是人造的 sed 破坏 —— 人造破坏依赖代码写法，
#   改一次写法就静默失效）。取不到就判红，不静默跳过。

# ── 修复前的真实实现（只给负向对照用）──
#   f730c8b：最初的实现，读侧只用裸 host 建索引、也只按裸 host 查
#   a7e23fc：TARGET 改 host:port 之后、但仍留着一份裸 host 宽键的那一版（N1-R1 的直接前态）
#   ★ sha 来自**单一真源** tests/cases/00_common.sh 的 sbx_required_history_shas
#     （跑批前预检用同一份清单检查对象在不在本地库 → 缺对象时用退出码 3 报，
#      不会被误读成产品回归）。不要在这里写死 sha。
_T52_PREFIX_SHA="$(sbx_history_sha t52-prefix)"
_T52_PREFIX_MARK='health_status\["\$host"\]'
_T52_PRE_N1R1_SHA="$(sbx_history_sha t52-pre-n1r1)"
_T52_PRE_N1R1_MARK='health_status\["\$_row_target"\]'

# 判定器：健康状态文件里，每个期望的 TARGET 都必须**恰好出现 1 条**
# 用法：_t52_judge_targets <文件> <期望TARGET...>
# 输出："<PASS|FAIL>\t<说明>"
#
# ★ 为什么是「恰好 1 条」而不是「至少 1 条」：
#   修复前的症状是两条记录**塌成一条**（后写的覆盖先写的），
#   「至少 1 条」在这种塌缩下照样判过 —— 断言必须能区分「两条」和「一条」。
_t52_judge_targets() {
    local file="$1"
    shift
    local rows t c
    rows=$(grep -v '^#' "$file" 2>/dev/null | grep -c . | tr -d ' ')
    [ -z "$rows" ] && rows=0
    local n_exp=$#
    if [ "$rows" != "$n_exp" ]; then
        printf 'FAIL\t状态记录行数 = %s（期望 %s）\n' "$rows" "$n_exp"
        return 1
    fi
    for t in "$@"; do
        c=$(grep -cE "^[0-9]+\|${t//./\\.}\|" "$file" 2>/dev/null | tr -d ' ')
        [ -z "$c" ] && c=0
        if [ "$c" != "1" ]; then
            printf 'FAIL\tTARGET = %s 的记录有 %s 条（期望恰好 1 条）\n' "$t" "$c"
            return 1
        fi
    done
    printf 'PASS\t%s 个 TARGET 各有且仅有 1 条记录\n' "$n_exp"
    return 0
}

# 造两条规则：**同一个端口组内**、同 REMOTE_HOST、不同 REMOTE_PORT
# ★ 这才是 N1 缺陷真正触发的形态（主备的标准拓扑）：
#   一个端口组里两个目标同 host 不同端口（10.0.0.1:111 / 10.0.0.1:222）。
#   RULE_ID 必须**连续**（1/2）—— 不连续会触发 reorder_rule_ids 重排
#   （ID 被重编成 1..N 且不同步状态文件）→ 老行的 RULE_ID 失效 → 归属认不出 → 用例假绿。
# 参数：<规则目录> <BALANCE_MODE> <REMOTE_HOST> <端口1> <端口2>
_t52_make_same_group_rules() {
    local dir="$1" mode="$2" host="$3" pa="$4" pb="$5"
    rm -f "$dir"/rule-*.conf
    cat > "$dir/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=same-group-1
SECURITY_LEVEL=none
LISTEN_PORT=443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$host
REMOTE_PORT=$pa
ENABLED=true
BALANCE_MODE="$mode"
TARGET_STATES=""
WEIGHTS="10,0"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF
    cat > "$dir/rule-2.conf" <<EOF
RULE_ID=2
RULE_ROLE=1
RULE_NAME=same-group-2
SECURITY_LEVEL=none
LISTEN_PORT=443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$host
REMOTE_PORT=$pb
ENABLED=true
BALANCE_MODE="$mode"
TARGET_STATES=""
WEIGHTS="0"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF
}

# 造两条规则：同一个 REMOTE_HOST，**不同的 LISTEN_PORT**（两个端口组，剔除模式）
# 参数：<规则目录> <REMOTE_HOST> <端口A> <端口B>
_t52_make_cross_group_rules() {
    local dir="$1" host="$2" pa="$3" pb="$4"
    rm -f "$dir"/rule-*.conf
    cat > "$dir/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=scope-test-1
SECURITY_LEVEL=none
LISTEN_PORT=443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$host,10.0.0.2
REMOTE_PORT=$pa
ENABLED=true
BALANCE_MODE="roundrobin"
TARGET_STATES=""
WEIGHTS=""
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF
    cat > "$dir/rule-2.conf" <<EOF
RULE_ID=2
RULE_ROLE=1
RULE_NAME=scope-test-2
SECURITY_LEVEL=none
LISTEN_PORT=844
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$host,10.0.0.3
REMOTE_PORT=$pb
ENABLED=true
BALANCE_MODE="roundrobin"
TARGET_STATES=""
WEIGHTS=""
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
EOF
}

# 在沙箱里跑 generate_endpoints_from_rules，输出原始结果
_t52_gen() {
    _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null
    '
}

# 用指定的 lib 根跑 generate_endpoints_from_rules，取 balance 字段
# ★ $1 = SBX_RUN、$2 = CONFIG_DIR、$3 = lib 根（坏副本时指向副本）
_t52_gen_balance_with_lib() {
    local libroot="$1"
    _run_in_sandbox '
        export CONFIG_DIR="$2"
        source "$3/lib/core.sh" >/dev/null 2>&1
        [ -f "$3/lib/health.sh" ] && source "$3/lib/health.sh" >/dev/null 2>&1
        source "$3/lib/rules.sh" >/dev/null 2>&1
        source "$3/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null | grep -o "\"balance\": \"[^\"]*\"" | head -1
    ' "$SBX_ROOT/realm" "$libroot"
}

# 准备一个「修复前实现」的坏副本：把指定 SHA 的 lib/realm.sh 换进去
# 用法：_t52_prepare_prefix_lib <sha> <marker正则>
# 副作用：把坏副本的 lib 根写进全局变量 _T52_LIBROOT
# 返回：0 = 成功；1 = 取不到实现；2 = 实现里找不到标记（实现变了，负向对照要重新对）
#
# ★ 必须在**当前 shell** 里调用（不要写成 $(...)）——
#   命令替换会开子 shell，全局变量赋值随之丢失 → 后面拿到的 lib 根是空串
#   → 源文件加载失败 → 负向对照静默返回空值（看着像「症状没复现」，其实是没跑起来）。
_T52_LIBROOT=""
_t52_prepare_prefix_lib() {
    local sha="$1" marker="$2"
    local libroot="$SBX_ROOT/t52_prefix_$sha"
    _T52_LIBROOT="$libroot"
    rm -rf "$libroot"
    mkdir -p "$libroot/lib"
    cp "$SBX_RUN/lib/"*.sh "$libroot/lib/" 2>/dev/null
    local raw="$SBX_ROOT/t52_raw_$sha.sh"
    if ! (cd "$SBX_REPO" && git show "$sha:lib/realm.sh" > "$raw" 2>/dev/null); then
        echo "取不到 $sha:lib/realm.sh" >&2
        return 1
    fi
    # 路径重定向（与沙箱其它副本同一套规则）→ 不许碰真实系统路径
    sbx_redirect "$raw" "$libroot/lib/realm.sh"
    if ! grep -qE "$marker" "$libroot/lib/realm.sh" 2>/dev/null; then
        echo "$sha 的 lib/realm.sh 里找不到标记 $marker（实现变了，负向对照要重新对）" >&2
        return 2
    fi
    return 0
}

# 从 generate_endpoints_from_rules 的输出里，取某个监听端口对应端口组的目标列表
# 用法：_t52_targets_of_port <输出> <监听端口> → 空格分隔（去重）
#
# 切块依据：每个端口组是一段 JSON 片段，开头是 "listen": "0.0.0.0:<端口>"，
#   端口组的其余内容（含 remote / extra_remotes）都在这一段里。
#   端口号取的是 `:端口"`（带引号），避免 443 命中 8443 这种子串误配。
_t52_targets_of_port() {
    local out="$1" lp="$2"
    printf '%s\n' "$out" | awk -v lp="$lp" '
        /"listen"/ { cur = (index($0, ":" lp "\"") > 0) ? 1 : 0; next }
        {
            if (cur == 1) {
                line = $0
                while (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/)) {
                    print substr(line, RSTART, RLENGTH)
                    line = substr(line, RSTART + RLENGTH)
                }
            }
        }
    ' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

case_T52_health_target_scope() {
    h_case_begin "T52" "健康状态 TARGET 口径：同 host 不同端口互不覆盖 + 旧格式兼容" \
        "沙箱 rules（同 REMOTE_HOST、不同 REMOTE_PORT）+ health_status.conf" \
        "health_check_script_body（写侧）/ generate_endpoints_from_rules（读侧）" \
        "写侧：同 host 不同端口 → 两条独立记录；读侧：跨端口组不互相覆盖、同端口组内同 host 不同端口旧格式与新格式产出一致；旧格式认得出归属则补端口、认不出则当无记录"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    mkdir -p "$(dirname "$health")"

    # ──────────────────────────────
    # ① 写侧：同 host 不同端口 → 两条独立记录
    # ──────────────────────────────
    # 用同一个端口组（LISTEN_PORT 相同）+ 同一个 host + 两个端口 —— 与 N1 的真实拓扑一致。
    # 两个端口都没人监听（用高位端口，避开 T51 的监听口）。
    _t52_make_same_group_rules "$rules" "roundrobin" "127.0.0.1" 18101 18102
    rm -f "$health"
    local hc="$SBX_ROOT/health_check.sh"
    _run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' > "$hc" 2>/dev/null
    h_check_file "$hc" "生成的 health_check.sh"
    local hrc
    hrc=$(bash "$hc" >/dev/null 2>&1; echo $?)
    h_log "health_check.sh 退出码: $hrc"
    h_check_eq "0" "$hrc" "健康检查脚本退出码 0"

    local w
    w=$(_t52_judge_targets "$health" "127.0.0.1:18101" "127.0.0.1:18102")
    h_log "写侧判定: $(printf '%s' "$w" | cut -f1) —— $(printf '%s' "$w" | cut -f2-)"
    h_check_contains "$w" "PASS" "写侧：同 host 不同端口 → 两条独立记录（TARGET 分别是 host:port）"

    # ──────────────────────────────
    # ② 读侧·跨端口组隔离：A 组的故障不被 B 组的健康盖掉
    # ──────────────────────────────
    # 两个端口组：
    #   端口组 443 → 目标 10.0.0.1:8443、10.0.0.2:8443
    #   端口组 844 → 目标 10.0.0.1:9443、10.0.0.3:9443
    # 状态：10.0.0.1:8443 故障，其余健康。
    _t52_make_cross_group_rules "$rules" "10.0.0.1" 8443 9443

    cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1:8443|failed|0|3|100|0
1|10.0.0.2:8443|healthy|0|3|100|0
2|10.0.0.1:9443|healthy|0|3|100|0
2|10.0.0.3:9443|healthy|0|3|100|0
EOF
    local out t443 t844
    out=$(_t52_gen)
    t443=$(_t52_targets_of_port "$out" 443)
    t844=$(_t52_targets_of_port "$out" 844)
    h_log "端口组 443 的目标: [$t443]"
    h_log "端口组 844 的目标: [$t844]"
    h_check_eq "10.0.0.2:8443" "$t443" "读侧：443 组剔除故障目标，只剩 10.0.0.2:8443"
    h_check_eq "10.0.0.1:9443 10.0.0.3:9443" "$t844" "读侧：844 组两个目标都在（没被 443 组的故障影响）"

    # ──────────────────────────────
    # ③ 读侧·**同一端口组内、同 host 不同端口**（N1 缺陷真正触发的形态）
    # ──────────────────────────────
    # 主备组：10.0.0.1:111（主，权重 10）与 10.0.0.1:222（备，权重 0）。
    # 场景：111 故障 → 必须切到 222。
    # ★ 验收口径：**旧格式输入与新格式输入的产出必须逐项一致**。
    #   「旧格式不报错」不是验收标准 —— 那会放过宽键泄漏这类静默失效。
    _t52_make_same_group_rules "$rules" "active-standby" "10.0.0.1" 111 222
    local b_new b_old
    # 新格式（当前生产写入口径）
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1:111|failed|0|3|100|0
EOF
    b_new=$(_t52_gen_balance_with_lib "$SBX_RUN")
    # 旧格式（TARGET 只有裸 host；归属认得出 → 按 RULE_ID 补出端口）
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1|failed|0|3|100|0
EOF
    b_old=$(_t52_gen_balance_with_lib "$SBX_RUN")
    h_log "同组同 host 不同端口 —— 新格式: $b_new / 旧格式: $b_old"
    h_check_contains "$b_new" "roundrobin: 0, 1" "同组形态·新格式：111 故障 → 切到 222"
    h_check_contains "$b_old" "roundrobin: 0, 1" "同组形态·旧格式：同样切到 222（与新格式产出逐项一致）"
    h_check_eq "$b_new" "$b_old" "同组形态：旧格式与新格式的产出必须完全一致"

    # 两条记录都在的旧格式（老文件里两个目标都写过记录）
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1|failed|0|3|100|0
2|10.0.0.1|healthy|0|3|100|0
EOF
    local b_old2
    b_old2=$(_t52_gen_balance_with_lib "$SBX_RUN")
    h_log "同组形态·旧格式两条记录: $b_old2"
    h_check_eq "$b_new" "$b_old2" "同组形态：旧格式两条记录时产出也与新格式一致"

    # ──────────────────────────────
    # ④ 兼容：认不出归属 → 当无记录（不判故障）
    # ──────────────────────────────
    # RULE_ID=9 对不上任何规则 → 补不出端口 → **当无记录**：
    # 那条老记录不让任何目标被判故障（宁可让健康检查下一轮重新探测出一份精确键，
    # 也不留一份会跨端口污染的宽键）。
    # ★ 这里用**剔除模式**的规则：剔除模式下「目标有没有被判故障」直接体现在目标列表上；
    #   主备模式下两个目标都会留在列表里，health 状态只影响权重 ——
    #   而「都判故障→全挂兜底」与「都健康→原主」的 balance 数值**恰好相同**（1,0），
    #   光看数值分不出好坏，必须同时记录场景。
    cat > "$health" <<'EOF'
# Realm健康状态文件
9|10.0.0.1|failed|0|3|100|0
EOF
    # ④a 跨端口组
    _t52_make_cross_group_rules "$rules" "10.0.0.1" 8443 9443
    out=$(_t52_gen)
    t443=$(_t52_targets_of_port "$out" 443)
    t844=$(_t52_targets_of_port "$out" 844)
    h_log "归属认不出时（跨组）443 组: [$t443] / 844 组: [$t844]"
    h_check_eq "10.0.0.1:8443 10.0.0.2:8443" "$t443" "归属认不出时当无记录 → 443 组两个目标都保留（不判故障）"
    h_check_eq "10.0.0.1:9443 10.0.0.3:9443" "$t844" "归属认不出时当无记录 → 844 组两个目标都保留（不判故障）"

    # ④b 同一端口组内、同 host 不同端口（宽键污染真正发生过的那个拓扑）
    _t52_make_same_group_rules "$rules" "roundrobin" "10.0.0.1" 111 222
    out=$(_t52_gen)
    t443=$(_t52_targets_of_port "$out" 443)
    h_log "归属认不出时（同组）443 组: [$t443]"
    h_check_eq "10.0.0.1:111 10.0.0.1:222" "$t443" "归属认不出时当无记录 → 同组内同 host 两个端口都不判故障"

    # ──────────────────────────────
    # 负向对照 1：判定器喂「两条记录挤在同一个 TARGET」的探针 → 必须判红
    # ──────────────────────────────
    local probe="$SBX_ROOT/t52_probe_collapse.conf"
    cat > "$probe" <<'EOF'
# Realm健康状态文件
1|10.0.0.1:8443|failed|0|3|100|0
2|10.0.0.1:8443|healthy|0|3|100|0
EOF
    local n1
    n1=$(_t52_judge_targets "$probe" "10.0.0.1:8443" "10.0.0.1:9443")
    h_log "同 TARGET 探针判定: $(printf '%s' "$n1" | cut -f1) —— $(printf '%s' "$n1" | cut -f2-)"
    h_check_contains "$n1" "FAIL" "负向对照 1：两条记录挤在同一个 TARGET 时判定器必须判红"
    h_check_contains "$n1" "恰好 1 条" "负向对照 1：判红原因指到「恰好 1 条」"

    # ──────────────────────────────
    # 负向对照 2：判定器喂「少一条记录」的探针 → 必须判红
    # ──────────────────────────────
    local probe2="$SBX_ROOT/t52_probe_missing.conf"
    cat > "$probe2" <<'EOF'
# Realm健康状态文件
1|10.0.0.1:8443|failed|0|3|100|0
EOF
    local n2
    n2=$(_t52_judge_targets "$probe2" "10.0.0.1:8443" "10.0.0.1:9443")
    h_log "缺记录探针判定: $(printf '%s' "$n2" | cut -f1) —— $(printf '%s' "$n2" | cut -f2-)"
    h_check_contains "$n2" "FAIL" "负向对照 2：少一条记录时判定器必须判红"
    h_check_contains "$n2" "行数" "负向对照 2：判红原因指到「行数」"

    # ──────────────────────────────
    # 负向对照 3：把读侧换回**修复前的真实实现** → 症状必须复现（不切备）
    # ──────────────────────────────
    # 这是「同 host 不同端口互相覆盖」唯一能复现的地方：
    # 修复后的实现里精确键一定先命中，症状不可达。
    # 两版历史实现都要试：
    #   a7e23fc —— N1-R1 的直接前态（留着一份裸 host 宽键）
    #   f730c8b —— 最初的实现（只用裸 host 建索引、也只按裸 host 查）
    local i
    for i in 1 2; do
        local sha marker libroot bad_balance rc
        if [ "$i" = "1" ]; then
            sha="$_T52_PRE_N1R1_SHA"; marker="$_T52_PRE_N1R1_MARK"
        else
            sha="$_T52_PREFIX_SHA"; marker="$_T52_PREFIX_MARK"
        fi
        # ★ 必须在当前 shell 调用（不能写进 $(...)）—— 见函数注释
        _t52_prepare_prefix_lib "$sha" "$marker"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            h_fail "负向对照 3（$sha）：取不到/对不上的修复前实现 —— 负向对照跑不起来等于没在证明"
            continue
        fi
        libroot="$_T52_LIBROOT"
        [ -z "$libroot" ] && libroot="$SBX_ROOT/t52_prefix_$sha"
        # ★ 回到**主备模式**的同组规则：剔除模式下「全挂兜底」只剩一个目标 →
        #   extra_remotes 为空 → 根本不输出 balance 字段 → 症状观察不到（会误以为「没复现」）。
        #   主备模式下两个目标都留在列表里，health 状态只体现在权重上（0,1 / 1,0）→ 症状看得见。
        _t52_make_same_group_rules "$rules" "active-standby" "10.0.0.1" 111 222
        # 用旧格式（修复前写入口径）+ 同一场景
        cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1|failed|0|3|100|0
EOF
        bad_balance=$(_t52_gen_balance_with_lib "$libroot")
        h_log "修复前实现（$sha）下的 balance: $bad_balance"
        # 断言的是「**坏情况确实发生了**」：该切不切（流量压在已故障的主机上）
        h_check_contains "$bad_balance" "roundrobin: 1, 0" \
            "负向对照 3（$sha）：换回修复前的实现后故障没被切走（A 组的故障被 B 组的记录盖掉）"
    done

    # 修好的实现下，同一个场景必须是「切走」—— 与上面两条负向对照正好相反
    _t52_make_same_group_rules "$rules" "active-standby" "10.0.0.1" 111 222
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|10.0.0.1|failed|0|3|100|0
EOF
    local good_balance
    good_balance=$(_t52_gen_balance_with_lib "$SBX_RUN")
    h_log "当前实现下的 balance: $good_balance"
    h_check_not_contains "$good_balance" "roundrobin: 1, 0" \
        "负向对照 3 的反向口径：当前实现下同一场景必须切走（不出现 1,0）"
}
