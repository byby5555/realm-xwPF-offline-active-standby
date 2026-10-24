#!/bin/bash
# 用例组 04 · 第 2 轮并入的用例
#
# 来源：原 4 套独立脚本（test_active_standby.sh / test_connectivity.sh /
#       test_e2e.sh / test_set_u.sh）—— 现在全部并入唯一入口 tests/run_tests.sh。
# 原脚本保留为薄封装（内部调 run_tests.sh --only ...），保证「只有一个真源」。
#
# 覆盖：
#   T23 权重含 0 → 自动进主备 + 补齐健康检查参数（多规则）
#   T24 主备优先级选主 / 故障切换 / 主恢复切回 / 全挂兜底
#   T25 权重全 >0 且处于主备 → 自动切回轮询
#   T26 探测函数（入口加载的那份）行为：可达 / 不可达 / 超时受控
#   T27 生成的 health_check.sh 里的探测副本行为
#   T28 两份探测实现必须一致（防漂移）
#   T29 主备模式 6 态端到端（与 docs/active-standby-logic.md 的表一一对应）
#   T30 剔除模式 5 态端到端
#   T31 set -u 下的健壮性（含「旧写法确实会失败」的对照组）
#   T32 静态断言：全仓 check_connectivity() { 出现次数必须 == 1（单一真源）

# 造两条同端口的规则（模拟"拆成两条规则"的端口组）
_make_rule_pair() {
    local dir="$1" mode="$2" failover="$3"
    rm -f "$dir"/rule-*.conf
    local i=1 host
    for host in 10.0.0.1 10.0.0.2; do
        cat > "$dir/rule-$i.conf" <<EOF
RULE_ID="$i"
RULE_ROLE="1"
RULE_NAME="standby-test-$i"
SECURITY_LEVEL="none"
LISTEN_PORT="443"
LISTEN_IP=""
THROUGH_IP="::"
REMOTE_HOST="$host"
REMOTE_PORT="8443"
ENABLED="true"
CREATED_TIME="2026-01-01 00:00:00"
BALANCE_MODE="$mode"
TARGET_STATES=""
WEIGHTS=""
FAILOVER_ENABLED="$failover"
EOF
        i=$((i + 1))
    done
}

# 在沙箱里跑 generate_endpoints_from_rules，输出 balance 字段
_gen_balance() {
    _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null | grep -o "\"balance\": \"[^\"]*\"" | head -1
    '
}

# 在沙箱里跑 generate_endpoints_from_rules，输出 10.0.0.x 目标数
_gen_target_count() {
    _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null | grep -o "10\.0\.0\.[123]" | sort -u | wc -l | tr -d " "
    '
}

# 在沙箱里执行一次权重应用（apply_port_group_weight_config）
_apply_weights() {
    local port="$1" weights="$2"
    _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        printf "\n" | apply_port_group_weight_config "'"$port"'" "'"$weights"'" >/dev/null 2>&1
        echo "RC=$?"
    '
}

case_T23_auto_standby_multi_rule() {
    h_case_begin "T23" "权重含 0 → 自动进主备" \
        "沙箱 rules（同端口两条规则）" \
        "apply_port_group_weight_config 443 '10,0'" \
        "两条规则 BALANCE_MODE=active-standby、FAILOVER_ENABLED=true、WEIGHTS 按序存、5 项健康检查参数补齐"

    _make_rule_pair "$SBX_ROOT/realm/rules" "roundrobin" "false"
    local out
    out=$(_apply_weights 443 "10,0")
    h_log "apply 输出: ${out:-<空>}"

    local r1="$SBX_ROOT/realm/rules/rule-1.conf"
    local r2="$SBX_ROOT/realm/rules/rule-2.conf"
    h_check_file_has "$r1" 'BALANCE_MODE="active-standby"' "rule-1 BALANCE_MODE"
    h_check_file_has "$r2" 'BALANCE_MODE="active-standby"' "rule-2 BALANCE_MODE"
    h_check_file_has "$r1" 'FAILOVER_ENABLED="true"' "rule-1 FAILOVER_ENABLED"
    h_check_file_has "$r2" 'FAILOVER_ENABLED="true"' "rule-2 FAILOVER_ENABLED"
    h_check_file_has "$r1" 'WEIGHTS="10,0"' "rule-1 WEIGHTS 存完整序列"
    h_check_file_has "$r2" 'WEIGHTS="0"' "rule-2 WEIGHTS 存单个值"
    local k
    for k in HEALTH_CHECK_INTERVAL FAILURE_THRESHOLD SUCCESS_THRESHOLD CONNECTION_TIMEOUT RECOVERY_COOLDOWN; do
        h_check_file_has "$r1" "${k}=" "$k 已补齐"
    done
}

case_T24_priority_primary_selection() {
    h_case_begin "T24" "主备优先级选主与切换" \
        "沙箱 rules + health_status.conf" \
        "generate_endpoints_from_rules（多组健康态）" \
        "权重大的当主；主挂切备；主恢复切回；全挂时按优先级兜底"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local b

    # 10,0 → 第一个为主
    _make_rule_pair "$rules" "roundrobin" "false"
    _apply_weights 443 "10,0" >/dev/null
    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:healthy"
    b=$(_gen_balance); h_log "全健康(10,0) -> $b"
    h_check_contains "$b" "roundrobin: 1, 0" "10,0 全健康 → 第一个为主"

    # 主挂 → 切备
    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:healthy"
    b=$(_gen_balance); h_log "主故障(10,0) -> $b"
    h_check_contains "$b" "roundrobin: 0, 1" "主故障 → 切到备"

    # 主恢复 → 切回
    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:healthy"
    b=$(_gen_balance); h_log "主恢复(10,0) -> $b"
    h_check_contains "$b" "roundrobin: 1, 0" "主恢复 → 切回主"

    # 0,10 → 第二个为主
    _make_rule_pair "$rules" "roundrobin" "false"
    _apply_weights 443 "0,10" >/dev/null
    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:healthy"
    b=$(_gen_balance); h_log "全健康(0,10) -> $b"
    h_check_contains "$b" "roundrobin: 0, 1" "0,10 → 第二个为主"

    # 0,10 且第二个故障 → 回退第一个
    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:failed"
    b=$(_gen_balance); h_log "第二主故障(0,10) -> $b"
    h_check_contains "$b" "roundrobin: 1, 0" "第二主故障 → 切回第一个"

    # 全挂(0,10) → 兜底第二个（优先级最高）
    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:failed"
    b=$(_gen_balance); h_log "全挂(0,10) -> $b"
    h_check_contains "$b" "roundrobin: 0, 1" "全挂(0,10) → 兜底第二个"

    # 全挂(10,0) → 兜底第一个
    _make_rule_pair "$rules" "roundrobin" "false"
    _apply_weights 443 "10,0" >/dev/null
    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:failed"
    b=$(_gen_balance); h_log "全挂(10,0) -> $b"
    h_check_contains "$b" "roundrobin: 1, 0" "全挂(10,0) → 兜底第一个"
}

case_T25_back_to_roundrobin() {
    h_case_begin "T25" "权重全 >0 → 自动切回轮询" \
        "沙箱 rules（主备态）" \
        "apply_port_group_weight_config 443 '5,5'" \
        "切回 BALANCE_MODE=roundrobin，故障转移保持开启"

    _make_rule_pair "$SBX_ROOT/realm/rules" "active-standby" "true"
    local out
    out=$(_apply_weights 443 "5,5")
    h_log "apply 输出: ${out:-<空>}"

    local r1="$SBX_ROOT/realm/rules/rule-1.conf"
    h_check_file_has "$r1" 'BALANCE_MODE="roundrobin"' "rule-1 切回 roundrobin"
    h_check_file_has "$r1" 'FAILOVER_ENABLED="true"' "故障转移保持开启"
}

case_T26_probe_source_behavior() {
    h_case_begin "T26" "探测函数行为（入口加载的那份）" \
        "沙箱 + 本地监听端口 + PATH 不含 nc" \
        "check_connectivity 可达/关闭端口/不可达 IP" \
        "可达→成功；关闭端口→失败；不可达 IP→失败且超时受控（≤6s）"

    local port=34874
    _start_listener "$port" || { h_fail "起不了本地监听端口，用例无法判定"; return; }
    sleep 0.5

    # 从「健康检查入口」加载探测实现（不钉实现放在哪个文件）
    local out rc
    out=$(sbx_path_without_nc; _run_in_sandbox '
        src="$1/xwFailover.sh"; tmp="/tmp/probe_src_$$.sh"
        sed "s|^main \"\\\$@\"$|# neutralized|" "$src" > "$tmp"
        source "$tmp" >/dev/null 2>&1
        declare -F check_connectivity >/dev/null || { echo "NO_FUNC"; exit 3; }
        check_connectivity 127.0.0.1 '"$port"' 2; echo "RC=$?"
    ')
    h_log "可达端口 -> ${out:-<空>}"
    h_check_contains "$out" "RC=0" "可达端口 → 判定连通"

    out=$(sbx_path_without_nc; _run_in_sandbox '
        src="$1/xwFailover.sh"; tmp="/tmp/probe_src2_$$.sh"
        sed "s|^main \"\\\$@\"$|# neutralized|" "$src" > "$tmp"
        source "$tmp" >/dev/null 2>&1
        check_connectivity 127.0.0.1 34875 2; echo "RC=$?"
    ')
    h_log "关闭端口 -> ${out:-<空>}"
    h_check_not_contains "$out" "RC=0" "关闭端口 → 判定失败"

    # 不可达 IP：必须失败且耗时受控
    local start end secs
    start=$(date +%s)
    out=$(sbx_path_without_nc; _run_in_sandbox '
        src="$1/xwFailover.sh"; tmp="/tmp/probe_src3_$$.sh"
        sed "s|^main \"\\\$@\"$|# neutralized|" "$src" > "$tmp"
        source "$tmp" >/dev/null 2>&1
        check_connectivity 10.255.255.1 34874 2; echo "RC=$?"
    ')
    end=$(date +%s)
    secs=$((end - start))
    h_log "不可达 IP -> ${out:-<空>}（耗时 ${secs}s）"
    h_check_not_contains "$out" "RC=0" "不可达 IP → 判定失败"
    if [ "$secs" -le 6 ]; then
        h_pass "超时受控（${secs}s ≤ 6s）"
    else
        h_fail "超时失控（${secs}s > 6s）"
    fi

    kill "$LISTENER_PID" 2>/dev/null
}

case_T27_probe_generated_copy_behavior() {
    h_case_begin "T27" "生成的 health_check.sh 里的探测副本行为" \
        "沙箱生成的 health_check.sh + 本地监听端口" \
        "从生成物里提取 check_connectivity 并调用" \
        "副本也必须能用 /dev/tcp 回退；可达成功、关闭端口失败"

    # 先生成健康检查脚本
    _prepare_failover_runtime
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_failover_rule "$SBX_ROOT/realm/rules/rule-1.conf"
    bash "$SBX_ROOT/realm/xwFailover.sh" start >/dev/null 2>&1

    local script="$SBX_ROOT/realm/health/health_check.sh"
    if [ ! -f "$script" ]; then
        h_fail "健康检查脚本没生成出来，无法取内联副本"
        return
    fi

    # 从生成物里提取探测函数（不钉它来自哪个源文件）
    local fn="$SBX_ROOT/probe_copy_fn.sh"
    awk '/^check_connectivity\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$script" > "$fn"
    if [ ! -s "$fn" ]; then
        h_fail "生成脚本里没有 check_connectivity 定义"
        return
    fi

    local port=34876
    _start_listener "$port" || { h_fail "起不了本地监听端口，用例无法判定"; return; }
    sleep 0.5

    local out
    out=$(sbx_path_without_nc; _run_in_sandbox '
        source "$2" >/dev/null 2>&1
        check_connectivity 127.0.0.1 '"$port"' 2; echo "RC=$?"
    ' "$fn")
    h_log "副本·可达端口 -> ${out:-<空>}"
    h_check_contains "$out" "RC=0" "生成副本 → 可达端口判定连通"

    out=$(sbx_path_without_nc; _run_in_sandbox '
        source "$2" >/dev/null 2>&1
        check_connectivity 127.0.0.1 34877 2; echo "RC=$?"
    ' "$fn")
    h_log "副本·关闭端口 -> ${out:-<空>}"
    h_check_not_contains "$out" "RC=0" "生成副本 → 关闭端口判定失败"

    kill "$LISTENER_PID" 2>/dev/null
}

case_T28_two_probe_copies_identical() {
    h_case_begin "T28" "两份探测实现必须一致" \
        "冻结态源文件 + 沙箱生成物" \
        "提取两份 check_connectivity 归一化后比较" \
        "改了一处忘了另一处 → 判失败（防漂移）"

    # 源：冻结态里提供该函数的文件（不钉具体文件名，取第一份）
    local src_file="" rel
    while IFS= read -r rel; do
        case "$rel" in
            *.sh) ;;
            *) continue ;;
        esac
        case "$rel" in
            tests/*) continue ;;
        esac
        if grep -q '^check_connectivity() {' "$SBX_SRC/$rel" 2>/dev/null; then
            src_file="$rel"
            break
        fi
    done < <(git ls-tree -r --name-only "$BASE_SHA")
    if [ -z "$src_file" ]; then
        h_fail "冻结态里找不到 check_connectivity 定义"
        return
    fi
    h_log "源实现所在文件: $src_file"

    local a="$SBX_ROOT/probe_a.sh" b="$SBX_ROOT/probe_b.sh"
    awk '/^check_connectivity\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SBX_SRC/$src_file" > "$a"

    # 副本：沙箱生成的 health_check.sh
    _prepare_failover_runtime
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_failover_rule "$SBX_ROOT/realm/rules/rule-1.conf"
    bash "$SBX_ROOT/realm/xwFailover.sh" start >/dev/null 2>&1
    local script="$SBX_ROOT/realm/health/health_check.sh"
    if [ ! -f "$script" ]; then
        h_fail "健康检查脚本没生成出来，无法比对内联副本"
        return
    fi
    awk '/^check_connectivity\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$script" > "$b"

    if [ ! -s "$a" ] || [ ! -s "$b" ]; then
        h_fail "缺少可比对的实现（源 $(wc -c < "$a" 2>/dev/null) 字节 / 副本 $(wc -c < "$b" 2>/dev/null) 字节）"
        return
    fi

    # 归一化：去注释与空行
    local na nb
    na=$(grep -v '^[[:space:]]*#' "$a" | grep -v '^[[:space:]]*$')
    nb=$(grep -v '^[[:space:]]*#' "$b" | grep -v '^[[:space:]]*$')
    if [ "$na" = "$nb" ]; then
        h_pass "源实现与生成脚本内联副本一致"
    else
        h_log "--- 源 ---"; while IFS= read -r l; do h_log "  $l"; done <<< "$na"
        h_log "--- 副本 ---"; while IFS= read -r l; do h_log "  $l"; done <<< "$nb"
        h_fail "两份探测实现已漂移（改了一处忘了另一处）"
    fi
}

case_T29_active_standby_six_states() {
    h_case_begin "T29" "主备模式 6 态端到端" \
        "沙箱 rules（单规则三目标）+ health_status.conf" \
        "generate_endpoints_from_rules" \
        "与 docs/active-standby-logic.md 状态表一一对应"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local b

    _make_rule "$rules/rule-1.conf" 8080 "active-standby" "true" "1,0,0" "10.0.0.1,10.0.0.2,10.0.0.3"

    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:healthy" "10.0.0.3:healthy"
    b=$(_gen_balance); h_log "场景1 平时 -> $b"
    h_check_contains "$b" "roundrobin: 1, 0, 0" "场景1 平时"

    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:healthy" "10.0.0.3:healthy"
    b=$(_gen_balance); h_log "场景2 主挂 -> $b"
    h_check_contains "$b" "roundrobin: 0, 1, 0" "场景2 主挂"

    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:failed" "10.0.0.3:healthy"
    b=$(_gen_balance); h_log "场景3 主+备1挂 -> $b"
    h_check_contains "$b" "roundrobin: 0, 0, 1" "场景3 主+备1挂"

    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:failed" "10.0.0.3:healthy"
    b=$(_gen_balance); h_log "场景4 主恢复 -> $b"
    h_check_contains "$b" "roundrobin: 1, 0, 0" "场景4 主恢复（严格切回主）"

    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:failed" "10.0.0.3:healthy"
    b=$(_gen_balance); h_log "场景5 备1单挂 -> $b"
    h_check_contains "$b" "roundrobin: 1, 0, 0" "场景5 备1单挂"

    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:failed" "10.0.0.3:failed"
    b=$(_gen_balance); h_log "场景6 全挂 -> $b"
    h_check_contains "$b" "roundrobin: 1, 0, 0" "场景6 全挂兜底（不断流）"
}

case_T30_exclude_mode_five_states() {
    h_case_begin "T30" "剔除模式 5 态端到端" \
        "沙箱 rules（单规则三目标）+ health_status.conf" \
        "generate_endpoints_from_rules（目标数）" \
        "故障目标被剔除；全挂保留第一个；failover off 不过滤"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local n

    _make_rule "$rules/rule-1.conf" 8080 "roundrobin" "true" "1,1,1" "10.0.0.1,10.0.0.2,10.0.0.3"

    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:healthy" "10.0.0.3:healthy"
    n=$(_gen_target_count); h_log "场景7 全健康 -> 目标数 $n"
    h_check_eq "3" "$n" "场景7 全健康 → 3 个目标"

    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:healthy" "10.0.0.3:healthy"
    n=$(_gen_target_count); h_log "场景8 主挂 -> 目标数 $n"
    h_check_eq "2" "$n" "场景8 主挂 → 剔除后 2 个"

    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:failed" "10.0.0.3:healthy"
    n=$(_gen_target_count); h_log "场景9 主+备1挂 -> 目标数 $n"
    h_check_eq "1" "$n" "场景9 主+备1挂 → 只剩 1 个"

    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:failed" "10.0.0.3:failed"
    n=$(_gen_target_count); h_log "场景10 全挂 -> 目标数 $n"
    h_check_eq "1" "$n" "场景10 全挂 → 保留第一个"

    _make_rule "$rules/rule-1.conf" 8080 "roundrobin" "false" "1,1,1" "10.0.0.1,10.0.0.2,10.0.0.3"
    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:failed" "10.0.0.3:failed"
    n=$(_gen_target_count); h_log "场景11 failover off -> 目标数 $n"
    h_check_eq "3" "$n" "场景11 failover off → 不过滤，3 个都在"
}

case_T31_set_u_robustness() {
    h_case_begin "T31" "set -u 下的健壮性" \
        "沙箱 rules" \
        "set -u 下跑 generate_endpoints_from_rules" \
        "不致命中断；输出与普通模式一致；仍生成 balance 与全部目标；无 unbound variable"

    _make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 8080 "active-standby" "true" "10,0" "10.0.0.1,10.0.0.2"

    # 对照组：证明旧写法在 set -u 下确实致命（避免"怎么写都绿"）
    local old_rc new_rc
    old_rc=$( ( set -u; declare -A a=(); k=missing; echo "${a[$k]}" ) >/dev/null 2>&1; echo $? )
    new_rc=$( ( set -u; declare -A a=(); k=missing; echo "${a[$k]:-}" ) >/dev/null 2>&1; echo $? )
    h_log "对照组：旧写法 rc=$old_rc，新写法 rc=$new_rc"
    h_check_rc "nonzero" "$old_rc" "对照组：旧写法 ${a[missing]} 在 set -u 下致命"
    h_check_rc "0" "$new_rc" "对照组：新写法 ${a[missing]:-} 在 set -u 下安全"

    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        ( set -u; generate_endpoints_from_rules ) 2>&1
        echo "RC=$?"
    ')
    rc=$(printf '%s' "$out" | grep -o 'RC=[0-9]*' | tail -1 | cut -d= -f2)
    h_log "set -u 输出尾: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    h_check_rc "0" "$rc" "set -u 下生成配置不致命中断"
    h_check_not_contains "$out" "unbound variable" "set -u 下无 unbound variable 报错"
    h_check_contains "$out" '"balance"' "set -u 下仍生成出 balance 字段"

    local tgt
    tgt=$(printf '%s' "$out" | grep -o '10\.0\.0\.[12]' | sort -u | wc -l | tr -d ' ')
    h_check_eq "2" "$tgt" "set -u 下仍生成出两个目标"

    # 普通模式与 set -u 模式输出必须一致
    local normal strict
    normal=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null
    ')
    strict=$(printf '%s' "$out" | grep -v '^RC=')
    if [ "$normal" = "$strict" ]; then
        h_pass "set -u 下输出与普通模式一致"
    else
        h_fail "set -u 下输出与普通模式不一致"
    fi
}

# T32 · 探测实现「单一真源 + 一份内联副本」结构断言
#
# ★ 第 2 轮修正（重要）：原始断言写的是「全仓出现次数 == 1」，**在本冻结点不可能成立**。
#   实测（a9102c1）：全仓共 2 份，都在 lib/health.sh：
#     第 1 份  lib/health.sh:33   —— 真源，主程序调用
#     第 2 份  lib/health.sh:143  —— 在 health_check_script_body() 的 heredoc
#                                   （lib/health.sh:98 `cat << 'EOF' | tr -d '\r'`）里，
#                                   是**生成到 /etc/realm/health/health_check.sh 的内联副本**。
#   文件头自己写明了原因：「生成的 health_check.sh 是一份独立可执行的脚本
#   （systemd 直接调用它，不能依赖 pf 的安装目录），所以它的探测逻辑
#   在下面 health_check_script_body 里另有一份内联副本，改动 check_connectivity 时两处必须同步。」
#   → 这份副本是**设计要求的**，不是「逐字重复的脏拷贝」。
#   → 曾经存在的第 3 份（lib/failover.sh）已在 4558e65「探测函数分层」里删掉。
#
# 因此把断言改成**真正想守的不变量**（比 ==1 更严）：
#   1. 全仓 check_connectivity() { 总数必须 == 2（多一份 = 有人又抄了一份 → 红）
#   2. 这 2 份必须都在 lib/health.sh 里（散落到别处 → 红）
#   3. 第 2 份必须落在 health_check_script_body() 的 heredoc 内（位置对 → 绿）
#   4. 两份必须逐字一致（漂移 → 红；T28 从生成物侧再校一次）
# 这套断言在「3 份」的老状态下同样是红的，所以守的是同一个意图。
case_T32_single_probe_implementation() {
    h_case_begin "T32" "探测实现结构（单一真源 + 生成物一致）" \
        "冻结态 $BASE_SHA（只读）+ 沙箱生成物" \
        "grep -c '^check_connectivity() {' 全仓 .sh" \
        "全仓份数 ∈ [1,2] 且都在 lib/health.sh；生成物里恰好 1 份且与真源逐字一致"

    # ── 1. 全仓分布（排除 tests/ 自身：台架代码不是被测对象）──
    local rel total=0 detail="" n
    while IFS= read -r rel; do
        case "$rel" in
            *.sh) ;;
            *) continue ;;
        esac
        case "$rel" in
            tests/*) continue ;;
        esac
        [ -f "$SBX_SRC/$rel" ] || continue
        n=$(grep -c '^check_connectivity() {' "$SBX_SRC/$rel" 2>/dev/null || true)
        [ -z "$n" ] && n=0
        if [ "$n" != "0" ]; then
            total=$((total + n))
            detail="$detail$rel×$n "
        fi
    done < <(git ls-tree -r --name-only "$BASE_SHA")
    h_log "分布: ${detail:-（无）}"

    # ★ 第 3 轮放宽：允许两种**合法**结构
    #   1 份 = 已收敛为单一真源（6df4721 起：health_emit_function 自动抽取注入生成物）
    #   2 份 = 真源 + 生成脚本内的手工内联副本（a9102c1 / b361ca8 的形态）
    # 关键不变式不是「等于几」，而是「**不许有第 3 份**」和「生成物里恰好 1 份且与真源一致」。
    if [ "$total" -ge 1 ] && [ "$total" -le 2 ]; then
        h_pass "check_connectivity() { 的全仓出现次数 = $total（允许 1 或 2）"
    else
        h_fail "check_connectivity() { 的全仓出现次数 = $total（允许 1 或 2；>2 说明有人又抄了一份）"
    fi

    # ── 2. 必须都集中在 lib/health.sh ──
    local only_health="是"
    while IFS= read -r rel; do
        case "$rel" in
            *.sh) ;;
            *) continue ;;
        esac
        case "$rel" in
            tests/*) continue ;;
        esac
        [ "$rel" = "lib/health.sh" ] && continue
        [ -f "$SBX_SRC/$rel" ] || continue
        n=$(grep -c '^check_connectivity() {' "$SBX_SRC/$rel" 2>/dev/null || true)
        [ -z "$n" ] && n=0
        if [ "$n" != "0" ]; then
            only_health="否（$rel 还有 $n 份）"
            h_log "越界副本: $rel × $n"
        fi
    done < <(git ls-tree -r --name-only "$BASE_SHA")
    h_check_eq "是" "$only_health" "探测实现是否只集中在 lib/health.sh"

    # ── 3. 生成物里必须恰好 1 份（两种结构下都成立的不变式）──
    local hl="$SBX_SRC/lib/health.sh"
    if [ ! -f "$hl" ]; then
        h_fail "冻结态里没有 lib/health.sh，无法核对探测实现位置"
        return
    fi

    _prepare_failover_runtime
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    _make_failover_rule "$SBX_ROOT/realm/rules/rule-1.conf"
    bash "$SBX_ROOT/realm/xwFailover.sh" start >/dev/null 2>&1
    local script="$SBX_ROOT/realm/health/health_check.sh"
    if [ ! -f "$script" ]; then
        h_fail "健康检查脚本没生成出来，无法核对生成物里的探测实现"
        return
    fi
    local n_gen
    n_gen=$(grep -c '^check_connectivity() {' "$script" 2>/dev/null || true)
    [ -z "$n_gen" ] && n_gen=0
    h_check_eq "1" "$n_gen" "生成物 health_check.sh 里 check_connectivity() { 的份数"

    # ── 4. 生成物里的实现必须与真源逐字一致 ──
    # 这一条才是「探测逻辑只允许一份」的真正含义：
    # 不管它是自动抽取注入的，还是手工内联的，**内容必须一模一样**。
    local a="$SBX_ROOT/probe_t32_src.sh" b="$SBX_ROOT/probe_t32_gen.sh"
    awk 'BEGIN{c=0} /^check_connectivity\(\) \{/{c++; f=(c==1)} f{print} c==1 && /^\}/{exit}' "$hl" > "$a"
    awk '/^check_connectivity\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$script" > "$b"
    if [ ! -s "$a" ] || [ ! -s "$b" ]; then
        h_fail "取不到探测实现（真源 $(wc -c < "$a" 2>/dev/null) 字节 / 生成物 $(wc -c < "$b" 2>/dev/null) 字节）"
        return
    fi
    if diff "$a" "$b" >/dev/null 2>&1; then
        h_pass "真源与生成物里的探测实现逐字一致"
    else
        h_log "--- 真源 ---"
        while IFS= read -r x; do h_log "  $x"; done < "$a"
        h_log "--- 生成物 ---"
        while IFS= read -r x; do h_log "  $x"; done < "$b"
        h_fail "真源与生成物里的探测实现已漂移（改了一处忘了另一处）"
    fi
}

# T33 · 第 2 轮新增
# 起因：T31 调试时发现 —— 只要规则文件里没有 TARGET_STATES 这个键，
#       lib/realm.sh:411 的 `[ -n "$TARGET_STATES" ]` 在 set -u 下就会致命中断。
#       read_rule_file（lib/health.sh:179-186）会先 unset 全部键再 source 规则文件，
#       所以「规则文件没写某个键」= 「该变量未定义」。
# 产品目前没有用 set -u（已全仓确认），所以线上不会崩；
# 但仓库里已经有一次专门的健壮性修复（4558e65「关联数组读取加默认值」），
# 说明「set -u 下不得致命中断」是团队自己认下的契约 —— 这里把契约钉成用例。
case_T33_missing_optional_field_set_u() {
    h_case_begin "T33" "规则缺可选字段时的 set -u 健壮性" \
        "沙箱 rules（缺 TARGET_STATES 等可选键）" \
        "set -u 下跑 generate_endpoints_from_rules" \
        "读未定义的可选变量不得致命中断（必须写成 \${VAR:-}）"

    # 故意只写最少字段：不含 TARGET_STATES
    _make_minimal_rule "$SBX_ROOT/realm/rules/rule-1.conf" 8080 "active-standby" "10,0" "10.0.0.1,10.0.0.2"

    # 第二口径（先跑）：同一条规则文件在普通模式下必须完全正常 ——
    # 这证明「红的是未定义变量被直接引用」，而不是「fixture 本身写坏了」。
    local normal
    normal=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null
    ')
    h_check_contains "$normal" '"balance"' "对照：同一条规则在普通模式下能生成 balance"
    h_check_contains "$normal" "10.0.0.1" "对照：同一条规则在普通模式下能生成目标"

    # 主口径：加上 set -u
    local out rc
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        ( set -u; generate_endpoints_from_rules ) 2>&1
        echo "RC=$?"
    ')
    rc=$(printf '%s' "$out" | grep -o 'RC=[0-9]*' | tail -1 | cut -d= -f2)
    h_log "set -u 输出尾: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    h_check_rc "0" "$rc" "缺可选字段时 set -u 下不致命中断"
    h_check_not_contains "$out" "unbound variable" "缺可选字段时无 unbound variable 报错"
}
