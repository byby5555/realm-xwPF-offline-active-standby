#!/bin/bash
# 用例组 17 · N5 阶段 1 · 质量指标只观测不动作（T63~T67）
#
# 背景（Chief 裁定 · N5）：
#   · 健康探测是**要新增的功能**；
#   · 新增的「质量指标（时延 / 失败计数窗口）」这条线**阶段 1 = 只观测，不动作**。
#   · 硬红线 = **注入超阈值不得触发任何切换**，断言口径是「权重 / 模式 / 配置都不变」。
#
# ★ 关键区分（写错方向就会写出假红）：
#   产品里「健康失败」（健康状态 STATUS=failed）驱动「剔除故障目标 / 主备切换」是**保留功能**
#   （由 T19 / T24 / T25 / T29 / T30 / T52 等用例覆盖）。
#   N5 阶段 1 的质量指标（LATENCY_MS / LATENCY_HISTORY / FAIL_COUNT / SUCCESS_COUNT）
#   是**新增的观测字段**，它们**自己不得驱动任何切换**。
#   这两件事不许混为一谈 —— 本组用 T65 的「对照口径」把两者分开钉死：
#   STATUS=failed → 应当切换（保留功能）；质量指标超阈值 → 不得切换。
#
# ★ 本组测的是**当前产品必须成立的不变量**（护栏），不是测 N5 的新功能 ——
#   N5 的产品实现**还没落地**。所以断言的落点是「现在就不许有这条路径」。
#
# ★ RULE_ID 必须连续（1、2）—— 写进文件头、也写进每条相关用例的注释：
#   健康状态文件的旧格式行归属靠 RULE_ID 对应规则；RULE_ID 不连续会触发
#   reorder_rule_ids 重排（ID 被重编成 1..N 且状态文件不同步）→ 老行的 RULE_ID 失效
#   → 归属认不出 → 场景走另一条路径 → **假绿**（顺带：重排会经 sync_health_status_ids
#   把状态文件重写成 7 字段，时延字段被丢掉 → 本组还会**假红**）。
#   → 造规则时 RULE_ID 固定 1 / 2，文件名固定 rule-1.conf / rule-2.conf，
#     且 LISTEN_PORT / RULE_ROLE 相同（重排排序键 = LISTEN_PORT|RULE_ROLE|RULE_ID）。
#
# ★ 负向对照形态：
#   · T63/T64/T65 的「不变」断言配**对照口径自检**（把 STATUS 改成 failed → 平衡必须翻转）
#     —— 证明观测面是活的，「没变」不是恒真。
#   · T66 的负向对照是**注入式退化**（N5 是新功能，没有历史旧实现可取），
#     如实标注在注释与用例里；并同时用「静态判定器必须抓到」+「注入的坏实现确实会改权重」
#     两腿自证。
#
# ★ 被测产物只来自冻结态（git show $BASE_SHA:<path>），绝不 source 工作区文件：
#   $SBX_RAW（原始字节）/ $SBX_SRC（LF 副本）/ $SBX_RUN（LF + 路径重定向 + root 模拟）。

# ─────────────────────────────────────────────────────────────
# 场景 fixture
# ─────────────────────────────────────────────────────────────

# 造规则：同一端口组（LISTEN_PORT=443、RULE_ROLE=1）、同 host、不同 REMOTE_PORT
#   —— 主备 10,0 的标准拓扑（权重 10 的是主，0 的是备）。
#   ★ RULE_ID 必须连续（1、2）：不连续会触发 reorder_rule_ids 重排 → 归属认不出 → 假绿/假红。
#   ★ 权重落盘口径：端口组里**第一条**规则存完整串 "10,0"，其余各存一个值 "0"
#     （产品口径：读取端口组权重时带逗号的那份优先）。
# 参数：<规则目录> <host> <端口1> <端口2>
_n5_make_rules() {
    local dir="$1" host="$2" pa="$3" pb="$4"
    rm -f "$dir"/rule-*.conf
    cat > "$dir/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=n5-rule-1
SECURITY_LEVEL=none
LISTEN_PORT=443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$host
REMOTE_PORT=$pa
ENABLED=true
BALANCE_MODE="active-standby"
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
RULE_NAME=n5-rule-2
SECURITY_LEVEL=none
LISTEN_PORT=443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$host
REMOTE_PORT=$pb
ENABLED=true
BALANCE_MODE="active-standby"
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

# 写健康状态文件（当前生产写入口径：TARGET = host:port；前两行是 # 注释头）
# 字段：RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY
# 用法：_n5_write_health <文件> <记录行> ...
_n5_write_health() {
    local file="$1"
    shift
    mkdir -p "$(dirname "$file")"
    {
        echo "# Realm健康状态文件"
        echo "# 格式: RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY"
        local l
        for l in "$@"; do
            printf '%s\n' "$l"
        done
    } > "$file"
}

# 在沙箱里跑 generate_endpoints_from_rules（读侧），输出完整 endpoints
_n5_gen() {
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

# 取 balance 字段（产品把 active-standby 映射成 roundrobin 输出给 realm）
# ★ 只取**值**（"roundrobin: 1, 0"），不带 JSON 键名 —— 断言要能逐字比对。
_n5_gen_balance() {
    _n5_gen | grep -o '"balance": "[^"]*"' | head -1 | sed 's/^"balance": "//; s/"$//'
}

# 规则目录指纹：<sha256>  <文件名>（按 glob 序，确定性）
_n5_rules_digest() {
    local dir="$1" f
    if [ ! -d "$dir" ]; then
        printf 'MISSING_DIR\n'
        return 1
    fi
    for f in "$dir"/rule-*.conf; do
        [ -f "$f" ] || continue
        printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"
    done
}

# 目录指纹：<sha256>  <相对路径>（逐文件排序；exclude 是相对路径的正则）
_n5_dir_digest() {
    local dir="$1" exclude="${2:-}" f rel
    if [ ! -d "$dir" ]; then
        printf 'MISSING_DIR\n'
        return 1
    fi
    while IFS= read -r f; do
        rel="${f#$dir/}"
        if [ -n "$exclude" ] && printf '%s\n' "$rel" | grep -qE "$exclude"; then
            continue
        fi
        printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$rel"
    done < <(find "$dir" -type f | LC_ALL=C sort)
}

# 读规则文件里的单值字段（剥外层引号）
_n5_rule_field() {
    local dir="$1" key="$2" f v
    for f in "$dir"/rule-*.conf; do
        [ -f "$f" ] || continue
        v=$(grep -m1 "^${key}=" "$f" 2>/dev/null | head -1)
        [ -n "$v" ] || continue
        v="${v#${key}=}"
        v="${v%\"}"
        v="${v#\"}"
        printf '%s\n' "$v"
        return 0
    done
    printf '\n'
}

# 读端口组权重（产品口径：带逗号的那份优先）
_n5_port_weights() {
    local dir="$1" f v first=""
    for f in "$dir"/rule-*.conf; do
        [ -f "$f" ] || continue
        v=$(grep -m1 '^WEIGHTS=' "$f" 2>/dev/null | head -1)
        [ -n "$v" ] || continue
        v="${v#WEIGHTS=}"
        v="${v%\"}"
        v="${v#\"}"
        case "$v" in
            *,*) printf '%s\n' "$v"; return 0 ;;
        esac
        [ -z "$first" ] && first="$v"
    done
    printf '%s\n' "$first"
}

# RULE_ID 连续性自检（不连续 → 重排 → 归属认不出 → 假绿/假红）
_n5_check_rule_ids() {
    local rules="$1" tag="$2"
    h_check_file_has "$rules/rule-1.conf" "RULE_ID=1" "$tag：rule-1.conf 的 RULE_ID=1（RULE_ID 必须连续 1/2，否则触发重排 → 归属认不出 → 假绿）"
    h_check_file_has "$rules/rule-2.conf" "RULE_ID=2" "$tag：rule-2.conf 的 RULE_ID=2（RULE_ID 必须连续 1/2，否则触发重排 → 归属认不出 → 假绿）"
}

# 取健康状态文件里某条记录的某个字段（按 RULE_ID|TARGET 前缀定位）
# 用法：_n5_health_field <文件> <RULE_ID|TARGET> <字段号>
_n5_health_field() {
    local file="$1" key="$2" idx="$3" line
    line=$(grep -m1 "^${key}|" "$file" 2>/dev/null | head -1)
    [ -n "$line" ] || { printf '\n'; return 1; }
    printf '%s\n' "$line" | cut -d'|' -f"$idx"
}

# 场景准备（规则 + 健康状态文件的父目录）
_n5_prepare() {
    local rules="$1" health="$2"
    mkdir -p "$rules" "$(dirname "$health")"
    _n5_make_rules "$rules" "127.0.0.1" 18101 18102
}

# ─────────────────────────────────────────────────────────────
# 静态判定器（T66 腿 A）
# ─────────────────────────────────────────────────────────────
# 判据：冻结态 lib/ 里**不得**存在「以质量指标（时延 / 失败计数窗口）为条件去改权重、
#   改 TARGET_STATES、触发切换」的代码路径。
#
# 命中要同时满足两条：
#   ① 「写」：该行写了会改变流量分配/切换结果的字段
#      —— WEIGHTS= / TARGET_STATES= 的赋值、sed 原地改写、_rule_set_field 写这两个键
#   ② 「由质量指标把门」：该写的邻近上下文里有一行**条件式**，
#      且条件里出现质量指标（latency / fail_count / success_count）
#
# ★ 不会误伤产品的**合法路径**：产品里 fail_count 只用来判定 STATUS 由 healthy 变 failed
#   （那是「健康失败」这条保留功能，不是质量指标驱动切换）—— 那条路径写的是 status，
#   不是 WEIGHTS / TARGET_STATES，所以不会被本判定器命中。
#
# 用法：_n5_static_detector <lib目录> → stdout 每行一条 "HIT <文件>:<行号>:<内容>"，
#       末行是 "SCAN files=<数> lines=<数>"（防空过护栏用）
_n5_static_detector() {
    local libdir="$1" f
    if [ ! -d "$libdir" ]; then
        printf 'SCAN files=0 lines=0\n'
        return 2
    fi
    local files=0 lines=0
    for f in "$libdir"/*.sh; do
        [ -f "$f" ] || continue
        files=$((files + 1))
        lines=$((lines + $(wc -l < "$f")))
        awk '
        function is_comment(l) { return (l ~ /^[[:space:]]*#/) }
        function has_quality(l, t) {
            t = tolower(l)
            return (t ~ /latency/ || t ~ /fail_count/ || t ~ /success_count/)
        }
        function is_guard(l) {
            return (l ~ /^[[:space:]]*(if|elif|while|until|case|test)[[:space:]]/ \
                 || l ~ /&&/ || l ~ /\|\|/ || l ~ /\[\[/ || l ~ /;[[:space:]]*then/)
        }
        function is_write(l) {
            if (is_comment(l)) return 0
            if (l ~ /(^|[[:space:]])local[[:space:]]/) return 0
            if (l ~ /(^|[^A-Za-z0-9_])(WEIGHTS|TARGET_STATES)=/) return 1
            if (l ~ /_rule_set_field[^)]*"(WEIGHTS|TARGET_STATES)"/) return 1
            if (l ~ /echo[^|]*"(WEIGHTS|TARGET_STATES)=/) return 1
            return 0
        }
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (!is_write(lines[i])) continue
                lo = i - 8; if (lo < 1) lo = 1
                for (j = lo; j <= i; j++) {
                    if (!is_guard(lines[j])) continue
                    if (!has_quality(lines[j])) continue
                    bad = 0
                    for (k = j + 1; k <= i; k++) {
                        if (lines[k] ~ /^[[:space:]]*(fi|done|esac)[[:space:]]*$/) { bad = 1; break }
                    }
                    if (bad) continue
                    printf "HIT %s:%d:%s\n", FILENAME, i, lines[i]
                    break
                }
            }
        }' "$f"
    done
    printf 'SCAN files=%s lines=%s\n' "$files" "$lines"
}

# ══════════════════════════════════════════════════════════════
# T63 · 时延指标只观测
# ══════════════════════════════════════════════════════════════
case_T63_latency_metric_observation_only() {
    h_case_begin "T63" "N5 阶段 1：时延指标只观测不动作（超阈值 LATENCY_MS 不得触发切换）" \
        "沙箱 rules（RULE_ID 连续 1/2，主备 10,0，同 host 不同端口）+ health_status.conf" \
        "注入 STATUS=healthy / LATENCY_MS=99999 的记录 → generate_endpoints_from_rules（读侧）" \
        "规则文件逐字节不变；WEIGHTS / BALANCE_MODE / FAILOVER_ENABLED 不变；balance 不变；该超阈值时延记录确实落盘"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T63"

    # 基线：正常时延的观测记录（STATUS=healthy）
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|0|3|100|0|12|12" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"

    local sha_before bal_before
    sha_before=$(_n5_rules_digest "$rules")
    bal_before=$(_n5_gen_balance)
    h_log "基线 balance: $bal_before"
    # 防空过护栏：基线必须是非空的真实产出（否则「不变」是恒真）
    h_check_eq "roundrobin: 1, 0" "$bal_before" "基线 balance 必须是「主未被切换」的真实产出（防空过护栏）"

    # 注入超阈值时延（★ STATUS 仍是 healthy —— 切换只允许由 STATUS 驱动）
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|0|3|100|0|99999|99999" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"

    local sha_after bal_after
    sha_after=$(_n5_rules_digest "$rules")
    bal_after=$(_n5_gen_balance)
    h_log "注入超阈值时延后 balance: $bal_after"

    # ① 规则文件逐字节不变
    h_check_eq "$sha_before" "$sha_after" "规则文件 sha256 逐字节不变（超阈值时延不得改写规则）"
    # ② 关键字段不变
    h_check_eq "10,0" "$(_n5_port_weights "$rules")" "WEIGHTS 不变"
    h_check_eq "active-standby" "$(_n5_rule_field "$rules" BALANCE_MODE)" "BALANCE_MODE 不变"
    h_check_eq "true" "$(_n5_rule_field "$rules" FAILOVER_ENABLED)" "FAILOVER_ENABLED 不变"
    # ③ balance 不变
    h_check_eq "$bal_before" "$bal_after" "balance 产出不变（时延不得驱动主备切换）"
    # ④ 记录确实落盘（证明观测面生效，不是「什么都没发生」）
    h_check_eq "1" "$(grep -c '^1|127.0.0.1:18101|healthy|0|3|100|0|99999|99999$' "$health" 2>/dev/null)" "注入的超阈值时延记录确实出现在健康状态文件里（恰好 1 条）"
    h_check_eq "99999" "$(_n5_health_field "$health" "1|127.0.0.1:18101" 8)" "记录里的 LATENCY_MS 字段确实是 99999（不是空值/占位）"
}

# ══════════════════════════════════════════════════════════════
# T64 · 失败计数窗口只观测
# ══════════════════════════════════════════════════════════════
case_T64_fail_count_window_observation_only() {
    h_case_begin "T64" "N5 阶段 1：失败计数窗口只观测不动作（超阈值 FAIL_COUNT 不得触发切换）" \
        "沙箱 rules（RULE_ID 连续 1/2，主备 10,0）+ health_status.conf" \
        "注入 STATUS=healthy / FAIL_COUNT=9 的记录 → generate_endpoints_from_rules（读侧）" \
        "规则文件逐字节不变；WEIGHTS / BALANCE_MODE / FAILOVER_ENABLED 不变；balance 不变；超阈值窗口记录确实落盘"

    # ★ 口径说明：主备切换只应由**健康状态 STATUS** 驱动（STATUS=failed 是保留功能）；
    #   FAIL_COUNT / SUCCESS_COUNT 这条「失败计数窗口」在阶段 1 **只是观测字段**，
    #   自己不得驱动任何切换。所以这里刻意造一个「FAIL_COUNT 已超阈值但 STATUS 仍 healthy」
    #   的记录：产品必须**不**因它切换。

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T64"

    local fail_threshold
    fail_threshold=$(_n5_rule_field "$rules" FAILURE_THRESHOLD)
    h_log "规则里的 FAILURE_THRESHOLD: $fail_threshold"

    # 基线：窗口计数正常
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|0|3|100|0|12|12" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"

    local sha_before bal_before
    sha_before=$(_n5_rules_digest "$rules")
    bal_before=$(_n5_gen_balance)
    h_log "基线 balance: $bal_before"
    h_check_eq "roundrobin: 1, 0" "$bal_before" "基线 balance 必须是「主未被切换」的真实产出（防空过护栏）"

    # 注入超阈值失败计数窗口（★ STATUS 仍是 healthy）
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|9|5|100|0|12|12" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"

    local sha_after bal_after
    sha_after=$(_n5_rules_digest "$rules")
    bal_after=$(_n5_gen_balance)
    h_log "注入超阈值失败计数窗口后 balance: $bal_after"

    # ① 规则文件逐字节不变
    h_check_eq "$sha_before" "$sha_after" "规则文件 sha256 逐字节不变（超阈值失败计数不得改写规则）"
    # ② 关键字段不变
    h_check_eq "10,0" "$(_n5_port_weights "$rules")" "WEIGHTS 不变"
    h_check_eq "active-standby" "$(_n5_rule_field "$rules" BALANCE_MODE)" "BALANCE_MODE 不变"
    h_check_eq "true" "$(_n5_rule_field "$rules" FAILOVER_ENABLED)" "FAILOVER_ENABLED 不变"
    # ③ balance 不变
    h_check_eq "$bal_before" "$bal_after" "balance 产出不变（失败计数窗口不得驱动主备切换）"
    # ④ 记录确实落盘 + 窗口值确实超阈值（否则上面几条是恒真）
    h_check_eq "1" "$(grep -c '^1|127.0.0.1:18101|healthy|9|5|100|0|12|12$' "$health" 2>/dev/null)" "注入的超阈值失败计数记录确实出现在健康状态文件里（恰好 1 条）"
    local fc
    fc=$(_n5_health_field "$health" "1|127.0.0.1:18101" 4)
    h_check_eq "9" "$fc" "记录里的 FAIL_COUNT 字段确实是 9"
    h_check_ge "$fail_threshold" "$fc" "注入的 FAIL_COUNT 确实 ≥ 规则的 FAILURE_THRESHOLD（阈值必须真的被超过，否则断言恒真）"
    h_check_eq "healthy" "$(_n5_health_field "$health" "1|127.0.0.1:18101" 3)" "记录里的 STATUS 仍是 healthy（切换只应由 STATUS 驱动）"
}

# ══════════════════════════════════════════════════════════════
# T65 · 核心红线：注入超阈值 → 断言不切换
# ══════════════════════════════════════════════════════════════
case_T65_quality_threshold_injection_no_switch() {
    h_case_begin "T65" "N5 阶段 1 核心红线：时延 + 失败计数同时超阈值也不得触发任何切换" \
        "沙箱 rules（RULE_ID 连续 1/2，主备 10,0）+ health_status.conf" \
        "注入 STATUS=healthy / LATENCY_MS=99999 / FAIL_COUNT=9 → generate_endpoints_from_rules（读侧）" \
        "规则文件 sha256 不变；WEIGHTS / BALANCE_MODE / FAILOVER_ENABLED 不变；balance 不变；无任何切换副作用（无规则改写 / 无 TARGET_STATES 被写 / 主备选择不变）；注入值确实超阈值"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T65"

    local fail_threshold
    fail_threshold=$(_n5_rule_field "$rules" FAILURE_THRESHOLD)
    # ★ 用例自设的时延观测阈值：N5 尚未落地，产品里**没有**时延阈值配置，
    #   所以这里取一个明确的阈值常量，只用来证明「注入值确实超阈值」。
    local lat_threshold=100

    # 基线
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|0|3|100|0|12|12" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"

    local sha_before out_before bal_before files_before
    sha_before=$(_n5_rules_digest "$rules")
    out_before=$(_n5_gen)
    bal_before=$(printf '%s\n' "$out_before" | grep -o '"balance": "[^"]*"' | head -1 | sed 's/^"balance": "//; s/"$//')
    files_before=$(ls -1 "$rules" | LC_ALL=C sort | tr '\n' ' ')
    h_log "基线 balance: $bal_before / 规则文件清单: $files_before"
    h_check_eq "roundrobin: 1, 0" "$bal_before" "基线 balance 必须是「主未被切换」的真实产出（防空过护栏）"

    # 注入：时延与失败计数**同时**超阈值，STATUS 仍是 healthy
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|9|5|100|0|99999|99999" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"

    local sha_after out_after bal_after files_after
    sha_after=$(_n5_rules_digest "$rules")
    out_after=$(_n5_gen)
    bal_after=$(printf '%s\n' "$out_after" | grep -o '"balance": "[^"]*"' | head -1 | sed 's/^"balance": "//; s/"$//')
    files_after=$(ls -1 "$rules" | LC_ALL=C sort | tr '\n' ' ')
    h_log "注入超阈值后 balance: $bal_after / 规则文件清单: $files_after"

    # ① 规则文件 sha256 不变
    h_check_eq "$sha_before" "$sha_after" "规则文件 sha256 不变（注入超阈值不得改写规则）"
    # ② WEIGHTS / BALANCE_MODE / FAILOVER_ENABLED 不变
    h_check_eq "10,0" "$(_n5_port_weights "$rules")" "WEIGHTS 不变"
    h_check_eq "active-standby" "$(_n5_rule_field "$rules" BALANCE_MODE)" "BALANCE_MODE 不变"
    h_check_eq "true" "$(_n5_rule_field "$rules" FAILOVER_ENABLED)" "FAILOVER_ENABLED 不变"
    # ③ balance 不变
    h_check_eq "$bal_before" "$bal_after" "balance 产出不变（超阈值不得驱动主备切换）"
    # ④ 没有任何「切换」副作用
    h_check_eq "$files_before" "$files_after" "规则目录文件清单不变（没有规则被新建/删除）"
    h_check_eq "" "$(_n5_rule_field "$rules" TARGET_STATES)" "TARGET_STATES 仍为空（不得被写入）"
    h_check_eq "$out_before" "$out_after" "整份 endpoints 产出逐字节不变（目标列表与主备选择都没变）"
    h_check_contains "$bal_after" "roundrobin: 1, 0" "主备选择仍是权重 10 的那个目标当主（没被切到备）"
    # ⑤ 注入值确实达到/超过阈值（否则上面几条是恒真）
    local fc lat
    fc=$(_n5_health_field "$health" "1|127.0.0.1:18101" 4)
    lat=$(_n5_health_field "$health" "1|127.0.0.1:18101" 8)
    h_check_eq "9" "$fc" "注入的 FAIL_COUNT 确实是 9"
    h_check_ge "$fail_threshold" "$fc" "注入的 FAIL_COUNT 确实 ≥ 规则的 FAILURE_THRESHOLD（阈值必须真的被超过）"
    h_check_eq "99999" "$lat" "注入的 LATENCY_MS 确实是 99999"
    h_check_ge "$lat_threshold" "$lat" "注入的 LATENCY_MS 确实 ≥ 用例自设的时延观测阈值（阈值必须真的被超过）"
    h_check_eq "healthy" "$(_n5_health_field "$health" "1|127.0.0.1:18101" 3)" "记录里的 STATUS 仍是 healthy（= 不得有任何切换）"

    # ── 判定器自检（对照口径，防假绿）──
    #   把同一条记录的 STATUS 改成 failed —— 这是**保留功能**（健康失败驱动切换），
    #   平衡必须翻成 "roundrobin: 0, 1"。
    #   这一步证明：① 观测面是活的（不是恒定字符串）；② 规则确实被产品读到了；
    #              ③ 「STATUS 驱动切换（允许）」与「质量指标驱动切换（禁止）」被分开钉死。
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|failed|9|5|100|0|99999|99999" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"
    local bal_ctrl
    bal_ctrl=$(_n5_gen_balance)
    h_log "对照口径（STATUS=failed，健康失败这条保留功能）balance: $bal_ctrl"
    h_check_contains "$bal_ctrl" "roundrobin: 0, 1" "对照口径：STATUS=failed 时必须切到备（证明上面的「不变」不是恒真）"
    h_check_not_contains "$bal_ctrl" "roundrobin: 1, 0" "对照口径：STATUS=failed 时不得留在原主"

    # 还原（后续用例不依赖本用例留下的状态）
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|0|3|100|0|12|12" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"
}

# ══════════════════════════════════════════════════════════════
# T66 · 判定器自检（静态探测器有牙齿 + 动态注入确实生效）
# ══════════════════════════════════════════════════════════════
case_T66_quality_detector_selfcheck() {
    h_case_begin "T66" "N5 质量判定器自检：静态探测器必须抓得住坏实现；动态注入必须真的落盘" \
        "冻结态 lib/（$SBX_SRC/lib）+ 注入式退化的坏实现副本 + 沙箱 health_status.conf" \
        "静态判定器扫 lib/ → 命中数；副本注入坏实现 → 同一判定器必须判红；坏实现实际改权重；T65 的注入值是否真的写进了状态文件" \
        "冻结态 lib/ 命中数 = 0（且扫描文件数 = 实际 .sh 数，防空过）；注入坏实现后判定器必须抓到；坏实现确实把 WEIGHTS/TARGET_STATES 改了；T65 的超阈值值确实落盘"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"

    # ── 腿 A（静态探测器）────────────────────────────────────
    # ① 冻结态 lib/ 里不得存在「以质量指标为条件改权重 / 改 TARGET_STATES / 触发切换」的路径
    local det_out hits scan_files scan_lines lib_sh_files
    det_out=$(_n5_static_detector "$SBX_SRC/lib")
    hits=$(printf '%s\n' "$det_out" | grep -c '^HIT ')
    [ -n "$hits" ] || hits=0
    scan_files=$(printf '%s\n' "$det_out" | sed -n 's/^SCAN files=\([0-9][0-9]*\).*/\1/p')
    scan_lines=$(printf '%s\n' "$det_out" | sed -n 's/^SCAN files=[0-9]* lines=\([0-9][0-9]*\).*/\1/p')
    lib_sh_files=$(ls -1 "$SBX_SRC/lib"/*.sh 2>/dev/null | wc -l | tr -d ' ')
    h_log "静态判定器：命中 $hits 条 / 扫描文件 $scan_files 个、共 $scan_lines 行（冻结态 lib 里 .sh 文件 $lib_sh_files 个）"
    if [ "$hits" -gt 0 ]; then
        printf '%s\n' "$det_out" | grep '^HIT ' | head -5 | while IFS= read -r l; do h_log "  $l"; done
    fi

    # 防空过护栏：判定器必须真的扫到了冻结态 lib 的全部 .sh 文件（否则「0 命中」是空扫出来的）
    h_check_eq "$lib_sh_files" "$scan_files" "静态判定器扫描的文件数 = 冻结态 lib 里的 .sh 文件数（防空过护栏）"
    h_check_ge "1000" "$scan_lines" "静态判定器确实扫到了代码（扫描行数下限，防空过护栏）"
    # ★ 核心断言：冻结态里这条路径不存在
    h_check_eq "0" "$hits" "冻结态 lib/ 里不存在「以质量指标为条件改权重 / 改 TARGET_STATES / 触发切换」的代码路径"

    # ② 负向对照（注入式退化）：N5 是新功能，没有历史旧实现可取 ——
    #    所以这里用**注入式退化**，如实标注：这不是历史旧实现。
    #    在 lib/rules.sh 的副本里注入一段「按时延改权重、按失败计数改 TARGET_STATES」的坏实现，
    #    同一个判定器必须抓到它（否则判定器是恒绿的）。
    local badroot="$SBX_ROOT/n5_bad_lib"
    rm -rf "$badroot"
    mkdir -p "$badroot/lib"
    cp "$SBX_SRC/lib/"*.sh "$badroot/lib/" 2>/dev/null
    cat >> "$badroot/lib/rules.sh" <<'EOF'

# ── 注入式退化（N5 负向对照用；这不是历史旧实现）──
#   形态：拿质量指标（时延 / 失败计数窗口）当条件去改权重、改 TARGET_STATES。
_n5_injected_quality_switch() {
    local LATENCY="${1:-0}"
    local FAIL_COUNT="${2:-0}"
    if [ "$LATENCY" -gt 100 ]; then
        WEIGHTS="0,10"
    fi
    if [ "$FAIL_COUNT" -ge 2 ]; then
        TARGET_STATES="0.0.0.9:9"
    fi
}
EOF

    local bad_det bad_hits
    bad_det=$(_n5_static_detector "$badroot/lib")
    bad_hits=$(printf '%s\n' "$bad_det" | grep -c '^HIT ')
    [ -n "$bad_hits" ] || bad_hits=0
    h_log "坏实现副本的判定结果：命中 $bad_hits 条"
    printf '%s\n' "$bad_det" | grep '^HIT ' | head -5 | while IFS= read -r l; do h_log "  $l"; done

    h_check_ge "1" "$bad_hits" "负向对照：注入式退化的坏实现必须被静态判定器抓到（判定器不是恒绿）"
    h_check_eq "2" "$bad_hits" "负向对照：恰好抓到 2 处（按时延改权重 + 按失败计数改 TARGET_STATES），不多不少"
    h_check_contains "$bad_det" "n5_bad_lib/lib/rules.sh" "负向对照：判红原因指向注入的坏实现所在文件（不是别的无关命中）"
    h_check_contains "$bad_det" "WEIGHTS=" "负向对照：判定器抓到的正是「按质量指标改权重」那类写法"
    h_check_contains "$bad_det" "TARGET_STATES=" "负向对照：判定器也抓到了「按质量指标改 TARGET_STATES」那类写法"

    # ③ 注入的坏实现**确实**会改权重（证明它不是一段摆设文本，探测器抓的确实是行为路径）
    local bad_fn="$SBX_ROOT/n5_bad_fn.sh"
    awk '/^_n5_injected_quality_switch\(\) \{/,/^\}/' "$badroot/lib/rules.sh" > "$bad_fn"
    h_check_file "$bad_fn" "从坏实现副本里抽出注入的函数"
    local behavior
    behavior=$(bash -c '
        source "$1" >/dev/null 2>&1
        WEIGHTS="10,0"
        TARGET_STATES=""
        _n5_injected_quality_switch 99999 9
        printf "weights=%s states=%s\n" "$WEIGHTS" "$TARGET_STATES"
    ' _ "$bad_fn" 2>&1)
    h_log "注入坏实现的行为: $behavior"
    h_check_contains "$behavior" "weights=0,10" "负向对照：注入的坏实现确实把 WEIGHTS 从 10,0 改成了 0,10（行为真实发生）"
    h_check_contains "$behavior" "states=0.0.0.9:9" "负向对照：注入的坏实现确实写了 TARGET_STATES（行为真实发生）"

    # ── 腿 B（动态注入生效）──────────────────────────────────
    #   确认 T65 注入的超阈值值**真的**被写进了健康状态文件 ——
    #   否则 T65 可能什么都没注入（那 T65 的「不变」就是恒真）。
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T66 腿 B"
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|9|5|100|0|99999|99999" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"
    h_check_eq "1" "$(grep -c '^1|127.0.0.1:18101|healthy|9|5|100|0|99999|99999$' "$health" 2>/dev/null)" "腿 B：T65 的超阈值注入记录确实落盘（恰好 1 条）"
    h_check_eq "9" "$(_n5_health_field "$health" "1|127.0.0.1:18101" 4)" "腿 B：落盘记录的 FAIL_COUNT 字段 = 9"
    h_check_eq "99999" "$(_n5_health_field "$health" "1|127.0.0.1:18101" 8)" "腿 B：落盘记录的 LATENCY_MS 字段 = 99999"
    h_check_eq "healthy" "$(_n5_health_field "$health" "1|127.0.0.1:18101" 3)" "腿 B：落盘记录的 STATUS = healthy"
    h_check_eq "2" "$(grep -c -v '^#' "$health" 2>/dev/null | tr -d ' ')" "腿 B：状态文件里恰好 2 条记录（注入没有写坏文件结构）"
}

# ══════════════════════════════════════════════════════════════
# T67 · 观测不产生副作用
# ══════════════════════════════════════════════════════════════
case_T67_observation_no_side_effect() {
    h_case_begin "T67" "N5 阶段 1：观测不产生副作用（跑一轮真实探测，除健康状态文件外不许改写任何文件）" \
        "沙箱 rules + health_status.conf + 冻结态生成的 health_check.sh" \
        "生成并执行 health_check.sh（真实探测一轮）→ 比对规则目录 / 配置目录的文件清单与 sha256" \
        "规则目录与配置目录（除健康状态文件外）文件清单与 sha256 全部不变；健康状态文件允许变化且确实变了（探测真的跑了）"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local configdir="$SBX_ROOT/realm"
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T67"

    # 探测前：健康状态文件里放「健康 + 计数 0」的记录
    _n5_write_health "$health" \
        "1|127.0.0.1:18101|healthy|0|3|100|0|12|12" \
        "2|127.0.0.1:18102|healthy|0|3|100|0|15|15"

    local rules_before cfg_before health_before
    rules_before=$(_n5_rules_digest "$rules")
    cfg_before=$(_n5_dir_digest "$configdir" '^health/health_status\.conf$')
    health_before=$(sha256sum "$health" | cut -d' ' -f1)
    h_log "探测前 规则指纹: $(printf '%s' "$rules_before" | tr '\n' ' ')"

    # 生成健康检查脚本（探测端，来自冻结态 lib/health.sh）并真实跑一轮
    local hc="$SBX_ROOT/health_check.sh"
    rm -f "$hc"
    _run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' > "$hc" 2>/dev/null
    h_check_file "$hc" "生成的 health_check.sh"
    local hrc
    hrc=$(bash "$hc" >/dev/null 2>&1; echo $?)
    h_log "health_check.sh 退出码: $hrc"
    h_check_eq "0" "$hrc" "健康检查脚本退出码 0"

    local rules_after cfg_after health_after
    rules_after=$(_n5_rules_digest "$rules")
    cfg_after=$(_n5_dir_digest "$configdir" '^health/health_status\.conf$')
    health_after=$(sha256sum "$health" | cut -d' ' -f1)
    h_log "探测后 规则指纹: $(printf '%s' "$rules_after" | tr '\n' ' ')"

    # ① 规则目录：文件清单 + sha256 全不变
    h_check_eq "$rules_before" "$rules_after" "规则目录文件清单与 sha256 全部不变（观测不得改写规则）"
    # ② 配置目录：除健康状态文件外，任何文件都不得被改写
    h_check_eq "$cfg_before" "$cfg_after" "配置目录（除健康状态文件外）文件清单与 sha256 全部不变（观测不得产生副作用）"
    # ③ 健康状态文件**确实**变了 —— 这一条同时是本用例的自检：
    #    它证明上面的「没变」是因为真的没写，而不是因为比对口径坏了（恒绿）。
    if [ "$health_before" != "$health_after" ]; then
        h_pass "健康状态文件已被探测改写（比对口径是活的，防假绿）"
    else
        h_fail "健康状态文件跑完探测后没有任何变化 —— 探测根本没跑起来，② 的「不变」就是恒真"
    fi
    local last_check
    last_check=$(_n5_health_field "$health" "1|127.0.0.1:18101" 6)
    h_check_ge "100" "$last_check" "规则 1 的记录被探测刷新（LAST_CHECK 已更新为真实时间戳）"
    h_check_eq "1" "$(grep -c '^2|127.0.0.1:18102|' "$health" 2>/dev/null)" "规则 2 的目标也被探测覆盖（探测真的跑到了每个目标）"
}

# ══════════════════════════════════════════════════════════════
# T108 · 质量窗口「真的可配」
# ══════════════════════════════════════════════════════════════
# ★ 为什么要有这一条（Chief 拍板）：
#   「配置项存在 ≠ 配置项可生效」—— 键写在白名单里、模板里有、文档里有，
#   都不等于**值真的被读到**。
#   实际踩过的坑：N5 第一版读值时去 grep 一个**从未被赋值**的变量
#   （$RULE_FILE 全代码库没人赋值）⇒ 那段是死代码 ⇒ 窗口永远回落默认 20
#   ⇒ 「可配」只是**看起来可配**。而当时台架里**一条断言都没有**
#   （T63-T67 只验「只观测不动作」红线）⇒ 缺陷就这么过去了。
#   ⇒ 本条专门盯「值被读到了」这件事。
#
# ★ 观测面：质量指标文件的**末列 WINDOW** = 该行**生效的窗口大小**
#   （产品侧在采样时把生效值一起写进去）⇒ 外部可以直接读到，
#   不用反推采样条数。
#
# ★ 四腿 + 一条负向对照：
#   腿 A：规则写 PROBE_QUALITY_WINDOW="12"  ⇒ 生效窗口 = 12（≠ 默认 20）
#   负向对照：把 quality_window_size 换成「恒返回 20」的坏实现 ⇒ 同一断言必须判红
#            （否则本条恒真、没有判别力）
#   腿 B：规则不写该键                        ⇒ 生效窗口 = 20（默认）
#   腿 C：规则写兼容别名 probe.quality_window="12" ⇒ 生效窗口 = 12
#   腿 D：规则写 PROBE_QUALITY_WINDOW="abc"  ⇒ 生效窗口 = 20（非法值回退）
#
# ★ 每条腿跑探测前都先删掉指标文件 ⇒ 陈旧文件不会造成假绿。
case_T108_quality_window_configurable() {
    h_case_begin "T108" "N5 阶段 1：质量窗口真的可配（规则里写 12 ⇒ 生效 12，而不是回落默认 20）" \
        "沙箱 rules（含 PROBE_QUALITY_WINDOW / 兼容别名）+ 冻结态生成的 health_check.sh" \
        "跑一轮真实探测 → 读质量指标文件末列 WINDOW（= 本行**生效**的窗口大小）" \
        "配 12 ⇒ 生效 12；没配 ⇒ 20；兼容别名 ⇒ 12；非法值 ⇒ 20；坏实现（恒 20）⇒ 判红"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local qm="$SBX_ROOT/var.lib.realm/quality_metrics.conf"
    local hc="$SBX_ROOT/health_check.sh"
    local hc_bad="$SBX_ROOT/health_check_bad.sh"

    # 读某一行的生效窗口（末列）
    _t108_win() {
        awk -F'|' '$1 == "127.0.0.1:18101" && $2 == "1" { print $5; exit }' "$qm" 2>/dev/null
    }

    # 生成冻结态探测脚本（好版本）
    rm -f "$hc"
    _run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' > "$hc" 2>/dev/null
    h_check_file "$hc" "生成的 health_check.sh"

    # ── 腿 A：规则里写规范名 12 ⇒ 生效 12 ─────────────────────
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T108 腿 A"
    printf 'PROBE_QUALITY_WINDOW="12"\n' >> "$rules/rule-1.conf"
    rm -f "$qm"
    bash "$hc" >/dev/null 2>&1
    h_check_file "$qm" "质量指标文件（独立文件）"
    local w
    w=$(_t108_win)
    h_log "腿 A 生效窗口 = ${w:-（读不到）}"
    h_check_eq "12" "$w" "规则里 PROBE_QUALITY_WINDOW=\"12\" ⇒ 生效窗口 = 12（不是默认 20 ⇒ 值真被读到了）"

    # ── 负向对照：把 quality_window_size 换成「恒 20」的坏实现 ──
    #    同一套断言在坏实现上必须判红 ⇒ 证明腿 A 不是恒真断言。
    awk '
        /^quality_window_size\(\) \{/ { print "quality_window_size() { echo 20; }"; inblk = 1; next }
        inblk && /^\}/ { inblk = 0; next }
        !inblk { print }
    ' "$hc" > "$hc_bad"
    h_check_file "$hc_bad" "缺陷版 health_check.sh（注入式退化）"
    h_check_file_has "$hc_bad" "quality_window_size() { echo 20; }" \
        "缺陷版确实把 quality_window_size 换成了恒 20 的坏实现（否则负向对照没生效）"
    rm -f "$qm"
    bash "$hc_bad" >/dev/null 2>&1
    local w_bad
    w_bad=$(_t108_win)
    h_log "坏实现下生效窗口 = ${w_bad:-（读不到）}"
    h_check_eq "20" "$w_bad" "坏实现（恒 20）下生效窗口 = 20 ⇒ 腿 A 的断言在缺陷版上会判红（有判别力，非恒真）"

    # ── 腿 B：规则不写该键 ⇒ 生效 20（默认）──────────────────
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T108 腿 B"
    rm -f "$qm"
    bash "$hc" >/dev/null 2>&1
    w=$(_t108_win)
    h_log "腿 B 生效窗口 = ${w:-（读不到）}"
    h_check_eq "20" "$w" "规则里没写该键 ⇒ 生效窗口 = 20（默认值）"

    # ── 腿 C：兼容别名（点号小写）⇒ 生效 12 ──────────────────
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T108 腿 C"
    printf 'probe.quality_window="12"\n' >> "$rules/rule-1.conf"
    rm -f "$qm"
    bash "$hc" >/dev/null 2>&1
    w=$(_t108_win)
    h_log "腿 C 生效窗口 = ${w:-（读不到）}"
    h_check_eq "12" "$w" "兼容别名 probe.quality_window=\"12\" ⇒ 生效窗口 = 12（别名也生效，不失效）"

    # ── 腿 D：非法值 ⇒ 回退 20 ────────────────────────────────
    _n5_prepare "$rules" "$health"
    _n5_check_rule_ids "$rules" "T108 腿 D"
    printf 'PROBE_QUALITY_WINDOW="abc"\n' >> "$rules/rule-1.conf"
    rm -f "$qm"
    bash "$hc" >/dev/null 2>&1
    w=$(_t108_win)
    h_log "腿 D 生效窗口 = ${w:-（读不到）}"
    h_check_eq "20" "$w" "非法值 PROBE_QUALITY_WINDOW=\"abc\" ⇒ 回退到默认 20（不中断探测端）"
}
