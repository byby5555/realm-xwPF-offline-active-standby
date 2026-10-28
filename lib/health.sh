# 健康检查共用逻辑（唯一真源）
#
# pf 主脚本（权重含 0 自动进主备）与故障转移脚本 xwFailover.sh 共用同一份实现：
#   1. 连通性探测：TCP 握手探测（不是 ping）
#   2. 规则文件解析：白名单逐行解析（绝不 source 规则文件）
#   3. 健康状态文件位置
#   4. 健康检查服务（systemd timer）的生成与启停
#
# 生成的 /etc/realm/health/health_check.sh 是一份**独立可执行**的脚本
# （systemd 直接调用它，不能依赖 pf 的安装目录）。
# 它需要的函数在生成时由 health_emit_function 从**本文件**原样抽取后拼进去 ——
# 抽取是机械动作，所以仓库里只存在一份实现，
# 不存在「两份实现靠人手同步」的问题。

CONFIG_DIR="${CONFIG_DIR:-/etc/realm}"
HEALTH_DIR="${HEALTH_DIR:-${CONFIG_DIR}/health}"
HEALTH_STATUS_FILE="${HEALTH_STATUS_FILE:-${HEALTH_DIR}/health_status.conf}"
HEALTH_LOCK_FILE="${HEALTH_LOCK_FILE:-/var/lock/realm-health-check.lock}"

# 本文件自身的路径：生成健康检查脚本时用它抽取函数原文
REALM_HEALTH_LIB="${REALM_HEALTH_LIB:-${BASH_SOURCE[0]}}"

# === 规则文件解析（唯一实现） ===
#
# 安全要求（不能改）：
#   规则文件由程序落盘，但仍可能被本地低权限用户改写；
#   而生成的 health_check.sh 是由 systemd 以 **root** 拉起的。
#   一旦用 source / eval 解析规则文件，文件里的 $(...) 就会被以 root 身份执行
#   —— 等于开了一个 root 提权面。
#   所以这里只做「白名单 + 逐行文本解析」：
#     - 只认白名单里的 KEY，其余行（函数定义、命令替换、管道等）一律忽略
#     - 绝不 source / eval
#
# 行为约定：
#   - 白名单里的 KEY 每读一条规则都会被重新赋值 → 上一条规则的残留值不会串到下一条
#   - 文件里没写的 KEY 回落成空串 → 下游直接读 $VAR 不会在 set -u 下致命中断
#
# ★ 新增规则键时必须同步做两件事，否则会静默失效：
#   1) 把键名加进下面的 _allowed 白名单（不加 → 该键永远读不到，且 set -u 下是未定义变量）
#   2) 把键名加进 lib/server.sh 的规则模板（不加 → 落盘的规则文件里没有这个键）
#   键名清单以本白名单为准；台架 T34 会核对文档里的函数级引用指向的符号是否还存在。
read_rule_file() {
    local rule_file="$1"
    local _line _k _v _key
    local _allowed='RULE_ID RULE_ROLE RULE_NAME SECURITY_LEVEL LISTEN_PORT LISTEN_IP THROUGH_IP REMOTE_HOST REMOTE_PORT FORWARD_TARGET TLS_SERVER_NAME TLS_CERT_PATH TLS_KEY_PATH WS_PATH WS_HOST RULE_NOTE ENABLED CREATED_TIME BALANCE_MODE PREV_BALANCE_MODE TARGET_STATES WEIGHTS FAILOVER_ENABLED HEALTH_CHECK_INTERVAL FAILURE_THRESHOLD SUCCESS_THRESHOLD CONNECTION_TIMEOUT RECOVERY_COOLDOWN PROBE_QUALITY_WINDOW MPTCP_MODE PROXY_MODE'

    if [ ! -f "$rule_file" ]; then
        return 1
    fi

    # 逐行解析：只认白名单 KEY，绝不执行文件内容
    declare -A _rule_vals=()
    while IFS= read -r _line || [ -n "$_line" ]; do   # xwpf:noninteractive-io（输入来自规则文件）
        # 去掉行尾 CR（规则文件若被 CRLF 写过，不剥掉会导致引号剥离失效、值里带 \r）
        [[ "$_line" == *$'\r' ]] && _line="${_line%$'\r'}"
        [[ -z "$_line" ]] && continue
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$_line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            _k="${BASH_REMATCH[1]}"
            _v="${BASH_REMATCH[2]}"
            # 剥外层双引号
            [[ "$_v" =~ ^\"(.*)\"$ ]] && _v="${BASH_REMATCH[1]}"
            # 剥外层单引号
            [[ "$_v" =~ ^\'(.*)\'$ ]] && _v="${BASH_REMATCH[1]}"

            # 白名单校验：只对已知允许的 KEY 记录取值
            if [[ " $_allowed " == *" $_k "* ]]; then
                _rule_vals[$_k]="$_v"
            fi
        fi
    done < "$rule_file"

    # 统一赋值：白名单里的每个 KEY 都会被重新赋值
    # → 上一条规则的残留值不会串到下一条；文件里没写的键回落成空串
    for _key in $_allowed; do
        printf -v "$_key" '%s' "${_rule_vals[$_key]:-}"
    done

    # 有语义默认值的键
    MPTCP_MODE="${MPTCP_MODE:-off}"
    PROXY_MODE="${PROXY_MODE:-off}"

    return 0
}

# === 函数原文抽取（生成健康检查脚本时用） ===
#
# 从本文件（唯一真源）里原样抽出指定函数的实现。
# 生成的 health_check.sh 用它把实现拼进去，
# 因此仓库里只需要一份源码，不存在「副本与正本手工同步」的问题。
health_emit_function() {
    local fn_name="$1"
    local lib_file="${REALM_HEALTH_LIB:-${BASH_SOURCE[0]}}"

    if [ ! -f "$lib_file" ]; then
        echo "错误: 无法定位 lib/health.sh（抽取 ${fn_name} 失败）" >&2
        return 1
    fi

    awk -v fn="$fn_name" '
        !started && $0 ~ ("^" fn "\\(\\) *\\{") { started = 1 }
        started { print }
        started && /^\}/ { exit }
    ' "$lib_file"
}

# 校验正整数，非法时回退默认值（不报错）
validate_positive_int() {
    local value="$1"
    local default_value="$2"

    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
        echo "$value"
    else
        echo "$default_value"
    fi
}

# 连通性探测（TCP 握手，不是 ping）
# 优先 netcat（需支持 -z 探测模式；busybox nc 不支持），
# 没有 nc（或 nc 不支持 -z）时回退 bash 内置 /dev/tcp
#
# ★ 超时预算 10 秒（**健康探测端**口径）：
#   真机实测正常目标 100-2274ms，3 秒预算只剩 24% 余量；
#   死端口墙钟 3057-3397ms 直接超预算 → 探测端误判「不可达」→ 主备误切。
#   交互式现场探测（菜单里的「立即测试所有目标时延」）是另一套口径，不走这里。
check_connectivity() {
    local target="$1"
    local port="$2"
    local timeout="${3:-10}"

    # 方式1: netcat（需支持 -z 探测模式；busybox nc 不支持，不能用）
    if command -v nc >/dev/null 2>&1; then
        if nc -h 2>&1 | grep -q -- '-z' 2>/dev/null; then
            nc -z -w "$timeout" "$target" "$port" >/dev/null 2>&1
            return $?
        fi
    fi

    # 方式2: bash 内置 /dev/tcp（很多精简 VPS 没装 netcat，
    # 缺 nc 时若直接判失败，会把所有目标误判成故障，导致永远不切换）
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout" bash -c "exec 3<>/dev/tcp/${target}/${port}" >/dev/null 2>&1
        local _cc_rc=$?
        # timeout 杀进程时退出码是 124，同样视为不可达，统一归一化成 0/1
        if [ "$_cc_rc" -eq 0 ]; then
            return 0
        fi
        return 1
    fi

    return 1
}

# 取当前时间（**微秒**）
#
# ★ 单位契约（函数名 / 本注释 / 返回值 三处必须写同一个单位）：
#   返回值 = **微秒**（16 位左右）。调用方统一按 (t1-t0)/1000 取毫秒。
#   ★ 两条分支**必须产出同一个单位** —— 这里最容易出错：
#     · bash 5 的 EPOCHREALTIME = **微秒** ✔
#     · `date +%s%N`          = **纳秒**（19 位）✘ ⇒ 必须在这里 ÷1000 换算，
#       否则调用方会把时延**放大 1000 倍**
#       （实测：睡 0.2 秒被算成 259620ms，真值约 200ms）。
#   ⇒ 换算在**本函数**里做 ⇒ 调用方永远只拿到微秒，不会各算各的。
#   ★ 回退分支的前提：GNU coreutils 的 date 支持 %N；
#     busybox date 不支持（返回字面量 N）⇒ 判定为不可用（返回 1），
#     调用方降级为「无时延」（优雅退化，不影响任何切换判定）。
#   ★ NOW_US_FORCE_FALLBACK=1：强制走 date 分支。
#     台架要能在 bash 5 的机器上**覆盖**回退分支 ——
#     否则回退分支永远没被测过（bash 4 的机器上它才是主路径 ⇒ 盲区）。
now_us() {
    if [ "${NOW_US_FORCE_FALLBACK:-0}" != "1" ] && [ -n "${EPOCHREALTIME:-}" ]; then
        local t="${EPOCHREALTIME}"
        t="${t/[.,]/}"
        case "$t" in
            ''|*[!0-9]*) return 1 ;;
        esac
        echo "$t"
        return 0
    fi

    local t
    t=$(date +%s%N 2>/dev/null)
    case "$t" in
        ''|*N*) return 1 ;;
        *[!0-9]*) return 1 ;;
    esac
    # 纳秒 → 微秒（÷1000）：换算在**本函数**里做，调用方只拿微秒
    echo $(( t / 1000 ))
    return 0
}

# 连通性探测 + 耗时（毫秒）
# 耗时写进全局 PROBE_LATENCY_MS（取不到时间戳就留空）
# 返回值语义与 check_connectivity 相同：0 通 / 1 不通
PROBE_LATENCY_MS=""
probe_with_latency() {
    local target="$1"
    local port="$2"
    local timeout="${3:-10}"
    local t0="" t1="" rc=0

    t0=$(now_us) || t0=""
    if check_connectivity "$target" "$port" "$timeout"; then
        rc=0
    else
        rc=1
    fi
    t1=$(now_us) || t1=""

    PROBE_LATENCY_MS=""
    if [ -n "$t0" ] && [ -n "$t1" ] && [ "$t1" -ge "$t0" ]; then
        PROBE_LATENCY_MS=$(( (t1 - t0) / 1000 ))
    fi
    return $rc
}

# 读取目标在健康状态文件里的整行记录
# 输出格式与状态文件一致（字段以 | 分隔），取不到返回 1
#
# ★ TARGET 字段口径：host:port（与 docs/health-check-and-failover.md 一致）。
#   同一个 host 上的不同端口是**不同目标**，状态互不覆盖。
# 旧格式（TARGET 只有 host）的老行**不**用「按裸 host 再查一次」兜底：
#   那会把同 host 另一个端口的记录当成这条目标的记录（显示成别人的状态）。
#   查不到就当无记录 —— 由健康检查重新探测、生成精确键。
get_health_status_record() {
    local target="$1"
    local status_file="${HEALTH_STATUS_FILE}"
    local line=""

    [ -f "$status_file" ] || return 1

    # 按 TARGET 字段精确匹配（不靠子串，避免 "10.0.0.1" 命中 "110.0.0.1"）
    line=$(awk -F'|' -v t="$target" '!/^#/ && $2 == t { print; exit }' "$status_file" 2>/dev/null)

    [ -n "$line" ] || return 1
    echo "$line"
}

# 在旧状态文件里按 (RULE_ID, 目标地址) 组合键找一行（跨轮继承用）
#
# ★ 匹配键 = (RULE_ID, TARGET)，**两者都要对上**：
#   ① 只按 RULE_ID 匹配：规则 ID 会被复用（删掉一条规则后，下一条规则可能拿到
#      同一个 ID）→ 老规则的 failed / 失败计数会算到新规则头上
#      → 新鲜健康的目标一上来就显示「故障」。
#   ② 只按目标地址匹配：两条规则共用同一个后端时（同 host 同 port），
#      一条规则的失败状态会被过户给另一条规则 → 误继承 → 误切。
#   组合键同时挡住两个方向：RULE_ID 或目标地址**任一**不同 → 认不出旧行
#      → 当成「没有记录」→ 从零重新计数。
#   ⇒ 认不出时的方向是**安全方向**（重新计数 = 最多晚几轮才切换），
#      不是**危险方向**（误继承 = 刚建好的目标被判 failed = 误切）。
#
# 口径：
#   ① 新格式行（TARGET = host:port）：RULE_ID 与 TARGET 都相等才算命中
#      （不靠子串，否则 "10.0.0.1" 会命中 "110.0.0.1"）。
#   ② 旧格式行（TARGET 只有 host，没有端口）：RULE_ID 相等且 TARGET 等于裸 host
#      才算命中 —— 老文件里那种行不能当成「没有记录」，否则目标会被当成健康
#      → 故障转移静默失效。
health_status_find_row() {
    local status_file="$1"
    local rule_id="$2"
    local endpoint="$3"
    local host="$4"
    local legacy_row="" _rid _field2 _rest

    [ -f "$status_file" ] || return 1

    while IFS='|' read -r _rid _field2 _rest || [ -n "${_field2:-}" ]; do   # xwpf:noninteractive-io（输入来自健康状态文件）
        case "$_rid" in
            '#'*) continue ;;
        esac
        [ -z "${_field2:-}" ] && continue
        # 组合键的 RULE_ID 那一半：对不上就跳过（不参与任何匹配）
        if [ "$_rid" != "$rule_id" ]; then
            continue
        fi
        if [ "$_field2" = "$endpoint" ]; then
            printf '%s|%s|%s\n' "$_rid" "$_field2" "$_rest"
            return 0
        fi
        # 旧格式行：TARGET 只有 host → 留作兜底（本轮没命中精确键时才用）
        if [ -z "$legacy_row" ] && [ "$_field2" = "$host" ]; then
            legacy_row="${_rid}|${_field2}|${_rest}"
        fi
    done < "$status_file"

    [ -n "$legacy_row" ] || return 1
    printf '%s\n' "$legacy_row"
    return 0
}

# 把时延历史（逗号分隔的样本）算成平均毫秒数
latency_avg_ms() {
    local hist="$1"
    [ -n "$hist" ] || return 1

    local sum=0 n=0 v
    local IFS=','
    for v in $hist; do
        case "$v" in
            ''|*[!0-9]*) continue ;;
        esac
        sum=$((sum + v))
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || return 1
    echo $((sum / n))
}

# ══════════════════════════════════════════════════════════════
# N5 阶段 1 · 质量指标窗口（**只观测，不动作**）
# ══════════════════════════════════════════════════════════════
#
# ★ 硬红线（Chief 拍板）：
#   本节的任何数字都**不得**参与切换/权重决策、**不得**影响探测端对目标的
#   status 判定、**不得**写进任何影响 realm 配置生成的字段。
#   本节**只**做一件事：把「采样总数 / 失败次数 / 成功样本时延均值 / 失败样本时延」记下来给人看。
#
# ★ 两套窗口并存（不许合并）：
#   · `latency_hist`（上限 5）= **显示口径**（菜单 `[时延: Xms (均 Yms)]` 的均值分母
#     + 文档「保留最近 5 次样本」）⇒ **一个字都不许改**（台架 T51 锁死：
#     「跑 3 轮累积 3 样本、跑 7 轮封顶 5 个」）。
#   · `quality_window`（默认 20）= **质量观测窗口** ⇒ **另开**，与上面互不影响。
#
# ★ 只钉相对量：失败率 = 窗口内失败次数 / 采样总数（**比例**），
#   时延均值只用**窗口内成功样本**的相对分布，
#   失败样本时延 = 窗口内**失败样本**的相对分布（失败次数 / 均值 / 最大值）。
#   ⇒ **不许出现任何跨宿主绝对阈值**（绝对阈值跨宿主不稳 = T53 同源坑）。
#
# ★ 落盘在**独立文件**：不动 `health_status.conf`
#   （它的形态被台架 T86 锁着：每轮原子重建、只留当前规则的行
#     ⇒ 往里加列/加行 = 改产品把门禁搞红）。
#
# 文件格式（每行一条记录；`#` 开头为注释）：
#   TARGET|RULE_ID|SAMPLE_SEQ|LAT_SEQ|WINDOW|FAIL_LAT_SEQ
#     TARGET      = host:port（与状态文件同口径）
#     RULE_ID     = 归属规则的 RULE_ID（组合键的一部分）
#     SAMPLE_SEQ  = 窗口内最近 N 次采样的**成败位**（逗号分隔，0=成功 / 1=失败）
#     LAT_SEQ     = 窗口内**成功样本**的时延（逗号分隔，毫秒；与 SAMPLE_SEQ 里的 0 一一对应）
#     WINDOW      = 该行**生效**的质量窗口大小
#     FAIL_LAT_SEQ= 窗口内**失败样本**的时延（逗号分隔，毫秒；与 SAMPLE_SEQ 里的 1 一一对应）
#   ⇒ 采样总数   = SAMPLE_SEQ 的个数
#   ⇒ 失败次数   = SAMPLE_SEQ 里 1 的个数
#   ⇒ 失败率     = 失败次数 / 采样总数（**比例**，相对量）
#   ⇒ 成功时延均值 = LAT_SEQ 的平均（**只用成功样本**，相对量）
#   ⇒ 失败时延分布 = FAIL_LAT_SEQ 的（个数 / 均值 / 最大值；**只用失败样本**，相对量）
#   ★ FAIL_LAT_SEQ 追加在**末尾**：前 5 列的位置保持不变 ⇒
#     老文件（没有第 6 列）与老读者（前 5 列）都不受影响（向后兼容）。
#   ★ 存**序列**而不是存「总数 + 总和」：窗口滚动时要丢掉最旧那次样本，
#     若只存总数就不知道该减「失败数」还是「成功数 + 它的时延」
#     ⇒ 序列能让滚动**精确**，不会把计数减错。

# 质量窗口大小（默认 20）。可配：PROBE_QUALITY_WINDOW（规范名）
#   兼容别名：probe.quality_window（点号小写 —— 解析器的键名规则认不得，
#   由 quality_window_size 按文本兜底读一次；两个写法都生效）
#   ★ 只影响**质量观测窗口**；与显示口径的 latency_hist（上限 5）无关。
QUALITY_WINDOW_DEFAULT=20

# 质量指标文件路径（独立文件，不碰 health_status.conf）
QUALITY_METRICS_FILE="${QUALITY_METRICS_FILE:-/var/lib/realm/quality_metrics.conf}"

# 取质量窗口大小（**当前规则**生效的窗口）
#   用法：quality_window_size <规则文件路径>
#   ★ 规范名的值**不用自己再去找**：read_rule_file 解析白名单时已经把
#     PROBE_QUALITY_WINDOW 赋值到同名变量（它在白名单里 ⇒ 一定被读到），
#     而且 read_rule_file 每次都会把白名单键**重置**（缺失即空串）
#     ⇒ 上一条规则的值不会串到下一条。
#   ★ 兼容别名 `probe.quality_window`（点号小写）**解析器认不得**
#     （键名规则 ^[A-Z_][A-Z0-9_]*$ ⇒ 点号 + 小写直接被跳过）
#     ⇒ 按文本单独读一次（规范名优先，别名兜底）。
#   ★ 非法值 / 0 一律回退默认（不报错、不中断探测端）。
quality_window_size() {
    local rule_file="${1:-}"
    local v="${PROBE_QUALITY_WINDOW:-}"
    if [ -z "$v" ] && [ -n "$rule_file" ] && [ -f "$rule_file" ]; then
        v=$(grep -m1 '^[[:space:]]*probe\.quality_window[[:space:]]*=' "$rule_file" 2>/dev/null \
            | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')
    fi
    case "$v" in
        ''|*[!0-9]*) v="$QUALITY_WINDOW_DEFAULT" ;;
    esac
    if [ "$v" -lt 1 ] 2>/dev/null; then
        v="$QUALITY_WINDOW_DEFAULT"
    fi
    printf '%s\n' "$v"
}

# 读某目标的质量窗口原始序列
#   用法：read_quality_window <target> <rule_id> → 输出 "SAMPLE_SEQ|LAT_SEQ|FAIL_LAT_SEQ"
#   找不到 = 无记录 = 输出 "||"（三段空序列，从零开始 = 安全方向）
#   ★ 老文件（没有第 6 列）⇒ FAIL_LAT_SEQ 读出来是空串 ⇒ 兼容，不报错。
read_quality_window() {
    local target="$1" rule_id="$2"
    local line=""
    [ -f "$QUALITY_METRICS_FILE" ] || { echo "||"; return 0; }

    # 组合键 = (RULE_ID, 目标)：与状态文件同口径，避免同后端两规则共用时串数据
    line=$(awk -F'|' -v r="$rule_id" -v t="$target" \
        '!/^#/ && $1 == t && $2 == r { print $3 "|" $4 "|" $6; exit }' \
        "$QUALITY_METRICS_FILE" 2>/dev/null)

    if [ -z "$line" ]; then
        echo "||"
        return 0
    fi
    echo "$line"
}

# 把新的采样推进窗口（**滚动环形**：满了就丢最旧一次）
#   用法：push_quality_sample <sample_seq> <lat_seq> <fail_lat_seq> <is_failure 0|1> <latency_ms> <window>
#   输出：新的 "SAMPLE_SEQ|LAT_SEQ|FAIL_LAT_SEQ"
#   ★ 纯计算，不碰任何判定状态（不写 status、不写权重）。
#   ★ 成功样本的时延进 LAT_SEQ、失败样本的时延进 FAIL_LAT_SEQ ——
#     两者**分开存**，才能分别算「成功时延分布」与「失败时延分布」。
push_quality_sample() {
    local seq="$1" lat_seq="$2" fail_lat_seq="$3" is_fail="$4" lat_ms="$5" win="$6"

    local -a s_arr l_arr fl_arr
    IFS=',' read -ra s_arr <<< "$seq"
    IFS=',' read -ra l_arr <<< "$lat_seq"
    IFS=',' read -ra fl_arr <<< "$fail_lat_seq"
    # 空串会造出一个空元素 ⇒ 过滤掉
    local -a s_new=() l_new=() fl_new=()
    local v
    for v in "${s_arr[@]}"; do
        case "$v" in 0|1) s_new+=("$v") ;; esac
    done
    for v in "${l_arr[@]}"; do
        case "$v" in ''|*[!0-9]*) continue ;; esac
        l_new+=("$v")
    done
    for v in "${fl_arr[@]}"; do
        case "$v" in ''|*[!0-9]*) continue ;; esac
        fl_new+=("$v")
    done

    # 追加本次样本
    case "$lat_ms" in
        ''|*[!0-9]*) lat_ms=0 ;;
    esac
    if [ "$is_fail" = "1" ]; then
        s_new+=("1")
        fl_new+=("$lat_ms")
    else
        s_new+=("0")
        l_new+=("$lat_ms")
    fi

    # 环形：超过窗口就丢最旧（失败位与它对应的时延序列**同步丢**）
    while [ "${#s_new[@]}" -gt "$win" ]; do
        _old="${s_new[0]}"
        s_new=("${s_new[@]:1}")
        if [ "$_old" = "0" ] && [ "${#l_new[@]}" -gt 0 ]; then
            l_new=("${l_new[@]:1}")
        elif [ "$_old" = "1" ] && [ "${#fl_new[@]}" -gt 0 ]; then
            fl_new=("${fl_new[@]:1}")
        fi
    done

    # 输出
    if [ "${#s_new[@]}" -eq 0 ]; then
        echo "||"
        return 0
    fi
    local out_s out_l out_fl
    out_s=$(IFS=','; echo "${s_new[*]}")
    if [ "${#l_new[@]}" -eq 0 ]; then
        out_l=""
    else
        out_l=$(IFS=','; echo "${l_new[*]}")
    fi
    if [ "${#fl_new[@]}" -eq 0 ]; then
        out_fl=""
    else
        out_fl=$(IFS=','; echo "${fl_new[*]}")
    fi
    echo "${out_s}|${out_l}|${out_fl}"
}

# 把质量窗口落盘（**整份原子重建**，与状态文件同一种写法）
#   用法：write_quality_window <行文件>
#   ★ 只写**本轮被采样到的**目标 ⇒ 目标消失后它的行自然消失
#     （不留在文件里当「还在观测」）。
write_quality_window() {
    local rows_file="$1"
    local dir
    dir=$(dirname "$QUALITY_METRICS_FILE")

    mkdir -p "$dir" 2>/dev/null || return 0

    {
        echo "# Realm质量观测指标（只观测，不动作）"
        echo "# 格式: TARGET|RULE_ID|SAMPLE_SEQ|LAT_SEQ|WINDOW|FAIL_LAT_SEQ"
        echo "# 采样总数 = SAMPLE_SEQ 个数；失败率 = 1 的个数 / 采样总数；成功时延均值 = LAT_SEQ 平均"
        echo "# 失败时延分布 = FAIL_LAT_SEQ 的（个数 / 均值 / 最大值；只用失败样本）"
        echo "# WINDOW = 该行**生效**的质量窗口大小（= 规则里配的值；未配 = 默认 20）"
        cat "$rows_file" 2>/dev/null
    } > "${QUALITY_METRICS_FILE}.tmp.$$" 2>/dev/null \
        && mv -f "${QUALITY_METRICS_FILE}.tmp.$$" "$QUALITY_METRICS_FILE" 2>/dev/null
    return 0
}

# 从质量窗口算出可展示的值（**只读，不改任何状态**）
#   用法：quality_window_stats <target> <rule_id>
#         → 输出 "SAMPLES|FAILURES|OK|AVG_LAT_MS|FAIL_LAT_AVG|FAIL_LAT_MAX|FAIL_LAT_N"
#   ★ AVG_LAT_MS 用整数除法（毫秒精度足够）；无成功样本时输出 0。
#   ★ FAIL_LAT_AVG / FAIL_LAT_MAX / FAIL_LAT_N = **失败样本**的时延分布
#     （个数 / 均值 / 最大值）；没有失败样本时三个都输出 0。
#   ★ 失败率由调用方用 FAILURES/SAMPLES 现算（**分母不写死**）。
quality_window_stats() {
    local target="$1" rule_id="$2"
    local raw seq lat_seq fail_lat_seq
    raw=$(read_quality_window "$target" "$rule_id")
    seq="${raw%%|*}"
    local _mid="${raw#*|}"
    lat_seq="${_mid%%|*}"
    fail_lat_seq="${_mid#*|}"

    local s f ok sum n v
    s=0; f=0; ok=0; sum=0; n=0
    local fsum=0 fn=0 fmax=0
    local IFS=','
    for v in $seq; do
        case "$v" in
            0) s=$((s+1)); ok=$((ok+1)) ;;
            1) s=$((s+1)); f=$((f+1)) ;;
        esac
    done
    for v in $lat_seq; do
        case "$v" in
            ''|*[!0-9]*) continue ;;
        esac
        sum=$((sum + v)); n=$((n+1))
    done
    for v in $fail_lat_seq; do
        case "$v" in
            ''|*[!0-9]*) continue ;;
        esac
        fsum=$((fsum + v)); fn=$((fn+1))
        [ "$v" -gt "$fmax" ] && fmax=$v
    done

    local avg=0 favg=0
    [ "$n" -gt 0 ] && avg=$((sum / n))
    [ "$fn" -gt 0 ] && favg=$((fsum / fn))
    echo "${s}|${f}|${ok}|${avg}|${favg}|${fmax}|${fn}"
}

# 把质量窗口拼成**展示串**（只读，不改任何状态）
#   用法：quality_window_display <target> <rule_id>
#   输出："[窗口: 失败率 30% (6/20) · 成功时延均值 12ms · 失败时延 均 2500ms 最大 3000ms]"
#         没有采样时输出 "[窗口: -]"（向后兼容：老机器没这个文件也不报错）
#   ★ 展示口径只有**这一处** ⇒ 菜单与别处不会两处漂。
#   ★ 没有失败样本时失败时延显示 "-"（不是 0ms —— 0ms 会被读成「失败得很快」）。
quality_window_display() {
    local target="$1" rule_id="$2"
    local stats s f ok avg favg fmax fn
    stats=$(quality_window_stats "$target" "$rule_id")
    IFS='|' read -r s f ok avg favg fmax fn <<< "$stats"
    if [ "${s:-0}" -le 0 ]; then
        echo "[窗口: -]"
        return 0
    fi

    # 失败率 = 失败次数 / 采样总数（整数百分比，**比例**；分母不写死）
    local rate=$(( f * 100 / s ))
    local avg_txt="-"
    [ "${ok:-0}" -gt 0 ] && avg_txt="${avg}ms"
    local fail_txt="-"
    if [ "${fn:-0}" -gt 0 ]; then
        fail_txt="均 ${favg}ms 最大 ${fmax}ms"
    fi
    echo "[窗口: 失败率 ${rate}% (${f}/${s}) · 成功时延均值 ${avg_txt} · 失败时延 ${fail_txt}]"
}

# 格式化时延展示：最近一次 + 最近若干次平均
format_latency_display() {
    local latency_ms="$1"
    local hist="$2"

    if [ -z "$latency_ms" ]; then
        echo "-"
        return 0
    fi

    local avg
    if avg=$(latency_avg_ms "$hist"); then
        echo "${latency_ms}ms (均 ${avg}ms)"
    else
        echo "${latency_ms}ms"
    fi
}

get_port_failover_params() {
    local port="$1"

    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ] && read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$port" ]; then
            local interval=$(validate_positive_int "${HEALTH_CHECK_INTERVAL:-4}" 4)
            local failure_threshold=$(validate_positive_int "${FAILURE_THRESHOLD:-2}" 2)
            local success_threshold=$(validate_positive_int "${SUCCESS_THRESHOLD:-2}" 2)
            local connection_timeout=$(validate_positive_int "${CONNECTION_TIMEOUT:-10}" 10)
            local recovery_cooldown=$(validate_positive_int "${RECOVERY_COOLDOWN:-120}" 120)
            echo "${interval}|${failure_threshold}|${success_threshold}|${connection_timeout}|${recovery_cooldown}"
            return 0
        fi
    done

    # 兜底值：interval|failure|success|timeout|cooldown
    # ★ timeout 默认 10 秒（探测端预算口径，与 CONNECTION_TIMEOUT 的默认值一致）
    echo "4|2|2|10|120"
}

get_effective_health_check_interval() {
    local min_interval=""

    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ] && read_rule_file "$rule_file"; then
            if [ "$RULE_ROLE" = "1" ] && [ "$ENABLED" = "true" ] && [ "${FAILOVER_ENABLED:-false}" = "true" ]; then
                local interval=$(validate_positive_int "${HEALTH_CHECK_INTERVAL:-4}" 4)
                if [ -z "$min_interval" ] || [ "$interval" -lt "$min_interval" ]; then
                    min_interval="$interval"
                fi
            fi
        fi
    done

    echo "${min_interval:-4}"
}

# 把规则里**显式写死**的探测超时 3 秒抬到 10 秒
#
# ★ 行为变更（装/升级时生效）：
#   老机器的规则文件里写死的是 CONNECTION_TIMEOUT="3"（老默认值）。
#   真机实测正常目标最慢 2274ms，3 秒预算只剩 24% 余量；
#   死端口墙钟 3057-3397ms 直接超预算 → 探测端误判「不可达」→ 主备误切。
#   不抬的话老机器的「权重 10,0 主备」切换一直不可靠。
#
# 只抬「恰好是 3」的值：用户自己改过的其它值（1/2/4/5...）一律不动。
# 每次调用都跑，幂等（已经是 10 的行不会被再次改写）。
health_migrate_connection_timeout() {
    local rules_dir="${1:-${RULES_DIR:-/etc/realm/rules}}"
    local rule_file
    local changed=0

    [ -d "$rules_dir" ] || return 0

    for rule_file in "$rules_dir"/rule-*.conf; do
        [ -f "$rule_file" ] || continue
        if grep -q '^CONNECTION_TIMEOUT="3"$' "$rule_file" 2>/dev/null; then
            sed -i 's/^CONNECTION_TIMEOUT="3"$/CONNECTION_TIMEOUT="10"/' "$rule_file" 2>/dev/null && changed=1
        elif grep -q '^CONNECTION_TIMEOUT=3$' "$rule_file" 2>/dev/null; then
            sed -i 's/^CONNECTION_TIMEOUT=3$/CONNECTION_TIMEOUT="10"/' "$rule_file" 2>/dev/null && changed=1
        fi
    done

    if [ "$changed" = "1" ]; then
        echo -e "${YELLOW}  已把规则里写死的探测超时从 3 秒抬到 10 秒（探测端预算）${NC}"
    fi
    return 0
}

# 生成健康检查脚本（独立可执行，systemd 直接调用）
# 里面的函数不是手抄副本，而是从本文件（唯一真源）机械抽取后拼进去，
# 所以生成物与主程序的实现天然一致。
health_check_script_body() {
    {
        cat << 'HEADER_EOF'
#!/bin/bash

# 健康检查脚本
# 本文件由 lib/health.sh 的 health_check_script_body 生成，请勿手工修改。
HEALTH_DIR="/etc/realm/health"
RULES_DIR="/etc/realm/rules"
LOCK_FILE="/var/lock/realm-health-check.lock"

# ★ 质量观测指标文件（**独立文件**，不碰 health_status.conf —— 它的形态被台架 T86 锁着）
QUALITY_METRICS_FILE="/var/lib/realm/quality_metrics.conf"
# ★ 质量窗口大小（默认 20，可配 PROBE_QUALITY_WINDOW；兼容别名 probe.quality_window）
#   —— 与显示口径的 latency_hist（上限 5）**无关**，两套窗口并存。
QUALITY_WINDOW_DEFAULT=20
PROBE_QUALITY_WINDOW=""

# 查找健康状态文件
HEALTH_STATUS_FILE=""
for path in "/etc/realm/health/health_status.conf" "/etc/realm/health_status.conf" "/var/lib/realm/health_status.conf"; do
    if [ -f "$path" ]; then
        HEALTH_STATUS_FILE="$path"
        break
    fi
done

# 如果找不到，使用默认路径
if [ -z "$HEALTH_STATUS_FILE" ]; then
    HEALTH_STATUS_FILE="$HEALTH_DIR/health_status.conf"
fi

# 内置清理：清理状态文件（>5MB按行截断保留2000行）
if [ -f "$HEALTH_STATUS_FILE" ]; then
    file_size=$(stat -c%s "$HEALTH_STATUS_FILE" 2>/dev/null || echo 0)
    if [ "$file_size" -gt 5242880 ]; then
        tail -n 2000 "$HEALTH_STATUS_FILE" > "$HEALTH_STATUS_FILE.tmp" 2>/dev/null
        mv "$HEALTH_STATUS_FILE.tmp" "$HEALTH_STATUS_FILE" 2>/dev/null
    fi
fi

# 内置清理：清理journal日志（保留7天，每小时整点执行）
current_minute=$(date +%M)
if [ "$current_minute" = "00" ]; then
    journalctl --vacuum-time=7d >/dev/null 2>&1
fi

# 获取文件锁
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 健康检查已在运行中，跳过本次检查"
    exit 0
fi
HEADER_EOF

        # ↓↓↓ 以下函数从 lib/health.sh（唯一真源）原样抽取，勿手工维护副本 ↓↓↓
        health_emit_function read_rule_file
        health_emit_function check_connectivity
        health_emit_function now_us
        health_emit_function probe_with_latency
        health_emit_function get_health_status_record
        health_emit_function health_status_find_row
        health_emit_function latency_avg_ms
        health_emit_function format_latency_display
        health_emit_function quality_window_size
        health_emit_function read_quality_window
        health_emit_function push_quality_sample
        health_emit_function write_quality_window
        health_emit_function quality_window_stats
        health_emit_function quality_window_display
        # ↑↑↑ 抽取结束 ↑↑↑

        cat << 'BODY_EOF'
# 初始化健康状态文件（文件不存在时先建空壳；内容由下面的原子重建写）
if [ ! -f "$HEALTH_STATUS_FILE" ]; then
    printf '# Realm健康状态文件\n' > "$HEALTH_STATUS_FILE"
fi

# ★ 本轮状态重建：先快照旧文件 → 逐个目标算新行 → 最后整份原子覆盖
#   顺序不能反：先覆盖后读会把旧状态读丢 → 跨轮继承（失败计数 / 故障起始时间）就断了。
_health_status_old="${HEALTH_STATUS_FILE}.old.$$"
_health_status_new="${HEALTH_STATUS_FILE}.new.$$"
cp -f "$HEALTH_STATUS_FILE" "$_health_status_old" 2>/dev/null || : > "$_health_status_old"
: > "$_health_status_new"

# ★ N5 阶段 1：质量观测指标的本轮行（**独立文件**，不碰 health_status.conf）
_quality_rows_new="${QUALITY_METRICS_FILE}.new.$$"
: > "$_quality_rows_new"

# 检查所有启用故障转移的规则
config_changed=false
current_time=$(date +%s)

for rule_file in "${RULES_DIR}"/rule-*.conf; do
    if [ ! -f "$rule_file" ]; then
        continue
    fi

    if ! read_rule_file "$rule_file"; then
        continue
    fi

    # 只检查启用故障转移的中转规则
    if [ "$RULE_ROLE" != "1" ] || [ "$ENABLED" != "true" ] || [ "$FAILOVER_ENABLED" != "true" ]; then
        continue
    fi

    # 处理REMOTE_HOST中的多个地址
    IFS=',' read -ra targets <<< "$REMOTE_HOST"
    for target in "${targets[@]}"; do
        target=$(echo "$target" | xargs)  # 去除空格

        # ★ TARGET 字段 = host:port（与 docs/health-check-and-failover.md 的口径一致）：
        #   同一个 host 上的不同端口是**不同目标**，状态互不覆盖。
        # ★ 行键 = RULE_ID + 目标地址（组合键）：状态归属到「哪条规则的哪个目标」，
        #   跨轮继承按同一个组合键回读（见 health_status_find_row）。
        target_endpoint="${target}:${REMOTE_PORT}"
        target_key="${RULE_ID}|${target_endpoint}"

        # 取上一轮的状态（跨轮继承）：按 **(RULE_ID, 目标地址) 组合键**匹配，
        #   两者都要对上。
        #   只按 RULE_ID 匹配 → ID 复用会把老规则的失败计数算到新规则头上；
        #   只按目标地址匹配 → 同后端被两条规则共用时，状态会过户给另一条规则。
        #   认不出旧行 → 当成没有记录 → 从零重新计数（安全方向）。
        #   旧格式行（TARGET 只有 host）仍然认出来并参与继承（RULE_ID 也要对上）。
        status_line=$(health_status_find_row "$_health_status_old" "$RULE_ID" "$target_endpoint" "$target")
        if [ -n "$status_line" ]; then
            IFS='|' read -r _ _ status fail_count success_count last_check failure_start_time latency_ms latency_hist <<< "$status_line"
            # 兼容旧格式行：字段更少（没有 failure_start_time / latency 两列）
            if [ -z "$failure_start_time" ]; then
                failure_start_time="$last_check"
            fi
            # 计数必须是整数：老文件被写坏时不能把整轮检查带崩
            case "$fail_count" in ''|*[!0-9]*) fail_count=0 ;; esac
            case "$success_count" in ''|*[!0-9]*) success_count=0 ;; esac
            case "$failure_start_time" in ''|*[!0-9]*) failure_start_time=0 ;; esac
        else
            status="healthy"
            fail_count=0
            success_count=2
            last_check=0
            failure_start_time=0
            latency_ms=""
            latency_hist=""
        fi

        # 执行健康检查
        #   ★ 本轮探测结果留一份给 N5 质量窗口采样用（_q_probe_fail）：
        #     质量窗口**复用这一次探测**的结果，**不重复探测** ——
        #     重复探测 = 真机探测次数翻倍（负载翻倍），
        #     且采样口径可能与本轮 status 判定来自不同的探测结果（两者不一致）。
        _q_probe_fail=0
        if probe_with_latency "$target" "$REMOTE_PORT" "${CONNECTION_TIMEOUT:-10}"; then
            # 检查成功
            success_count=$((success_count + 1))
            fail_count=0

            # 如果之前是故障状态，检查是否可以恢复
            if [ "$status" = "failed" ] && [ "$success_count" -ge "${SUCCESS_THRESHOLD:-2}" ]; then
                # 检查冷却期（基于故障开始时间）
                cooldown_period="${RECOVERY_COOLDOWN:-120}"
                if [ $((current_time - failure_start_time)) -ge "$cooldown_period" ]; then
                    status="healthy"
                    config_changed=true
                    failure_start_time=0  # 重置故障开始时间
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [RECOVERY] 目标 $target:$REMOTE_PORT 已恢复健康"
                fi
            fi
        else
            # 检查失败
            _q_probe_fail=1
            fail_count=$((fail_count + 1))
            success_count=0

            # 如果连续失败达到阈值，标记为故障
            if [ "$status" = "healthy" ] && [ "$fail_count" -ge "${FAILURE_THRESHOLD:-2}" ]; then
                status="failed"
                config_changed=true
                failure_start_time="$current_time"  # 记录故障开始时间
                echo "$(date '+%Y-%m-%d %H:%M:%S') [FAILURE] 目标 $target:$REMOTE_PORT 检测失败，标记为故障"
            fi
        fi

        # 时延历史：保留最近 5 次样本（用于算平均值，避免单次抖动误导）
        #   ★ 这是**显示口径**，上限 5 一个字都不许改（台架 T51 锁死）。
        if [ -n "$PROBE_LATENCY_MS" ]; then
            latency_ms="$PROBE_LATENCY_MS"
            _lat_hist=()
            IFS=',' read -ra _lat_hist <<< "$latency_hist"
            _lat_hist+=("$latency_ms")
            if [ "${#_lat_hist[@]}" -gt 5 ]; then
                _lat_hist=("${_lat_hist[@]: -5}")
            fi
            latency_hist=$(IFS=','; echo "${_lat_hist[*]}")
        else
            latency_ms=""
        fi

        # ── N5 阶段 1 · 质量观测窗口采样（**只观测，不动作**）────────────
        #   ★ 硬红线：下面这段**不写** status、**不写**权重、**不碰** config_changed
        #     ⇒ 指标永远不参与切换判定。
        #   · 成功与失败**各算一次采样** ⇒ 失败率的分母 = 采样总数
        #   · 失败 = 探测不通（**不区分 timeout / refused**：check_connectivity
        #     把两者归一化成同一个 rc=1；区分原因是阶段 2 的活）
        #   · 时延分两路记：**成功样本**进 LAT_SEQ、**失败样本**进 FAIL_LAT_SEQ
        #     ⇒ 「成功时延分布」与「失败时延分布」都能算（失败样本的耗时也有观测价值）
        #   · 窗口满 N 后**滚动**丢最旧一次（环形）
        #   ★ 存序列（成败位 + 各样本时延）⇒ 滚动时能**精确**移除最旧样本，
        #     不会「总数减一但不知道该减失败数还是成功数」。
        #   ★ 窗口大小取**当前规则**的配置值（quality_window_size 传当前规则文件）：
        #     规范名 PROBE_QUALITY_WINDOW 由 read_rule_file 解析白名单时赋值，
        #     兼容别名 probe.quality_window 按文本兜底读。
        _q_win=$(quality_window_size "$rule_file")
        case "$_q_win" in
            ''|*[!0-9]*) _q_win="$QUALITY_WINDOW_DEFAULT" ;;
        esac
        [ "$_q_win" -lt 1 ] && _q_win=1

        _q_prev=$(read_quality_window "$target_endpoint" "$RULE_ID")
        _q_seq="${_q_prev%%|*}"
        _q_mid="${_q_prev#*|}"
        _q_lat="${_q_mid%%|*}"
        _q_fail_lat="${_q_mid#*|}"

        #   ★ 复用**本轮那一次**探测的结果（不重复探测）：
        #     重复探测 ⇒ 真机探测次数翻倍（负载翻倍），
        #     且采样口径可能与本轮 status 判定来自不同的探测结果（不一致）。
        #     ⇒ 采样 = 驱动切换的那一次探测（同一口径）。
        #   ★ 失败路径同样有 PROBE_LATENCY_MS（probe_with_latency 两条路径都测耗时）
        #     ⇒ 失败样本的时延可直接取用，不用再探一次。
        _q_is_fail=$_q_probe_fail
        _q_new=$(push_quality_sample "$_q_seq" "$_q_lat" "$_q_fail_lat" "$_q_is_fail" "${PROBE_LATENCY_MS:-0}" "$_q_win")
        _q_new_seq="${_q_new%%|*}"
        _q_new_mid="${_q_new#*|}"
        _q_new_lat="${_q_new_mid%%|*}"
        _q_new_fail_lat="${_q_new_mid#*|}"

        # 记到本轮的质量指标行（循环结束后整份落盘）
        #   ★ 末位记**本行生效的窗口大小** ⇒ 「配的值真的生效」可被外部直接读到
        #     （配置项存在 ≠ 配置项可生效：没有这一列就证明不了值被读到了）。
        #   ★ 失败样本时延追加在**最后一列** ⇒ 前 5 列位置不变（向后兼容）。
        echo "${target_endpoint}|${RULE_ID}|${_q_new_seq}|${_q_new_lat}|${_q_win}|${_q_new_fail_lat}" >> "$_quality_rows_new"
        # ────────────────────────────────────────────────────────────

        # 本轮新行先写进临时文件（循环结束后才整份覆盖）
        #   ★ 不再逐个目标改写状态文件：那样会留下「已被删掉的规则」的残留行
        #   （残留行会被当成「还在监控」）→ 整份重建，残留行自然消失。
        echo "${target_key}|${status}|${fail_count}|${success_count}|${current_time}|${failure_start_time}|${latency_ms}|${latency_hist}" >> "$_health_status_new"
    done
done

# 原子重建状态文件：只保留当前这一轮监控的规则行
#   （规则被删 → 它的残留行一并消失；否则残留行会被当成「还在监控」）
{
    echo "# Realm健康状态文件"
    echo "# 格式: RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY"
    cat "$_health_status_new" 2>/dev/null
} > "${HEALTH_STATUS_FILE}.tmp.$$" 2>/dev/null && mv -f "${HEALTH_STATUS_FILE}.tmp.$$" "$HEALTH_STATUS_FILE" 2>/dev/null
rm -f "$_health_status_old" "$_health_status_new" 2>/dev/null

# ── N5 阶段 1 · 质量观测指标落盘（**独立文件**）────────────────────
#   ★ 与上面的状态文件**完全分开**：不碰 health_status.conf（形态被台架 T86 锁着）。
#   ★ 整份原子重建：只留本轮被采样到的目标 ⇒ 目标消失后它的行自然消失。
#   ★ 写失败**不中断探测端**（观测指标是辅助信息，不是判定依据）。
write_quality_window "$_quality_rows_new" 2>/dev/null || true
rm -f "$_quality_rows_new" 2>/dev/null

# 如果配置有变化，调用xwPF.sh重启接口
if [ "$config_changed" = true ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 检测到节点状态变化，正在更新配置..."

    # 直接调用主脚本的重启接口
    # ★ 看退出码：重启失败（配置形态非法 ⇒ realm 崩溃 ⇒ 全站断流）时
    #   必须把失败**说清楚**，不能照样打「配置更新完成」。
    pf --restart-service >/dev/null 2>&1
    _restart_rc=$?
    if [ "$_restart_rc" -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 配置更新失败（重启返回码 $_restart_rc）—— 权重可能未生效"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 配置更新完成"
    fi
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 健康检查完成"
BODY_EOF
    } | tr -d '\r'
}

# 把「重新生成健康探测脚本失败」写进日志文件
#
# ★ 落点由 Chief 定：/var/log/xwPF/health-regenerate.log
#   （产品此前没有日志约定，这条是第一条）
# ★ 只在失败时写；带时间戳 + 失败原因，便于事后判断。
# ★ **写日志本身失败不许影响主流程**：
#   日志写不进去（目录不可写 / 磁盘满 / 权限不足）时静默返回 0，
#   不能因为「记个日志失败」把安装或升级带崩。
# ★ 日志目录不存在要先 mkdir -p（失败也不致命）。
health_regenerate_log_failure() {
    local reason="${1:-未知原因}"
    local log_dir="/var/log/xwPF"
    local log_file="${log_dir}/health-regenerate.log"

    mkdir -p "$log_dir" 2>/dev/null || true
    {
        echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] 健康探测脚本重新生成失败：${reason}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] 影响：/etc/realm/health/health_check.sh 仍是旧产物 → 权重 10,0 主备的切换会静默失效（探测端不再更新状态）"
    } >> "$log_file" 2>/dev/null || true

    return 0
}

# 重新生成健康检查脚本（**只生成**，不碰 systemd）
#
# ★ 唯一真源 = 本文件（lib/health.sh）。
#   装/升级必须调用它，否则机器上跑的是旧产物 = 探测端**静默失效**：
#   日志照样每 4 秒打「[INFO] 健康检查完成」、退出码 0，
#   但状态文件 LAST_CHECK 停在几小时前 → 权重 10,0 主备永远不切。
#
# 只做三件事：写脚本 + chmod +x + 函数自检。
#   不写 unit/timer、不 daemon-reload、不 enable/start ——
#   升级不该把没在跑的定时器拉起来；unit 是 Type=oneshot + ExecStart=<路径>，
#   产物换掉后下个 tick 自然生效。
health_check_script_regenerate() {
    local health_script="${1:-/etc/realm/health/health_check.sh}"
    local health_dir tmp_script _missing

    health_dir=$(dirname "$health_script")
    tmp_script="${health_script}.tmp.$$"

    # 创建健康检查目录
    if ! mkdir -p "$health_dir"; then
        echo -e "${RED}✗ 创建健康检查目录失败: ${health_dir}${NC}" >&2
        return 1
    fi

    # 生成健康检查脚本（函数实现从本文件抽取）
    # 原子落盘：先写临时文件再 mv —— systemd 读到半截脚本会直接失败
    rm -f "$tmp_script"
    if ! health_check_script_body > "$tmp_script" || [ ! -s "$tmp_script" ]; then
        echo -e "${RED}✗ 生成健康检查脚本失败: ${health_script}${NC}" >&2
        rm -f "$tmp_script"
        return 1
    fi
    if ! mv -f "$tmp_script" "$health_script"; then
        echo -e "${RED}✗ 写入健康检查脚本失败: ${health_script}${NC}" >&2
        rm -f "$tmp_script"
        return 1
    fi
    chmod +x "$health_script" || {
        echo -e "${RED}✗ 设置可执行权限失败: ${health_script}${NC}" >&2
        return 1
    }

    # 必要函数自检：抽取失败时不要装一个跑不起来的探测端
    _missing=""
    grep -q '^read_rule_file() {' "$health_script" || _missing="read_rule_file"
    grep -q '^check_connectivity() {' "$health_script" || _missing="${_missing} check_connectivity"
    # 尾部标记：生成物被截断时（抽取中途失败）这里能抓到
    grep -q '健康检查完成' "$health_script" || _missing="${_missing} <脚本尾部>"
    if [ -n "$_missing" ]; then
        echo -e "${RED}✗ 生成的健康检查脚本缺少函数: ${_missing}${NC}" >&2
        rm -f "$health_script"
        return 1
    fi

    return 0
}

start_health_check_service() {
    local health_dir="/etc/realm/health"
    local health_script="/etc/realm/health/health_check.sh"
    local health_timer="/etc/systemd/system/realm-health-check.timer"
    local health_service="/etc/systemd/system/realm-health-check.service"

    local effective_interval="${1:-$(get_effective_health_check_interval)}"

    # 创建健康检查目录（目录由 health_check_script_regenerate 负责建）
    if ! mkdir -p "$health_dir"; then
        echo -e "${RED}✗ 创建健康检查目录失败: ${health_dir}${NC}" >&2
        return 1
    fi

    # 探测超时预算：规则里写死的 3 秒抬到 10 秒
    # （探测端刚装上/刚启用时就要是对的预算，否则第一轮探测就按 3 秒判 → 主备误切）
    health_migrate_connection_timeout || true

    # 生成健康检查脚本（**生成逻辑只有这一份**：唯一真源 = 本文件）
    # 装/升级路径走的是同一个函数（health_check_script_regenerate）
    if ! health_check_script_regenerate "$health_script"; then
        return 1
    fi

    # 创建systemd服务文件
    tr -d '\r' > "$health_service" << EOF
[Unit]
Description=Realm Health Check Service
After=network.target

[Service]
Type=oneshot
ExecStart=$health_script
User=root
WorkingDirectory=/etc/realm
StandardOutput=journal
StandardError=journal
SyslogIdentifier=realm-health

[Install]
WantedBy=multi-user.target
EOF

    # 创建systemd定时器
    tr -d '\r' > "$health_timer" << EOF
[Unit]
Description=Realm Health Check Timer
Requires=realm-health-check.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=${effective_interval}sec
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 启用并启动定时器
    # 失败必须报错并返回非 0：静默失败会让主备模式「配置显示主备、实际没有探测端」
    if ! systemctl daemon-reload; then
        echo -e "${RED}✗ systemctl daemon-reload 失败${NC}" >&2
        return 1
    fi
    if ! systemctl enable realm-health-check.timer; then
        echo -e "${RED}✗ systemctl enable realm-health-check.timer 失败${NC}" >&2
        return 1
    fi
    if ! systemctl start realm-health-check.timer; then
        echo -e "${RED}✗ systemctl start realm-health-check.timer 失败${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}✓ 健康检查服务已启动 (检查间隔: ${effective_interval}s)${NC}"
}

stop_health_check_service() {
    # 停止并禁用健康检查服务
    systemctl stop realm-health-check.timer >/dev/null 2>&1
    systemctl disable realm-health-check.timer >/dev/null 2>&1
    systemctl stop realm-health-check.service >/dev/null 2>&1
    systemctl disable realm-health-check.service >/dev/null 2>&1

    # 删除服务文件
    rm -f "/etc/systemd/system/realm-health-check.timer"
    rm -f "/etc/systemd/system/realm-health-check.service"
    rm -f "/etc/realm/health/health_check.sh"

    systemctl daemon-reload

    echo -e "${GREEN}✓ 健康检查服务已停止${NC}"
}
