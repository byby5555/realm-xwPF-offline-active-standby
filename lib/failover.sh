#!/bin/bash
#
# Active/Passive failover helper library for xwPF
#
# Real primary/backup, separate from realm's LB modes.
# Backed by /usr/local/bin/xwpf-failover (Python, see cmd/).
#

# Filesystem layout
XWPF_FAILOVER_BIN="/usr/local/bin/xwpf-failover"
XWPF_FAILOVER_SERVICE="xwpf-failover"
XWPF_FAILOVER_UNIT="/etc/systemd/system/xwpf-failover.service"
XWPF_FAILOVER_CONF_DIR="/etc/xwpf"
XWPF_FAILOVER_CONF="${XWPF_FAILOVER_CONF_DIR}/failover.json"
# 已安装 daemon 的版本记录（用于判断是否需要重装升级）
XWPF_FAILOVER_VERSION_FILE="/usr/local/bin/.xwpf-failover-version"
# 端口占用探测结果（failover_check_port_listening 写入，调用方打印原因用）
FAILOVER_PORT_PROBE_DETAIL=""

# Loopback port range used by realm listeners backing each failover pool.
XWPF_FAILOVER_PORT_BASE=10443
XWPF_FAILOVER_PORT_LAST=11442

#
# File operations on /etc/xwpf/failover.json — done ENTIRELY in Python via a
# runner helper below. This avoids having to construct JSON inside bash.
#

failover_json_run() {
    # $1 is the python heredoc body
    XWPF_FAILOVER_CONF="${XWPF_FAILOVER_CONF}" python3 <<'PYEOF'
import json, os, sys, pathlib
p = os.environ["XWPF_FAILOVER_CONF"]
PYEOF
    # concatenate caller body after the imports/prelude
    bash -c "$1" <<< "# caller body follows"
}

# The above function is too clever. Let me use a different approach: a python
# caller function that imports the rest from a python-side helper module.

failover_py_helper() {
    # Generate a temporary Python helper script and run it.
    # Body is passed verbatim to python.
    local body="$1"
    python3 -c "$body"
}

# === Validate addr ===
# Allow "host:port" or bare "port".
# === Normalize addr ===
# Strip invisible/wide characters that terminals, IMEs, or copy-paste insert
# between visible chars (BOM, zero-width, full-width, NBSP, CR, LF, TAB).
# Returns cleaned string on stdout; empty if nothing remains.
failover_normalize_addr() {
    local raw="$1"
    XWPF_FAILOVER_NORMALIZE_RAW="$raw" python3 -c "
import os
raw = os.environ['XWPF_FAILOVER_NORMALIZE_RAW']
for c in '\ufeff\u200b\u200c\u200d\u200e\u200f\u3000\u00a0\r\n\t':
    raw = raw.replace(c, '')
print(raw.strip(), end='')
"
}

# === Hex dump helper for error messages ===
# Prints raw bytes as a hex string (caller appends to error labels).
failover_addr_debug_dump() {
    local s="${1:-}"
    if [ -z "$s" ]; then printf '%s' '<empty>'; return; fi
    printf '%s' "$s" | od -An -tx1 | tr -d ' \n' | head -c 80
}

# === Validate addr (now tolerant of invisible chars) ===
failover_validate_addr() {
    local raw="$1" addr
    addr=$(failover_normalize_addr "$raw")
    if [[ -z "$addr" ]]; then return 1; fi
    if [[ "$addr" =~ ^([0-9]+)$ ]]; then
        validate_port "$addr" || return 1
        return 0
    fi
    if [[ "$addr" =~ ^([^:]+):([0-9]+)$ ]]; then
        validate_port "${BASH_REMATCH[2]}" || return 1
        return 0
    fi
    return 1
}

# === Port-collision check (TCP bind probe) ===
# 退出码：0 = 端口空闲；1 = 确认被占用；2 = 无法判定（探测环境不可用）
# 占用详情放在全局 FAILOVER_PORT_PROBE_DETAIL（供调用方打印原因）。
#
# ★ 单一真源：端口占用的**事前校验**逻辑只有这一份（socket 试绑）。
#   cmd/xwpf-failover.py 不另写一份探测 —— 它只在真实 bind 失败时把
#   EADDRINUSE 翻译成人话（运行时兜底），不做事前校验。
#
# ★ 旧实现有个洞：socket() 创建失败（协议族不可用，例如内核禁用 IPv6）
#   也走 except OSError → 一律判「端口被占用」。查不到占用者却下结论，
#   比直接报错更误导运维。现在三态：不可用 → 「无法判定」。
failover_check_port_listening() {
    local port="${1:?port required}"
    local out=""
    FAILOVER_PORT_PROBE_DETAIL=""
    command -v python3 >/dev/null 2>&1 || return 2
    out="$(python3 - "$port" 2>/dev/null <<'PY'
import socket, sys
try:
    port = int(sys.argv[1])
except (IndexError, ValueError):
    sys.exit(2)
for fam, addr in ((socket.AF_INET, ("0.0.0.0", port)),
                  (socket.AF_INET6, ("::", port))):
    try:
        s = socket.socket(fam, socket.SOCK_STREAM)
    except OSError:
        # 该协议族不可用（例如内核禁用 IPv6）→ 跳过，
        # 不能据此判定「端口被占用」。
        continue
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(addr)
    except OSError as e:
        print("BUSY %s:%d %s" % (addr[0], port, e.strerror or str(e)))
        sys.exit(0)
    finally:
        try:
            s.close()
        except OSError:
            pass
print("FREE")
PY
)" || return 2
    case "$out" in
        FREE*)
            return 0 ;;
        BUSY*)
            FAILOVER_PORT_PROBE_DETAIL="${out#BUSY }"
            return 1 ;;
    esac
    return 2
}

# === 写配置前的 listen 端口前置校验（单一真源） ===
# 端口被占用 → daemon 必然绑不上 → 起不来就退出 → 崩溃循环。
# 所以必须在**写 failover.json 之前**拦下来，并打印原因 + 处置建议。
# 退出码：0 = 端口可用；非 0 = 不可用（调用方必须拒绝写入并返回非 0）。
failover_require_listen_port_free() {
    local port="$1" probe_rc=0
    failover_check_port_listening "$port" || probe_rc=$?
    if [ "$probe_rc" -eq 0 ]; then
        return 0
    fi
    if [ "$probe_rc" -eq 1 ]; then
        # 确认被占用：说清楚占用者 + 处置办法
        echo -e "${RED}端口 ${port} 已被占用 (listen address already in use) — 拒绝写入 ${XWPF_FAILOVER_CONF}${NC}"
        if [ -n "$FAILOVER_PORT_PROBE_DETAIL" ]; then
            echo -e "  原因: ${FAILOVER_PORT_PROBE_DETAIL}"
        fi
        ss -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -3
        echo -e "${YELLOW}处置: 改 listen 端口，或停掉占用该端口的服务后重试${NC}"
    else
        # 无法判定：**不能**写「已被占用」——
        # 查不到占用者却下结论，比直接报错更误导运维。
        echo -e "${RED}无法确认端口 ${port} 是否空闲 (探测环境不可用: 缺 python3 或探测失败) — 拒绝写入 ${XWPF_FAILOVER_CONF}${NC}"
        echo -e "${YELLOW}处置: 装好 python3 后重试；或先用 ss -lntp 确认端口状态${NC}"
    fi
    return 1
}

# === TCP-reachability probe ===
# 连通性探测的唯一实现在 lib/health.sh 的 check_connectivity
# （netcat 优先；缺 nc 时回退 bash 内置 /dev/tcp）。
# 这里只做参数拆分 + 转发，不再另写一份探测逻辑。
# lib/failover.sh 被单独 source 时自动把唯一实现所在文件加载进来。
if ! declare -F check_connectivity >/dev/null 2>&1; then
    _REALM_FAILOVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -f "${_REALM_FAILOVER_LIB_DIR}/health.sh" ]; then
        # shellcheck disable=SC1091
        . "${_REALM_FAILOVER_LIB_DIR}/health.sh"
    fi
    unset _REALM_FAILOVER_LIB_DIR
fi

failover_probe_reachable() {
    local raw="$1"
    local host="${raw%:*}"
    local port="${raw##*:}"
    check_connectivity "$host" "$port" 3
}

# === Normalize listen addr ===
# Bare port -> 0.0.0.0:port
failover_normalize_listen() {
    local addr="$1"
    if [[ "$addr" =~ ^([0-9]+)$ ]]; then
        echo "0.0.0.0:$addr"
    else
        echo "$addr"
    fi
}

# === Used ports (filesystem) ===
# Reads LISTEN_PORT= directly from each rule-N.conf (avoids read_rule_file
# dependency on lib/rules.sh). Prints one port per line.
failover_used_ports_from_rules() {
    local f p
    if [ -d "${RULES_DIR:-/etc/realm/rules}" ]; then
        for f in "${RULES_DIR}"/rule-*.conf; do
            [ -f "$f" ] || continue
            # Strip trailing CR + filter only LISTEN_PORT="N" lines
            p=$(grep -E '^LISTEN_PORT="([0-9]+)"' "$f" 2>/dev/null \
                | sed -E 's/.*"([0-9]+)".*/\1/' | head -1)
            if [[ "$p" =~ ^[0-9]+$ ]]; then
                echo "$p"
            fi
        done
    fi
}

# === Used ports (from /etc/xwpf/failover.json) ===
# Extracts loopback ports previously committed to the failover config so that
# adding a new pool never reuses one. Prints one port per line.
failover_used_ports_from_failover_json() {
    XWPF_FAILOVER_CONF_PATH="${XWPF_FAILOVER_CONF}" python3 <<'PYEOF'
import json, os, re, sys
path = os.environ.get("XWPF_FAILOVER_CONF_PATH", "")
try:
    with open(path) as f:
        txt = f.read()
    # Only consider loopback addresses — non-loopback (public) addresses
    # don't collide with our internal 127.0.0.1 listeners.
    for m in re.finditer(r'127\.0\.0\.1:(\d+)', txt):
        print(m.group(1))
except Exception:
    pass
PYEOF
}

# === Combined used ports ===
failover_used_ports() {
    {
        failover_used_ports_from_rules
        failover_used_ports_from_failover_json
    } | sort -un
}

# === Allocate one free port ===
# Args are ports already allocated WITHIN THIS SESSION that must be excluded
# (the regex-based rules-dir scan can't see ports we haven't written yet).
failover_alloc_port() {
    local reserved=("$@")
    local used
    used="$(failover_used_ports)"
    local p r skip
    for ((p = XWPF_FAILOVER_PORT_BASE; p <= XWPF_FAILOVER_PORT_LAST; p++)); do
        skip=0
        if printf '%s\n' "$used" | grep -qx "$p"; then
            skip=1
        else
            for r in "${reserved[@]}"; do
                if [ "$r" = "$p" ]; then
                    skip=1
                    break
                fi
            done
        fi
        if [ $skip -eq 0 ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# === Create a server-side rule-N.conf (loopback listener) ===
# args: rule_id  listen_port  remote_addr  tls_sni
failover_create_server_rule() {
    local rule_id="$1" listen_port="$2" remote_addr="$3" tls_sni="${4:-}"
    local r_host r_port
    if [[ "$remote_addr" =~ ^([^:]+):([0-9]+)$ ]]; then
        r_host="${BASH_REMATCH[1]}"
        r_port="${BASH_REMATCH[2]}"
    else
        r_host="$remote_addr"
        r_port="443"
    fi
    local outfile="${RULES_DIR}/rule-${rule_id}.conf"
    tr -d '\r' > "$outfile" <<EOF
RULE_ID="${rule_id}"
RULE_NAME="failover-backend-${rule_id}"
RULE_ROLE="2"
SECURITY_LEVEL="off"
LISTEN_PORT="${listen_port}"
LISTEN_IP="127.0.0.1"
THROUGH_IP="127.0.0.1"
FORWARD_TARGET="${r_host}:${r_port}"
TLS_SERVER_NAME="${tls_sni}"
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=""
WS_HOST=""
RULE_NOTE="xwPF failover pool backend"
ENABLED="true"
CREATED_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
BALANCE_MODE="off"
TARGET_STATES=""
WEIGHTS=""
FAILOVER_ENABLED="false"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"
RECOVERY_COOLDOWN="120"
MPTCP_MODE="off"
PROXY_MODE="off"
EOF
}

# === Helper: write pool into failover.json via python helper script ===
# This is invoked from failover_pool_create and works without heredoc weirdness
# by using env vars.
failover_pool_write_json() {
    # Args:
    # $1 = name  $2 = listen  $3 = primary_port  $4 = primary_rule_id
    # $5 = backup_ports_csv  $6 = backups_csv  $7 = backup_rules_csv
    local name="$1" listen="$2" primary_port="$3" primary_rule_id="$4"
    local backup_ports_csv="$5" backups_csv="$6" backup_rules_csv="$7"
    mkdir -p "${XWPF_FAILOVER_CONF_DIR}"
    primary_args=(--name "$name" --listen "$listen" --primary "127.0.0.1:$primary_port")
    # Build backup args + rule_ids list (passed in via --primary/--backup as values)
    backup_args=()
    IFS=',' read -ra bps <<< "$backup_ports_csv"
    IFS=',' read -ra bas <<< "$backups_csv"
    IFS=',' read -ra brs <<< "$backup_rules_csv"
    local i=0
    for bp in "${bps[@]}"; do
        if [ "${#brs[@]}" -gt "$i" ]; then
            backup_args+=(--backup "127.0.0.1:$bp|${bas[$i]}|${brs[$i]}")
        else
            backup_args+=(--backup "127.0.0.1:$bp|${bas[$i]}")
        fi
        i=$((i+1))
    done

    XWPF_FAILOVER_RULES_DIR="${RULES_DIR:-/etc/realm/rules}" \
    python3 - "$XWPF_FAILOVER_CONF" --primary-rule "$primary_rule_id" "${primary_args[@]}" "${backup_args[@]}" <<'PY'
import json, os, sys
conf = sys.argv[1]
args = {a:v for a,v in zip(sys.argv[2::2], sys.argv[3::2])}
try:
    with open(conf) as f:
        cur = json.load(f)
    if not isinstance(cur, list):
        cur = []
except Exception:
    cur = []
backups_raw = [v for k,v in zip(sys.argv[2::2], sys.argv[3::2]) if k == "--backup"]
backups = []
backup_rule_ids = []
for b in backups_raw:
    parts = b.rsplit("|", 1) if "|" in b else [b, ""]
    if len(parts) == 2 and parts[1].isdigit():
        backups.append(parts[0])
        backup_rule_ids.append(int(parts[1]))
    else:
        backups.append(b)
        backup_rule_ids.append(None)
primary_rule_id = int(args.get("--primary-rule", "0")) if args.get("--primary-rule","").isdigit() else None
pool = {
    "name": args.get("--name",""),
    "listen": args.get("--listen",""),
    "primary": args.get("--primary",""),
    "primary_rule_id": primary_rule_id,
    "backups": backups,
    "backup_rule_ids": backup_rule_ids,
    "probe": {
        "interval_sec": 4,
        "timeout_sec": 3,
        "fail_threshold": 2,
        "success_threshold": 2,
        "cooldown_sec": 120,
    },
}
cur.append(pool)
with open(conf,"w") as f:
    json.dump(cur, f, indent=2, ensure_ascii=False)
print(json.dumps(pool, ensure_ascii=False))
PY
}

# === Create a failover pool (interactive caller) ===
# === Direct mode: bypass realm wrapper ===
# Daemon forwards raw TCP directly to remote - no realm server rule.
# Faster (1 hop vs 2), simpler, but loses per-rule logging/TLS that
# realm would provide (with security=off these are all no-ops anyway).
failover_pool_create_direct() {
    local name="$1" public_listen="$2" primary_addr="$3" backup_csv="$4"

    # Usage hint for direct callers (dispatcher covers --help for itself).
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "usage: failover_pool_create_direct <name> <listen> <primary> [backup,backup,...]"
        echo "  Writes a direct-mode pool entry into /etc/xwpf/failover.json"
        echo "  (skips loopback realm server rule wrapper, daemon forwards raw TCP)."
        return 0
    fi

    failover_validate_addr "$public_listen" || {
        local hex; hex=$(failover_addr_debug_dump "$public_listen")
        echo -e "${RED}公开监听地址不合法: '$public_listen' (hex=${hex})${NC}"
        return 1
    }
    public_listen="$(failover_normalize_listen "$public_listen")"

    failover_validate_addr "$primary_addr" || {
        local hex; hex=$(failover_addr_debug_dump "$primary_addr")
        echo -e "${RED}主后端不合法: '$primary_addr' (hex=${hex})${NC}"
        return 1
    }

    local backups=()
    if [ -n "$backup_csv" ]; then
        IFS=',' read -ra backups <<< "$backup_csv"
        for b in "${backups[@]}"; do
            failover_validate_addr "$b" || {
                local hex; hex=$(failover_addr_debug_dump "$b")
                echo -e "${RED}备后端不合法: '$b' (hex=${hex})${NC}"
                return 1
            }
        done
    fi

    local public_port="${public_listen##*:}"
    # 写 failover.json 之前必须先确认 listen 端口可用：
    # 端口被占用 → daemon 必然起不来 → 崩溃循环。
    failover_require_listen_port_free "$public_port" || return 1

    local unreachable=()
    for addr_target in "$primary_addr" "${backups[@]}"; do
        if ! failover_probe_reachable "$addr_target"; then
            unreachable+=("$addr_target")
        fi
    done
    if [ ${#unreachable[@]} -gt 0 ]; then
        echo -e "${YELLOW}警告: 以下后端从本机不可达 (可能需在远端 ufw 放行):${NC}"
        printf '  - %s\n' "${unreachable[@]}"
        if [ -t 0 ]; then
            local yn=""
            read -rt 10 -p "仍继续创建? [y/N] " yn || yn=""
            [[ "$yn" =~ ^[Yy] ]] || { echo "已取消"; return 1; }
        else
            echo "(non-tty, 跳过确认)"
        fi
    fi

    # 写配置失败必须当场报错：下面的 echo 会把函数返回码覆盖成 0，
    # 不检查的话菜单照样打印「已创建主备池」，而配置根本没写进去。
    if ! failover_pool_write_json_direct "$name" "$public_listen" "$primary_addr" "$(IFS=,; echo "${backups[*]}")"; then
        echo -e "${RED}写入主备池配置失败${NC}"
        return 1
    fi

    echo -e "${GREEN}已创建主备池 '$name' (direct 模式, 不走 realm)${NC}"
    echo -e "  公开监听: ${YELLOW}${public_listen}${NC}"
    echo -e "  ${BLUE}主${NC}  -> ${primary_addr}"
    local i=1
    for b in "${backups[@]}"; do
        echo -e "  ${BLUE}备${i}${NC} -> ${b}"
        i=$((i+1))
    done
    echo
    echo -e "${YELLOW}下一步: 在 [3] 启停守护 中启动 xwpf-failover (无需重启 realm)${NC}"
}

# === Dispatcher: --direct routes to failover_pool_create_direct ===
# Other args are positional: <name> <listen> <primary> [backup,backup,...]
failover_pool_create_dispatch() {
    local direct=false
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --direct|-d) direct=true; shift ;;
            --help|-h) echo "usage: failover_pool_create_dispatch [--direct|-d] <name> <listen> <primary> [backup,backup,...]"; return 0 ;;
            --) shift; while [ $# -gt 0 ]; do positional+=("$1"); shift; done ;;
            --*) echo -e "${RED}未知选项: $1${NC}" >&2; return 2 ;;
            *)  positional+=("$1"); shift ;;
        esac
    done
    if [ "${#positional[@]}" -lt 3 ]; then
        echo -e "${RED}参数不足: 需要 名称 监听 主后端 [备后端...], got ${#positional[@]}${NC}" >&2
        return 2
    fi
    local name="${positional[0]}" public_listen="${positional[1]}" primary_addr="${positional[2]}"
    local backup_csv=""
    if [ "${#positional[@]}" -gt 3 ]; then
        local IFS=','
        backup_csv="${positional[*]:3}"
    fi
    if $direct; then
        failover_pool_create_direct "$name" "$public_listen" "$primary_addr" "$backup_csv"
    else
        failover_pool_create "$name" "$public_listen" "$primary_addr" "$backup_csv"
    fi
}

# === Positional shim for callers passing --direct as first arg ===
failover_pool_create_parse() {
    local direct=false
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --direct|-d) direct=true; shift ;;
            *) args+=("$1"); shift ;;
        esac
    done
    if [ "${#args[@]}" -lt 3 ] || [ "${#args[@]}" -gt 4 ]; then
        echo "usage: failover_pool_create_parse [--direct|-d] <name> <listen> <primary> [backup_csv]" >&2
        return 2
    fi
    if $direct; then
        failover_pool_create_direct "${args[0]}" "${args[1]}" "${args[2]}" "${args[3]:-}"
    else
        failover_pool_create "${args[0]}" "${args[1]}" "${args[2]}" "${args[3]:-}"
    fi
}

failover_pool_create() {
    local name="$1" public_listen="$2" primary_addr="$3" backup_csv="$4"

    # === A+B: Validate with byte-level error context ===
    failover_validate_addr "$public_listen" || {
        local hex; hex=$(failover_addr_debug_dump "$public_listen")
        echo -e "${RED}公开监听地址不合法: '$public_listen' (hex=${hex})${NC}"
        return 1
    }
    public_listen="$(failover_normalize_listen "$public_listen")"

    failover_validate_addr "$primary_addr" || {
        local hex; hex=$(failover_addr_debug_dump "$primary_addr")
        echo -e "${RED}主后端不合法: '$primary_addr' (hex=${hex})${NC}"
        return 1
    }

    local backups=()
    if [ -n "$backup_csv" ]; then
        IFS=',' read -ra backups <<< "$backup_csv"
        for b in "${backups[@]}"; do
            failover_validate_addr "$b" || {
                local hex; hex=$(failover_addr_debug_dump "$b")
                echo -e "${RED}备后端不合法: '$b' (hex=${hex})${NC}"
                return 1
            }
        done
    fi

    # === C: pre-check listen port is free (TCP bind probe) ===
    # 写 failover.json 之前必须先确认 listen 端口可用：
    # 端口被占用 → daemon 必然起不来 → 崩溃循环。
    local public_port="${public_listen##*:}"
    failover_require_listen_port_free "$public_port" || return 1

    # === D: probe reachability of primary + backups (ufw gate) ===
    local unreachable=()
    for addr_target in "$primary_addr" "${backups[@]}"; do
        if ! failover_probe_reachable "$addr_target"; then
            unreachable+=("$addr_target")
        fi
    done
    if [ ${#unreachable[@]} -gt 0 ]; then
        echo -e "${YELLOW}警告: 以下后端从本机不可达 (可能需在远端 ufw 放行):${NC}"
        printf '  - %s\n' "${unreachable[@]}"
        if [ -t 0 ]; then
            local yn=""
            read -rt 10 -p "仍继续创建? [y/N] " yn || yn=""
            [[ "$yn" =~ ^[Yy] ]] || { echo "已取消"; return 1; }
        else
            echo "(non-tty, 跳过确认)"
        fi
    fi

    # Allocate ports and rule IDs together by INTERLEAVING the writes:
    # each rule file must exist on disk before generate_rule_id() is called
    # for the next one, so we can't pre-allocate everything in batch.
    local primary_rule_id
    primary_rule_id="$(generate_rule_id)"
    local primary_internal_port
    primary_internal_port="$(failover_alloc_port)"
    if [ -z "$primary_internal_port" ]; then
        echo -e "${RED}无可用 loopback 端口 - 请调整 XWPF_FAILOVER_PORT_BASE/LAST${NC}"
        return 1
    fi
    failover_create_server_rule "${primary_rule_id}" "${primary_internal_port}" "${primary_addr}" ""

    local backup_rule_ids=()
    local backup_internal_ports=()
    local bp rid j
    for ((j=0; j<${#backups[@]}; j++)); do
        # Pass primary + any already-allocated+written backup ports as
        # in-session exclusions.
        local -a reservations=("$primary_internal_port")
        if [ ${#backup_internal_ports[@]} -gt 0 ]; then
            reservations+=("${backup_internal_ports[@]}")
        fi
        bp="$(failover_alloc_port "${reservations[@]}")"
        if [ -z "$bp" ]; then
            echo -e "${RED}分配端口耗尽${NC}"
            return 1
        fi
        # Now that the previous rule file (primary, or earlier backup) is on
        # disk, generate_rule_id() returns the next sequential ID.
        rid="$(generate_rule_id)"
        failover_create_server_rule "$rid" "$bp" "${backups[$j]}" ""
        backup_internal_ports+=("$bp")
        backup_rule_ids+=("$rid")
    done

    # Build CSV strings for python helper
    local bps_csv bas_csv brs_csv
    bps_csv="$(IFS=,; echo "${backup_internal_ports[*]}")"
    bas_csv="$(IFS=,; echo "${backups[*]}")"
    brs_csv="$(IFS=,; echo "${backup_rule_ids[*]}")"

    # 同上：写配置失败必须当场报错，不能被后面的 echo 覆盖返回码。
    # 注意此模式（realm 回环）在写配置**之前**已经生成过 realm 规则，
    # 所以失败时提示里要说明可能留下了半成品。
    if ! failover_pool_write_json "${name}" "${public_listen}" "${primary_internal_port}" "${primary_rule_id}" "${bps_csv}" "${bas_csv}" "${brs_csv}"; then
        echo -e "${RED}写入主备池配置失败（realm 回环规则可能已生成，请检查后手工清理）${NC}"
        return 1
    fi

    echo -e "${GREEN}已创建主备池 '${name}'${NC}"
    echo -e "  公开监听: ${YELLOW}${public_listen}${NC}"
    echo -e "  ${BLUE}主${NC}  → ${primary_addr}  (loopback :${primary_internal_port}, rule-${primary_rule_id}.conf)"
    local i=1
    for b in "${backups[@]}"; do
        echo -e "  ${BLUE}备${i}${NC}  → ${b}  (loopback :${backup_internal_ports[$((i-1))]}, rule-${backup_rule_ids[$((i-1))]}.conf)"
        i=$((i+1))
    done
    echo
    echo -e "${YELLOW}下一步: 在 [3] 启停守护 中启动 xwpf-failover 并重启 realm${NC}"
}

# === List pools ===
failover_pool_list() {
    if [ ! -f "${XWPF_FAILOVER_CONF}" ]; then
        echo "  (暂无主备池)"
        return 0
    fi
    XWPF_FAILOVER_CONF_PATH="${XWPF_FAILOVER_CONF}" python3 <<'PYEOF'
import json, os
try:
    with open(os.environ["XWPF_FAILOVER_CONF_PATH"]) as f:
        pools = json.load(f) or []
except Exception:
    pools = []
if not pools:
    print("  (暂无主备池)")
else:
    for i,p in enumerate(pools,1):
        print(f"  [{i}] {p.get('name','?')}")
        print(f"      listen  : {p.get('listen','?')}")
        print(f"      primary : {p.get('primary','?')}")
        for j,b in enumerate(p.get('backups',[]) or [],1):
            print(f"      backup{j}: {b}")
        pr = p.get('probe') or {}
        print(f"      probe   : iv={pr.get('interval_sec')}s, fail>={pr.get('fail_threshold')}, succ>={pr.get('success_threshold')}, cd={pr.get('cooldown_sec')}s")
PYEOF
}

# === Delete pool by index ===
failover_pool_delete() {
    local idx="$1"
    if [ ! -f "${XWPF_FAILOVER_CONF}" ]; then
        echo "无配置"
        return 1
    fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}索引必须是数字${NC}"
        return 1
    fi
    XWPF_FAILOVER_CONF_PATH="${XWPF_FAILOVER_CONF}" \
    XWPF_FAILOVER_RULES_DIR="${RULES_DIR:-/etc/realm/rules}" \
    XWPF_FAILOVER_IDX="$idx" python3 <<'PYEOF'
import json, os, sys
path = os.environ.get("XWPF_FAILOVER_CONF_PATH", "")
rules_dir = os.environ.get("XWPF_FAILOVER_RULES_DIR", "/etc/realm/rules")
idx_s = os.environ.get("XWPF_FAILOVER_IDX", "")
try:
    with open(path) as f:
        pools = json.load(f) or []
except Exception as e:
    print(f"读配置失败: {e}")
    sys.exit(1)
if not pools:
    print("无配置")
    sys.exit(1)
idx = int(idx_s) - 1
if idx < 0 or idx >= len(pools):
    print(f"索引超出范围 (1..{len(pools)})")
    sys.exit(1)
removed = pools.pop(idx)
deleted_files = []
for rid_key in ("primary_rule_id",):
    rid = removed.get(rid_key)
    if isinstance(rid, int):
        f = os.path.join(rules_dir, f"rule-{rid}.conf")
        if os.path.exists(f):
            os.remove(f)
            deleted_files.append(os.path.basename(f))
for rid in (removed.get("backup_rule_ids") or []):
    if isinstance(rid, int):
        f = os.path.join(rules_dir, f"rule-{rid}.conf")
        if os.path.exists(f):
            os.remove(f)
            deleted_files.append(os.path.basename(f))
with open(path, "w") as f:
    json.dump(pools, f, indent=2, ensure_ascii=False)
print(f"已删除池 #{int(idx_s)}: {removed.get('name','?')}")
if deleted_files:
    print(f"  同时清理: {', '.join(deleted_files)}")
print(f"剩余 {len(pools)} 个池")
PYEOF
}

# === Delete ALL pools ===
failover_pool_delete_all() {
    rm -f "${XWPF_FAILOVER_CONF}"
    echo -e "${GREEN}已清空${XWPF_FAILOVER_CONF}${NC}"
}

# === Install/uninstall daemon ===
# cmd/ 源文件目录（已安装布局下为 /usr/local/bin/cmd）
failover_cmd_dir() {
    local base
    base="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    printf '%s\n' "${base}/cmd"
}

# 文件指纹：内容变化即视为新版本
failover_file_fingerprint() {
    local f="$1"
    [ -f "$f" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        wc -c < "$f" | tr -d ' '
    fi
}

# 取 daemon 源码版本：优先 __version__ 常量，取不到则退回文件指纹
failover_source_version() {
    local src="$1"
    [ -f "$src" ] || return 1
    local v
    v=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$src" 2>/dev/null | head -n 1)
    if [ -n "$v" ]; then
        printf '%s\n' "$v"
        return 0
    fi
    failover_file_fingerprint "$src"
}

# 已安装版本（无记录时返回空串）
failover_installed_version() {
    [ -f "${XWPF_FAILOVER_VERSION_FILE}" ] || return 0
    head -n 1 "${XWPF_FAILOVER_VERSION_FILE}" 2>/dev/null | tr -d ' \r\n'
}

# 记录已安装版本
failover_save_version() {
    local ver="$1"
    [ -n "$ver" ] || return 0
    if printf '%s\n' "$ver" > "${XWPF_FAILOVER_VERSION_FILE}" 2>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}警告: 写入版本文件失败: ${XWPF_FAILOVER_VERSION_FILE}${NC}"
    return 0
}

# 已安装但版本落后时重装（例如 fork 更新了 cmd/xwpf-failover.py）
failover_install_check() {
    local src_dir src_py src_ver installed_ver
    src_dir="$(failover_cmd_dir)"
    src_py="${src_dir}/xwpf-failover.py"

    if [ ! -x "${XWPF_FAILOVER_BIN}" ] || [ ! -f "${XWPF_FAILOVER_UNIT}" ]; then
        echo -e "${YELLOW}未检测到 xwpf-failover, 正在安装...${NC}"
        failover_install_files
        return $?
    fi

    installed_ver="$(failover_installed_version)"
    src_ver="$(failover_source_version "$src_py" 2>/dev/null || true)"

    if [ -z "$src_ver" ]; then
        # 拿不到源码版本（离线且缺少 cmd/ 副本），保持现状不重装
        echo -e "${YELLOW}未找到 cmd/xwpf-failover.py 源文件, 跳过版本比对${NC}"
        return 0
    fi

    if [ "$installed_ver" != "$src_ver" ]; then
        echo -e "${YELLOW}检测到 xwpf-failover 版本更新 (${installed_ver:-未记录} -> ${src_ver}), 正在安装...${NC}"
        failover_install_files
        return $?
    fi

    # ★ 已装且版本一致 → **仍要**保证崩溃循环防护 drop-in 在位。
    #   老机器可能是「守护已装、但 drop-in 是人工建的旧版或压根没有」→
    #   只在重装时写 drop-in 会让这些机器永远拿不到产品口径。
    if ! failover_write_crash_loop_guard; then
        return 0
    fi
    systemctl daemon-reload || true

    return 0
}

# === 崩溃循环防护 drop-in（单一真源） ===
# 落点：/etc/systemd/system/xwpf-failover.service.d/10-crash-loop-guard.conf
# ★ 路径写成 ${VAR:-默认} 而不是硬编码：
#   ① 台架/单测可以把落点指到沙箱目录（否则测试会往真机路径写文件）；
#   ② 运维临时换落点时不用改代码。默认仍是标准 systemd drop-in 目录。
XWPF_FAILOVER_DROPIN_DIR="${XWPF_FAILOVER_DROPIN_DIR:-/etc/systemd/system/xwpf-failover.service.d}"
XWPF_FAILOVER_DROPIN_FILE="${XWPF_FAILOVER_DROPIN_FILE:-${XWPF_FAILOVER_DROPIN_DIR}/10-crash-loop-guard.conf}"

# 每次 install / 升级都重写**同一个路径**的这份文件：
#   · 覆盖同名的人工文件 → 两边口径不打架
#   · 别的名字的人工文件 → 仍然生效（用户主权，产品不越权删）
# 先写 .tmp.$$ 再 mv → 不留半成品（systemd 读到半截文件会直接拒载该 drop-in）
failover_write_crash_loop_guard() {
    local dir="${XWPF_FAILOVER_DROPIN_DIR}"
    local file="${XWPF_FAILOVER_DROPIN_FILE}"
    local tmp="${file}.tmp.$$"
    if ! mkdir -p "$dir" 2>/dev/null; then
        echo -e "${YELLOW}警告: 无法创建 drop-in 目录: ${dir}${NC}"
        return 1
    fi
    if ! cat > "$tmp" <<'DROPIN'
# realm-xwPF 崩溃循环防护 drop-in
#
# ★ 本文件由 pf install / 更新中心**自动生成，并在每次 install / 升级时重写同一路径**。
#   手改会在下次 install / 升级时被覆盖 —— 要改本机参数请另起文件名
#   （systemctl edit xwpf-failover），那是你的主权范围。
#
#   · StartLimit* 三件套 = 崩溃循环的物理刹车：60 秒内最多 3 次，超限后 systemd 停手
#   · Restart=always（**不要**改成 on-failure）：
#       守护异常退出时退出码非 0（见 cmd/xwpf-failover.py 的退出码语义），
#       但 always 还有一道纵深 —— 退出码语义万一被改坏，always 仍会把它拉起
#       （响亮地失败），on-failure 会让守护静默消失、转发悄悄断。
#   · 同样的键在主 unit cmd/xwpf-failover.service 里也有一份 → 哪边生效结果相同。
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=3
StartLimitAction=none

[Service]
Restart=always
RestartSec=5s
DROPIN
    then
        rm -f "$tmp" 2>/dev/null
        echo -e "${YELLOW}警告: 写入 drop-in 失败: ${file}${NC}"
        return 1
    fi
    if ! mv -f "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        echo -e "${YELLOW}警告: 安装 drop-in 失败: ${file}${NC}"
        return 1
    fi
    chmod 0644 "$file" 2>/dev/null || true
    return 0
}

failover_install_files() {
    mkdir -p "${XWPF_FAILOVER_CONF_DIR}"
    local src_dir repo_cmd_base name f url need_sync local_ver installed_ver
    src_dir="$(failover_cmd_dir)"
    repo_cmd_base="https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/cmd"

    # Bootstrap 只下载 xwPF.sh + lib/；cmd/ 源文件按 README「按需索取」原则处理：
    # 本地 cmd/ 已有文件优先（离线安装场景需手动放置），
    # 但当本地副本与已安装版本不一致时必须重新下载，否则 fork 更新后的 daemon 永远同步不到 VPS。
    local_ver="$(failover_source_version "${src_dir}/xwpf-failover.py" 2>/dev/null || true)"
    installed_ver="$(failover_installed_version)"
    need_sync=1
    if [ -n "$local_ver" ] && [ "$local_ver" = "$installed_ver" ]; then
        need_sync=0
    fi

    for name in xwpf-failover.py xwpf-failover.service; do
        f="${src_dir}/${name}"
        url="${repo_cmd_base}/${name}"
        mkdir -p "$src_dir"
        if [ -f "$f" ] && [ "$need_sync" -eq 0 ]; then
            continue
        fi
        if (curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 "$url" -o "${f}.tmp" ||
            wget -q --timeout=60 "$url" -O "${f}.tmp") 2>/dev/null && [ -s "${f}.tmp" ]; then
            mv -f "${f}.tmp" "$f"
            echo -e "${GREEN}已下载 cmd/${name}${NC}"
        else
            rm -f "${f}.tmp"
            if [ -f "$f" ]; then
                # 离线环境：下载失败时保留本地已有文件继续安装
                echo -e "${YELLOW}下载失败, 使用本地 cmd/${name}${NC}"
            else
                echo -e "${RED}未找到源文件: ${f}${NC}"
                echo -e "${YELLOW}本地与 GitHub 均无法获取: ${url}${NC}"
                echo -e "${YELLOW}离线环境请按 README 手动放置该文件到 ${src_dir}/ 后重试${NC}"
                return 1
            fi
        fi
    done

    if ! install -m 0755 "${src_dir}/xwpf-failover.py" "${XWPF_FAILOVER_BIN}"; then
        echo -e "${RED}安装失败: ${XWPF_FAILOVER_BIN}${NC}"
        return 1
    fi
    if ! install -m 0644 "${src_dir}/xwpf-failover.service" "${XWPF_FAILOVER_UNIT}"; then
        echo -e "${RED}安装失败: ${XWPF_FAILOVER_UNIT}${NC}"
        return 1
    fi
    # 崩溃循环防护 drop-in：每次 install / 升级都重写同一路径（覆盖同名人工文件）
    failover_write_crash_loop_guard || true
    systemctl daemon-reload || true

    # 记录已安装版本，供下次比对决定是否重装
    failover_save_version "$(failover_source_version "${src_dir}/xwpf-failover.py" 2>/dev/null || true)"

    echo -e "${GREEN}已安装${NC}"
}

# === 守护启动前置校验（单一真源） ===
# 守护必须有可用的 failover.json（至少一个池）才能起来。
# 没有配置就启动 → 守护 exit 1 → Restart=always 每 RestartSec 拉一次 → 崩溃循环。
# 所以在 enable 之前拦下来，并说清楚怎么办。
# 退出码：0 = 可以启动；非 0 = 不能启动。
failover_config_ready() {
    [ -s "${XWPF_FAILOVER_CONF}" ] || return 1
    local py="" c
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1 && "$c" --version >/dev/null 2>&1; then py="$c"; break; fi
    done
    if [ -n "$py" ]; then
        "$py" - "${XWPF_FAILOVER_CONF}" >/dev/null 2>&1 <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, list) and d else 1)
PY
        return $?
    fi
    # 没有可用解释器 → 退化为结构启发式：至少有一个 pool 对象（每个池都有 "name"）
    grep -q '"name"' "${XWPF_FAILOVER_CONF}"
}

failover_service_enable() {
    if ! failover_config_ready; then
        echo -e "${RED}没有可用的主备池配置 (${XWPF_FAILOVER_CONF}) —— 守护启动后会立刻退出${NC}"
        echo -e "${YELLOW}处置: 先用「建立主备池」建至少一个池，再启动守护${NC}"
        return 1
    fi
    systemctl enable --now "${XWPF_FAILOVER_SERVICE}" 2>/dev/null         || (systemctl daemon-reload && systemctl enable --now "${XWPF_FAILOVER_SERVICE}")
}

failover_service_restart() {
    systemctl restart "${XWPF_FAILOVER_SERVICE}"
}

failover_service_stop() {
    systemctl stop "${XWPF_FAILOVER_SERVICE}" 2>/dev/null || true
    systemctl disable "${XWPF_FAILOVER_SERVICE}" 2>/dev/null || true
}

failover_status_header() {
    echo -e "${BLUE}=== xwpf-failover ===${NC}"
    if systemctl is-active "${XWPF_FAILOVER_SERVICE}" >/dev/null 2>&1; then
        echo -e "  ${GREEN}● ACTIVE${NC}"
    else
        echo -e "  ${RED}● INACTIVE${NC}"
    fi
}

failover_log_follow() {
    journalctl -fu "${XWPF_FAILOVER_SERVICE}"
}

failover_log_tail() {
    journalctl -u "${XWPF_FAILOVER_SERVICE}" -n 50 --no-pager
}


# === Direct-mode pool JSON writer ===
# primary/backups are REMOTE addresses; no realm server rule.
# Appended at end of file to avoid colliding with python heredocs elsewhere.
failover_pool_write_json_direct() {
    local name="$1" listen="$2" primary_addr="$3" backup_csv="$4"
    python3 - "$XWPF_FAILOVER_CONF" "$name" "$listen" "$primary_addr" "$backup_csv" <<'PYEOF'
import json, sys, pathlib
conf, name, listen, primary_addr, backup_csv = sys.argv[1:6]
try:
    with open(conf) as f:
        cur = json.load(f) or []
    pools = cur if isinstance(cur, list) else []
except Exception:
    pools = []
backups = [s.strip() for s in backup_csv.split(",") if s.strip()]
pool = {
    "name": name,
    "listen": listen,
    "primary": primary_addr,
    "backups": backups,
    "direct": True,
    "probe": {
        "interval_sec": 4,
        "timeout_sec": 3,
        "fail_threshold": 2,
        "success_threshold": 2,
        "cooldown_sec": 120,
    },
}
replaced = False
for i, p in enumerate(pools):
    if p.get("name") == pool["name"]:
        pools[i] = pool
        replaced = True
        break
if not replaced:
    pools.append(pool)
pathlib.Path(conf).parent.mkdir(parents=True, exist_ok=True)
with open(conf, "w") as f:
    json.dump(pools, f, indent=2, ensure_ascii=False)
print("wrote direct pool '" + pool["name"] + "' to " + conf + " (" + str(len(pools)) + " pool(s))")
PYEOF
}
