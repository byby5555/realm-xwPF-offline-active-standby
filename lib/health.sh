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
    local _allowed='RULE_ID RULE_ROLE RULE_NAME SECURITY_LEVEL LISTEN_PORT LISTEN_IP THROUGH_IP REMOTE_HOST REMOTE_PORT FORWARD_TARGET TLS_SERVER_NAME TLS_CERT_PATH TLS_KEY_PATH WS_PATH WS_HOST RULE_NOTE ENABLED CREATED_TIME BALANCE_MODE PREV_BALANCE_MODE TARGET_STATES WEIGHTS FAILOVER_ENABLED HEALTH_CHECK_INTERVAL FAILURE_THRESHOLD SUCCESS_THRESHOLD CONNECTION_TIMEOUT RECOVERY_COOLDOWN MPTCP_MODE PROXY_MODE'

    if [ ! -f "$rule_file" ]; then
        return 1
    fi

    # 逐行解析：只认白名单 KEY，绝不执行文件内容
    declare -A _rule_vals=()
    while IFS= read -r _line || [ -n "$_line" ]; do
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

# 取当前时间（微秒）
# 优先 bash 5 的 EPOCHREALTIME（不 fork，更快）；回退 date +%s%N
# （GNU coreutils 支持；busybox date 不支持 %N，会返回字面量 N，此时判定为不可用）
now_us() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
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
    esac
    echo "$t"
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

# 在旧状态文件里按 TARGET 找一行（跨轮继承用）
#
# ★ 匹配键是「目标地址」，**不是 RULE_ID**：
#   规则 ID 会被复用（删掉一条规则后，下一条规则可能拿到同一个 ID），
#   按 RULE_ID 继承会把老规则的 failed / 失败计数算到新规则头上
#   → 新鲜健康的目标一上来就显示「故障」，甚至被当成故障。
#   按目标地址继承则不会串：目标地址不同 → 认不出旧行 → 当成没有记录。
#
# 口径：
#   ① 新格式行（TARGET = host:port）：整段相等才算命中（不靠子串，
#      否则 "10.0.0.1" 会命中 "110.0.0.1"）。
#   ② 旧格式行（TARGET 只有 host，没有端口）：仍然认出来并参与继承
#      —— 老文件里那种行不能当成「没有记录」，否则目标会被当成健康
#      → 故障转移静默失效。
health_status_find_row() {
    local status_file="$1"
    local endpoint="$2"
    local host="$3"
    local legacy_row="" _rid _field2 _rest

    [ -f "$status_file" ] || return 1

    while IFS='|' read -r _rid _field2 _rest || [ -n "${_field2:-}" ]; do
        case "$_rid" in
            '#'*) continue ;;
        esac
        [ -z "${_field2:-}" ] && continue
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
        target_endpoint="${target}:${REMOTE_PORT}"
        target_key="${RULE_ID}|${target_endpoint}"

        # 取上一轮的状态（跨轮继承）：按**目标地址**匹配，不按 RULE_ID 匹配。
        #   规则 ID 会被复用（删掉一条规则后，下一条规则可能拿到同一个 ID），
        #   按 RULE_ID 继承会把老规则的 failed / 失败计数算到新规则头上
        #   → 新鲜健康的目标一上来就显示「故障」。
        #   旧格式行（TARGET 只有 host）仍然认出来并参与继承。
        status_line=$(health_status_find_row "$_health_status_old" "$target_endpoint" "$target")
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

# 如果配置有变化，调用xwPF.sh重启接口
if [ "$config_changed" = true ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 检测到节点状态变化，正在更新配置..."

    # 直接调用主脚本的重启接口
    pf --restart-service >/dev/null 2>&1

    echo "$(date '+%Y-%m-%d %H:%M:%S') [CONFIG] 配置更新完成"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 健康检查完成"
BODY_EOF
    } | tr -d '\r'
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
