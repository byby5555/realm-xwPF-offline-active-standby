#!/bin/bash
# 用例组 08 · 主备语义与权重落盘索引（第 6 轮新增 · 小编）
#
# 背景（Chief 裁定 1 · 多主语义）：
#   口径 = 权重是**主备优先级顺序**，不是流量比例；同一时刻只有一个主承接流量。
#   审稿第 1 轮把「多主」列为缺口，是因为 UI 文案写的是「权重>0 的目标当主」（复数），
#   与实现不符 —— 缺陷在文案不在逻辑。本组用例把「只有一个主」这个语义钉死：
#   权重 5,3,0 生成的 balance 必须是 0/1 列表（roundrobin: 1, 0, 0），
#   而不是 5,3,0 —— 这一条同时证明「权重表示优先级，不是分流比例」。
#
# 背景（M9 / 审稿第 1 轮建议 S1 · 权重落盘索引错位）：
#   用户填的权重序列按**目标序号**编号（展示侧把每条规则的 REMOTE_HOST 按逗号展开成
#   目标序列，validate_weight_input 也按目标数校验个数）；旧实现却按**规则序号**去取
#   weight_array[rule_index] —— 两套口径不一致，一条规则含多个地址时必然串位。
#
# 覆盖：
#   T41 权重落盘不错位：组内每条规则拿到的权重按目标序号对应，不串位
#   T42 主备优先级 5,3,0：主取权重 5 的那个，权重 3 的是第一备

# 造一条规则（复用官方键集，只覆盖需要的字段）
_w8_make_rule() {
    local file="$1" id="$2" port="$3" mode="$4" failover="$5" weights="$6" hosts="$7"
    _make_rule "$file" "$port" "$mode" "$failover" "$weights" "$hosts"
    sed -i "s/^RULE_ID=.*/RULE_ID=\"$id\"/" "$file"
}

# 在沙箱里读某条规则的 WEIGHTS 字段
_w8_read_weights() {
    local rule_file="$1"
    _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        [ -f "$1/lib/health.sh" ] && source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        read_rule_file "'"$rule_file"'" >/dev/null 2>&1
        echo "WEIGHTS=${WEIGHTS:-}"
    '
}

case_T41_weight_writeback_index() {
    h_case_begin "T41" "权重落盘按目标序号对应，不串位" \
        "沙箱 rules（同端口：rule-1 含两个地址 + rule-2 一个地址）" \
        "apply_port_group_weight_config 443 '10,5,3' → 读回每条规则的 WEIGHTS" \
        "每条规则的权重按**目标序号**对应；组权重串与展示的目标序列一一对应"

    local rules="$SBX_ROOT/realm/rules"
    rm -f "$rules"/rule-*.conf

    # 展示侧把 REMOTE_HOST 按逗号展开成目标序列：
    #   rule-1 → 10.0.0.1, 10.0.0.3   rule-2 → 10.0.0.2
    #   展开后的目标序列 = [10.0.0.1, 10.0.0.3, 10.0.0.2]（3 个目标）
    _w8_make_rule "$rules/rule-1.conf" 1 443 roundrobin false "" "10.0.0.1,10.0.0.3"
    _w8_make_rule "$rules/rule-2.conf" 2 443 roundrobin false "" "10.0.0.2"

    local out
    out=$(_apply_weights 443 "10,5,3")
    h_log "apply 输出: ${out:-<空>}"

    local w1 w2
    w1=$(_w8_read_weights "$rules/rule-1.conf")
    w2=$(_w8_read_weights "$rules/rule-2.conf")
    h_log "rule-1 WEIGHTS=${w1}  rule-2 WEIGHTS=${w2}"

    # 组内第一条规则存完整权重串（组权重串的落点）
    h_check_eq "WEIGHTS=10,5,3" "$w1" "rule-1 存组完整权重串"
    # ★ 关键断言：rule-2 的目标在展开序列里的下标是 2（rule-1 占了两个目标）
    #   → 它对应的是权重 3，不是 5。
    #   旧实现按规则序号取 → 会拿到 weight_array[1] = 5 → 这条断言会红。
    h_check_eq "WEIGHTS=3" "$w2" "rule-2 按目标序号拿权重（不是按规则序号）"

    # 组权重串（realm 实际用的那份）与展示的目标序列一一对应：
    #   3 个目标 → 3 个权重 → balance 直接按序输出
    local b
    b=$(_gen_balance)
    h_log "balance -> $b"
    h_check_contains "$b" "roundrobin: 10, 5, 3" "组权重串与目标序列一一对应（不截断、不串位）"
}

case_T42_priority_single_primary() {
    h_case_begin "T42" "主备优先级：5,3,0 → 主取 5，3 为第一备" \
        "沙箱 rules（同端口三条规则）+ health_status.conf" \
        "apply_port_group_weight_config 443 '5,3,0' → generate_endpoints_from_rules" \
        "同一时刻只有一个主承接流量：balance 是 0/1 列表，不是 5,3,0"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    rm -f "$rules"/rule-*.conf

    _w8_make_rule "$rules/rule-1.conf" 1 443 roundrobin false "" "10.0.0.1"
    _w8_make_rule "$rules/rule-2.conf" 2 443 roundrobin false "" "10.0.0.2"
    _w8_make_rule "$rules/rule-3.conf" 3 443 roundrobin false "" "10.0.0.3"

    _apply_weights 443 "5,3,0" >/dev/null

    local b
    # 全健康 → 主 = 权重 5 的那个（第一个）
    _write_health "$health" "10.0.0.1:healthy" "10.0.0.2:healthy" "10.0.0.3:healthy"
    b=$(_gen_balance); h_log "全健康(5,3,0) -> $b"
    # ★ 关键断言：权重是优先级不是分流比例 → 输出的是 0/1 列表，不是 5,3,0
    h_check_contains "$b" "roundrobin: 1, 0, 0" "全健康 → 只有权重 5 的目标当主（不是 5,3,0 分流）"

    # 权重 5 的挂了 → 第一备（权重 3）顶上
    _write_health "$health" "10.0.0.1:failed" "10.0.0.2:healthy" "10.0.0.3:healthy"
    b=$(_gen_balance); h_log "主挂(5,3,0) -> $b"
    h_check_contains "$b" "roundrobin: 0, 1, 0" "权重 5 的故障 → 权重 3 的当第一备"
}
