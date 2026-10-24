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

# T32 · 探测实现：唯一手写真源 + 生成物与真源一致（**形态无关**）
#
# ── 这条用例守的不变量 ───────────────────────────────────────────
#   「健康检查的探测实现只有一份手写真源；生成的 health_check.sh 用的探测逻辑
#     与那份真源**逐字一致**。」
#
# ── 第 7 轮修正：条件 4 之前钉死了「内嵌」这一种实现形态 ─────────
#   旧条件 4 写的是「生成物 health_check.sh 里 check_connectivity() { 的份数 == 1」，
#   这只对「机械抽取内嵌」这一种形态成立。将来如果把生成物改成
#   「显式 source 已安装的真源」（依赖更少、漂移风险更低，是产品变好），
#   份数会变成 0 → **误红**。断言钉住的是形态，而不是不变式。
#
#   现在条件 4 判的是「生成物的探测逻辑与真源是否一致」，两种合法形态都判过：
#     形态 A：生成物内含 1 份 check_connectivity() {，且与真源逐字一致 → 过
#     形态 B：生成物不含内嵌副本，但显式 source 已安装的真源
#             （且该 source 路径能解析到真源、那份真源与基准逐字一致）→ 过
#     其余（内嵌多份 / 逐字漂移 / 既不内嵌也不 source / source 路径解析不到）→ 红
#
#   条件 1/2/3 守的是**源码树**（唯一真源、集中在 lib/health.sh），
#   它们对两种形态都成立，不受影响。
#
# ── 第 7 轮修正：条件 5 的扫描正则收紧 ───────────────────────────
#   旧正则 `另有一份内联副本|两处必须同步` 漏掉了真实存在的过时说法
#   「内含一份同源的探测副本，改动需两处同步」——「需两处同步」≠「两处必须同步」，
#   「内含一份同源」≠「另有一份内联」。现在：
#     ① 只匹配**肯定误导句式**（真的在说要手工同步两份）；
#     ② 同一行若含否定词（不需要 / 不存在 / 无需 / 也不再 / 不再 …）→ 豁免该行；
#     ③ 加**扫描范围下限护栏**（扫描到的候选文件数 ≥ N）——
#        「违规数 == 0」这类断言最大的假绿风险是「扫描器什么都没扫」，
#        正则一坏 / 路径过滤一改就永远 0 命中 → 绿灯假象。护栏把它挡住。
#
# ★ 每条负向对照都**先验证破坏手法生效**（注入处数 == 1）再信它的红 ——
#   「怎么写都绿的断言等于没写」；「破坏没生效的红」比「红」更误导。

# ── T32 的判定器（可复用：真实产物 + 负向对照变体走**同一条**判定）──────────

# 抽出某个文件里 check_connectivity() 的实现文本（从函数头到顶格 '}'）
_t32_extract_fn() {
    awk '/^check_connectivity\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$1" 2>/dev/null
}

# 判定器 1：生成物的探测实现与真源是否一致（形态 A / B 都判过）
# 用法：_t32_judge_probe <生成物路径> <基准真源路径>
# 输出："<PASS|FAIL>\t<说明>"；返回码 0 = PASS
_t32_judge_probe() {
    local script="$1" baseline="$2"
    local n_gen form eff base src_line src_path resolved

    n_gen=$(grep -c '^check_connectivity() {' "$script" 2>/dev/null || true)
    [ -z "$n_gen" ] && n_gen=0

    if [ "$n_gen" -ge 2 ]; then
        printf 'FAIL\t生成物里内嵌了 %s 份探测实现（多份 = 又抄了一份）\n' "$n_gen"
        return 1
    fi

    if [ "$n_gen" -eq 1 ]; then
        form="形态A（生成物内嵌副本）"
        eff=$(_t32_extract_fn "$script")
    else
        # 形态 B：生成物不含内嵌副本，但显式 source 已安装的真源
        src_line=$(grep -nE '(^|[[:space:]])(source|\.)[[:space:]]+[^[:space:]]*health\.sh' "$script" 2>/dev/null | head -1)
        if [ -z "$src_line" ]; then
            printf 'FAIL\t生成物既不含内嵌副本，也没有 source 真源\n'
            return 1
        fi
        src_path=$(printf '%s' "${src_line#*:}" | sed -E 's/.*(source|\.)[[:space:]]+([^[:space:]]*health\.sh).*/\2/')
        case "$src_path" in
            /*) resolved="$src_path" ;;
            *)  resolved="$(dirname "$script")/$src_path" ;;
        esac
        if [ ! -f "$resolved" ]; then
            printf 'FAIL\t形态B 的 source 路径解析不到真源：%s\n' "$src_path"
            return 1
        fi
        if ! grep -q '^check_connectivity() {' "$resolved" 2>/dev/null; then
            printf 'FAIL\t形态B source 的文件里没有探测实现：%s\n' "$resolved"
            return 1
        fi
        form="形态B（生成物 source 真源）"
        eff=$(_t32_extract_fn "$resolved")
    fi

    base=$(_t32_extract_fn "$baseline")
    if [ -z "$base" ] || [ -z "$eff" ]; then
        printf 'FAIL\t取不到探测实现（基准 %s 字节 / 生成物 %s 字节）\n' "${#base}" "${#eff}"
        return 1
    fi
    if [ "$eff" = "$base" ]; then
        printf 'PASS\t%s：与真源逐字一致\n' "$form"
        return 0
    fi
    printf 'FAIL\t%s：与真源逐字漂移\n' "$form"
    return 1
}

# 判定器 2：仓库里是否仍出现「要手工同步两份探测实现」的**肯定**误导句式
# 用法：_t32_scan_stale <扫描根目录> <相对路径清单>
#   命中行写到 $SBX_ROOT/t32_stale_hits.txt
#   T32_SCAN_N = 实际扫描到的文件数；T32_STALE_HITS = 命中行数
#
# 正则口径（为什么这么写）：
#   「误导」= 在**肯定**地说「改动 X 要动两处」。所以：
#     · 只匹配带「改动…两处…同步」这类**动作语义**的句式；
#     · 描述性的「内含一份同源的探测副本」单独出现时**不算违规** ——
#       形态 A 下生成物确实含一份副本，这句话是真的；只有「要手工同步」才是假的。
#       （把它也算违规 = 又把断言钉回「内嵌」这一种形态，第 7 轮要避免的正是这个。）
#     · 否定句（不需要 / 不再 / 无需 …）豁免整行 —— 「不需要两处同步」是对的写法。
_T32_STALE_RE='改动[^，。；、]{0,40}两处[^，。；、]{0,6}同步|两处必须同步|需两处同步|必须两处同步|改动[^，。；、]{0,40}两处[^，。；、]{0,6}手工同步'
_T32_NEG_RE='不需要|不存在|无需|无须|不再|不必|不用|不涉及|并非|没有'
# 扫描范围下限护栏：实测候选文件 28 个（6a1e8a1），取约一半。
# 作用：挡住「扫描器一个文件都没扫 → 违规数必然 0 → 假绿」。
_T32_SCAN_FLOOR=14

_t32_candidate_list() {
    local rel
    while IFS= read -r rel; do
        case "$rel" in
            tests/*|reports/*) continue ;;
        esac
        case "$rel" in
            lib/*|cmd/*|docs/*|notifications/*) ;;
            *.sh|*.md) ;;
            *) continue ;;
        esac
        printf '%s\n' "$rel"
    done < <(git ls-tree -r --name-only "$BASE_SHA")
}

_t32_scan_stale() {
    local root="$1" list="$2"
    local rel l text
    T32_SCAN_N=0
    T32_STALE_HITS=0
    : > "$SBX_ROOT/t32_stale_hits.txt"
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        [ -f "$root/$rel" ] || continue
        T32_SCAN_N=$((T32_SCAN_N + 1))
        while IFS= read -r l; do
            [ -z "$l" ] && continue
            text="${l#*:}"
            # 同一行含否定词 → 豁免（这是否定句，不是肯定误导句式）
            if printf '%s' "$text" | grep -qE "$_T32_NEG_RE"; then
                h_log "  豁免（含否定词）: $rel:${l%%:*}  $(printf '%s' "$text" | cut -c1-90)"
                continue
            fi
            T32_STALE_HITS=$((T32_STALE_HITS + 1))
            printf '%s\n' "$rel:$l" >> "$SBX_ROOT/t32_stale_hits.txt"
        done < <(grep -nE "$_T32_STALE_RE" "$root/$rel" 2>/dev/null || true)
    done < "$list"
}

case_T32_single_probe_implementation() {
    h_case_begin "T32" "探测实现：唯一手写真源 + 生成物与真源逐字一致（形态无关）" \
        "冻结态 $BASE_SHA（只读）+ 沙箱生成物" \
        "生成物 health_check.sh 的探测实现 vs 真源（形态 A 内嵌 / 形态 B source 都判过）+ 扫仓库里的「要手工同步」句式" \
        "全仓手写份数 == 1 且集中在 lib/health.sh；生成物的探测实现与真源逐字一致（形态无关）；仓库无肯定误导句式"

    local hl="$SBX_SRC/lib/health.sh"

    # ── 1. 全仓手写份数必须 == 1（多一份 = 有人又手抄了一份）──
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
    h_log "手写份数分布: ${detail:-（无）}"
    h_check_eq "1" "$total" "check_connectivity() { 的全仓手写份数（唯一真源）"

    # ── 2. 这 1 份必须在 lib/health.sh（散落到别处 → 红）──
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

    # ── 3. 生成脚本所在文件里仍只有 1 处 ──
    # 守的是**源码树**的性质（真源在 lib/health.sh 里），
    # 对「生成物内嵌」和「生成物 source」两种形态都成立。
    local body_file=""
    while IFS= read -r rel; do
        case "$rel" in
            *.sh) ;;
            *) continue ;;
        esac
        case "$rel" in
            tests/*) continue ;;
        esac
        [ -f "$SBX_SRC/$rel" ] || continue
        if grep -q '^health_check_script_body() {' "$SBX_SRC/$rel" 2>/dev/null; then
            body_file="$rel"
            break
        fi
    done < <(git ls-tree -r --name-only "$BASE_SHA")
    h_log "health_check_script_body() 所在文件: ${body_file:-（未找到）}"
    if [ -z "$body_file" ]; then
        h_fail "冻结态里找不到 health_check_script_body()"
    else
        n=$(grep -c '^check_connectivity() {' "$SBX_SRC/$body_file" 2>/dev/null || true)
        [ -z "$n" ] && n=0
        h_check_eq "1" "$n" "生成脚本所在文件里 check_connectivity() { 的处数"
    fi

    # ── 4. 生成物的探测实现必须与真源逐字一致（**形态无关**）──
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

    # 基准 = 沙箱可执行副本（冻结态 + 与被测同款重定向）——
    # 生成器（health_emit_function）抽取的就是这一份，所以比较是同源对同源。
    local baseline="$SBX_RUN/lib/health.sh"
    # 附带的保真度断言：沙箱重定向**不得改变**探测实现的文本
    # （改了的话，下面比的就是「副本 vs 副本」，不是「真源 vs 生成物」）。
    local t_frozen t_base
    t_frozen=$(_t32_extract_fn "$hl")
    t_base=$(_t32_extract_fn "$baseline")
    if [ "$t_frozen" = "$t_base" ]; then
        h_pass "沙箱重定向未改变探测实现的文本（真源 = 冻结态原样）"
    else
        h_fail "沙箱重定向改变了探测实现的文本：真源 ${#t_frozen} 字节 vs 沙箱副本 ${#t_base} 字节（下面的比较将不可信）"
    fi

    local verdict detail
    verdict=$(_t32_judge_probe "$script" "$baseline")
    detail=$(printf '%s' "$verdict" | cut -f2-)
    h_log "条件 4 判定: $(printf '%s' "$verdict" | cut -f1) —— $detail"
    h_check_contains "$verdict" "PASS" "生成物的探测实现与真源一致（形态 A/B 都判过）：$detail"

    # ── 负向对照 1：形态 B（生成物改成 source 真源）→ 必须判过 ──
    # 造一个形态 B 的变体：去掉内嵌副本，改成 source 已安装的真源。
    local formB="$SBX_ROOT/t32_formB.sh" formB_body="$SBX_ROOT/t32_formB.body"
    local real_src="$SBX_ROOT/realm/lib/health.sh"
    awk '
        /^check_connectivity\(\) \{/ { inb=1; next }
        inb { if ($0 ~ /^\}/) { inb=0 } ; next }
        { print }
    ' "$script" > "$formB_body"
    {
        head -1 "$formB_body"
        echo "source $real_src"
        tail -n +2 "$formB_body"
    } > "$formB"
    local formB_inj n_formB
    formB_inj=$(grep -c '^source ' "$formB" 2>/dev/null || true)
    n_formB=$(grep -c '^check_connectivity() {' "$formB" 2>/dev/null || true)
    [ -z "$formB_inj" ] && formB_inj=0
    [ -z "$n_formB" ] && n_formB=0
    h_log "负向对照 1 构造：形态 B 变体（内嵌副本 $n_formB 份 / source $formB_inj 处）"
    h_check_eq "1" "$formB_inj" "负向对照 1 的破坏手法生效（形态 B 变体确实 source 了真源）"
    h_check_eq "0" "$n_formB" "负向对照 1 的破坏手法生效（形态 B 变体确实不含内嵌副本）"
    local v_formB
    v_formB=$(_t32_judge_probe "$formB" "$baseline")
    h_log "形态 B 判定: $(printf '%s' "$v_formB" | cut -f1) —— $(printf '%s' "$v_formB" | cut -f2-)"
    h_check_contains "$v_formB" "PASS" "负向对照 1：形态 B（source 真源）必须判过"
    h_check_contains "$v_formB" "形态B" "负向对照 1：形态 B 被识别成形态 B（不是碰巧内嵌）"

    # ── 负向对照 2：内嵌副本逐字漂移 → 必须判红 ──
    local drift="$SBX_ROOT/t32_drift.sh"
    awk '/^check_connectivity\(\) \{/{print; print "    : # T32-NEG-DRIFT 注入"; next} {print}' \
        "$script" > "$drift"
    local drift_inj
    drift_inj=$(grep -c 'T32-NEG-DRIFT' "$drift" 2>/dev/null || true)
    [ -z "$drift_inj" ] && drift_inj=0
    h_check_eq "1" "$drift_inj" "负向对照 2 的破坏手法生效（漂移注入点 == 1）"
    local v_drift
    v_drift=$(_t32_judge_probe "$drift" "$baseline")
    h_log "漂移判定: $(printf '%s' "$v_drift" | cut -f1) —— $(printf '%s' "$v_drift" | cut -f2-)"
    h_check_contains "$v_drift" "FAIL" "负向对照 2：内嵌副本逐字漂移必须判红"
    h_check_contains "$v_drift" "漂移" "负向对照 2：判红原因指到「逐字漂移」"

    # ── 负向对照 3：内嵌多份 → 必须判红 ──
    local dup="$SBX_ROOT/t32_dup.sh"
    { cat "$script"; _t32_extract_fn "$script"; } > "$dup"
    local n_dup
    n_dup=$(grep -c '^check_connectivity() {' "$dup" 2>/dev/null || true)
    [ -z "$n_dup" ] && n_dup=0
    h_check_eq "2" "$n_dup" "负向对照 3 的构造生效（内嵌 2 份）"
    local v_dup
    v_dup=$(_t32_judge_probe "$dup" "$baseline")
    h_log "多份判定: $(printf '%s' "$v_dup" | cut -f1) —— $(printf '%s' "$v_dup" | cut -f2-)"
    h_check_contains "$v_dup" "FAIL" "负向对照 3：内嵌多份必须判红"

    # ── 负向对照 4：既不内嵌也不 source → 必须判红 ──
    local none="$SBX_ROOT/t32_none.sh"
    cp "$formB_body" "$none"
    local n_none
    n_none=$(grep -c '^check_connectivity() {' "$none" 2>/dev/null || true)
    [ -z "$n_none" ] && n_none=0
    h_check_eq "0" "$n_none" "负向对照 4 的构造生效（内嵌 0 份）"
    local v_none
    v_none=$(_t32_judge_probe "$none" "$baseline")
    h_log "既无内嵌也无 source 判定: $(printf '%s' "$v_none" | cut -f1) —— $(printf '%s' "$v_none" | cut -f2-)"
    h_check_contains "$v_none" "FAIL" "负向对照 4：既不内嵌也不 source 必须判红"

    # ── 5. 仓库里不得再出现「要手工同步两份探测实现」的肯定误导句式 ──
    # 实现已经改成机械抽取（health_emit_function），文档/注释再说「改动要两处同步」就是骗人。
    # 扫描范围：产品代码 + 面向用户的文档；排除 tests/（台架自己）与 reports/（历史报告）。
    local list="$SBX_ROOT/t32_candidates.txt"
    _t32_candidate_list > "$list"
    _t32_scan_stale "$SBX_SRC" "$list"
    h_log "条件 5 扫描了 $T32_SCAN_N 个候选文件，命中 $T32_STALE_HITS 行"
    if [ -s "$SBX_ROOT/t32_stale_hits.txt" ]; then
        while IFS= read -r l; do
            h_log "  过时字样: $(printf '%s' "$l" | cut -c1-160)"
        done < "$SBX_ROOT/t32_stale_hits.txt"
    fi
    # 扫描范围下限护栏：候选文件一个都没扫到 → 「违规数 == 0」就是假绿
    h_check_ge "$_T32_SCAN_FLOOR" "$T32_SCAN_N" "条件 5 的扫描范围下限护栏（扫描到的候选文件数）"
    h_check_eq "0" "$T32_STALE_HITS" "仍声称「改动要手工同步两份探测实现」的行数"

    # ── 负向对照 5：注入一句肯定误导句式 → 条件 5 必须变红 ──
    # ★ 隔离做法：用**合成探针树**（只放一个候选文件），不复制冻结态整棵树。
    #   原因：冻结态里若还有真实缺陷（当前就有），复制整棵树会把真实命中混进计数，
    #   负向对照就变成「在测真实缺陷」而不是「在测扫描器」——
    #   这跟「负向对照红了先怀疑破坏手法」是同一类错误，只是方向相反。
    local probe="$SBX_ROOT/t32_probe"
    local plist="$SBX_ROOT/t32_probe.list"
    rm -rf "$probe"
    mkdir -p "$probe/docs"
    printf '# 干净的探针文件\n' > "$probe/docs/t32-probe.md"
    printf '# T32-NEG-STALE: 改动需两处同步\n' >> "$probe/docs/t32-probe.md"
    printf 'docs/t32-probe.md\n' > "$plist"
    local n_inj
    n_inj=$(grep -c 'T32-NEG-STALE' "$probe/docs/t32-probe.md" 2>/dev/null || true)
    [ -z "$n_inj" ] && n_inj=0
    h_check_eq "1" "$n_inj" "负向对照 5 的破坏手法生效（注入点 == 1）"
    _t32_scan_stale "$probe" "$plist"
    h_log "负向对照 5：合成探针树扫描了 $T32_SCAN_N 个文件，命中 $T32_STALE_HITS 行"
    h_check_eq "1" "$T32_STALE_HITS" "负向对照 5：注入「改动需两处同步」后条件 5 必须变红"

    # ── 负向对照 6：注入否定句 → 条件 5 必须保持绿 ──
    # 两种否定句各来一行：
    #   (a) 纯否定句「不需要手工同步」—— 本来就不该命中；
    #   (b) 否定句里**带着**肯定误导句式（「…两处必须同步（现在不再需要手工同步）」）——
    #       这才真正检验「同一行含否定词 → 豁免该行」这条规则真的生效。
    rm -rf "$probe"
    mkdir -p "$probe/docs"
    printf '# 干净的探针文件\n' > "$probe/docs/t32-probe.md"
    printf '# T32-NEG-NEG: 不需要手工同步\n' >> "$probe/docs/t32-probe.md"
    printf '# T32-NEG-NEG2: 改动 check_connectivity 时两处必须同步（现在不再需要手工同步）\n' >> "$probe/docs/t32-probe.md"
    local n_inj2
    n_inj2=$(grep -c 'T32-NEG-NEG' "$probe/docs/t32-probe.md" 2>/dev/null || true)
    [ -z "$n_inj2" ] && n_inj2=0
    h_check_ge 2 "$n_inj2" "负向对照 6 的构造生效（两句否定句都在）"
    _t32_scan_stale "$probe" "$plist"
    h_log "负向对照 6：合成探针树扫描了 $T32_SCAN_N 个文件，命中 $T32_STALE_HITS 行"
    h_check_eq "0" "$T32_STALE_HITS" "负向对照 6：否定句（含带肯定句式的否定句）必须保持绿"
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
