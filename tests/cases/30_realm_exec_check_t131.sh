#!/bin/bash
# 用例组 30 · realm 二进制「装得上、跑不起来」的护栏
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   **装完的 realm 二进制必须能在本机执行。**
#
#   ★ 起因（真机实测：VPS 上用 Docker 起一台干净 Debian 12 容器，
#     跑仓库的官方安装脚本）：
#     GitHub 上的 realm v2.9.6 需要 **glibc ≥ 2.38**，Debian 12 只有 **2.36**
#     ⇒ 二进制**装得上、跑不起来**：
#       /usr/local/bin/realm: /lib/x86_64-linux-gnu/libc.so.6:
#       version `GLIBC_2.38' not found (required by /usr/local/bin/realm)
#     ★ 原实现只 `cp + chmod` 就打印「✓ realm 安装成功」，
#       后面服务启动失败也照样一路打印「=== 安装完成！ ===」
#       ⇒ 用户看到「装好了」，实际**一个转发都没跑**；
#         而且**没有任何一条报错指向真因**（只有一句「服务启动失败」）。
#     ⇒ 修法：装完当场执行一次；跑不起来就**明确报错 + 给出方向**并中止安装。
#
# ★ 平台差异（写断言时必须避开，否则这条用例换个平台就假红）：
#   MSYS2（Windows 上的 Git Bash）用「有没有 shebang」模拟执行位
#   ⇒ 「没执行权限」「非 ELF 垃圾文件」这两档在 Windows 上**表现不同**。
#   ⇒ 断言只钉**两个平台一致**的三档：
#     可执行的假 realm（rc=0）/ 坏解释器（rc≠0）/ 文件不存在（rc≠0）。

# ── 修复前的冻结点（负向对照锚点）────────────────────────────────
#   realm-exec-pre = 加上「二进制可执行性校验」之前的那一版 main
_T30_PRE_SHA="$(sbx_history_sha realm-exec-pre 2>/dev/null || true)"
[ -n "$_T30_PRE_SHA" ] || _T30_PRE_SHA="7f6ee54"

# 取「修复前那一版」的整份 lib/ 文件树（负向对照的被测对象）
#   ★ 必须走 sbx_redirect：老树里写死的是**生产路径**（/etc/realm、/usr/local/bin …），
#     不重定向就会读真实系统目录（Linux 上就是生产目录）⇒ 越界。
_T30_prepare_pre_tree() {
    local dest="$1" f raw
    rm -rf "$dest" 2>/dev/null
    mkdir -p "$dest" 2>/dev/null || return 1
    for f in $(cd "$SBX_REPO" && git ls-tree -r --name-only "$_T30_PRE_SHA" 2>/dev/null); do
        case "$f" in
            lib/*.sh) ;;
            *) continue ;;
        esac
        mkdir -p "$dest/$(dirname "$f")" 2>/dev/null
        raw="$dest/.raw.$$"
        (cd "$SBX_REPO" && git show "$_T30_PRE_SHA:$f" 2>/dev/null) > "$raw" || { rm -f "$raw"; return 1; }
        sbx_redirect "$raw" "$dest/$f" || { rm -f "$raw"; return 1; }
        rm -f "$raw"
    done
    [ -f "$dest/lib/core.sh" ] || return 1
    [ -f "$dest/lib/realm.sh" ] || return 1
    return 0
}

# 造一个「装上去但跑不起来」的 realm 安装包（tar.gz，内含 realm 文件）
#   ★ 坏解释器这一档在 Linux 与 MSYS2 上**表现一致**（都是 bad interpreter）⇒ 可跨平台断言。
_T30_make_broken_pkg() {
    local dir="$1"
    rm -rf "$dir" 2>/dev/null
    mkdir -p "$dir/build" 2>/dev/null || return 1
    printf '#!/nonexistent/interp\necho realm\n' > "$dir/build/realm"
    chmod +x "$dir/build/realm" 2>/dev/null
    ( cd "$dir/build" && tar -czf "$dir/realm-bad.tar.gz" realm ) 2>/dev/null || return 1
    [ -s "$dir/realm-bad.tar.gz" ]
}

# ══════════════════════════════════════════════════════════════
# T131 · 判据本体：realm_binary_exec_check 必须会拒绝跑不了的二进制
# ══════════════════════════════════════════════════════════════
case_T131_realm_exec_check_judge() {
    h_case_begin "T131" "realm 二进制可执行性判据：跑不了的必须判红（不能一路放行）" \
        "冻结态 lib/realm.sh 的 realm_binary_exec_check（纯函数，不依赖全局状态）" \
        "realm_binary_exec_check <路径>（可执行的假 realm / 坏解释器 / 不存在）" \
        "可执行 ⇒ rc=0；坏解释器 / 不存在 ⇒ rc≠0；负向对照：判据被退化成「永远放行」时必须被抓到"

    # ── 0. 静态：函数必须存在 ──
    local has_fn=0
    grep -q '^realm_binary_exec_check() {' "$SBX_SRC/lib/realm.sh" 2>/dev/null && has_fn=1
    h_check_eq "1" "$has_fn" "冻结态 lib/realm.sh 里存在 realm_binary_exec_check"

    # ── 1. 行为：三种形态各判一次 ──
    local work="$SBX_ROOT/t131_work"
    rm -rf "$work" 2>/dev/null
    mkdir -p "$work" 2>/dev/null

    local out
    out=$(_run_in_sandbox '
        d="$2"
        source "$1/lib/core.sh" >/dev/null
        source "$1/lib/realm.sh" >/dev/null
        if declare -F realm_binary_exec_check >/dev/null 2>&1; then
            echo "FUNC_OK=1"
        else
            echo "FUNC_MISSING=1"
        fi
        printf "#!/bin/bash\necho realm\n" > "$d/good"; chmod +x "$d/good"
        printf "#!/nonexistent/interp\necho realm\n" > "$d/bad"; chmod +x "$d/bad"
        realm_binary_exec_check "$d/good" >/dev/null 2>&1; echo "GOOD_RC=$?"
        realm_binary_exec_check "$d/bad"  >/dev/null 2>&1; echo "BAD_RC=$?"
        realm_binary_exec_check "$d/nope" >/dev/null 2>&1; echo "MISSING_RC=$?"
        diag=$(realm_binary_exec_check "$d/bad" 2>&1 >/dev/null)
        echo "DIAG=$diag"
    ' "$work")
    h_log "判据输出: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"

    h_check_contains "$out" "FUNC_OK=1" "realm_binary_exec_check 确实存在于冻结态 lib/realm.sh"

    # 可执行的假 realm ⇒ 放行
    if printf '%s' "$out" | grep -q 'GOOD_RC=0'; then
        h_pass "能执行的 realm 被放行（GOOD_RC=0）"
    else
        h_fail "能执行的 realm 竟然没被放行（判据写反了）"
    fi
    # 坏解释器 ⇒ 必须拒绝
    if printf '%s' "$out" | grep -q 'BAD_RC=0'; then
        h_fail "跑不了的 realm（坏解释器）被判据放行 ⇒ 安装会报「安装成功」但转发根本没跑"
    else
        h_pass "跑不了的 realm（坏解释器）被拒绝（BAD_RC≠0）"
    fi
    # 文件不存在 ⇒ 必须拒绝
    if printf '%s' "$out" | grep -q 'MISSING_RC=0'; then
        h_fail "不存在的文件被判据放行"
    else
        h_pass "不存在的文件被拒绝（MISSING_RC≠0）"
    fi
    # 诊断信息要含真实报错（用户要靠它定位）
    # ★ 措辞**随平台不同**：MSYS2 说「bad interpreter」，Linux 说「cannot execute: required file not found」
    #   ⇒ 只钉「报错里提到了那个二进制」这一层，两平台都成立。
    if printf '%s' "$out" | grep -qiE 'bad interpreter|cannot execute|not found|exec format'; then
        h_pass "诊断信息里带上了真实报错（执行失败原因）"
    else
        h_fail "诊断信息里没有真实报错 ⇒ 用户无从判断是 glibc 还是架构问题"
    fi

    # ── 2. 负向对照（注入式退化）：判据被改成「永远放行」⇒ 必须被抓到 ──
    #   这一条证明上面那个「BAD_RC≠0」不是恒绿。
    local badlib="$SBX_ROOT/t131_badlib"
    rm -rf "$badlib" 2>/dev/null
    mkdir -p "$badlib" 2>/dev/null
    cp -r "$SBX_RUN/lib" "$badlib/" 2>/dev/null
    awk '
        /^realm_binary_exec_check\(\) \{/ { inf=1 }
        {
            if (inf && /if \[ "\$rc" -ne 0 \]; then/) {
                print "    if false; then  # T131-NEG: 永远放行"
                hit=1
                inf=0
                next
            }
            print
        }
    ' "$SBX_RUN/lib/realm.sh" > "$badlib/lib/realm.sh" 2>/dev/null
    local n_inj
    n_inj=$(grep -c 'T131-NEG' "$badlib/lib/realm.sh" 2>/dev/null); n_inj=${n_inj:-0}
    h_check_eq "1" "$n_inj" "负向对照的注入点命中（退化手法生效）"

    local bad_out
    # ★★ source 的目标必须是**退化副本**（$2），不是 runner 注入的冻结点新树（$1）
    #   —— `_run_in_sandbox` 的 $1 永远是冻结点新树，拿它 source 等于「退化没生效」
    #   （第一次跑就是这样：退化后仍然拒绝 ⇒ 负向对照判红 ⇒ 对照其实没在对照）。
    bad_out=$(_run_in_sandbox '
        libroot="$2"
        d="$3"
        source "$libroot/lib/core.sh" >/dev/null
        source "$libroot/lib/realm.sh" >/dev/null
        printf "#!/nonexistent/interp\necho realm\n" > "$d/bad2"; chmod +x "$d/bad2"
        realm_binary_exec_check "$d/bad2" >/dev/null 2>&1; echo "BAD_RC=$?"
    ' "$badlib" "$work")
    h_log "退化后输出: $(printf '%s' "$bad_out" | tr '\n' ' ' | cut -c1-160)"
    if printf '%s' "$bad_out" | grep -q 'BAD_RC=0'; then
        h_pass "负向对照：判据退化成「永远放行」后**确实放行了坏二进制** ⇒ 上面那条断言有判别力"
    else
        h_fail "负向对照失效：退化后仍然拒绝（退化没生效或断言方向错了）"
    fi

    rm -rf "$work" "$badlib" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════
# T132 · install_realm 的下载路径必须真的调这个校验（端到端）
# ══════════════════════════════════════════════════════════════
case_T132_install_rejects_unrunnable_binary() {
    h_case_begin "T132" "install 装上跑不了的 realm 时必须中止并报错，不许报「安装成功」" \
        "冻结态 lib/realm.sh 的 install_realm（离线安装路径：喂一个含坏 realm 的 tar.gz）" \
        "install_realm（stdin 喂离线包路径）" \
        "退出码非 0 + 输出含「无法在本机执行」+ **不得**出现「✓ realm 安装成功」；负向对照：修复前的实现必须报成功"

    # ── 0. 静态：调用点必须在「✓ realm 安装成功」之前 ──
    local body
    body=$(awk '/^install_realm\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SBX_SRC/lib/realm.sh" 2>/dev/null)
    local n_check n_ok_line
    n_check=$(printf '%s' "$body" | grep -c 'realm_binary_exec_check')
    n_ok_line=$(printf '%s' "$body" | grep -n 'realm 安装成功' | head -1 | cut -d: -f1)
    h_log "install_realm 里 realm_binary_exec_check 出现次数=$n_check；「realm 安装成功」在第 $n_ok_line 行"
    h_check_ge "1" "$n_check" "install_realm 里调用了 realm_binary_exec_check"
    if [ -n "$n_ok_line" ]; then
        local n_call_line
        n_call_line=$(printf '%s' "$body" | grep -n 'realm_binary_exec_check "' | head -1 | cut -d: -f1)
        if [ -n "$n_call_line" ] && [ "$n_call_line" -lt "$n_ok_line" ]; then
            h_pass "可执行性校验发生在「✓ realm 安装成功」之前（$n_call_line < $n_ok_line）"
        else
            h_fail "可执行性校验没有排在「✓ realm 安装成功」之前（顺序反了 ⇒ 报错打在成功之后）"
        fi
    else
        h_fail "install_realm 里找不到「realm 安装成功」那行（结构变了，断言要重写）"
    fi

    # ── 1. 行为：喂一个「装上去但跑不起来」的包 ⇒ 必须中止 ──
    local pkg="$SBX_ROOT/t132_pkg"
    if ! _T30_make_broken_pkg "$pkg"; then
        h_fail "造不出「跑不了的 realm」安装包 —— 场景不成立"
        return 1
    fi

    local out
    out=$(_run_in_sandbox '
        tb="$2"
        source "$1/lib/core.sh"  >/dev/null
        source "$1/lib/health.sh" >/dev/null
        source "$1/lib/rules.sh" >/dev/null
        source "$1/lib/realm.sh"  >/dev/null
        source "$1/lib/ui.sh"     >/dev/null
        # ★★ 必须先删掉 REALM_PATH ⇒ 强制走**下载安装**那条路径。
        #   否则沙箱里若已存在 realm（别的用例留下的桩），install 会走
        #   「已安装」分支 ⇒ 根本不会执行新装的那个二进制 ⇒ 断言测的是另一条路径。
        #   （实测：Linux 上就是这样红过一次。）
        rm -f "$REALM_PATH"
        # 离线安装路径：ui_read_default 从 stdin 读包路径
        ( printf "%s\n" "$tb" | install_realm ) 2>&1
        echo "RC=$?"
    ' "$pkg/realm-bad.tar.gz")
    h_log "install 输出（尾部）: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-260)"

    # ★ 先证前提：这一轮确实走了「下载安装」路径（否则下面的断言全在测另一条路径）
    if printf '%s' "$out" | grep -q '正在解压安装'; then
        h_pass "这一轮确实走了「下载安装」路径"
    else
        h_fail "没有走「下载安装」路径（沙箱里已有 realm？）⇒ 下面几条断言测的不是这条路径"
    fi

    if printf '%s' "$out" | grep -q 'RC=0'; then
        h_fail "装上跑不了的 realm 后 install 仍然返回 0（调用方会以为成功了）"
    else
        h_pass "装上跑不了的 realm 后 install 返回非 0"
    fi
    if printf '%s' "$out" | grep -q '无法在本机执行'; then
        h_pass "install 明确报出「无法在本机执行」（用户能看到真因）"
    else
        h_fail "install 没有说清「二进制跑不起来」⇒ 用户只看到一句无关的报错"
    fi
    if printf '%s' "$out" | grep -q 'realm 安装成功'; then
        h_fail "install 仍打印了「✓ realm 安装成功」⇒ 装了个跑不起来的二进制还报成功"
    else
        h_pass "install 没有打印「✓ realm 安装成功」"
    fi
    # 报错要指向方向（glibc / 架构 / 损坏）
    if printf '%s' "$out" | grep -qi 'glibc'; then
        h_pass "报错里点名了 glibc（用户知道该换系统还是该换二进制）"
    else
        h_fail "报错里没有提到 glibc ⇒ 用户无从判断方向"
    fi

    # ── 2. 负向对照：修复前的真实实现跑同一场景 ⇒ 必须报成功（缺陷复现）──
    local pre_tree="$SBX_ROOT/t132_pre"
    if _T30_prepare_pre_tree "$pre_tree"; then
        # ★ 对照有效性自检：老树里**确实没有**这个校验
        local pre_has_fn=0
        grep -q '^realm_binary_exec_check() {' "$pre_tree/lib/realm.sh" 2>/dev/null && pre_has_fn=1
        h_check_eq "0" "$pre_has_fn" "对照有效性自检：修复前的 lib/realm.sh 里没有 realm_binary_exec_check"

        local pre_out
        pre_out=$(bash -c '
            tb="$2"
            source "$1/lib/core.sh"  >/dev/null
            source "$1/lib/health.sh" >/dev/null
            source "$1/lib/rules.sh" >/dev/null
            source "$1/lib/realm.sh"  >/dev/null
            source "$1/lib/ui.sh"     >/dev/null
            rm -f "$REALM_PATH"
            ( printf "%s\n" "$tb" | install_realm ) 2>&1
            echo "RC=$?"
        ' _ "$pre_tree" "$pkg/realm-bad.tar.gz" 2>&1)
        h_log "修复前输出（尾部）: $(printf '%s' "$pre_out" | tr '\n' ' ' | cut -c1-260)"
        # ★ 对照也必须走下载路径，否则「老实现报成功」就成了假象
        if printf '%s' "$pre_out" | grep -q '正在解压安装'; then
            h_pass "负向对照同样走了「下载安装」路径"
        else
            h_fail "负向对照没走下载路径 ⇒ 对照无效"
        fi
        if printf '%s' "$pre_out" | grep -q 'realm 安装成功'; then
            h_pass "负向对照：修复前的实现**照样报「✓ realm 安装成功」** ⇒ 上面那几条断言确实有判别力"
        else
            h_fail "负向对照失效：修复前的实现没有报成功（对照选错了树）"
        fi
    else
        h_fail "取不到修复前实现的 lib/（sha $_T30_PRE_SHA 不可达）—— 负向对照无法执行"
    fi

    rm -rf "$pkg" "$pre_tree" 2>/dev/null
}
