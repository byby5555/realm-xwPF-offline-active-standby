#!/bin/bash
# 用例组 28 · 快探测流（**只观测**：每秒一轮，刷新菜单里的时延/丢包显示）
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   1) **快探测不参与切换**：它不写判定流的状态文件、不触发配置重生成。
#      这条是**架构级**承诺（口径：1 秒探测只用于检测和显示时延，
#      实际切换仍按负载均衡脚本的默认时间）。
#      ⇒ 判据落在**生成物**上：产物里出现「写状态文件 / 触发配置重生成」
#        的字样 ⇒ 必须**拒绝安装**（反向护栏，可测的硬不变式）。
#   2) **1 秒一轮真的轮得起来**：systemd 定时器默认 AccuracySec=1min，
#      会被对齐到分钟边界 ⇒ 「1 秒一轮」实际是每分钟一轮。
#      ⇒ timer 里必须显式 AccuracySec=1s。
#   3) **失败分型可判**：同一个「连不上」在不同宿主上可能是 RST 拒绝、
#      也可能是 SYN 被丢 ⇒ 断言不能绑宿主，必须测**分型规则本身**。
#   4) **菜单时延口径**：快探测（1 秒刷新）优先，没有快探测数据时回落
#      判定流的状态文件（两处都是 TCP 握手耗时，同一个口径）。
#
# ★ 全部在沙箱里做：规则/状态/生成物都落在沙箱路径（路径重定向在源码层生效）。

# ── 快探测用的一条规则（TARGET_STATES 形态：同 host 不同端口的备机）──
_t28_make_rule() {
    local rule_file="$1"
    local target_states="${2:-127.0.0.1:18111,127.0.0.1:18112}"

    cat > "$rule_file" <<EOF
RULE_ID=1
RULE_NAME="fast-probe"
RULE_ROLE="1"
SECURITY_LEVEL="none"
LISTEN_PORT="19910"
LISTEN_IP="0.0.0.0"
THROUGH_IP="::"
REMOTE_HOST="127.0.0.1"
REMOTE_PORT="18111"
TLS_SERVER_NAME=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_NOTE="快探测用例"
ENABLED="true"
CREATED_TIME="2026-10-27 00:00:00"
BALANCE_MODE="active-standby"
PREV_BALANCE_MODE=""
TARGET_STATES="$target_states"
WEIGHTS="10,0"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="10"
RECOVERY_COOLDOWN="120"
PROBE_QUALITY_WINDOW="20"
MPTCP_MODE="off"
PROXY_MODE="off"
EOF
}

# 生成快探测脚本到沙箱（返回生成物路径）
_t28_generate() {
    local out="$1"
    _run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        fast_probe_script_body
    ' > "$out" 2>/dev/null
}


# ══════════════════════════════════════════════════════════════
# T123 · 生成物护栏：快探测**只观测**，不参与切换
# ══════════════════════════════════════════════════════════════
case_T123_fast_probe_guard_and_timer() {
    h_case_begin "T123" "快探测生成物：只观测不参与切换 + 1 秒轮得起来" \
        "沙箱生成物（lib/health.sh 的 fast_probe_script_body）" \
        "fast_probe_script_body + fast_probe_guard_check + start_fast_probe_service 生成的 unit/timer" \
        "产物里没有「写判定流状态文件 / 触发配置重生成」的字样；护栏对坏产物判红；timer 的 AccuracySec=1s（否则 1 秒一轮会被对齐到分钟边界）"

    local fp="$SBX_ROOT/t123_fast_probe.sh"
    rm -f "$fp"

    _t28_generate "$fp"
    h_check_file "$fp" "生成的快探测脚本"

    # ── 1. 生成物里**不许**出现「写状态文件 / 触发配置重生成」的字样 ──
    local n_status n_restart
    n_status=$(grep -cF 'health_status.conf' "$fp" 2>/dev/null); n_status=${n_status:-0}
    n_restart=$(grep -cF 'restart-service' "$fp" 2>/dev/null); n_restart=${n_restart:-0}
    h_log "生成物里 health_status.conf 命中 $n_status 处 / restart-service 命中 $n_restart 处"
    h_check_eq "0" "$n_status" "生成物里没有「写判定流状态文件」的字样"
    h_check_eq "0" "$n_restart" "生成物里没有「触发配置重生成」的字样"

    # ── 2. 护栏：真产物放行（阳性对照）──
    local guard_out guard_rc
    guard_out=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        fast_probe_guard_check "$2"
    ' "$fp" 2>&1)
    guard_rc=$?
    h_log "护栏（真产物）: rc=$guard_rc 输出=${guard_out:-（空）}"
    h_check_rc 0 "$guard_rc" "护栏对真实生成物放行"

    # ── 3. 护栏：注入坏产物 ⇒ 必须判红（负向对照）──
    #   注入手法 = 在**副本**末尾追加一句「偷写状态文件」（不改冻结态、不改仓库）。
    #   这一条必须真的判红，否则第 1 条断言就是恒绿。
    local bad="$SBX_ROOT/t123_fast_probe_bad.sh"
    cp "$fp" "$bad"
    printf '\n# T123-NEG: 偷写状态文件\necho x >> /etc/realm/health/health_status.conf\n' >> "$bad"
    local n_inj
    n_inj=$(grep -c 'T123-NEG' "$bad" 2>/dev/null); n_inj=${n_inj:-0}
    h_check_eq "1" "$n_inj" "负向对照的注入点命中（破坏手法生效）"

    local bad_out bad_rc
    bad_out=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        fast_probe_guard_check "$2"
    ' "$bad" 2>&1)
    bad_rc=$?
    h_log "护栏（坏产物）: rc=$bad_rc 输出=${bad_out}"
    h_check_rc nonzero "$bad_rc" "护栏对「偷写状态文件」的坏产物判红"
    h_check_contains "$bad_out" "状态文件" "判红原因指到「写状态文件」"

    # ── 4. timer：1 秒一轮必须用**日历表达式**，且必须显式压 AccuracySec ──
    #   真机实测（systemd 257 / Debian 13，各复现两轮）：
    #     OnUnitActiveSec=1sec + AccuracySec=1s ⇒ 实际间隔约 2 秒（还有一轮直接 0 次）
    #     OnCalendar=*-*-* *:*:0/1 + AccuracySec=1s ⇒ 实际间隔约 1.00 秒（三轮都稳）
    #   ⇒ 用 OnUnitActiveSec 写的「1 秒一轮」在真机上根本不是 1 秒。
    local unitdir="$SBX_ROOT/t123_units"
    rm -rf "$unitdir"; mkdir -p "$unitdir"
    _run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        # 只生成 unit/timer 文本，不碰 systemd（沙箱里 systemctl 是桩）
        start_health_check_service 4 >/dev/null 2>&1
        start_fast_probe_service 1 >/dev/null 2>&1
    ' >/dev/null 2>&1

    local timer="$SBX_ROOT/systemd/realm-fast-probe.timer"
    local svc="$SBX_ROOT/systemd/realm-fast-probe.service"
    local judge_svc="$SBX_ROOT/systemd/realm-health-check.service"
    h_check_file "$timer" "生成的快探测 timer"
    h_check_file "$svc" "生成的快探测 service"
    h_check_file "$judge_svc" "生成的判定端 service（对照）"

    local acc cal n_limit_fast n_limit_judge
    acc=$(grep -c '^AccuracySec=1s$' "$timer" 2>/dev/null); acc=${acc:-0}
    cal=$(grep -c '^OnCalendar=\*-\*-\* \*:\*:0/1$' "$timer" 2>/dev/null); cal=${cal:-0}
    n_limit_fast=$(grep -c '^StartLimitIntervalSec=0$' "$svc" 2>/dev/null); n_limit_fast=${n_limit_fast:-0}
    n_limit_judge=$(grep -c '^StartLimitIntervalSec=0$' "$judge_svc" 2>/dev/null); n_limit_judge=${n_limit_judge:-0}
    h_log "timer: AccuracySec=1s 命中 $acc / OnCalendar 每秒命中 $cal"
    h_log "service: 快探测 StartLimitIntervalSec=0 命中 $n_limit_fast / 判定端命中 $n_limit_judge"
    h_check_eq "1" "$acc" "timer 显式压到 AccuracySec=1s（默认 1 分钟 ⇒ 会被对齐到分钟边界）"
    h_check_eq "1" "$cal" "timer 用日历表达式定「1 秒一轮」（OnUnitActiveSec=1sec 真机实测是 2 秒）"
    h_check_eq "1" "$n_limit_fast" "快探测 service 关掉了启动限流（否则 1 秒一轮会被判 start-limit-hit）"
    h_check_eq "1" "$n_limit_judge" "判定端 service 也关掉了启动限流（间隔配到 ≤2 秒时同样会撞限流）"

    # ── 5. 快探测与判定端是**两套** unit（不许共用同一个）──
    local n_exec n_judge_exec
    n_exec=$(grep -c 'ExecStart=.*fast_probe\.sh' "$svc" 2>/dev/null); n_exec=${n_exec:-0}
    n_judge_exec=$(grep -c 'health_check\.sh' "$svc" 2>/dev/null); n_judge_exec=${n_judge_exec:-0}
    h_log "service: ExecStart 指快探测 $n_exec 处 / 指判定端 $n_judge_exec 处"
    h_check_eq "1" "$n_exec" "快探测的 service 指向自己的脚本（fast_probe.sh）"
    h_check_eq "0" "$n_judge_exec" "快探测的 service 不复用判定端的脚本"

    rm -f "$fp" "$bad"
}


# ══════════════════════════════════════════════════════════════
# T124 · 真跑一轮：写自己的观测文件，**不碰**判定流
# ══════════════════════════════════════════════════════════════
case_T124_fast_probe_runs_without_touching_judgement() {
    h_case_begin "T124" "快探测真跑一轮：只写观测文件，判定流的状态文件与配置一个都不碰" \
        "沙箱规则（TARGET_STATES：主 18111 + 备 18112）+ 本地监听端口 + 生成的快探测脚本" \
        "跑两轮生成的 fast_probe.sh（PATH 里放一个会记账的 pf 桩）" \
        "观测文件有两行且带时延/结果序列；判定流的状态文件逐字节不变；pf 桩一次都没被调用"

    local rules="$SBX_ROOT/realm/rules"
    local obs="$SBX_ROOT/var.lib.realm/fast_probe.conf"
    local judge="$SBX_ROOT/realm/health/health_status.conf"
    local fp="$SBX_ROOT/t124_fast_probe.sh"
    local stubdir="$SBX_ROOT/t124_stub"
    local pflog="$stubdir/pf.log"

    mkdir -p "$rules" "$SBX_ROOT/realm/health" "$SBX_ROOT/var.lib.realm" "$stubdir"
    rm -f "$rules"/rule-*.conf "$obs" "$judge" "$fp" "$pflog"

    _t28_make_rule "$rules/rule-1.conf"

    # 判定流的状态文件：先放一份**已知内容**当基准（跑完必须逐字节不变）
    printf '# Realm健康状态文件\n1|127.0.0.1:18111|healthy|0|3|1792810000|0|12|10,12,14\n' > "$judge"
    local sha_before
    sha_before=$(sha256sum "$judge" 2>/dev/null | cut -d' ' -f1)

    # pf 桩：任何一次调用都记账（快探测**一次都不许**调它）
    cat > "$stubdir/pf" <<'STUB'
#!/bin/bash
echo "pf $*" >> "$PF_STUB_LOG"
exit 0
STUB
    chmod +x "$stubdir/pf"

    # 起一个本地监听端口当阳性对照（成功握手的那一侧）
    if ! _start_listener 18111; then
        h_fail "起本地监听端口失败（阳性对照缺失）"
        return
    fi

    _t28_generate "$fp"
    h_check_file "$fp" "生成的快探测脚本"

    # stdout/stderr 分开落盘（stdout 必须为空 ⇒ 见下面的不变量断言）
    local out1="$SBX_ROOT/t124_fp1.stdout"
    local out2="$SBX_ROOT/t124_fp2.stdout"
    rm -f "$out1" "$out2"

    PF_STUB_LOG="$pflog" PATH="$stubdir:$PATH" \
    FAST_PROBE_FILE="$obs" \
    FAST_PROBE_RULES_DIR="$rules" \
    FAST_PROBE_LOCK_FILE="$SBX_ROOT/var.lock/realm-fast-probe.lock" \
    FAST_PROBE_TIMEOUT=2 FAST_PROBE_WINDOW=20 \
        bash "$fp" >"$out1" 2>/dev/null
    local rc1=$?
    PF_STUB_LOG="$pflog" PATH="$stubdir:$PATH" \
    FAST_PROBE_FILE="$obs" \
    FAST_PROBE_RULES_DIR="$rules" \
    FAST_PROBE_LOCK_FILE="$SBX_ROOT/var.lock/realm-fast-probe.lock" \
    FAST_PROBE_TIMEOUT=2 FAST_PROBE_WINDOW=20 \
        bash "$fp" >"$out2" 2>/dev/null
    local rc2=$?

    h_check_rc 0 "$rc1" "快探测第 1 轮退出码 0"
    h_check_rc 0 "$rc2" "快探测第 2 轮退出码 0"

    # ── 关键不变量：快探测脚本的 stdout 必须为空 ──
    #   ★ 为什么钉这条：快探测由 systemd timer **每秒**拉一次，stdout 直接进 journal。
    #     任何一行正常输出 = 每秒一行日志（一天八万六千行）⇒ journal 被打爆、
    #     磁盘被吃满，而且现场根本看不出来（journal 里全是数字）。
    #     ★ 这是真踩过的坑：把时间戳函数的 stdout 漏出去，每秒泄一行微秒戳。
    local n_out=0
    [ -f "$out1" ] && n_out=$(grep -c . "$out1" 2>/dev/null)
    n_out=${n_out:-0}
    h_log "第 1 轮 stdout 行数: $n_out"
    [ -f "$out1" ] && head -3 "$out1" | sed 's/^/    /'
    h_check_eq "0" "$n_out" "快探测脚本的 stdout 必须为空（每秒一行就是 journal 刷屏）"

    local n_out2=0
    [ -f "$out2" ] && n_out2=$(grep -c . "$out2" 2>/dev/null)
    n_out2=${n_out2:-0}
    h_check_eq "0" "$n_out2" "快探测第 2 轮的 stdout 同样必须为空"

    # ── 负向对照：把「时间戳取值的 stdout 重定向」去掉 → 上面那条断言必须抓到 ──
    #   注入式退化（不是历史旧实现）：这正是减 fork 改造时踩到的那个真 bug 的原样复现。
    #   ★ 必须先自检「破坏手法生效」（退化副本与原文件确实不同），
    #     否则代码写法一变、sed 匹配不到 ⇒ 负向对照静默失效 ⇒ 断言变成恒绿。
    #   ★ 负向对照必须用**独立的观测文件**：快探测每轮都会原子重写观测文件，
    #     负向对照那一轮若共用主观测文件，就会把后面「两轮累积」断言依赖的
    #     观测冲成第三轮 ⇒ 观察对象被对照本身污染 ⇒ 断言假红。
    local badfp="$SBX_ROOT/t124_fp_noisy.sh"
    local badout="$SBX_ROOT/t124_fp_noisy.stdout"
    local badobs="$SBX_ROOT/var.lib.realm/t124_noisy.conf"
    rm -f "$badfp" "$badout" "$badobs"
    sed 's|now_us >/dev/null|now_us|g' "$fp" > "$badfp"
    local n_diff=0
    if ! diff -q "$fp" "$badfp" >/dev/null 2>&1; then n_diff=1; fi
    h_check_eq "1" "$n_diff" "负向对照自检 · 退化副本确实去掉了 stdout 重定向（破坏手法生效）"

    PF_STUB_LOG="$pflog" PATH="$stubdir:$PATH" \
    FAST_PROBE_FILE="$badobs" \
    FAST_PROBE_RULES_DIR="$rules" \
    FAST_PROBE_LOCK_FILE="$SBX_ROOT/var.lock/realm-fast-probe.lock" \
    FAST_PROBE_TIMEOUT=2 FAST_PROBE_WINDOW=20 \
        bash "$badfp" >"$badout" 2>/dev/null
    local n_bad=0
    [ -f "$badout" ] && n_bad=$(grep -c . "$badout" 2>/dev/null)
    n_bad=${n_bad:-0}
    h_log "退化副本 stdout 行数: $n_bad"
    h_check_ge 1 "$n_bad" "负向对照 · 去掉 stdout 重定向后必须被 stdout 断言抓到（否则上面那条断言是恒绿）"

    # ★ 对照跑完之后：主观测文件必须**原封不动**（观测对象没被对照污染）
    local n_rows_b
    n_rows_b=$(grep -c '^127\.0\.0\.1:' "$obs" 2>/dev/null); n_rows_b=${n_rows_b:-0}
    h_check_eq "2" "$n_rows_b" "负向对照跑完后主观测文件没被污染（仍两行、仍是两轮的序列）"

    [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null

    # ── 观测文件的内容 ──
    h_check_file "$obs" "快探测观测文件"
    h_log "--- 观测文件 ---"
    cat "$obs" 2>/dev/null | sed 's/^/    /'

    local n_rows
    n_rows=$(grep -c '^127\.0\.0\.1:' "$obs" 2>/dev/null); n_rows=${n_rows:-0}
    h_check_eq "2" "$n_rows" "观测文件里有两个目标各一行"

    # 监听端口那个目标：通（ok）+ 有握手时延
    local ok_line ok_result ok_lat
    ok_line=$(grep '^127\.0\.0\.1:18111|' "$obs" 2>/dev/null | head -1)
    ok_result=$(printf '%s' "$ok_line" | cut -d'|' -f3)
    ok_lat=$(printf '%s' "$ok_line" | cut -d'|' -f4)
    h_log "监听目标: result=$ok_result lat=$ok_lat"
    h_check_eq "ok" "$ok_result" "监听端口的目标判定为通（ok）"
    case "$ok_lat" in
        ''|*[!0-9]*) h_fail "监听目标的握手时延不是毫秒数: <$ok_lat>" ;;
        *) h_pass "监听目标的握手时延是毫秒数 = $ok_lat" ;;
    esac

    # 死端口那个目标：不通，且**分型**到具体类型
    #   ★ 形态由宿主网络栈决定（Windows 上是超时，Linux 上通常是拒绝）
    #     ⇒ 只断言「不通 + 属于已知类型」，不断言某个具体类型。
    local dead_line dead_result
    dead_line=$(grep '^127\.0\.0\.1:18112|' "$obs" 2>/dev/null | head -1)
    dead_result=$(printf '%s' "$dead_line" | cut -d'|' -f3)
    h_log "死端口目标: result=$dead_result"
    case "$dead_result" in
        refused|timeout|unreachable|unknown) h_pass "死端口的目标判定为不通且已分型（$dead_result）" ;;
        *) h_fail "死端口的目标判定不对: <$dead_result>（期望 refused/timeout/unreachable/unknown 之一）" ;;
    esac

    # 两轮之后：结果序列累积到 2 个样本（窗口在滚动，不是每轮重置）
    local seq hist
    seq=$(printf '%s' "$ok_line" | cut -d'|' -f6)
    hist=$(printf '%s' "$ok_line" | cut -d'|' -f7)
    h_log "两轮后 ok 行: seq=$seq hist=$hist"
    h_check_eq "2" "${#seq}" "两轮之后结果序列累积到 2 个样本"
    case "$hist" in
        *,*) h_pass "两轮之后成功样本的时延历史累积起来了（$hist）" ;;
        *)   h_fail "两轮之后时延历史没有累积: <$hist>" ;;
    esac

    # ── 关键不变量：判定流的状态文件逐字节不变 ──
    local sha_after
    sha_after=$(sha256sum "$judge" 2>/dev/null | cut -d' ' -f1)
    h_log "判定流状态文件 sha: before=$sha_before after=$sha_after"
    h_check_eq "$sha_before" "$sha_after" "判定流的状态文件逐字节不变（快探测没碰它）"

    # ── 关键不变量：pf 一次都没被调用（没有触发配置重生成）──
    local n_pf=0
    [ -f "$pflog" ] && n_pf=$(grep -c 'pf ' "$pflog" 2>/dev/null)
    n_pf=${n_pf:-0}
    h_log "pf 桩被调用次数: $n_pf"
    h_check_eq "0" "$n_pf" "快探测一次都没调用 pf（没有触发配置重生成）"

    rm -f "$rules"/rule-*.conf "$obs" "$judge" "$fp" "$badobs" "$badfp" "$badout" "$out1" "$out2"
    rm -rf "$stubdir"
}


# ══════════════════════════════════════════════════════════════
# T125 · 分型规则与窗口计算（**纯函数**，不依赖宿主网络栈）
# ══════════════════════════════════════════════════════════════
case_T125_fast_probe_classify_and_window() {
    h_case_begin "T125" "快探测的失败分型规则 + 窗口/丢包计算" \
        "冻结态 lib/health.sh（纯函数，直接喂退出码与文本）" \
        "fast_probe_classify / fast_probe_seq_push / fast_probe_hist_push / fast_probe_stats" \
        "分型：0→ok、124→超时、RST→拒绝、路由不可达→不可达、/dev/tcp 不支持→未知、认不出来→未知（不猜）；窗口满了丢最旧；时延历史上限 5"

    # ── 1. 分型规则：逐条喂，断言逐条对 ──
    local out
    out=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        echo "ok=$(fast_probe_classify 0 "")"
        echo "timeout=$(fast_probe_classify 124 "")"
        echo "refused=$(fast_probe_classify 1 "bash: connect to host 127.0.0.1 port 19999 failed: Connection refused")"
        echo "unreachable=$(fast_probe_classify 1 "bash: connect to host 192.0.2.1 port 80 failed: Network is unreachable")"
        echo "noroute=$(fast_probe_classify 1 "bash: connect to host 192.0.2.1 port 80 failed: No route to host")"
        echo "notcp=$(fast_probe_classify 1 "bash: /dev/tcp/1.2.3.4/80: No such file or directory")"
        echo "unknown=$(fast_probe_classify 1 "some totally different text")"
    ' 2>/dev/null)
    h_log "分型结果: $(printf '%s' "$out" | tr '\n' ' ')"

    h_check_contains "$out" "ok=ok" "退出码 0 → ok"
    h_check_contains "$out" "timeout=timeout" "退出码 124（超时杀进程）→ timeout（SYN 被丢 = 丢包）"
    h_check_contains "$out" "refused=refused" "RST 拒绝 → refused（**不是**丢包）"
    h_check_contains "$out" "unreachable=unreachable" "网络不可达 → unreachable"
    h_check_contains "$out" "noroute=unreachable" "无路由 → unreachable"
    h_check_contains "$out" "notcp=unknown" "本机不支持 /dev/tcp → unknown（不猜）"
    h_check_contains "$out" "unknown=unknown" "认不出来的文本 → unknown（**不猜**）"

    # ── 2. 结果序列：窗口满了丢最旧 ──
    local seq
    seq=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        s=""
        s=$(fast_probe_seq_push "$s" "o" 3)
        s=$(fast_probe_seq_push "$s" "t" 3)
        s=$(fast_probe_seq_push "$s" "r" 3)
        echo "before=$s"
        s=$(fast_probe_seq_push "$s" "o" 3)
        echo "after=$s"
    ' 2>/dev/null)
    h_log "序列: $(printf '%s' "$seq" | tr '\n' ' ')"
    h_check_contains "$seq" "before=otr" "前三次采样按序累积"
    h_check_contains "$seq" "after=tro" "窗口（3）满了之后丢最旧那次"

    # ── 3. 时延历史：上限 5 ──
    local hist
    hist=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        h=""
        for v in 1 2 3 4 5 6 7; do h=$(fast_probe_hist_push "$h" "$v" 5); done
        echo "hist=$h"
    ' 2>/dev/null)
    h_log "历史: $hist"
    h_check_contains "$hist" "hist=3,4,5,6,7" "时延历史封顶 5 个样本（丢最旧）"

    # ── 4. 丢包率：从观测文件算出来 ──
    #   夹具三行：
    #     18111 序列 "ooto" = 4 个样本、1 次超时  ⇒ 丢包 25%
    #     18112 序列 "ttt"  = 3 个样本、3 次超时  ⇒ 丢包 100%
    #     18113 序列 "oooo" = 4 个样本、0 次超时  ⇒ 丢包 0（**不显示**）
    local obs="$SBX_ROOT/t125_obs.conf"
    mkdir -p "$(dirname "$obs")"
    cat > "$obs" <<'EOF'
# Realm快探测观测文件（只观测，不参与切换）
127.0.0.1:18111|1|ok|7|1792810000|ooto|7,9
127.0.0.1:18112|1|timeout|2000|1792810000|ttt|
127.0.0.1:18113|1|ok|5|1792810000|oooo|5,5,5,5
EOF
    # ★ 用 export 而不是「前缀赋值 + 函数调用」：
    #   前缀赋值对**函数**的导出行为在不同 shell 下不一致 ⇒ 观测文件可能读不到。
    export FAST_PROBE_FILE="$obs"
    local st
    st=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        echo "A=$(fast_probe_stats 127.0.0.1:18111 1)"
        echo "B=$(fast_probe_stats 127.0.0.1:18112 1)"
        echo "C=$(fast_probe_stats 127.0.0.1:18113 1)"
        echo "LOSS_A=$(fast_probe_loss_display 127.0.0.1:18111 1)"
        echo "LOSS_B=$(fast_probe_loss_display 127.0.0.1:18112 1)"
        echo "LOSS_C=$(fast_probe_loss_display 127.0.0.1:18113 1)"
        echo "KIND_B=$(fast_probe_result_display 127.0.0.1:18112 1)"
        echo "KIND_A=$(fast_probe_result_display 127.0.0.1:18111 1)"
    ' 2>/dev/null)
    unset FAST_PROBE_FILE
    h_log "统计: $(printf '%s' "$st" | tr '\n' ' ')"
    h_check_contains "$st" "A=ok|7|1792810000|1|4|7,9" "统计行：结果/时延/时间戳/超时数/样本数/时延历史"
    h_check_contains "$st" "B=timeout|2000|1792810000|3|3|" "全超时那行：3 个样本全是超时"
    h_check_contains "$st" "LOSS_B=[丢包: 100% (3/3)]" "全超时 ⇒ 丢包 100%（3/3）"
    h_check_contains "$st" "LOSS_A=[丢包: 25% (1/4)]" "1/4 超时 ⇒ 丢包 25%"
    h_check_contains "$st" "LOSS_C=" "丢包为 0 时**不显示**（不占菜单一行）"
    h_check_contains "$st" "KIND_B=[探测: 超时]" "失败分型展示：超时"
    h_check_contains "$st" "KIND_A=" "成功时不显示失败分型"

    # ── 5. 形状校验：畸形目标/端口**不猜**，也不拼进内层命令 ──
    #   目标值来自规则文件，而规则文件可能被本地低权限用户改写；
    #   快探测是把 host/port 拼进内层 bash 命令的 ⇒ 形状校验是命令注入面。
    local shape
    shape=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        fast_probe_connect "127.0.0.1; echo pwned" "18111" 2 >/dev/null
        echo "badhost_rc=$? result=$FAST_PROBE_RESULT"
        fast_probe_connect "127.0.0.1" "notaport" 2 >/dev/null
        echo "badport_rc=$? result=$FAST_PROBE_RESULT"
        fast_probe_connect "" "" 2 >/dev/null
        echo "empty_rc=$? result=$FAST_PROBE_RESULT"
    ' 2>/dev/null)
    h_log "形状校验: $(printf '%s' "$shape" | tr '\n' ' ')"
    h_check_contains "$shape" "badhost_rc=1 result=unknown" "畸形 host（带分号）直接判 unknown，不拼进命令"
    h_check_contains "$shape" "badport_rc=1 result=unknown" "畸形端口判 unknown"
    h_check_contains "$shape" "empty_rc=1 result=unknown" "空目标判 unknown"

    rm -f "$obs"
}


# ══════════════════════════════════════════════════════════════
# T126 · 菜单时延口径：快探测优先，没有快探测数据时回落状态文件
# ══════════════════════════════════════════════════════════════
#
# ★ 口径（两条线）：
#   ① [健康]/[故障] 仍取**判定流**的状态文件（切换判据在那儿，快探测不参与）
#   ② [时延] 快探测（1 秒刷新）优先；没有快探测数据时回落状态文件
#      （两处都是 TCP 握手耗时，同一个口径 —— 不混成两个数字）

# 造菜单用的两条规则 + 状态文件
_t126_make_fixture() {
    local rules="$1" health="$2"

    mkdir -p "$rules" "$(dirname "$health")"
    rm -f "$rules"/rule-*.conf

    cat > "$rules/rule-1.conf" <<'EOF'
RULE_ID=1
RULE_ROLE=1
RULE_NAME=fast-probe-menu
SECURITY_LEVEL=none
LISTEN_PORT=8080
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=18097
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
    cat > "$rules/rule-2.conf" <<'EOF'
RULE_ID=2
RULE_ROLE=1
RULE_NAME=fast-probe-menu
SECURITY_LEVEL=none
LISTEN_PORT=8080
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.2
REMOTE_PORT=18097
ENABLED=true
BALANCE_MODE="active-standby"
TARGET_STATES=""
WEIGHTS="0"
FAILOVER_ENABLED="true"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="10"
RECOVERY_COOLDOWN="120"
EOF

    # 判定流的状态文件（时延口径：12ms / 88ms）
    cat > "$health" <<'EOF'
# Realm健康状态文件
1|127.0.0.1:18097|healthy|0|3|1792810000|0|12|10,12,14
2|127.0.0.2:18097|healthy|0|3|1792810000|0|88|80,90
EOF
}

# 在沙箱里渲染一次菜单（$2 = CONFIG_DIR）
_t126_render_menu() {
    local libroot="$1" cfgdir="$2"
    bash -c '
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh"  >/dev/null 2>&1
        source "$1/lib/realm.sh"  >/dev/null 2>&1
        ( set -u; printf "0\n" | load_balance_management_menu )
    ' _ "$libroot" "$cfgdir" 2>&1
}

case_T126_menu_latency_prefers_fast_probe() {
    h_case_begin "T126" "菜单时延口径：快探测优先（1 秒刷新），没有快探测数据时回落状态文件" \
        "沙箱 rules（端口组两个目标）+ 判定流状态文件 + 快探测观测文件" \
        "load_balance_management_menu（set -u 下真渲染）+ 负向对照（把快探测的时延丢弃）" \
        "有快探测数据时菜单显示快探测的时延（7ms / 9ms）而不是状态文件的（12ms / 88ms）；没有快探测文件时回落到状态文件"

    local rules="$SBX_ROOT/realm/rules"
    local health="$SBX_ROOT/realm/health/health_status.conf"
    local obs="$SBX_ROOT/var.lib.realm/fast_probe.conf"
    local cfg="$SBX_ROOT/realm"

    _t126_make_fixture "$rules" "$health"

    # ── 腿 1（回落口径）：没有快探测文件 ⇒ 显示状态文件的时延 ──
    rm -f "$obs"
    local menu_a
    menu_a=$(_t126_render_menu "$SBX_RUN" "$cfg")
    h_log "腿1 菜单片段: $(printf '%s' "$menu_a" | grep -a '时延' | head -2 | tr '\n' ' ' | cut -c1-200)"
    h_check_contains "$menu_a" '[时延: 12ms (均 12ms)]' "没有快探测数据时：主目标显示状态文件的时延"
    h_check_contains "$menu_a" '[时延: 88ms (均 85ms)]' "没有快探测数据时：备目标显示状态文件的时延"
    h_check_not_contains "$menu_a" "unbound variable" "菜单在 set -u 下没崩"

    # ── 腿 2（快探测优先）：有快探测文件 ⇒ 显示快探测的时延 ──
    mkdir -p "$(dirname "$obs")"
    cat > "$obs" <<'EOF'
# Realm快探测观测文件（只观测，不参与切换）
127.0.0.1:18097|1|ok|7|1792810000|oo|7,8
127.0.0.2:18097|2|ok|9|1792810000|o|9
EOF
    local menu_b
    menu_b=$(_t126_render_menu "$SBX_RUN" "$cfg")
    h_log "腿2 菜单片段: $(printf '%s' "$menu_b" | grep -a '时延' | head -2 | tr '\n' ' ' | cut -c1-200)"
    h_check_contains "$menu_b" '[时延: 7ms (均 7ms)]' "有快探测数据时：主目标显示快探测的时延"
    h_check_contains "$menu_b" '[时延: 9ms (均 9ms)]' "有快探测数据时：备目标显示快探测的时延"
    h_check_not_contains "$menu_b" '[时延: 12ms (均 12ms)]' "有快探测数据时：不再显示状态文件那个更旧的时延"
    # [健康]/[故障] 仍然只来自判定流（快探测不参与切换判定）
    h_check_eq "2" "$(printf '%s' "$menu_b" | grep -ac '\[健康\]' || true)" "健康判定仍来自判定流（两个目标都判健康）"

    # ── 负向对照：把快探测的时延丢弃 ⇒ 断言必须变红 ──
    #   注入手法：副本里把「查快探测」那个 if 的条件改成 false
    #   （= 退化成旧口径：菜单只认状态文件）。
    #   这一步证明「优先快探测」这条断言不是恒绿。
    local badlib="$SBX_ROOT/t126_badlib"
    rm -rf "$badlib"; mkdir -p "$badlib/lib"
    cp "$SBX_RUN/lib/"*.sh "$badlib/lib/" 2>/dev/null
    awk '
        /if declare -F fast_probe_stats >\/dev\/null 2>&1; then/ {
            print "                        if false; then  # T126-NEG: 完全不看快探测"
            next
        }
        { print }
    ' "$SBX_RUN/lib/rules.sh" > "$badlib/lib/rules.sh"
    local n_inj
    n_inj=$(grep -c 'T126-NEG' "$badlib/lib/rules.sh" 2>/dev/null); n_inj=${n_inj:-0}
    h_check_eq "1" "$n_inj" "负向对照的注入点命中（破坏手法生效）"

    local menu_bad
    menu_bad=$(_t126_render_menu "$badlib" "$cfg")
    h_log "负向对照 菜单片段: $(printf '%s' "$menu_bad" | grep -a '时延' | head -2 | tr '\n' ' ' | cut -c1-200)"
    h_check_not_contains "$menu_bad" '[时延: 7ms (均 7ms)]' "负向对照：快探测的时延被丢弃后，菜单不再渲染出它（说明断言拦得住）"
    h_check_contains "$menu_bad" '[时延: 12ms (均 12ms)]' "负向对照：退化成旧口径后回落到状态文件的时延"

    rm -rf "$badlib"
    rm -f "$rules"/rule-*.conf "$health" "$obs"
}


# ══════════════════════════════════════════════════════════════
# T127 · 快探测起不来**不许**让主备开关回滚
# ══════════════════════════════════════════════════════════════
#
# ★ 口径：快探测只是显示增强（时延/丢包刷新），切换判据在判定流那边。
#   ⇒ 快探测起不来时：主备**照旧**开启、判定端**照旧**装上，
#     只提示一句「不影响切换」—— 不许把主备开关回滚掉。
case_T127_fast_probe_failure_does_not_roll_back_standby() {
    h_case_begin "T127" "快探测起不来时：主备开关不许回滚，判定端照旧装上" \
        "沙箱 lib/（health.sh 被注入：fast_probe_script_regenerate 恒失败）" \
        "start_health_check_service" \
        "退出码 0（不是失败）+ 判定端脚本已生成 + 输出里点明「不影响主备切换」"

    local badlib="$SBX_ROOT/t127_badlib"
    rm -rf "$badlib"; mkdir -p "$badlib/lib"
    cp "$SBX_RUN/lib/"*.sh "$badlib/lib/" 2>/dev/null
    cat >> "$badlib/lib/health.sh" <<'EOS'

# T127-NEG: 让快探测的生成恒失败
fast_probe_script_regenerate() {
    echo "快探测生成失败（注入）" >&2
    return 1
}
EOS
    local n_inj
    n_inj=$(grep -c 'T127-NEG' "$badlib/lib/health.sh" 2>/dev/null); n_inj=${n_inj:-0}
    h_check_eq "1" "$n_inj" "负向对照的注入点命中（破坏手法生效）"

    local out rc
    out=$(bash -c '
        source "$2/lib/core.sh"  >/dev/null 2>&1
        source "$2/lib/health.sh" >/dev/null 2>&1
        start_health_check_service 4
        exit $?
    ' _ "$SBX_RUN" "$badlib" 2>&1)
    rc=$?
    h_log "输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    h_check_rc 0 "$rc" "快探测起不来时 start_health_check_service 仍然成功（主备开关不回滚）"
    h_check_contains "$out" "不受影响" "输出里点明了「主备切换不受影响」"
    h_check_file "$SBX_ROOT/realm/health/health_check.sh" "判定端脚本照旧装上了（判定流不受快探测影响）"

    rm -rf "$badlib"
}
