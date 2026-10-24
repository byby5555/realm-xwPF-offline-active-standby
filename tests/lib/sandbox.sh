#!/bin/bash
# 测试台架 · 沙箱构建
#
# 契约（每一层都做减法，绝不写仓库、绝不写 /etc、/usr、/var 等真实系统路径）：
#   1) 被测产物 = 仓库工作区 .sh 的 LF 副本
#      仓库 core.autocrlf=true，工作区是 CRLF；直接 source 会让 bash 解析失败/行为异常。
#   2) 路径重定向：副本里所有系统绝对路径改写到沙箱目录（两步 sed：先换占位符，再换真实前缀）。
#   3) root 模拟：Git Bash 的 EUID 是 Windows uid（197610），check_root 会直接 exit 1；
#      沙箱副本里把 EUID 判断改成 false，等价于"以 root 身份运行"。
#   4) 外部依赖打桩：systemctl / nc / curl / wget / realm / journalctl / flock / bc / id
#
# 三处改写都会在报告里列出来，方便审阅"测的到底是不是原实现"。

SBX_ROOT=""
SBX_SRC=""     # LF 原样副本（静态检查用）
SBX_RUN=""     # 路径重定向 + root 模拟后的可执行副本（功能测试用）
SBX_BIN=""     # 假 bin（不含 nc）
SBX_BIN_NC=""  # 假 bin（仅 nc，用例按需加入 PATH）
SBX_MIRROR=""  # 离线镜像（curl/wget 桩从这里取文件）
SBX_LOG_DIR=""
SBX_RULES_DIR=""
SBX_REPO=""

# 需要改写到沙箱的绝对路径前缀表（长的排前面，避免短前缀误伤长前缀）
# 格式：<原始前缀> <沙箱内相对目录>
SBX_PATH_MAP=(
    "/etc/os-release|os-release"
    "/etc/lsb-release|lsb-release"
    "/etc/debian_version|debian_version"
    "/etc/alpine-release|alpine-release"
    "/etc/port-traffic-dog|port-traffic-dog"
    "/etc/systemd/system|systemd"
    "/etc/sysctl.d|sysctl.d"
    "/etc/init.d|init.d"
    "/etc/xwpf|xwpf"
    "/etc/realm|realm"
    "/usr/local/realm|usr.local.realm"
    "/usr/local/sbin|usr.local.sbin"
    "/usr/local/bin|usr.local.bin"
    "/usr/sbin|usr.sbin"
    "/usr/bin|usr.bin"
    "/sbin|sbin"
    "/opt/bin|opt.bin"
    "/root/bin|root.bin"
    "/var/lib/realm|var.lib.realm"
    "/var/lock|var.lock"
    "/var/log|var.log"
    "/var/tmp|var.tmp"
    "/root|root"
    "/tmp|tmp"
    "/bin|bin"
)

sbx_init() {
    local repo="$1"
    SBX_REPO="$repo"

    SBX_ROOT="${SBX_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/xwpf-sbx.XXXXXX")}"
    SBX_SRC="$SBX_ROOT/src"
    SBX_RUN="$SBX_ROOT/run"
    SBX_BIN="$SBX_ROOT/bin"
    SBX_BIN_NC="$SBX_ROOT/bin_nc"
    SBX_MIRROR="$SBX_ROOT/mirror"
    SBX_LOG_DIR="$SBX_ROOT/logs"
    SBX_RULES_DIR="$SBX_ROOT/realm/rules"

    mkdir -p "$SBX_SRC" "$SBX_RUN" "$SBX_BIN" "$SBX_BIN_NC" "$SBX_MIRROR" \
             "$SBX_LOG_DIR" "$SBX_RULES_DIR" "$SBX_ROOT/cases" \
             "$SBX_ROOT/systemd" "$SBX_ROOT/usr.local.bin" "$SBX_ROOT/usr.local.bin/lib" \
             "$SBX_ROOT/usr.local.bin/cmd" "$SBX_ROOT/xwpf" "$SBX_ROOT/realm/health" \
             "$SBX_ROOT/var.lock" "$SBX_ROOT/tmp" "$SBX_ROOT/root" "$SBX_ROOT/var.log"

    # 假的 os-release（detect_system 需要）
    cat > "$SBX_ROOT/os-release" <<'EOF'
NAME="Debian GNU/Linux"
VERSION_ID="12"
ID=debian
PRETTY_NAME="Debian GNU/Linux 12 (sandbox)"
EOF

    sbx_build_lf_copies
    sbx_build_mirror
    sbx_install_shims
    sbx_export_env
}

# 仓库里被跟踪的 .sh（工作区副本，CRLF）→ LF 副本
sbx_build_lf_copies() {
    local rel src dst
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        src="$SBX_REPO/$rel"
        [ -f "$src" ] || continue
        dst="$SBX_SRC/$rel"
        mkdir -p "$(dirname "$dst")"
        tr -d '\r' < "$src" > "$dst"
        # 可执行副本：路径重定向 + root 模拟
        dst="$SBX_RUN/$rel"
        mkdir -p "$(dirname "$dst")"
        sbx_redirect "$SBX_SRC/$rel" "$dst"
    done < <(cd "$SBX_REPO" && git ls-files -- '*.sh' '*.py' '*.service')
}

# 路径重定向：先换成 @SBX@ 占位符（避免真实路径里含 /tmp 被二次替换），再换真实前缀
sbx_redirect() {
    local src="$1" dst="$2"
    local args=() entry from to
    for entry in "${SBX_PATH_MAP[@]}"; do
        from="${entry%%|*}"
        to="${entry##*|}"
        args+=(-e "s|${from}|@SBX@${to}|g")
    done
    # root 模拟：EUID 判断改成 false
    args+=(-e 's|\[\[ \$EUID -ne 0 \]\]|false|g')
    sed "${args[@]}" "$src" | sed -e "s|@SBX@|${SBX_ROOT}/|g" > "$dst"
}

# 离线镜像：把 LF 副本按仓库相对路径摆好，curl/wget 桩从这里取
sbx_build_mirror() {
    local rel
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        mkdir -p "$SBX_MIRROR/$(dirname "$rel")"
        cp "$SBX_SRC/$rel" "$SBX_MIRROR/$rel"
    done < <(cd "$SBX_REPO" && git ls-files -- '*.sh' '*.py' '*.service')
}

sbx_install_shims() {
    local shim
    for shim in "$SBX_REPO"/tests/shims/*; do
        [ -f "$shim" ] || continue
        chmod +x "$shim"
        cp "$shim" "$SBX_BIN/"
    done
    # nc 单独放一份：用例默认不放进 PATH，模拟"机器上没装 nc"
    if [ -f "$SBX_BIN/nc" ]; then
        cp "$SBX_BIN/nc" "$SBX_BIN_NC/nc"
        chmod +x "$SBX_BIN_NC/nc"
    fi
}

sbx_export_env() {
    export SBX_ROOT SBX_SRC SBX_RUN SBX_BIN SBX_BIN_NC SBX_MIRROR SBX_LOG_DIR SBX_RULES_DIR SBX_REPO
    export SBX_NC_DOWN="$SBX_ROOT/nc_down.txt"
    : > "$SBX_NC_DOWN"
    export PATH="$SBX_BIN:$PATH"
}

# 用例专用 PATH：含 / 不含 nc
sbx_path_without_nc() {
    PATH="$SBX_BIN:/usr/bin:/bin:/usr/local/bin"
    export PATH
}

sbx_path_with_nc() {
    PATH="$SBX_BIN:$SBX_BIN_NC:/usr/bin:/bin:/usr/local/bin"
    export PATH
}

# 沙箱越界扫描：副本里还剩哪些真实系统绝对路径（只读路径白名单除外）
sbx_escape_scan() {
    local f
    grep -rnoE '"/(etc|usr|var|opt|root|sbin|bin)/[^"]*"' "$SBX_RUN" 2>/dev/null |
        grep -vE '/(etc/(passwd|hosts|resolv\.conf|localtime|nsswitch\.conf|mtab|group|shadow))' |
        sed "s|^$SBX_ROOT/||" | sort -u
}

# 统计文件里的 CR 字节数。
# 注意：MSYS 的 grep 对含 CR 的模式不可靠（实测 `printf 'a\r\n' | grep -c $'\r'` 返回 0），
# 所以行尾一律用 od 数字节，不靠 grep 字符类。
sbx_count_cr() {
    od -An -v -tx1 "$1" 2>/dev/null | tr -s ' ' '\n' | grep -c '^0d$'
}

# 统计文件里 CRLF 结尾的行数
sbx_count_crlf() {
    od -An -v -tx1 "$1" 2>/dev/null | tr -s ' ' '\n' |
        awk 'BEGIN{prev="";c=0} {if(prev=="0d" && $0=="0a") c++; prev=$0} END{print c+0}'
}
