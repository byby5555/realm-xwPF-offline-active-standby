#!/bin/bash
# 用例组 18 · 主备切换可靠性（Chief 派单：只要你测试好主备的切换的可靠性就可以了）
#
# ── 本组只钉「主备切换」这一件事 ───────────────────────────────
#   主备切换的**唯一驱动是健康探测**：
#     健康状态文件里目标 STATUS 变了 → 规则里的目标权重随之变 → 流量切走 / 切回。
#   ①~⑨ 九组断言：
#     T68 进得了主备（配置齐全 + 探测端真的起来了）
#     T69 切得走（主故障；达阈值才切，未达阈值不得切）
#     T70 切得回（主恢复；过冷却期才切回，冷却期内必须切不回）
#     T71 抖动不反复切（两道闸：连续失败阈值 + 恢复冷却期）
#     T72 探测端真在探测（产物真的在动，不只看退出码/日志）
#     T73 不误切（慢但未断不被判故障 + 探针超时预算真的生效）
#     T74 不继承老状态（删规则 → 新建同 ID 规则，初始状态健康、失败计数 0）
#     T75 不留半吊子（探测端起不来 → 回滚主备开关，不得留半状态）
#     T76 切走/切回的目标必须是**同一批**目标（不能凭空多出或少掉）
#
# ── 产品范围（保留项）────────────────────────────────────────
#   权重 10,0 主备（realm 规则的 BALANCE_MODE=active-standby + FAILOVER_ENABLED=true
#   + TARGET_STATES）、多端口负载均衡（权重 5,5）、单端口中转、健康探测。
#   被测落点（冻结态）：
#     lib/health.sh  health_check_script_body / probe_with_latency /
#                   get_health_status_record / start_health_check_service
#     lib/realm.sh   generate_endpoints_from_rules（读侧：状态 → 权重）
#     lib/rules.sh   apply_port_group_weight_config / auto_enable_active_standby /
#                   ensure_health_check_service / delete_rule
#
# ── 不测、也不引用（产品删除项）────────────────────────────────
#   独立守护进程 cmd/xwpf-failover.py、cmd/xwpf-failover.service、failover.json 池机制、
#   崩溃循环防护 / drop-in、realm 回环旧建池路。
#
# ── 场景锚定 ─────────────────────────────────────────────────
#   拓扑：监听口 443 → 主目标 → 备目标。
#   主备两个目标用「同 host 不同端口」（127.0.0.1:<主端口> / 127.0.0.1:<备端口>）：
#     · 同 host 不同端口是**两个不同目标**，状态互不覆盖（这是主备的标准拓扑）；
#     · 两个端口都在本机 → 主目标可以用「没人监听的本地端口」造不可达
#       （连接被拒 → 快速失败；不用黑洞地址，否则每轮多等十几秒）。
#   权重写法用两种：**10,0** 与 **5,0** —— 两种写法在任何口径下都是主备，没有歧义。
#
# ★★ RULE_ID 必须连续（1、2）—— 本组最重要的台架纪律 ★★
#   健康状态文件的**旧格式行**（TARGET 只有裸 host）归属靠「该行 RULE_ID → 对应规则的
#   REMOTE_PORT」来认领。RULE_ID 不连续会触发 reorder_rule_ids 把 ID 重排成 1..N
#   （且不与健康状态文件同步）→ 老行的 RULE_ID 失效 → 归属认不出 → 读侧落回
#   「当无记录」分支 → 场景走的是**另一条路径** → 用例照样绿 = **假绿**。
#   所以本组规则 fixture 一律 RULE_ID=1 / RULE_ID=2 连续编号（第 ⑦ 组 T74 尤其关键）。
#
# ── 负向对照策略 ─────────────────────────────────────────────
#   · 有历史旧形态的：优先用**真实旧实现**（git show <sha>:<path>，sha 一律从
#     sbx_history_sha <key> 取，不在用例里写死）；取不到 → h_fail 判红，不静默跳过。
#   · 历史上没有对应「修复前实现」的（阈值 / 冷却 / 回滚 / 时间戳 / 目标集合这类行为）：
#     用**注入式退化** —— 在**副本**（$SBX_ROOT/n8_deg/lib/）里制造一个已知的坏形态，
#     同一套判定器必须判红。注入式退化在注释与用例里都**如实标注**
#     「这是注入式退化，不是历史旧实现」。
#   · 每一条「断言 X 没发生」的断言，都配一条「制造 X 发生了 → 判定器必须判红」的自检。
#   · 判定器要能**区分强弱**：用「恰好 N 条」而不是「至少 N 条」；
#     「没切」断言「目标集合/权重等于切之前那个」，不是「看起来没变」。
#
# 被测产物只从 git show $BASE_SHA:<path> 导出（沙箱的 $SBX_RUN / $SBX_SRC），绝不 source 工作区文件。
# 行尾一律 LF（Windows 检出成 CRLF 会被 systemd 拒绝执行）。

# ══════════════════════════════════════════════════════════════
# 公共 helper
# ══════════════════════════════════════════════════════════════

# 沙箱复位：清掉规则、健康状态文件、systemctl 调用日志
#   理由（与 T29 同）：沙箱是**跨用例共用**的，前面用例留下的同端口规则
#   会改变本例的故障转移判定 —— 用例结果不能依赖跑批顺序。
_n8_reset() {
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf
    rm -f "$SBX_ROOT/realm/health/health_status.conf"
    : > "$SBX_LOG_DIR/systemctl.log"
}

# 造一个端口组（监听口 443）的两条规则：同 host、不同端口、连续 RULE_ID
# 参数：<规则目录> <权重串> <主端口> <备端口> [BALANCE_MODE] [FAILOVER_ENABLED]
#       [RECOVERY_COOLDOWN] [FAILURE_THRESHOLD] [SUCCESS_THRESHOLD] [CONNECTION_TIMEOUT]
#
# ★ RULE_ID 固定 1 / 2（连续）—— 见文件头的纪律说明。
# ★ 权重串写在哪条规则上：权重配置管理（apply_port_group_weight_config）自己也是
#   「第一条规则存完整权重串、后续规则各存自己那个目标的权重」，本 fixture 与产品
#   落盘形态一致。
_n8_make_rules() {
    local dir="$1" weights="$2" pa="$3" pb="$4"
    local mode="${5:-active-standby}" failover="${6:-true}"
    local cooldown="${7:-120}" ft="${8:-2}" st="${9:-2}" ct="${10:-10}"
    rm -f "$dir"/rule-*.conf
    local i rp ww
    for i in 1 2; do
        rp="$pa"; ww="$weights"
        [ "$i" = "2" ] && { rp="$pb"; ww="0"; }
        cat > "$dir/rule-$i.conf" <<EOF
RULE_ID=$i
RULE_ROLE=1
RULE_NAME=n8-rule-$i
SECURITY_LEVEL=none
LISTEN_PORT=443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=$rp
ENABLED=true
BALANCE_MODE="$mode"
TARGET_STATES=""
WEIGHTS="$ww"
FAILOVER_ENABLED="$failover"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="$ft"
SUCCESS_THRESHOLD="$st"
CONNECTION_TIMEOUT="$ct"
RECOVERY_COOLDOWN="$cooldown"
EOF
    done
}

# 读侧：跑 generate_endpoints_from_rules（按给定 lib 根）
#   参数：<lib 根>（默认 $SBX_RUN）；退化对照时传退化副本的根
_n8_gen_with() {
    local libroot="${1:-$SBX_RUN}"
    _run_in_sandbox '
        source "$2/lib/core.sh" >/dev/null 2>&1
        [ -f "$2/lib/health.sh" ] && source "$2/lib/health.sh" >/dev/null 2>&1
        source "$2/lib/rules.sh" >/dev/null 2>&1
        source "$2/lib/realm.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }
        generate_endpoints_from_rules 2>/dev/null
    ' "$libroot"
}

# 写侧：按给定 lib 根生成 health_check.sh
#   参数：<lib 根> <输出文件>
#   ★ 生成的脚本里，函数是从**被 source 的那份** health.sh 原样抽出来的
#     （health_emit_function 读 BASH_SOURCE[0]）→ 退化副本的改动会进到生成物里。
_n8_mkhc() {
    local libroot="${1:-$SBX_RUN}" out="$2"
    _run_in_sandbox '
        source "$2/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' "$libroot" > "$out" 2>/dev/null
}

# 从生成的 realm 配置里，取某个监听口的端口组片段
_n8_group_block() {
    printf '%s\n' "$1" | awk -v lp="$2" '
        /"listen"/ { cur = (index($0, ":" lp "\"") > 0) ? 1 : 0; next }
        cur { print }
    '
}

# 端口组里「目标 → 权重」的映射（空格分隔，例：127.0.0.1:18251=1 127.0.0.1:18252=0）
#   ★ 按**目标**取值而不是按位置取值：位置口径在目标顺序变化时会误判。
_n8_weights() {
    local out="$1" lp="$2"
    local blk remote extra bal
    blk=$(_n8_group_block "$out" "$lp")
    [ -z "$blk" ] && { printf ''; return 0; }
    remote=$(printf '%s\n' "$blk" | grep -m1 '"remote"' | sed -E 's/.*"remote": "([^"]+)".*/\1/')
    extra=$(printf '%s\n' "$blk" | grep -m1 '"extra_remotes"' | sed -E 's/.*\[(.*)\].*/\1/' | tr -d '" ' | tr ',' ' ')
    # ★ 权重串的形态是「1, 0」（逗号 + 空格）—— 必须**按逗号**切分。
    #   按空格切会把 "1," 当成一个权重（台架自己踩过的解析坑：判定器读到 "1,"）。
    bal=$(printf '%s\n' "$blk" | grep -m1 '"balance"' | sed -E 's/.*"balance": "[^"]*: *//; s/".*//' | tr -d ' ')
    local -a ws
    ws=(${bal//,/ })
    local i=0 res="" t
    if [ -n "$remote" ]; then res="$remote=${ws[0]}"; i=1; fi
    for t in $extra; do
        res="$res $t=${ws[$i]}"
        i=$((i+1))
    done
    printf '%s' "$res"
}

# 端口组的目标集合（去重、排序、空格分隔）
_n8_targets() {
    local out="$1" lp="$2"
    local blk remote extra
    blk=$(_n8_group_block "$out" "$lp")
    [ -z "$blk" ] && { printf ''; return 0; }
    remote=$(printf '%s\n' "$blk" | grep -m1 '"remote"' | sed -E 's/.*"remote": "([^"]+)".*/\1/')
    extra=$(printf '%s\n' "$blk" | grep -m1 '"extra_remotes"' | sed -E 's/.*\[(.*)\].*/\1/' | tr -d '" ' | tr ',' ' ')
    printf '%s\n' $remote $extra | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# 从「目标=权重」映射里取某个目标的权重
_n8_weight_of() {
    local map="$1" target="$2" t
    for t in $map; do
        case "$t" in
            "$target="*) printf '%s' "${t#*=}"; return 0 ;;
        esac
    done
    printf '<无此目标>'
}

# 健康状态文件里某个目标的整行（取不到返回空）
_n8_status_row() {
    local file="$1" target="$2"
    [ -f "$file" ] || return 1
    awk -F'|' -v t="$target" '!/^#/ && $2 == t { print; exit }' "$file" 2>/dev/null
}

# 健康状态行的第 n 个字段
_n8_field_of_row() {
    printf '%s\n' "$1" | cut -d'|' -f"$2"
}

# 规则文件里某个键的值（去掉外层引号；没有该键 → <无此键>）
_n8_rule_field() {
    local file="$1" key="$2"
    [ -f "$file" ] || { printf '<无文件>'; return 0; }
    local v
    v=$(grep -m1 "^${key}=" "$file" 2>/dev/null | sed -E "s|^${key}=(.*)$|\1|")
    [ -z "$v" ] && v="<无此键>"
    v="${v#\"}"; v="${v%\"}"
    printf '%s' "$v"
}

# 端口上有没有东西在监听（返回 0 = 有）
#   用例前提检查用：主目标必须是「没人监听」才能造出快速失败；
#   万一上一次的残留监听还占着这个端口 → 场景失真（主目标其实还活着）→ 必须判红，
#   不能让它悄悄变成「主一直健康」。
_n8_port_listening() {
    local port="$1"
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}

# 本地监听端口（**分槽位**可控启停 —— T71 要在「主目标好/坏」之间反复切换，
#   主备两个槽位必须分开记 PID：共用一个变量会误杀另一个端口的监听）
#   本机 python3 是 Windows 占位符（不可用）→ 优先用真实 python（同 00_common 的做法）
#   用法：_n8_listener_start <端口> <槽位 p|b> / _n8_listener_stop <槽位 p|b>
_N8_LP_PID=""
_N8_LB_PID=""
_n8_listener_start() {
    local port="$1" slot="$2"
    local py="" c
    for c in python python3; do
        if command -v "$c" >/dev/null 2>&1 && "$c" --version >/dev/null 2>&1; then py="$c"; break; fi
    done
    if [ -z "$py" ]; then
        h_log "找不到可用的 python，无法起本地监听端口"
        return 1
    fi
    "$py" -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port))
s.listen(8)
# 「慢但未断」：接受侧迟迟不来（TCP 握手由内核完成，探测判的是握手）
time.sleep(3)
deadline = time.time() + 240
while time.time() < deadline:
    try:
        s.settimeout(1)
        c, _ = s.accept()
        time.sleep(3)
        c.close()
    except socket.timeout:
        pass
" >/dev/null 2>&1 &
    local pid=$!
    case "$slot" in
        p) _N8_LP_PID="$pid" ;;
        b) _N8_LB_PID="$pid" ;;
        *) kill "$pid" 2>/dev/null; return 1 ;;
    esac
    sleep 1
    return 0
}

_n8_listener_stop() {
    local slot="$1" pid=""
    case "$slot" in
        p) pid="$_N8_LP_PID"; _N8_LP_PID="" ;;
        b) pid="$_N8_LB_PID"; _N8_LB_PID="" ;;
    esac
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 0
}

# ── 注入式退化：造一份「已知坏形态」的 lib 副本 ────────────────
#   ★ 这是**注入式退化，不是历史旧实现**（历史旧实现走 git show，见文件头）。
#   ★ 退化只发生在**副本**里（$SBX_ROOT/n8_deg/lib/），冻结态产物本身不动。
#   ★ 每种退化都要**自检**：sed 没改到东西 → 说明产品写法变了 → 直接判红，
#     绝不能「改不动就当没退化」（那等于负向对照静默失效）。
#   副作用：把退化副本的 lib 根写进全局变量 _N8_LIBROOT
_N8_LIBROOT=""
_n8_prepare_degraded_lib() {
    local mode="$1"
    local libroot="$SBX_ROOT/n8_deg"
    _N8_LIBROOT="$libroot"
    rm -rf "$libroot"
    mkdir -p "$libroot/lib"
    cp "$SBX_RUN/lib/"*.sh "$libroot/lib/" 2>/dev/null
    local changed=0
    case "$mode" in
        fail-once)
            # 「失败一次就切」：把「失败计数达阈值」改成「失败计数 ≥ 1」
            sed -i 's|\[ "\$fail_count" -ge "\${FAILURE_THRESHOLD:-2}" \]|[ "$fail_count" -ge 1 ]|' \
                "$libroot/lib/health.sh"
            grep -q 'fail_count" -ge 1' "$libroot/lib/health.sh" && changed=1
            ;;
        no-cooldown)
            # 「去掉恢复冷却期」：冷却期判断恒真
            sed -i 's|\[ \$((current_time - failure_start_time)) -ge "\$cooldown_period" \]|[ $((current_time - failure_start_time)) -ge 0 ]|' \
                "$libroot/lib/health.sh"
            grep -q 'current_time - failure_start_time)) -ge 0' "$libroot/lib/health.sh" && changed=1
            ;;
        frozen-time)
            # 「LAST_CHECK 写死」：探测跑完也不更新时间戳
            sed -i 's|^current_time=\$(date +%s)$|current_time=1000|' "$libroot/lib/health.sh"
            grep -q '^current_time=1000$' "$libroot/lib/health.sh" && changed=1
            ;;
        hard-timeout)
            # 「超时预算写死 3s」：check_connectivity 忽略传入的预算
            sed -i 's|local timeout="\${3:-3}"|local timeout=3|' "$libroot/lib/health.sh"
            grep -q 'local timeout=3' "$libroot/lib/health.sh" && changed=1
            ;;
        no-rollback)
            # 「回滚被去掉」：探测端起不来时不恢复主备开关
            sed -i 's|^\( *\)_restore_port_mode_state$|\1: n8-degraded-no-rollback|' "$libroot/lib/rules.sh"
            grep -q 'n8-degraded-no-rollback' "$libroot/lib/rules.sh" && changed=1
            ;;
        id-rekey)
            # 「同 RULE_ID 的遗留行也算这条目标的记录」—— 制造「规则 ID 被复用
            #   → 新规则继承老规则的 failed」这个形态。
            #   ★ 这是注入式退化，不是历史旧实现。
            sed -i 's@^        if \[ -n "\$status_line" \]; then@        # n8-degraded-reuse-rule-id\n        if [ -z "$status_line" ]; then\n            status_line=$(grep "^${RULE_ID}|" "$HEALTH_STATUS_FILE" 2>/dev/null | head -1)\n        fi\n        if [ -n "$status_line" ]; then@' \
                "$libroot/lib/health.sh"
            grep -q 'n8-degraded-reuse-rule-id' "$libroot/lib/health.sh" && changed=1
            ;;
        drop-target)
            # 「切换后目标凭空少掉一个」
            sed -i 's|^\( *\)port_weights\[\$port_key\]="\$flipped_weights"$|\1port_weights[$port_key]="$flipped_weights"; port_groups[$port_key]="${all_targets[0]}"|' \
                "$libroot/lib/realm.sh"
            grep -q 'flipped_weights"; port_groups' "$libroot/lib/realm.sh" && changed=1
            ;;
        add-target)
            # 「切换后目标凭空多出一个」
            sed -i 's|^\( *\)port_weights\[\$port_key\]="\$flipped_weights"$|\1port_weights[$port_key]="$flipped_weights"; port_groups[$port_key]="${port_groups[$port_key]},10.9.9.9:1"|' \
                "$libroot/lib/realm.sh"
            grep -q 'flipped_weights"; port_groups' "$libroot/lib/realm.sh" && changed=1
            ;;
        *)
            h_fail "未知的退化形态: $mode"
            return 1
            ;;
    esac
    if [ "$changed" != "1" ]; then
        h_fail "注入式退化（$mode）没改到任何东西 —— 产品写法已变，这组负向对照失效（不能当成通过）"
        return 1
    fi
    h_log "注入式退化已就绪（$mode）：$libroot（这是注入式退化，不是历史旧实现）"
    return 0
}

# ── 真实旧实现负向对照：把 lib/realm.sh 换成 git 里的历史版本 ──
#   ★ 这是**真实旧实现**（git show $sha:lib/realm.sh），不是注入式退化。
#   ★ sha 一律从 sbx_history_sha <key> 取（单一真源在 tests/cases/00_common.sh），
#     **不在用例里写死 sha**。
#   ★ 取不到历史实现 → h_fail 判红：负向对照跑不起来 = 证明力归零，不能静默跳过。
#   副作用：把历史副本的 lib 根写进全局变量 _N8_HIST_LIBROOT
_N8_HIST_LIBROOT=""
_n8_prepare_history_lib() {
    local key="$1" marker="$2"
    local sha
    sha=$(sbx_history_sha "$key" 2>/dev/null)
    if [ -z "$sha" ]; then
        h_fail "取不到历史实现（sbx_history_sha $key 为空）—— 负向对照跑不起来等于没在证明"
        return 1
    fi
    local libroot="$SBX_ROOT/n8_hist_$key"
    _N8_HIST_LIBROOT="$libroot"
    rm -rf "$libroot"
    mkdir -p "$libroot/lib"
    cp "$SBX_RUN/lib/"*.sh "$libroot/lib/" 2>/dev/null
    local raw="$SBX_ROOT/n8_hist_raw_$key.sh"
    if ! (cd "$SBX_REPO" && git show "$sha:lib/realm.sh" > "$raw" 2>/dev/null); then
        h_fail "取不到 $sha:lib/realm.sh —— 负向对照跑不起来等于没在证明"
        return 1
    fi
    # 路径重定向（与沙箱其它副本同一套规则）→ 不许碰真实系统路径
    sbx_redirect "$raw" "$libroot/lib/realm.sh"
    if ! grep -qE "$marker" "$libroot/lib/realm.sh" 2>/dev/null; then
        h_fail "$sha 的 lib/realm.sh 里找不到标记 $marker（实现变了，负向对照要重新对）"
        return 1
    fi
    h_log "真实旧实现负向对照已就绪（$key = $sha）：$libroot"
    return 0
}

# ══════════════════════════════════════════════════════════════
# 判定器（每条都输出 "PASS|FAIL\t<说明>"，红的时候必须能被看懂）
# ══════════════════════════════════════════════════════════════

# T68：探测端真的起来了 —— 「enable」与「start」**两个动作**都必须发生
#   ★ 判据不能只看「日志打了健康检查完成」：真机踩过的坑就是
#     每 4 秒打一行、退出码 0，但产物停在 7 小时前 → 那是假活。
_n8_judge_probe_started() {
    local log="$1"
    if [ ! -f "$log" ]; then
        printf 'FAIL\t探测端调用日志不存在: %s\n' "$log"
        return 1
    fi
    local en st
    en=$(grep -c '^systemctl enable realm-health-check\.timer$' "$log" 2>/dev/null)
    st=$(grep -c '^systemctl start realm-health-check\.timer$' "$log" 2>/dev/null)
    [ -z "$en" ] && en=0
    [ -z "$st" ] && st=0
    if [ "$en" -eq 0 ]; then
        printf 'FAIL\t探测端没被 enable（配置显示主备、实际没有探测端 → 永远不切换）\n'
        return 1
    fi
    if [ "$st" -eq 0 ]; then
        printf 'FAIL\t探测端只 enable 没 start（timer 没跑起来 → 永远不切换）\n'
        return 1
    fi
    printf 'PASS\t探测端 enable + start 两个动作都发生了\n'
    return 0
}

# T69：切得走（主故障）
#   判据：主目标 STATUS=failed **且失败计数达阈值**，且主权重=0、备权重=1
_n8_judge_switched_away() {
    local hf="$1" map="$2" p="$3" b="$4" thr="$5"
    local row st fc pw bw
    row=$(_n8_status_row "$hf" "$p")
    if [ -z "$row" ]; then
        printf 'FAIL\t健康状态文件里没有主目标 %s 的记录\n' "$p"
        return 1
    fi
    st=$(_n8_field_of_row "$row" 3)
    fc=$(_n8_field_of_row "$row" 4)
    pw=$(_n8_weight_of "$map" "$p")
    bw=$(_n8_weight_of "$map" "$b")
    if [ "$st" != "failed" ]; then
        printf 'FAIL\t主目标状态 = %s（期望 failed）\n' "$st"
        return 1
    fi
    if [ "$fc" -lt "$thr" ] 2>/dev/null; then
        printf 'FAIL\t主目标失败计数 = %s（未达阈值 %s → 不得切走）\n' "$fc" "$thr"
        return 1
    fi
    if [ "$pw" != "0" ]; then
        printf 'FAIL\t主目标权重 = %s（期望 0 → 流量没切走）\n' "$pw"
        return 1
    fi
    if [ "$bw" != "1" ]; then
        printf 'FAIL\t备目标权重 = %s（期望 1 → 流量没全走备）\n' "$bw"
        return 1
    fi
    printf 'PASS\t已切走（主权重 0 / 备权重 1；主失败计数 %s 达阈值 %s）\n' "$fc" "$thr"
    return 0
}

# T69/T71：未达失败阈值**不得**切走（主仍在承接流量）
_n8_judge_not_switched_away() {
    local hf="$1" map="$2" p="$3" b="$4"
    local row st pw bw
    row=$(_n8_status_row "$hf" "$p")
    if [ -z "$row" ]; then
        printf 'FAIL\t健康状态文件里没有主目标 %s 的记录\n' "$p"
        return 1
    fi
    st=$(_n8_field_of_row "$row" 3)
    pw=$(_n8_weight_of "$map" "$p")
    bw=$(_n8_weight_of "$map" "$b")
    if [ "$st" = "failed" ]; then
        printf 'FAIL\t主目标状态 = failed（未达失败阈值就判故障 → 过早切走）\n'
        return 1
    fi
    if [ "$pw" != "1" ]; then
        printf 'FAIL\t主目标权重 = %s（期望 1 → 未达阈值就切走了）\n' "$pw"
        return 1
    fi
    if [ "$bw" != "0" ]; then
        printf 'FAIL\t备目标权重 = %s（期望 0）\n' "$bw"
        return 1
    fi
    printf 'PASS\t未切走（主权重 1 / 备权重 0，主状态 %s）\n' "$st"
    return 0
}

# T70：切得回（主恢复且已过冷却期）
_n8_judge_switched_back() {
    local hf="$1" map="$2" p="$3" b="$4"
    local row st pw bw
    row=$(_n8_status_row "$hf" "$p")
    if [ -z "$row" ]; then
        printf 'FAIL\t健康状态文件里没有主目标 %s 的记录\n' "$p"
        return 1
    fi
    st=$(_n8_field_of_row "$row" 3)
    pw=$(_n8_weight_of "$map" "$p")
    bw=$(_n8_weight_of "$map" "$b")
    if [ "$st" != "healthy" ]; then
        printf 'FAIL\t主目标状态 = %s（期望 healthy → 没切回主）\n' "$st"
        return 1
    fi
    if [ "$pw" != "1" ]; then
        printf 'FAIL\t主目标权重 = %s（期望 1 → 流量没切回主）\n' "$pw"
        return 1
    fi
    if [ "$bw" != "0" ]; then
        printf 'FAIL\t备目标权重 = %s（期望 0）\n' "$bw"
        return 1
    fi
    printf 'PASS\t已切回主（主权重 1 / 备权重 0，主状态 healthy）\n'
    return 0
}

# T70/T71：冷却期内**不得**切回主（主仍是 failed，流量留在备上）
_n8_judge_cooldown_blocked() {
    local hf="$1" map="$2" p="$3" b="$4"
    local row st pw bw
    row=$(_n8_status_row "$hf" "$p")
    if [ -z "$row" ]; then
        printf 'FAIL\t健康状态文件里没有主目标 %s 的记录\n' "$p"
        return 1
    fi
    st=$(_n8_field_of_row "$row" 3)
    pw=$(_n8_weight_of "$map" "$p")
    bw=$(_n8_weight_of "$map" "$b")
    if [ "$st" != "failed" ]; then
        printf 'FAIL\t主目标状态 = %s（冷却期内就恢复成 healthy → 提前切回主）\n' "$st"
        return 1
    fi
    if [ "$pw" != "0" ]; then
        printf 'FAIL\t主目标权重 = %s（期望 0 → 冷却期内提前切回主）\n' "$pw"
        return 1
    fi
    if [ "$bw" != "1" ]; then
        printf 'FAIL\t备目标权重 = %s（期望 1）\n' "$bw"
        return 1
    fi
    printf 'PASS\t冷却期内没切回（主仍 failed，权重 0/1）\n'
    return 0
}

# T71：切换次数必须**恰好**是 N（抖动不反复切）
_n8_judge_switch_count() {
    local n="$1" expect="$2"
    if [ "$n" = "$expect" ]; then
        printf 'PASS\t切换次数 = %s（期望 %s）\n' "$n" "$expect"
        return 0
    fi
    if [ "$n" = "0" ]; then
        printf 'FAIL\t切换次数 = 0（期望恰好 %s → 根本没切走，场景失真）\n' "$expect"
        return 1
    fi
    printf 'FAIL\t切换次数 = %s（期望恰好 %s → 出现来回切）\n' "$n" "$expect"
    return 1
}

# T72：LAST_CHECK 必须真的前进
_n8_judge_last_check() {
    local old="$1" new="$2"
    if [ -z "$new" ]; then
        printf 'FAIL\tLAST_CHECK 取不到（状态记录没有这一项）\n'
        return 1
    fi
    if [ "$new" -gt "$old" ] 2>/dev/null; then
        printf 'PASS\tLAST_CHECK 前进（%s → %s）\n' "$old" "$new"
        return 0
    fi
    printf 'FAIL\tLAST_CHECK 没前进（%s → %s → 探测端没在真探测）\n' "$old" "$new"
    return 1
}

# T73：探针超时预算真的生效
#   判据：预算 2 → 墙钟 ≈2s；预算 10 → 墙钟 ≈10s；两者都判失败；
#         上界 30000ms（与 cases/11_latency.sh 同口径：探测预算已放宽到 10s）
_n8_judge_budget() {
    local w2="$1" w10="$2"
    if [ "$w2" -lt 1500 ] 2>/dev/null; then
        printf 'FAIL\t预算 2s 的墙钟 = %sms（太小 → 没真的按预算等）\n' "$w2"
        return 1
    fi
    if [ "$w2" -gt 8000 ] 2>/dev/null; then
        printf 'FAIL\t预算 2s 的墙钟 = %sms（超 8s → 预算参数没被使用）\n' "$w2"
        return 1
    fi
    if [ "$w10" -lt 8000 ] 2>/dev/null; then
        printf 'FAIL\t预算 10s 的墙钟 = %sms（< 8s → 预算参数被写死，没真用）\n' "$w10"
        return 1
    fi
    if [ "$w10" -gt 30000 ] 2>/dev/null; then
        printf 'FAIL\t预算 10s 的墙钟 = %sms（> 30000ms → 超过判据上界）\n' "$w10"
        return 1
    fi
    if [ "$w10" -lt $((w2 + 3000)) ] 2>/dev/null; then
        printf 'FAIL\t预算 10s（%sms）没有比预算 2s（%sms）明显更久 → 预算参数疑似被写死\n' "$w10" "$w2"
        return 1
    fi
    printf 'PASS\t预算真的生效（2s→%sms / 10s→%sms）\n' "$w2" "$w10"
    return 0
}

# T74：新规则不继承老状态（健康 + 失败计数 0 + 读侧不判故障）
_n8_judge_new_rule_state() {
    local hf="$1" map="$2" target="$3" exp_status="$4" exp_fc="$5"
    local n row st fc w
    n=$(grep -cE "^[0-9]+\|${target//./\\.}\|" "$hf" 2>/dev/null)
    [ -z "$n" ] && n=0
    if [ "$n" != "1" ]; then
        printf 'FAIL\t新规则目标 %s 的状态记录有 %s 条（期望恰好 1 条）\n' "$target" "$n"
        return 1
    fi
    row=$(_n8_status_row "$hf" "$target")
    st=$(_n8_field_of_row "$row" 3)
    fc=$(_n8_field_of_row "$row" 4)
    if [ "$st" != "$exp_status" ]; then
        printf 'FAIL\t新规则目标 %s 的状态 = %s（期望 %s → 继承了老规则的故障）\n' "$target" "$st" "$exp_status"
        return 1
    fi
    if [ "$fc" != "$exp_fc" ]; then
        printf 'FAIL\t新规则目标 %s 的失败计数 = %s（期望 %s → 继承了老规则的失败计数）\n' "$target" "$fc" "$exp_fc"
        return 1
    fi
    w=$(_n8_weight_of "$map" "$target")
    if [ "$w" = "0" ]; then
        printf 'FAIL\t读侧把新规则目标 %s 判成故障（权重 0）→ 一上来就显示故障\n' "$target"
        return 1
    fi
    printf 'PASS\t新规则初始状态健康（状态 %s / 失败计数 %s / 权重 %s）\n' "$st" "$fc" "$w"
    return 0
}

# T75：回滚必须**原样**恢复（不是「大概恢复了」）
_n8_judge_rollback() {
    local rf="$1" mode="$2" failover="$3" ts="$4"
    local m f t
    m=$(_n8_rule_field "$rf" BALANCE_MODE)
    f=$(_n8_rule_field "$rf" FAILOVER_ENABLED)
    t=$(_n8_rule_field "$rf" TARGET_STATES)
    if [ "$m" != "$mode" ]; then
        printf 'FAIL\t回滚后 BALANCE_MODE = %s（期望 %s）\n' "$m" "$mode"
        return 1
    fi
    if [ "$f" != "$failover" ]; then
        printf 'FAIL\t回滚后 FAILOVER_ENABLED = %s（期望 %s）\n' "$f" "$failover"
        return 1
    fi
    if [ "$t" != "$ts" ]; then
        printf 'FAIL\t回滚后 TARGET_STATES = %s（期望 %s → 残留半状态）\n' "$t" "$ts"
        return 1
    fi
    printf 'PASS\t已原样回滚（mode=%s failover=%s target_states=%s）\n' "$m" "$f" "$t"
    return 0
}

# T76：切换前后的目标集合必须是**同一批**（逐项相等，不是「看起来没变」）
_n8_judge_same_targets() {
    local before="$1" after="$2" expect_n="$3"
    local nb na
    nb=$(printf '%s\n' $before | grep -c . )
    na=$(printf '%s\n' $after | grep -c . )
    [ -z "$nb" ] && nb=0
    [ -z "$na" ] && na=0
    if [ "$nb" != "$expect_n" ]; then
        printf 'FAIL\t切换前目标数 = %s（期望恰好 %s）\n' "$nb" "$expect_n"
        return 1
    fi
    if [ "$na" != "$nb" ]; then
        printf 'FAIL\t切换前后目标数不同（前 %s / 后 %s → 目标凭空多出或少掉）\n' "$nb" "$na"
        return 1
    fi
    if [ "$after" != "$before" ]; then
        printf 'FAIL\t切换前后的目标集合不同\n  前: [%s]\n  后: [%s]\n' "$before" "$after"
        return 1
    fi
    printf 'PASS\t切换前后是同一批目标（%s 个，逐项相等）\n' "$na"
    return 0
}

# ══════════════════════════════════════════════════════════════
# ① T68 · 进得了主备
# ══════════════════════════════════════════════════════════════
case_T68_enter_active_standby() {
    h_case_begin "T68" "进得了主备：配置齐全 + 探测端真的起来了" \
        "沙箱 rules（权重 10,0；初始 roundrobin + failover off）" \
        "apply_port_group_weight_config 443 '10,0' 1（真实 ensure_health_check_service）" \
        "BALANCE_MODE=active-standby、FAILOVER_ENABLED=true、5 个健康检查参数齐全；systemctl 日志里 enable 与 start 两个动作都发生"

    local rules="$SBX_ROOT/realm/rules"
    local pa=18201 pb=18202
    local out j k v

    _n8_reset
    _n8_make_rules "$rules" "10,0" "$pa" "$pb" "roundrobin" "false"
    : > "$SBX_LOG_DIR/systemctl.log"

    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        apply_port_group_weight_config 443 "10,0" 1 < /dev/null
    ' 2>&1)
    h_log "输出: $(printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-300)"

    # ── 配置口径 ──
    h_check_file_has "$rules/rule-1.conf" 'BALANCE_MODE="active-standby"' "权重 10,0 → BALANCE_MODE=active-standby"
    h_check_file_has "$rules/rule-1.conf" 'FAILOVER_ENABLED="true"' "权重 10,0 → FAILOVER_ENABLED=true"

    for k in HEALTH_CHECK_INTERVAL FAILURE_THRESHOLD SUCCESS_THRESHOLD CONNECTION_TIMEOUT RECOVERY_COOLDOWN; do
        v=$(_n8_rule_field "$rules/rule-1.conf" "$k")
        if [ "$v" = "<无此键>" ] || [ -z "$v" ]; then
            h_fail "健康检查参数 $k 缺失或为空（主备探测端没法按配置工作）"
        else
            h_pass "健康检查参数 $k = $v"
        fi
    done

    # ── 探测端口径：enable + start **两个动作**都发生 ──
    j=$(_n8_judge_probe_started "$SBX_LOG_DIR/systemctl.log")
    h_log "探测端判定: $j"
    h_check_contains "$j" "PASS" "探测端真的起来了（enable + start 两个动作都发生）"
    h_check_file "$SBX_ROOT/realm/health/health_check.sh" "生成的健康检查脚本（探测端产物）"
    h_check_file "$SBX_ROOT/systemd/realm-health-check.timer" "健康检查 timer unit（探测端产物）"

    # ── 负向对照 1（真实故障形态）：只写配置、探测端没起 ──
    #   这是真机踩过的坑：配置显示主备、实际永不切换。
    #   这里让 ensure_health_check_service 变成「报告成功但什么也不做」的桩。
    _n8_reset
    _n8_make_rules "$rules" "10,0" "$pa" "$pb" "roundrobin" "false"
    : > "$SBX_LOG_DIR/systemctl.log"
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        ensure_health_check_service(){ return 0; }   # 桩：报告成功，实际没启服务
        apply_port_group_weight_config 443 "10,0" 1 < /dev/null
    ' 2>&1)
    h_log "负向对照1 输出: $(printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-240)"
    j=$(_n8_judge_probe_started "$SBX_LOG_DIR/systemctl.log")
    h_log "负向对照1 判定: $j"
    h_check_contains "$j" "FAIL" "负向对照 1：配置写主备但探测端没起 → 判定器必须判红"

    # ── 负向对照 2：只 enable 没 start（半启动）──
    local half="$SBX_ROOT/n8_half_started.log"
    printf 'systemctl daemon-reload\nsystemctl enable realm-health-check.timer\n' > "$half"
    j=$(_n8_judge_probe_started "$half")
    h_log "负向对照2 判定: $j"
    h_check_contains "$j" "FAIL" "负向对照 2：只有 enable 没有 start → 判定器必须判红"
}

# ══════════════════════════════════════════════════════════════
# ② T69 · 切得走（主故障）
# ══════════════════════════════════════════════════════════════
case_T69_switch_away_on_failure() {
    h_case_begin "T69" "切得走：主故障连续失败达阈值才切走，未达阈值不得切" \
        "沙箱 rules（权重 10,0；主=没人监听的本地端口，备=本地监听口）" \
        "health_check.sh 连跑两轮 + generate_endpoints_from_rules" \
        "第 1 轮失败计数 1（未达阈值）→ 不得切；第 2 轮失败计数达阈值 → 主 STATUS=failed 且权重切到备"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local pa=18211 pb=18212
    local hc="$SBX_ROOT/n8_hc69.sh"
    local thr=2 row j map

    _n8_reset
    _n8_make_rules "$rules" "10,0" "$pa" "$pb" "active-standby" "true" "120" "$thr" "2" "10"
    if _n8_port_listening "$pa"; then
        h_fail "主目标端口 $pa 上有别的监听（主目标本该是「没人监听」）→ 场景失真"
        return
    fi
    if ! _n8_listener_start "$pb" b; then
        h_fail "起不来本地监听端口（备目标不可达），本组无法判定"
        return
    fi
    _n8_mkhc "$SBX_RUN" "$hc"
    h_check_file "$hc" "生成的 health_check.sh"

    # ── 第 1 轮：失败一次，**不得**切 ──
    bash "$hc" >/dev/null 2>&1
    row=$(_n8_status_row "$health" "127.0.0.1:$pa")
    h_log "第1轮后主目标记录: $row"
    map=$(_n8_weights "$(_n8_gen_with)" 443)
    h_log "第1轮后 目标=权重: $map"
    j=$(_n8_judge_not_switched_away "$health" "$map" "127.0.0.1:$pa" "127.0.0.1:$pb")
    h_log "第1轮判定: $j"
    h_check_contains "$j" "PASS" "失败 1 次（未达阈值 2）→ 不得切走"
    h_check_eq "1" "$(_n8_field_of_row "$row" 4)" "第1轮主目标失败计数 = 1（未达阈值）"

    # ── 第 2 轮：失败达阈值 → 切走 ──
    bash "$hc" >/dev/null 2>&1
    row=$(_n8_status_row "$health" "127.0.0.1:$pa")
    map=$(_n8_weights "$(_n8_gen_with)" 443)
    h_log "第2轮后主目标记录: $row"
    h_log "第2轮后 目标=权重: $map"
    j=$(_n8_judge_switched_away "$health" "$map" "127.0.0.1:$pa" "127.0.0.1:$pb" "$thr")
    h_log "第2轮判定: $j"
    h_check_contains "$j" "PASS" "失败达阈值 → 切走（流量全走备）"
    h_check_eq "failed" "$(_n8_field_of_row "$row" 3)" "主目标 STATUS=failed"

    # ── 负向对照（注入式退化，不是历史旧实现）：失败一次就切 ──
    #   同一套判定器必须判红 —— 否则「达阈值才切」这条就是恒真断言。
    if _n8_prepare_degraded_lib "fail-once"; then
        rm -f "$health"
        _n8_mkhc "$_N8_LIBROOT" "$SBX_ROOT/n8_hc69_deg.sh"
        bash "$SBX_ROOT/n8_hc69_deg.sh" >/dev/null 2>&1
        row=$(_n8_status_row "$health" "127.0.0.1:$pa")
        map=$(_n8_weights "$(_n8_gen_with "$_N8_LIBROOT")" 443)
        h_log "退化后主目标记录: $row"
        h_log "退化后 目标=权重: $map"
        j=$(_n8_judge_switched_away "$health" "$map" "127.0.0.1:$pa" "127.0.0.1:$pb" "$thr")
        h_log "退化判定: $j"
        h_check_contains "$j" "FAIL" "负向对照（注入式退化：失败一次就切）：判定器必须判红"
        j=$(_n8_judge_not_switched_away "$health" "$map" "127.0.0.1:$pa" "127.0.0.1:$pb")
        h_log "退化判定（未达阈值侧）: $j"
        h_check_contains "$j" "FAIL" "负向对照（注入式退化）：未达阈值就切走的形态必须被抓住"
    fi

    # ── 负向对照 2（真实旧实现，不是注入式退化）：读侧按裸 host 建索引的那一版 ──
    #   形态：健康状态文件里明明写着主目标 failed，但读侧按裸 host 查 → 查不到 →
    #         主被当成健康 → **该切不切**（流量压在已故障的主机上，故障转移静默失效）。
    if _n8_prepare_history_lib "t52-prefix" 'health_status\["\$host"\]'; then
        rm -f "$health"
        _n8_mkhc "$_N8_HIST_LIBROOT" "$SBX_ROOT/n8_hc69_hist.sh"
        bash "$SBX_ROOT/n8_hc69_hist.sh" >/dev/null 2>&1
        bash "$SBX_ROOT/n8_hc69_hist.sh" >/dev/null 2>&1
        row=$(_n8_status_row "$health" "127.0.0.1:$pa")
        map=$(_n8_weights "$(_n8_gen_with "$_N8_HIST_LIBROOT")" 443)
        h_log "真实旧实现下 主目标记录: $row"
        h_log "真实旧实现下 目标=权重: $map"
        j=$(_n8_judge_switched_away "$health" "$map" "127.0.0.1:$pa" "127.0.0.1:$pb" "$thr")
        h_log "真实旧实现判定: $j"
        h_check_contains "$j" "FAIL" "负向对照 2（真实旧实现：读侧按裸 host 建索引）：该切不切 → 判定器必须判红"
    fi

    _n8_listener_stop b
}

# ══════════════════════════════════════════════════════════════
# ③ T70 · 切得回（主恢复）
# ══════════════════════════════════════════════════════════════
case_T70_switch_back_on_recovery() {
    h_case_begin "T70" "切得回：主恢复后必须过恢复冷却期才切回" \
        "沙箱 rules（RECOVERY_COOLDOWN=3600）+ health_status.conf（主=failed、成功计数达阈值、故障起始=现在）" \
        "health_check.sh + generate_endpoints_from_rules" \
        "冷却期内不得切回主（主仍 failed、权重 0/1）；冷却期过后必须切回主（主 healthy、权重 1/0）"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local pa=18221 pb=18222
    local hc="$SBX_ROOT/n8_hc70.sh"
    local now old j map

    _n8_reset
    _n8_make_rules "$rules" "10,0" "$pa" "$pb" "active-standby" "true" "3600" "2" "2" "10"
    if ! _n8_listener_start "$pa" p; then
        h_fail "起不来本地监听端口（主目标不可达），本组无法判定"
        return
    fi
    if ! _n8_listener_start "$pb" b; then
        h_fail "起不来本地监听端口（备目标不可达），本组无法判定"
        _n8_listener_stop p
        _n8_listener_stop b
        return
    fi
    _n8_mkhc "$SBX_RUN" "$hc"

    now=$(date +%s)
    mkdir -p "$(dirname "$health")"
    cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$pa|failed|2|2|$now|$now|100|100
2|127.0.0.1:$pb|healthy|0|3|$now|0|100|100
EOF

    # ── 腿 1：冷却期内（3600s）—— 必须切不回 ──
    bash "$hc" >/dev/null 2>&1
    map=$(_n8_weights "$(_n8_gen_with)" 443)
    h_log "冷却期内 目标=权重: $map"
    h_log "冷却期内 主目标记录: $(_n8_status_row "$health" "127.0.0.1:$pa")"
    j=$(_n8_judge_cooldown_blocked "$health" "$map" "127.0.0.1:$pa" "127.0.0.1:$pb")
    h_log "冷却期内判定: $j"
    h_check_contains "$j" "PASS" "冷却期（3600s）内：不得切回主"

    # ── 腿 2：冷却期过后 —— 必须切回 ──
    old=$((now - 7200))
    sed -i 's|^RECOVERY_COOLDOWN=.*|RECOVERY_COOLDOWN="1"|' "$rules"/rule-*.conf
    cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$pa|failed|2|2|$now|$old|100|100
2|127.0.0.1:$pb|healthy|0|3|$now|0|100|100
EOF
    bash "$hc" >/dev/null 2>&1
    map=$(_n8_weights "$(_n8_gen_with)" 443)
    h_log "冷却期后 目标=权重: $map"
    h_log "冷却期后 主目标记录: $(_n8_status_row "$health" "127.0.0.1:$pa")"
    j=$(_n8_judge_switched_back "$health" "$map" "127.0.0.1:$pa" "127.0.0.1:$pb")
    h_log "冷却期后判定: $j"
    h_check_contains "$j" "PASS" "冷却期过后：切回主"

    # ── 负向对照（注入式退化，不是历史旧实现）：去掉冷却期判断 ──
    if _n8_prepare_degraded_lib "no-cooldown"; then
        _n8_make_rules "$rules" "10,0" "$pa" "$pb" "active-standby" "true" "3600" "2" "2" "10"
        cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$pa|failed|2|2|$now|$now|100|100
2|127.0.0.1:$pb|healthy|0|3|$now|0|100|100
EOF
        _n8_mkhc "$_N8_LIBROOT" "$SBX_ROOT/n8_hc70_deg.sh"
        bash "$SBX_ROOT/n8_hc70_deg.sh" >/dev/null 2>&1
        map=$(_n8_weights "$(_n8_gen_with "$_N8_LIBROOT")" 443)
        h_log "退化后 目标=权重: $map"
        h_log "退化后 主目标记录: $(_n8_status_row "$health" "127.0.0.1:$pa")"
        j=$(_n8_judge_cooldown_blocked "$health" "$map" "127.0.0.1:$pa" "127.0.0.1:$pb")
        h_log "退化判定: $j"
        h_check_contains "$j" "FAIL" "负向对照（注入式退化：去掉冷却期判断）：冷却期内就切回主 → 判定器必须判红"
    fi

    _n8_listener_stop p
    _n8_listener_stop b
}

# ══════════════════════════════════════════════════════════════
# ④ T71 · 抖动不反复切
# ══════════════════════════════════════════════════════════════
case_T71_no_flapping() {
    h_case_begin "T71" "抖动不反复切：连续失败阈值 + 恢复冷却期两道闸都要在" \
        "沙箱 rules（权重 10,0；主目标可控启停）+ health_status.conf" \
        "health_check.sh 连跑 4 轮（主：坏→坏→好→好）+ generate_endpoints_from_rules" \
        "坏坏阶段才切走；好好阶段（冷却期内）切不回；整个抖动序列里切换次数恰好 1 次"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local pa=18231 pb=18232
    local hc="$SBX_ROOT/n8_hc71.sh"
    local map seq count j

    _n8_reset
    _n8_make_rules "$rules" "10,0" "$pa" "$pb" "active-standby" "true" "3600" "2" "2" "10"
    if _n8_port_listening "$pa"; then
        h_fail "主目标端口 $pa 上有别的监听（主目标本该能被置为「没人监听」）→ 抖动场景失真"
        return
    fi
    if ! _n8_listener_start "$pb" b; then
        h_fail "起不来本地监听端口（备目标不可达），本组无法判定"
        return
    fi
    _n8_mkhc "$SBX_RUN" "$hc"

    # ── 抖动序列：主 坏 → 坏 → 好 → 好 ──
    #   记录每一轮之后主目标的权重（1=主承接流量，0=备承接流量）。
    #   ★ 主备监听分槽位：停主不能误停备（共用一个 PID 变量会把备也杀掉 → 两侧都挂
    #     → 读侧走「全挂兜底」→ 权重恒为 1 → 场景失真）。
    seq=""
    local r primary_up=0
    for r in 1 2 3 4; do
        if [ "$r" -le 2 ]; then
            # 主目标坏（没人监听 → 连接被拒 → 快速失败）
            if [ "$primary_up" = "1" ]; then
                _n8_listener_stop p
                primary_up=0
            fi
        else
            if [ "$primary_up" != "1" ]; then
                if _n8_listener_start "$pa" p; then
                    primary_up=1
                else
                    h_log "第${r}轮主目标监听启动失败"
                fi
            fi
        fi
        bash "$hc" >/dev/null 2>&1
        map=$(_n8_weights "$(_n8_gen_with)" 443)
        local w
        w=$(_n8_weight_of "$map" "127.0.0.1:$pa")
        seq="$seq $w"
        h_log "第${r}轮（主=$([ "$r" -le 2 ] && echo 坏 || echo 好)）后 目标=权重: $map"
    done
    _n8_listener_stop p
    _n8_listener_stop b

    count=$(_n8_count_switches "$seq")
    h_log "抖动序列（主权重）:$seq  切换次数=$count"
    # 前提自检：序列里必须真的出现过「切走」（权重 0），否则场景没成立
    h_check_contains "$seq" "0" "正序腿前提：主确实切走过一次（场景成立，不是「两边都挂」）"
    j=$(_n8_judge_switch_count "$count" "1")
    h_log "切换次数判定: $j"
    h_check_contains "$j" "PASS" "整个抖动序列里主备只切换了 1 次（没有来回切）"

    # 逐轮口径：第 1 轮未达阈值不得切走；第 2 轮达阈值切走；第 3/4 轮冷却期内切不回
    local first second third fourth
    first=$(printf '%s' "$seq" | awk '{print $1}')
    second=$(printf '%s' "$seq" | awk '{print $2}')
    third=$(printf '%s' "$seq" | awk '{print $3}')
    fourth=$(printf '%s' "$seq" | awk '{print $4}')
    h_check_eq "1" "$first" "第1轮（失败 1 次，未达阈值）主仍在承接流量"
    h_check_eq "0" "$second" "第2轮（失败达阈值）已切走"
    h_check_eq "0" "$third" "第3轮（恢复 1 次，冷却期内）切不回"
    h_check_eq "0" "$fourth" "第4轮（恢复达成功阈值，冷却期内）切不回"

    # ── 负向对照（注入式退化，不是历史旧实现）：去掉冷却期判断 ──
    #   同一套判定器必须判红：退化后第 4 轮会切回主 → 切换次数变成 2 次。
    if _n8_prepare_degraded_lib "no-cooldown"; then
        rm -f "$health"
        _n8_mkhc "$_N8_LIBROOT" "$SBX_ROOT/n8_hc71_deg.sh"
        # ★ 备目标必须**重新拉起来**：正序腿结束时把它停了；备目标不在线的话
        #   两边都故障 → 读侧走「全挂兜底」→ 权重恒为 1 → 负向对照会因为
        #   「场景失真」而变红，而不是因为「冷却期被去掉」而变红 —— 那是假证明。
        if ! _n8_listener_start "$pb" b; then
            h_fail "起不来本地监听端口（退化腿的备目标不可达），负向对照无法判定"
            return
        fi
        local seq2="" count2 primary_up2=0
        for r in 1 2 3 4; do
            if [ "$r" -le 2 ]; then
                if [ "$primary_up2" = "1" ]; then
                    _n8_listener_stop p
                    primary_up2=0
                fi
            else
                if [ "$primary_up2" != "1" ]; then
                    if _n8_listener_start "$pa" p; then
                        primary_up2=1
                    else
                        h_log "退化第${r}轮主目标监听启动失败"
                    fi
                fi
            fi
            bash "$SBX_ROOT/n8_hc71_deg.sh" >/dev/null 2>&1
            map=$(_n8_weights "$(_n8_gen_with "$_N8_LIBROOT")" 443)
            local w2
            w2=$(_n8_weight_of "$map" "127.0.0.1:$pa")
            seq2="$seq2 $w2"
        done
        _n8_listener_stop p
        _n8_listener_stop b
        count2=$(_n8_count_switches "$seq2")
        h_log "退化序列（主权重）:$seq2  切换次数=$count2"
        # 前提自检：退化腿里也必须真的切走过一次 —— 否则变红是因为「场景失真」，
        #   不是因为「冷却期被去掉」→ 那是假证明，必须在这里挡住。
        h_check_contains "$seq2" "0" "退化腿前提：主确实切走过一次（场景成立）"
        j=$(_n8_judge_switch_count "$count2" "1")
        h_log "退化切换次数判定: $j"
        h_check_contains "$j" "FAIL" "负向对照（注入式退化：去掉冷却期判断）：出现来回切 → 判定器必须判红"
    fi
}

# 统计「主承接流量」在序列里变化的次数（相邻两轮权重不同就算一次切换）
_n8_count_switches() {
    local seq="$1" prev="" cur n=0
    for cur in $seq; do
        if [ -n "$prev" ] && [ "$cur" != "$prev" ]; then
            n=$((n + 1))
        fi
        prev="$cur"
    done
    printf '%s' "$n"
}

# ══════════════════════════════════════════════════════════════
# ⑤ T72 · 探测端真在探测
# ══════════════════════════════════════════════════════════════
case_T72_probe_actually_runs() {
    h_case_begin "T72" "探测端真在探测：健康状态产物的最后检查时间必须前进" \
        "沙箱 rules（权重 10,0）+ health_status.conf（LAST_CHECK 写成很旧的旧值）" \
        "health_check.sh 连跑两轮" \
        "每轮之后 LAST_CHECK 必须前进（产出物真的变了，不是只看退出码/日志）"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local pa=18241 pb=18242
    local hc="$SBX_ROOT/n8_hc72.sh"
    local old=1000 row before after j

    _n8_reset
    _n8_make_rules "$rules" "10,0" "$pa" "$pb" "active-standby" "true" "120" "2" "2" "10"
    if ! _n8_listener_start "$pa" p; then
        h_fail "起不来本地监听端口（主目标不可达），本组无法判定"
        return
    fi
    _n8_mkhc "$SBX_RUN" "$hc"

    # ── 第 1 轮：LAST_CHECK 从旧值前进 ──
    mkdir -p "$(dirname "$health")"
    cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$pa|healthy|0|3|$old|0|0|0
2|127.0.0.1:$pb|healthy|0|3|$old|0|0|0
EOF
    before=$(_n8_status_row "$health" "127.0.0.1:$pa")
    bash "$hc" >/dev/null 2>&1
    after=$(_n8_status_row "$health" "127.0.0.1:$pa")
    h_log "第1轮前: $before"
    h_log "第1轮后: $after"
    j=$(_n8_judge_last_check "$old" "$(_n8_field_of_row "$after" 6)")
    h_log "第1轮判定: $j"
    h_check_contains "$j" "PASS" "第1轮：LAST_CHECK 前进"
    if [ "$before" = "$after" ]; then
        h_fail "第1轮后状态记录**一字未改** → 产出物没变（探测端没在真探测）"
    else
        h_pass "第1轮：状态记录整行都变了（不只是退出码）"
    fi
    local lat
    lat=$(_n8_field_of_row "$after" 8)
    if printf '%s' "$lat" | grep -qE '^[0-9]+$'; then
        h_pass "第1轮：时延字段有真实采样（${lat}ms → 探测真的执行了）"
    else
        h_fail "第1轮：时延字段不是毫秒数（<${lat}>）→ 探测疑似没真跑"
    fi

    # ── 第 2 轮：再把 LAST_CHECK 改回旧值，必须**再次**前进（不是一次性动作）──
    cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$pa|healthy|0|3|$old|0|0|0
2|127.0.0.1:$pb|healthy|0|3|$old|0|0|0
EOF
    bash "$hc" >/dev/null 2>&1
    after=$(_n8_status_row "$health" "127.0.0.1:$pa")
    h_log "第2轮后: $after"
    j=$(_n8_judge_last_check "$old" "$(_n8_field_of_row "$after" 6)")
    h_log "第2轮判定: $j"
    h_check_contains "$j" "PASS" "第2轮：LAST_CHECK 再次前进（每轮都在探测）"

    # ── 负向对照（注入式退化，不是历史旧实现）：LAST_CHECK 写死 ──
    #   这正是真机踩过的坑的形态：每 4 秒打一行、退出码 0，但产物停在 7 小时前。
    if _n8_prepare_degraded_lib "frozen-time"; then
        cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$pa|healthy|0|3|$old|0|0|0
2|127.0.0.1:$pb|healthy|0|3|$old|0|0|0
EOF
        _n8_mkhc "$_N8_LIBROOT" "$SBX_ROOT/n8_hc72_deg.sh"
        bash "$SBX_ROOT/n8_hc72_deg.sh" >/dev/null 2>&1
        after=$(_n8_status_row "$health" "127.0.0.1:$pa")
        h_log "退化后: $after"
        j=$(_n8_judge_last_check "$old" "$(_n8_field_of_row "$after" 6)")
        h_log "退化判定: $j"
        h_check_contains "$j" "FAIL" "负向对照（注入式退化：LAST_CHECK 写死）：判定器必须判红"
    fi

    _n8_listener_stop p
}

# ══════════════════════════════════════════════════════════════
# ⑥ T73 · 不误切（慢但未断）
# ══════════════════════════════════════════════════════════════
case_T73_no_false_switch_slow_target() {
    h_case_begin "T73" "不误切：慢但未断不被判故障 + 探针超时预算真的生效" \
        "沙箱 rules（权重 5,0）+ 黑洞地址 10.255.255.1 + 本地监听口" \
        "probe_with_latency（预算 2 / 预算 10）+ health_check.sh" \
        "预算 2 → 墙钟≈2s、预算 10 → 墙钟≈10s 且都判失败；可达但慢的目标判健康（不判故障）"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local pa=18251
    local hole="10.255.255.1" holeport=80
    local hc="$SBX_ROOT/n8_hc73.sh"
    local w2 w10 r2 r10 j row

    # ── 腿 1：探针超时预算真的生效（黑洞地址：连不上的远端 IP，连接会挂住）──
    local t0 t1
    t0=$(date +%s%3N)
    r2=$(_run_in_sandbox '
        source "$2/lib/health.sh" >/dev/null 2>&1
        probe_with_latency "$3" "$4" 2
        echo "RC=$?"
    ' "$SBX_RUN" "$hole" "$holeport" 2>&1 | grep -o 'RC=[0-9]*' | tail -1 | cut -d= -f2)
    t1=$(date +%s%3N)
    w2=$((t1 - t0))

    t0=$(date +%s%3N)
    r10=$(_run_in_sandbox '
        source "$2/lib/health.sh" >/dev/null 2>&1
        probe_with_latency "$3" "$4" 10
        echo "RC=$?"
    ' "$SBX_RUN" "$hole" "$holeport" 2>&1 | grep -o 'RC=[0-9]*' | tail -1 | cut -d= -f2)
    t1=$(date +%s%3N)
    w10=$((t1 - t0))

    h_log "黑洞 $hole:$holeport 预算2 → ${w2}ms rc=$r2；预算10 → ${w10}ms rc=$r10"
    h_check_rc "nonzero" "$r2" "预算 2 探测黑洞 → 判失败"
    h_check_rc "nonzero" "$r10" "预算 10 探测黑洞 → 判失败"
    j=$(_n8_judge_budget "$w2" "$w10")
    h_log "预算判定: $j"
    h_check_contains "$j" "PASS" "探针超时预算真的生效（2s 与 10s 墙钟明显不同）"

    # ── 腿 2：可达但慢 → 判健康，不判故障 ──
    _n8_reset
    _n8_make_rules "$rules" "5,0" "$pa" 18252 "active-standby" "true" "120" "2" "2" "10"
    if ! _n8_listener_start "$pa" p; then
        h_fail "起不来本地监听端口（慢目标不可达），本组无法判定"
        return
    fi
    local r_ok
    r_ok=$(_run_in_sandbox '
        source "$2/lib/health.sh" >/dev/null 2>&1
        probe_with_latency "$3" "$4" 10
        echo "RC=$?"
        echo "MS=$PROBE_LATENCY_MS"
    ' "$SBX_RUN" "127.0.0.1" "$pa" 2>&1)
    h_log "慢目标探测输出: $(printf '%s' "$r_ok" | tr '\n' ' ')"
    local rc_ok ms_ok
    rc_ok=$(printf '%s' "$r_ok" | grep -o '^RC=[0-9]*' | tail -1 | cut -d= -f2)
    ms_ok=$(printf '%s' "$r_ok" | grep -o '^MS=[0-9]*' | tail -1 | cut -d= -f2)
    h_check_rc "0" "$rc_ok" "可达但慢的目标 → 探测判连通"
    if printf '%s' "$ms_ok" | grep -qE '^[0-9]+$'; then
        h_pass "慢目标探测有真实时延采样（${ms_ok}ms）"
    else
        h_fail "慢目标探测没拿到时延采样（<${ms_ok}>）"
    fi

    # 健康检查跑一轮 → 该目标必须仍是 healthy（没被误判故障）
    _n8_mkhc "$SBX_RUN" "$hc"
    bash "$hc" >/dev/null 2>&1
    row=$(_n8_status_row "$health" "127.0.0.1:$pa")
    h_log "慢目标跑一轮后的记录: $row"
    h_check_eq "healthy" "$(_n8_field_of_row "$row" 3)" "慢目标不被判故障（状态仍是 healthy）"
    h_check_eq "0" "$(_n8_field_of_row "$row" 4)" "慢目标的失败计数为 0"

    # ── 负向对照（注入式退化，不是历史旧实现）：超时预算写死 3s ──
    if _n8_prepare_degraded_lib "hard-timeout"; then
        local dw2 dw10
        t0=$(date +%s%3N)
        _run_in_sandbox '
            source "$2/lib/health.sh" >/dev/null 2>&1
            probe_with_latency "$3" "$4" 2
        ' "$_N8_LIBROOT" "$hole" "$holeport" >/dev/null 2>&1
        t1=$(date +%s%3N)
        dw2=$((t1 - t0))
        t0=$(date +%s%3N)
        _run_in_sandbox '
            source "$2/lib/health.sh" >/dev/null 2>&1
            probe_with_latency "$3" "$4" 10
        ' "$_N8_LIBROOT" "$hole" "$holeport" >/dev/null 2>&1
        t1=$(date +%s%3N)
        dw10=$((t1 - t0))
        h_log "退化后 预算2 → ${dw2}ms；预算10 → ${dw10}ms"
        j=$(_n8_judge_budget "$dw2" "$dw10")
        h_log "退化预算判定: $j"
        h_check_contains "$j" "FAIL" "负向对照（注入式退化：超时预算写死 3s）：判定器必须判红"
    fi

    _n8_listener_stop p
}

# ══════════════════════════════════════════════════════════════
# ⑦ T74 · 不继承老状态
# ══════════════════════════════════════════════════════════════
case_T74_no_inherited_state() {
    h_case_begin "T74" "不继承老状态：删规则后新建同 ID 规则，初始状态健康、失败计数 0" \
        "沙箱 rules（RULE_ID 连续 1/2）+ health_status.conf（老规则目标=failed）" \
        "delete_rule 1 true → 新建同 ID 规则 → health_check.sh + generate_endpoints_from_rules" \
        "新规则目标不继承老规则的 failed：状态 healthy、失败计数 0、读侧权重不为 0"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local old_target=18261 other_target=18262 new_target=18263
    local hc="$SBX_ROOT/n8_hc74.sh"
    local j map out

    # ── 造老规则：目标 old_target 在健康状态文件里是 failed（失败计数达阈值）──
    _n8_reset
    _n8_make_rules "$rules" "10,0" "$old_target" "$other_target" "active-standby" "true" "120" "2" "2" "10"
    mkdir -p "$(dirname "$health")"
    cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$old_target|failed|2|0|100|100|0|0
2|127.0.0.1:$other_target|healthy|0|3|100|0|0|0
EOF

    # ── 新目标要**可达** ──
    #   「失败计数 0」只有在探测成功时成立；目标不可达时计数会是 1（不是继承了老状态，
    #   是新目标真的连不上）—— 那就判不出「继承」这回事了。
    if ! _n8_listener_start "$new_target" p; then
        h_fail "起不来本地监听端口（新目标不可达），本组无法判定"
        return
    fi

    # ── 删掉老规则 ──
    out=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        delete_rule 1 true < /dev/null
    ' 2>&1)
    h_log "删规则输出: $(printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-160)"
    if [ -f "$rules/rule-1.conf" ]; then
        h_fail "老规则没删掉（rule-1.conf 还在）→ 场景没成立"
        return
    fi
    h_pass "老规则已删除"

    # ── 新建**同 ID**（RULE_ID=1）的规则，目标换成一个**新目标** ──
    #   ★ RULE_ID 连续性（文件头纪律）：剩下的 rule-2 是 ID=2，新规则是 ID=1 →
    #     连续 1/2 → 不会触发 reorder_rule_ids 重排 → 健康状态文件里老行的
    #     RULE_ID 归属仍然认得出 → 场景走的是「同 ID 复用」这条路径。
    #     如果这里写成不连续的 ID（比如 1 和 5），reorder 会把 ID 重排成 1..N
    #     且不同步健康状态文件 → 老行归属认不出 → 读侧落回「当无记录」分支
    #     → 场景走另一条路径 → 用例假绿。
    cat > "$rules/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=n8-new-rule
SECURITY_LEVEL=none
LISTEN_PORT=443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=$new_target
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
    h_check_file "$rules/rule-1.conf" "新建的同 ID 规则"

    _n8_mkhc "$SBX_RUN" "$hc"
    bash "$hc" >/dev/null 2>&1
    map=$(_n8_weights "$(_n8_gen_with)" 443)
    h_log "新建后 目标=权重: $map"
    h_log "新建后 新目标记录: $(_n8_status_row "$health" "127.0.0.1:$new_target")"

    j=$(_n8_judge_new_rule_state "$health" "$map" "127.0.0.1:$new_target" "healthy" "0")
    h_log "不继承老状态判定: $j"
    h_check_contains "$j" "PASS" "新规则不继承老规则的 failed（健康、失败计数 0、读侧不判故障）"

    # ── 负向对照（注入式退化，不是历史旧实现）：健康状态按 RULE_ID 认领 ──
    #   退化后老规则留下的行会被同 ID 的新规则认领 → 新规则一上来就显示故障。
    #   同一套判定器必须判红 —— 否则「不继承老状态」这条就是恒真断言。
    if _n8_prepare_degraded_lib "id-rekey"; then
        _n8_reset
        _n8_make_rules "$rules" "10,0" "$old_target" "$other_target" "active-standby" "true" "120" "2" "2" "10"
        cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$old_target|failed|2|0|100|100|0|0
2|127.0.0.1:$other_target|healthy|0|3|100|0|0|0
EOF
        _run_in_sandbox '
            source "$1/lib/core.sh" >/dev/null 2>&1
            source "$1/lib/health.sh" >/dev/null 2>&1
            source "$1/lib/rules.sh" >/dev/null 2>&1
            delete_rule 1 true < /dev/null
        ' >/dev/null 2>&1
        cat > "$rules/rule-1.conf" <<EOF
RULE_ID=1
RULE_ROLE=1
RULE_NAME=n8-new-rule
SECURITY_LEVEL=none
LISTEN_PORT=443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=$new_target
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
        _n8_mkhc "$_N8_LIBROOT" "$SBX_ROOT/n8_hc74_deg.sh"
        bash "$SBX_ROOT/n8_hc74_deg.sh" >/dev/null 2>&1
        map=$(_n8_weights "$(_n8_gen_with "$_N8_LIBROOT")" 443)
        h_log "退化后 目标=权重: $map"
        j=$(_n8_judge_new_rule_state "$health" "$map" "127.0.0.1:$new_target" "healthy" "0")
        h_log "退化判定: $j"
        h_check_contains "$j" "FAIL" "负向对照（注入式退化：按 RULE_ID 认领）：新规则继承了老状态 → 判定器必须判红"
    fi

    _n8_listener_stop p
}

# ══════════════════════════════════════════════════════════════
# ⑧ T75 · 不留半吊子
# ══════════════════════════════════════════════════════════════
case_T75_rollback_when_probe_fails() {
    h_case_begin "T75" "不留半吊子：探测端起不来必须回滚主备开关（加固 T37）" \
        "沙箱 rules + 真实 ensure_health_check_service + systemctl enable 失败的桩" \
        "apply_port_group_weight_config 443 '10,0' 1" \
        "打印真实失败原因；BALANCE_MODE / FAILOVER_ENABLED / TARGET_STATES 原样回滚；探测端确实没起来"

    local rules="$SBX_ROOT/realm/rules"
    local rf="$rules/rule-1.conf"
    local failbin="$SBX_ROOT/n8_failbin"
    local out j

    _n8_reset
    _n8_make_rules "$rules" "10,0" 18271 18272 "roundrobin" "false" "120" "2" "2" "10"
    # 造一个「探测端起不来」的TARGET_STATES（主备模式不使用它 → 回滚后必须原样还在）
    sed -i 's|^TARGET_STATES=.*|TARGET_STATES="10.0.0.9"|' "$rules"/rule-*.conf

    # systemctl 的 enable 失败桩（走**真实**的 start_health_check_service 链路，
    #   不是像 T37 那样把 ensure_health_check_service 整个桩掉 —— 这一条是加固）
    mkdir -p "$failbin"
    cat > "$failbin/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >> "${SBX_LOG_DIR:-/tmp}/systemctl.log"
case "${1:-}" in
    enable) exit 1 ;;
esac
exit 0
SH
    chmod +x "$failbin/systemctl"
    : > "$SBX_LOG_DIR/systemctl.log"

    out=$(PATH="$failbin:$PATH" _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        service_restart(){ return 0; }
        apply_port_group_weight_config 443 "10,0" 1 < /dev/null
    ' 2>&1)
    h_log "输出: $(printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-300)"

    # ── 前提：探测端确实没起来（否则这条用例的前提不成立）──
    local syslog
    syslog=$(cat "$SBX_LOG_DIR/systemctl.log" 2>/dev/null)
    h_log "systemctl 调用记录: $(printf '%s' "$syslog" | tr '\n' ' ')"
    h_check_contains "$syslog" "systemctl enable realm-health-check.timer" "前提：探测端的 enable 被调用过（真实链路）"
    h_check_not_contains "$syslog" "systemctl start realm-health-check.timer" "前提：探测端确实没起来（没有 start）"

    # ── 明确提示 ──
    h_check_contains "$out" "健康检查服务启动失败" "打印了真实失败原因"
    h_check_contains "$out" "已回滚" "明确告知已回滚"

    # ── 回滚口径（比 T37 更细：三个字段**逐个精确**回到原值，不残留半状态）──
    j=$(_n8_judge_rollback "$rf" "roundrobin" "false" "10.0.0.9")
    h_log "回滚判定: $j"
    h_check_contains "$j" "PASS" "三个字段原样回滚（不留 TARGET_STATES 半状态）"

    # ── 负向对照（注入式退化，不是历史旧实现）：回滚被去掉 ──
    if _n8_prepare_degraded_lib "no-rollback"; then
        _n8_reset
        _n8_make_rules "$rules" "10,0" 18271 18272 "roundrobin" "false" "120" "2" "2" "10"
        sed -i 's|^TARGET_STATES=.*|TARGET_STATES="10.0.0.9"|' "$rules"/rule-*.conf
        : > "$SBX_LOG_DIR/systemctl.log"
        out=$(PATH="$failbin:$PATH" _run_in_sandbox '
            source "$2/lib/core.sh" >/dev/null 2>&1
            source "$2/lib/health.sh" >/dev/null 2>&1
            source "$2/lib/rules.sh" >/dev/null 2>&1
            service_restart(){ return 0; }
            apply_port_group_weight_config 443 "10,0" 1 < /dev/null
        ' "$_N8_LIBROOT" 2>&1)
        h_log "退化输出: $(printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-240)"
        j=$(_n8_judge_rollback "$rf" "roundrobin" "false" "10.0.0.9")
        h_log "退化回滚判定: $j"
        h_check_contains "$j" "FAIL" "负向对照（注入式退化：回滚被去掉）：留下半吊子 → 判定器必须判红"
    fi
}

# ══════════════════════════════════════════════════════════════
# ⑨ T76 · 切走/切回的目标必须是同一批目标
# ══════════════════════════════════════════════════════════════
case_T76_same_target_set() {
    h_case_begin "T76" "切走/切回的目标必须是同一批目标（不能凭空多出或少掉）" \
        "沙箱 rules（权重 10,0；同 host 不同端口的主备）+ health_status.conf" \
        "health_check.sh（切走）+ generate_endpoints_from_rules（切走前后 + 切回后）" \
        "切换前后的目标集合逐项相等、目标数恒为 2；切走是切到同一个备、切回是切回同一个主"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local pa=18281 pb=18282
    local hc="$SBX_ROOT/n8_hc76.sh"
    local s0 s1 s2 map j

    _n8_reset
    _n8_make_rules "$rules" "10,0" "$pa" "$pb" "active-standby" "true" "120" "2" "2" "10"
    if _n8_port_listening "$pa"; then
        h_fail "主目标端口 $pa 上有别的监听（主目标本该是「没人监听」）→ 场景失真"
        return
    fi
    if ! _n8_listener_start "$pb" b; then
        h_fail "起不来本地监听端口（备目标不可达），本组无法判定"
        return
    fi
    _n8_mkhc "$SBX_RUN" "$hc"

    # ── 切换前 ──
    map=$(_n8_weights "$(_n8_gen_with)" 443)
    s0=$(_n8_targets "$(_n8_gen_with)" 443)
    h_log "切换前 目标集合: [$s0]  目标=权重: $map"
    h_check_eq "2" "$(printf '%s\n' $s0 | grep -c .)" "切换前端口组恰好 2 个目标（同 host 不同端口 = 两个不同目标）"
    h_check_eq "1" "$(_n8_weight_of "$map" "127.0.0.1:$pa")" "切换前主目标承接流量"

    # ── 切走（主连续失败达阈值）──
    bash "$hc" >/dev/null 2>&1
    bash "$hc" >/dev/null 2>&1
    map=$(_n8_weights "$(_n8_gen_with)" 443)
    s1=$(_n8_targets "$(_n8_gen_with)" 443)
    h_log "切走后 目标集合: [$s1]  目标=权重: $map"
    j=$(_n8_judge_same_targets "$s0" "$s1" "2")
    h_log "切走判定: $j"
    h_check_contains "$j" "PASS" "切走前后的目标集合是同一批（逐项相等）"
    h_check_eq "0" "$(_n8_weight_of "$map" "127.0.0.1:$pa")" "切走：主目标权重变 0（切到同一个备目标）"
    h_check_eq "1" "$(_n8_weight_of "$map" "127.0.0.1:$pb")" "切走：备目标权重变 1"

    # ── 切回（主恢复）──
    local now
    now=$(date +%s)
    cat > "$health" <<EOF
# Realm健康状态文件
1|127.0.0.1:$pa|healthy|0|3|$now|0|100|100
2|127.0.0.1:$pb|healthy|0|3|$now|0|100|100
EOF
    map=$(_n8_weights "$(_n8_gen_with)" 443)
    s2=$(_n8_targets "$(_n8_gen_with)" 443)
    h_log "切回后 目标集合: [$s2]  目标=权重: $map"
    j=$(_n8_judge_same_targets "$s0" "$s2" "2")
    h_log "切回判定: $j"
    h_check_contains "$j" "PASS" "切回前后的目标集合还是同一批"
    h_check_eq "1" "$(_n8_weight_of "$map" "127.0.0.1:$pa")" "切回：主目标权重回到 1（切回同一个主目标）"
    h_check_eq "0" "$(_n8_weight_of "$map" "127.0.0.1:$pb")" "切回：备目标权重回到 0"

    # ── 负向对照 1（注入式退化，不是历史旧实现）：切换后目标凭空少一个 ──
    if _n8_prepare_degraded_lib "drop-target"; then
        map=$(_n8_weights "$(_n8_gen_with "$_N8_LIBROOT")" 443)
        s1=$(_n8_targets "$(_n8_gen_with "$_N8_LIBROOT")" 443)
        h_log "退化（少目标）后 目标集合: [$s1]"
        j=$(_n8_judge_same_targets "$s0" "$s1" "2")
        h_log "退化判定: $j"
        h_check_contains "$j" "FAIL" "负向对照 1（注入式退化：目标凭空少掉）：判定器必须判红"
    fi

    # ── 负向对照 2（注入式退化，不是历史旧实现）：切换后目标凭空多一个 ──
    if _n8_prepare_degraded_lib "add-target"; then
        map=$(_n8_weights "$(_n8_gen_with "$_N8_LIBROOT")" 443)
        s1=$(_n8_targets "$(_n8_gen_with "$_N8_LIBROOT")" 443)
        h_log "退化（多目标）后 目标集合: [$s1]"
        j=$(_n8_judge_same_targets "$s0" "$s1" "2")
        h_log "退化判定: $j"
        h_check_contains "$j" "FAIL" "负向对照 2（注入式退化：目标凭空多出）：判定器必须判红"
    fi

    _n8_listener_stop b
}
