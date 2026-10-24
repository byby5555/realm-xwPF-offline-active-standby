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
SBX_RAW=""     # 冻结态原始内容（git show 输出，未去 CR）—— 行尾断言的权威来源
SBX_SRC=""     # 冻结态 LF 副本（静态检查用）
SBX_RUN=""     # 冻结态 + 路径重定向 + root 模拟后的可执行副本（功能测试用）
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
    "/opt/realm|opt.realm"
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
    SBX_RAW="$SBX_ROOT/raw"
    SBX_SRC="$SBX_ROOT/src"
    SBX_RUN="$SBX_ROOT/run"
    SBX_BIN="$SBX_ROOT/bin"
    SBX_BIN_NC="$SBX_ROOT/bin_nc"
    SBX_MIRROR="$SBX_ROOT/mirror"
    SBX_LOG_DIR="$SBX_ROOT/logs"
    SBX_RULES_DIR="$SBX_ROOT/realm/rules"

    mkdir -p "$SBX_RAW" "$SBX_SRC" "$SBX_RUN" "$SBX_BIN" "$SBX_BIN_NC" "$SBX_MIRROR" \
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

    sbx_export_frozen_tree
    sbx_build_run_copies
    sbx_build_mirror
    sbx_install_shims
    sbx_export_env
    sbx_write_manifest
}

# 基线快照：把「这次到底测了哪一份代码」钉死
# ★ 第 2 轮起，快照锚定的是 BASE_SHA（冻结点），不是工作区 HEAD。
#   仓库多人并行改动 → HEAD 会在跑批期间漂移；冻结点由 Chief 指定，跑批期间不变。
sbx_write_manifest() {
    local out="$SBX_ROOT/manifest.txt"
    {
        echo "# 被测产物基线快照（冻结点机制）"
        echo "repo        : $SBX_REPO"
        echo "BASE_SHA    : $BASE_SHA"
        echo "BASE_SHA 全 : $(git -C "$SBX_REPO" rev-parse "$BASE_SHA" 2>/dev/null)"
        echo "BASE 标题   : $(git -C "$SBX_REPO" log -1 --format='%ad %s' "$BASE_SHA" 2>/dev/null)"
        echo "harness     : $HARNESS_VERSION"
        echo "time        : $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "sandbox     : $SBX_ROOT"
        echo
        echo "--- 当前工作区 HEAD（仅供对照，不作为被测产物）---"
        echo "head        : $(cd "$SBX_REPO" && git rev-parse HEAD 2>/dev/null)"
        echo
        echo "--- git status --porcelain（跑批时刻的工作区状态）---"
        (cd "$SBX_REPO" && git status --porcelain 2>/dev/null)
        echo
        echo "--- sha256（冻结态原始 blob = 本次被测产物，git show \$BASE_SHA:<path>）---"
        local rel
        while IFS= read -r rel; do
            [ -z "$rel" ] && continue
            [ -f "$SBX_RAW/$rel" ] || continue
            printf '%s  %s\n' "$(sha256sum "$SBX_RAW/$rel" | cut -d' ' -f1)" "$rel"
        done < <(git -C "$SBX_REPO" ls-tree -r --name-only "$BASE_SHA")
    } > "$out"
}

# 冻结态导出（★ 第 2 轮重点）
# 被测产物一律来自 `git show $BASE_SHA:<path>`，**不碰工作区文件**。
# 原因：仓库多人并行改动，工作区随时在变 —— 第 1 轮出现过「第 1 轮红、后 2 轮绿」的假抖动，
# 根因就是第 2/3 轮读到的已经是改写后的工作区文件。
# 产物分三层：
#   $SBX_RAW  git show 的原始字节（行尾断言的权威来源）
#   $SBX_SRC  去 CR 的 LF 副本（静态检查用）
#   $SBX_RUN  再加路径重定向 + root 模拟（功能测试用）
sbx_export_frozen_tree() {
    local rel n_exported=0
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        case "$rel" in
            *.sh|*.py|*.service|*.md) ;;
            *) continue ;;
        esac
        mkdir -p "$SBX_RAW/$(dirname "$rel")" "$SBX_SRC/$(dirname "$rel")"
        # ★ 用 `git -C "$SBX_REPO"`：**不能依赖当前工作目录**。
        #   起因（第 13 轮实测踩到）：台架被从**仓库外面**启动时
        #   （例如 `bash /path/to/clone/tests/run_tests.sh`），
        #   裸 `git show` 会在「不是 git 仓库」的目录里跑 →
        #   **冻结态导出 0 个文件** → 每条用例都因为「函数不存在 / 文件缺失」而红
        #   → 满屏红看起来像「产品全坏」，实际是**台架自己错了**。
        #   这个形态必须从根上堵死：导出与 cwd 解耦 + 导出为空就硬失败。
        if git -C "$SBX_REPO" show "$BASE_SHA:$rel" > "$SBX_RAW/$rel" 2>/dev/null; then
            tr -d '\r' < "$SBX_RAW/$rel" > "$SBX_SRC/$rel"
            n_exported=$((n_exported + 1))
        else
            echo "警告: 冻结态里取不到 $rel" >&2
        fi
    done < <(git -C "$SBX_REPO" ls-tree -r --name-only "$BASE_SHA")

    # ── 硬护栏：冻结态导出为空 = 台架自身错误，不许当成「用例红」────────
    #   被测产物一份都没导出来时，所有用例都会以「文件缺失 / 函数不存在」的形式红，
    #   那个形态**会被误读成产品全坏**（实际是被测产物根本没进来）。
    #   ⇒ 必须响亮地以退出码 2 停下（台架配置/环境错误，不是产品回归）。
    if [ "$n_exported" -eq 0 ]; then
        echo "==============================================================" >&2
        echo " ✗ 台架预检自身异常：冻结态导出 **0 个文件**" >&2
        echo "==============================================================" >&2
        echo "后果：被测产物一份都没进沙箱 → 每条用例都会以「文件缺失 / 函数不存在」" >&2
        echo "      的形式红 —— 那个形态会被误读成**产品全坏**，实际是**台架自己错了**。" >&2
        echo "排查：① 冻结点 $BASE_SHA 在仓库 $SBX_REPO 里可达吗" >&2
        echo "      ② 启动目录对吗（本台架的 git 调用已与 cwd 解耦，这里是双保险）" >&2
        echo "      ③ 仓库里 .sh/.py/.service/.md 文件是不是一个都没有" >&2
        echo "汇总: 冻结态导出为空 —— 未跑任何用例，退出码 2（台架自身错误）" >&2
        exit 2
    fi
}

# 可执行副本：只有 .sh 需要路径重定向（.py/.service 是被下载/被 systemd 读的）
sbx_build_run_copies() {
    local rel
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        case "$rel" in
            *.sh) ;;
            *) continue ;;
        esac
        [ -f "$SBX_SRC/$rel" ] || continue
        mkdir -p "$(dirname "$SBX_RUN/$rel")"
        sbx_redirect "$SBX_SRC/$rel" "$SBX_RUN/$rel"
    done < <(git -C "$SBX_REPO" ls-tree -r --name-only "$BASE_SHA")
}

# 离线镜像：模拟 GitHub raw 上的内容 = 冻结态的仓库文件（同样只来自 git show）
sbx_build_mirror() {
    local rel
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        [ -f "$SBX_SRC/$rel" ] || continue
        mkdir -p "$SBX_MIRROR/$(dirname "$rel")"
        cp "$SBX_SRC/$rel" "$SBX_MIRROR/$rel"
    done < <(git -C "$SBX_REPO" ls-tree -r --name-only "$BASE_SHA")
}

# 路径重定向：先换成 @SBX@ 占位符（避免真实路径里含 /tmp 被二次替换），再换真实前缀
# 用法：sbx_redirect <源> <目标> [沙箱基准目录]（默认 $SBX_ROOT）
sbx_redirect() {
    local src="$1" dst="$2" base="${3:-$SBX_ROOT}"
    local args=() entry from to
    for entry in "${SBX_PATH_MAP[@]}"; do
        from="${entry%%|*}"
        to="${entry##*|}"
        args+=(-e "s|${from}|@SBX@${to}|g")
    done
    # root 模拟：EUID 判断改成 false
    args+=(-e 's|\[\[ \$EUID -ne 0 \]\]|false|g')
    sed "${args[@]}" "$src" | sed -e "s|@SBX@|${base}/|g" > "$dst"
}

sbx_install_shims() {
    # 桩来自**工作区**（台架自己的代码，不是被测产物）—— 这是有意的：
    # 被测产物冻结，测试台架永远用最新版本。
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
    # ★ 沙箱里必须有一份**真 bash**
    #   路径映射表里有 "/bin|bin" ⇒ 被测产物的 shebang（#!/bin/bash）会被
    #   重定向成 "#!<沙箱>/bin/bash" ⇒ 那个解释器**并不存在** ⇒ 直接执行报
    #   "bad interpreter"（rc=126）。
    #   ★ 产品里有一条**直接执行已装脚本**的自检：
    #     lib/update.sh 的 "${INSTALL_DIR}/xwPF.sh" --help
    #   ⇒ 沙箱里没有 bash ⇒ 自检必败 ⇒ 被误判成「脚本包更新失败」
    #     ⇒ 自动回滚 ⇒ 升路径用例恒红，而且根因离症状很远（看着像下载/版本问题）。
    #   ⇒ 沙箱提供一份真 bash：路径映射管的是「被测产物里引用的路径」，
    #     解释器本身必须是真能跑的那个。
    #   ★ 不进越界扫描范围（sbx_escape_scan 只扫 $SBX_RUN）。
    local _bash
    _bash=$(command -v bash 2>/dev/null)
    if [ -n "$_bash" ] && [ -x "$_bash" ]; then
        cp -f "$_bash" "$SBX_BIN/bash" 2>/dev/null && chmod +x "$SBX_BIN/bash" 2>/dev/null
    fi
}

sbx_export_env() {
    export SBX_ROOT SBX_RAW SBX_SRC SBX_RUN SBX_BIN SBX_BIN_NC SBX_MIRROR SBX_LOG_DIR SBX_RULES_DIR SBX_REPO
    export BASE_SHA HARNESS_VERSION
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
#
# ★ 第 3 轮：/opt/realm 改成**重定向**而不是加白名单。
#   它出现在 xwFailover.sh 的 find_file_path 的 common_paths 候选数组里
#   （只有 `[ -f "$path" ]` 读判断，是只读探测点，不是写目标）。
#   但 /etc/realm、/var/lib/realm、/usr/local/realm、/tmp 都已经在路径重定向表里，
#   只有 /opt/realm 漏网 → 扫描器永远报「越界残留 1 处」。
#   加白名单 = 把这个口子永久豁免；改成重定向 = 沙箱彻底密闭，扫描器回到 0 处，
#   以后任何**新的**真实越界仍然会被抓到。
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
