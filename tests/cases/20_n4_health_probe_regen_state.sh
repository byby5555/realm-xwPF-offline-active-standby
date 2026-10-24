#!/bin/bash
# 用例组 20 · N4：健康探测端（生成物重新生成 + 状态文件口径 + 继承键）
#
# ── 背景（Chief + 小编 10/24 派单）────────────────────────────────
#   产品删掉了「进程级主备池整块」（2beb7bd：lib/failover.sh、cmd/xwpf-failover.* 已删），
#   **健康探测成了唯一的切换驱动** → N4 优先级最高。
#   真机踩过的坑：旧版生成物每 4 秒打「健康检查完成」、退出码 0，
#   但**最后检查时间停在 7 小时前** → 探测端根本没在工作，全程无报错。
#   根因：装/升级路径**一个都不经过**生成写点 → health_check.sh 不重新生成 = 静默失效。
#
# ── 覆盖 ────────────────────────────────────────────────────────
#   T85 生成物必须重新生成：装/升级路径跑完后 health_check.sh 的**内容或 mtime 必须变**，
#       且生成物与 lib/health.sh 真源的生成物**逐字一致**（sha256 级，不是目测）。
#   T86 状态文件每轮原子重建：只留当前规则的行；删掉的规则不留孤儿行；
#       每行要么完整要么不存在（没有半截行）。
#   T87 跨轮继承的键 = **RULE_ID + 目标地址**（组合键）：
#       同 ID 新建（地址不同）不得继承老 failed；**换了 RULE_ID、地址相同也不许拿别人的那行**（不串）。
#   T88 负向对照：同一套判定器在**缺陷版**上必须判红、在「老实现本来是对的」那版上必须判绿。
#
# ── 历史锚点（单一真源 tests/cases/00_common.sh 的 sbx_required_history_shas；不写死 sha）──
#   n4-pre      = f59e389  T85/T86 的缺陷版：装/升级不重生成 + 状态文件不原子重建
#   inherit-pre = 9dc5b56  T87/T88 的缺陷版：health_status_find_row **只比对目标地址、没看 RULE_ID**
#   inherit-ok  = f59e389  T87/T88「老实现本来是对的」：老实现用 grep 组合键（RULE_ID|地址）→ 必须**不串**
#   n4-del      = 2beb7bd  补「冻结点删掉的历史文件」时取它的父提交（n4-del^）
#
#   ★ 锚点分工为什么这么分（Chief 复核 · 逐版 git show 核实）：
#     - health_status_find_row 在 7c5f147 / f59e389 / 2beb7bd 里出现次数 = **0**（根本不存在），
#       它是 9dc5b56 才引入的，且引入时**只比对目标地址、没看 RULE_ID**
#       → 「继承键只看目标地址」的缺陷版 = **9dc5b56**（真会串）。
#     - f59e389 的老实现是 `grep "^${target_key}|"`（target_key = RULE_ID|地址）→ **本来就是对的组合键**
#       → 它只能当「老实现本来是对的」那条**正面证明**（同一场景必须**不串**）。
#     - 9dc5b56 起才有「整份原子重建」（`> "$HEALTH_STATUS_FILE.new.$$" && mv -f`），
#       它的提交说明也写了「装/升级用真源重新生成 health_check.sh」
#       → 9dc5b56 **不是**生成物重生成/原子重建的缺陷版；那两条的缺陷版 = **f59e389**。
#
# ── ★★ Chief 踩过的坑：函数在该版本**不存在**时，对照会**静默失效** ──
#   负向对照拿「某个版本的实现」跑判定器时，如果那个版本**根本没有**被测函数
#   （例如 health_status_find_row 在 f59e389 里根本不存在），
#   对照会返回空/报不出来 → 看起来像「缺陷不存在」→ **而且不会报错**。
#   ⇒ 本文件所有历史实现对照都先做**存在性断言**（函数在不在那棵树里），
#     再判行为；存在性断言不过 → 直接 h_fail，不许静默跳过。
#
# ── ★ RULE_ID 必须连续（1、2 …）──────────────────────────────────
#   旧格式行（只有 host、没有端口）的**归属**靠 RULE_ID 对应到规则；
#   RULE_ID 不连续会触发 lib/rules.sh 的 reorder_rule_ids 重排
#   （ID 被重编成 1..N 且状态文件不同步）→ 归属认不出 → 场景走另一条路径
#   → **假绿**。所以本文件每条相关用例都用连续 RULE_ID；
#   需要「换 ID」的场景用**独立规则目录**（单条规则，ID=1），不出现 1、3 这种组合。
#
# ── 判定口径 ────────────────────────────────────────────────────
#   · 「恰好 1 条」优于「至少 1 条」：修复前的症状是**多一条**（孤儿行），「至少」会放过。
#   · 「哈希/逐字节没变」优于「看起来没变」。
#   · 每条「断言 X 没发生」都配「制造 X 发生了 → 判定器必须判红」的自检（恒真 = 假绿）。
#   · 被测产物只来自 git show $BASE_SHA:<path>（$SBX_RUN），绝不 source 工作区文件。
#   · 私有离线镜像：装/升级路径装到「机器」上的必须是**路径重定向后**的冻结态文件
#     —— 否则装上去的副本会去找真实 /etc/os-release、真实 /etc/realm → 越界。
#     镜像放在**私有目录**（SBX_MIRROR 指向它），不改共享的 $SBX_MIRROR（会影响别的用例）。
#   · ★ 冻结点 2beb7bd 删了 lib/failover.sh，但 xwPF.sh 的 LIB_FILES 与
#     lib/update.sh 的 UPDATE_LIB_FILES **仍然引用它** → 装/升级路径在下载那一项时就退出。
#     本文件把「删除前的真实历史文件」（n4-del^ = 2beb7bd^）补进**私有镜像**，
#     好让装/升级路径能跑到生成环节 —— 补的是**真实产品文件**，不是编的；补了什么写进日志。

# ── 历史实现 sha（单一真源；清单里没登记就退回 Chief 指定值）──────
_N4_PRE_SHA="$(sbx_history_sha n4-pre 2>/dev/null || true)"
if [ -z "$_N4_PRE_SHA" ]; then _N4_PRE_SHA="f59e389"; fi
_N4_INHERIT_PRE_SHA="$(sbx_history_sha inherit-pre 2>/dev/null || true)"
if [ -z "$_N4_INHERIT_PRE_SHA" ]; then _N4_INHERIT_PRE_SHA="9dc5b56"; fi
_N4_INHERIT_OK_SHA="$(sbx_history_sha inherit-ok 2>/dev/null || true)"
if [ -z "$_N4_INHERIT_OK_SHA" ]; then _N4_INHERIT_OK_SHA="f59e389"; fi
_N4_DEL_SHA="$(sbx_history_sha n4-del 2>/dev/null || true)"
if [ -z "$_N4_DEL_SHA" ]; then _N4_DEL_SHA="2beb7bd"; fi

# ── 常量（★ 路径必须在**调用时**取：本文件是被 run_tests.sh 在 sbx_init **之前** source 的，
#      source 期 $SBX_ROOT 还是空串 —— 早前写成顶层常量会让判定器去读 /health_status.conf）──
_N4_PORT_A=18701      # 可达目标（起本地监听）
_N4_PORT_B=18702      # 可达目标
_N4_PORT_C=18703      # 不可达目标（连接被拒 → 快速失败）

# 健康状态文件 / 探测端生成物的路径（调用时求值）
_n4_status_file() { printf '%s\n' "$SBX_ROOT/realm/health/health_status.conf"; }
_n4_probe_script() { printf '%s\n' "$SBX_ROOT/realm/health/health_check.sh"; }

# ─────────────────────────────────────────────────────────────
# helper · 规则 fixture
# ─────────────────────────────────────────────────────────────
# 造一条规则（写全官方键集：read_rule_file 会 unset 掉所有键再解析，
# 少一个键 → set -u 下致命中断；见 00_common.sh 的说明）
# 用法：_n4_make_rule <文件> <RULE_ID> <LISTEN_PORT> <REMOTE_HOST> <REMOTE_PORT>
#   CONNECTION_TIMEOUT=10：与台架 v2.13.0 的探测超时预算一致（3s 在机器压满时会被打满）
_n4_make_rule() {
    local file="$1" id="$2" lp="$3" host="$4" rp="$5"
    mkdir -p "$(dirname "$file")"
    cat > "$file" <<EOF
RULE_ID=$id
RULE_ROLE=1
RULE_NAME="n4-rule-$id"
SECURITY_LEVEL=none
LISTEN_PORT=$lp
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=$host
REMOTE_PORT=$rp
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
}

# 清空规则目录 + 健康状态文件（每条场景从干净起点开始）
_n4_reset_rules() {
    rm -f "$SBX_ROOT/realm/rules"/rule-*.conf 2>/dev/null
    rm -f "$(_n4_status_file)" "$(_n4_status_file).tmp" "$(_n4_status_file).old."* 2>/dev/null
    mkdir -p "$SBX_ROOT/realm/rules" "$SBX_ROOT/realm/health"
}

# 起一个本地监听（可达目标用）
#   ★ 输出重定向到 /dev/null：监听进程会继承 stdout，
#     而台架用命令替换收用例输出 → 不重定向的话，用例会等监听退出（30s）才收尾。
_n4_listener() {
    _start_listener "$1" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────
# helper · 探测端生成物与探测轮次
# ─────────────────────────────────────────────────────────────
# 用指定产品树生成探测端脚本（真源 = 该树的 lib/health.sh 的 health_check_script_body）
# 用法：_n4_gen_probe <tree> <输出文件>
_n4_gen_probe() {
    local tree="$1" out="$2"
    mkdir -p "$(dirname "$out")"
    _run_in_sandbox '
        source "$2/lib/core.sh" >/dev/null 2>&1
        source "$2/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' "$tree" > "$out" 2>/dev/null
}

# 跑一轮探测（执行生成物；它会按当前规则重写健康状态文件）
_n4_run_round() {
    local script="$1" rc
    bash "$script" >/dev/null 2>&1
    rc=$?
    return $rc
}

# ─────────────────────────────────────────────────────────────
# helper · 判定器（判定器本身就是被测对象之一：恒真 = 假绿）
# ─────────────────────────────────────────────────────────────
# 判定器 A：健康状态文件必须**恰好**是期望的那些行
#   用法：_n4_judge_status <文件> <期望...>；期望格式 "RULE_ID|TARGET|STATUS|FAIL_COUNT"
#   输出："<PASS|FAIL>\t<说明>"
_n4_judge_status() {
    local file="$1"
    shift
    local rows n_exp
    rows=$(grep -v '^#' "$file" 2>/dev/null | grep -c . | tr -d ' ')
    [ -z "$rows" ] && rows=0
    n_exp=$#
    if [ "$rows" != "$n_exp" ]; then
        printf 'FAIL\t状态文件行数 = %s（期望 %s）\n' "$rows" "$n_exp"
        return 1
    fi
    local exp id tgt st fc c row status failc
    for exp in "$@"; do
        id="${exp%%|*}"; tgt=$(printf '%s' "${exp#*|}" | cut -d'|' -f1)
        st=$(printf '%s' "${exp#*|}" | cut -d'|' -f2)
        fc=$(printf '%s' "${exp#*|}" | cut -d'|' -f3)
        c=$(grep -c "^${id}|${tgt//./\\.}|" "$file" 2>/dev/null | tr -d ' ')
        [ -z "$c" ] && c=0
        if [ "$c" != "1" ]; then
            printf 'FAIL\tRULE_ID=%s TARGET=%s 的记录有 %s 条（期望恰好 1 条）\n' "$id" "$tgt" "$c"
            return 1
        fi
        row=$(grep "^${id}|${tgt//./\\.}|" "$file" 2>/dev/null | head -1)
        status=$(printf '%s' "$row" | cut -d'|' -f3)
        failc=$(printf '%s' "$row" | cut -d'|' -f4)
        if [ "$status" != "$st" ] || [ "$failc" != "$fc" ]; then
            printf 'FAIL\t%s|%s 期望 status=%s fail_count=%s，实际 status=%s fail_count=%s\n' \
                "$id" "$tgt" "$st" "$fc" "$status" "$failc"
            return 1
        fi
    done
    printf 'PASS\t%s 行与期望逐项一致\n' "$n_exp"
    return 0
}

# 判定器 A'：只判**某一条**记录的状态（不管文件里还有几行、失败计数多少）
#   用法：_n4_judge_row_status <文件> "RULE_ID|TARGET|STATUS"
#   ★ 「串没串」这条判定只看状态：串了 = 新规则拿到了别人的 failed；
#     不看失败计数是因为失败计数受当轮探测成败影响（探测抖动会把判据变成假红）。
_n4_judge_row_status() {
    local file="$1" exp="$2"
    local id tgt st c row status
    id="${exp%%|*}"; tgt=$(printf '%s' "${exp#*|}" | cut -d'|' -f1)
    st=$(printf '%s' "${exp#*|}" | cut -d'|' -f2)
    c=$(grep -c "^${id}|${tgt//./\\.}|" "$file" 2>/dev/null | tr -d ' ')
    [ -z "$c" ] && c=0
    if [ "$c" != "1" ]; then
        printf 'FAIL\tRULE_ID=%s TARGET=%s 的记录有 %s 条（期望恰好 1 条）\n' "$id" "$tgt" "$c"
        return 1
    fi
    row=$(grep "^${id}|${tgt//./\\.}|" "$file" 2>/dev/null | head -1)
    status=$(printf '%s' "$row" | cut -d'|' -f3)
    if [ "$status" != "$st" ]; then
        printf 'FAIL\t%s|%s 期望 status=%s，实际 status=%s（整行: %s）\n' "$id" "$tgt" "$st" "$status" "$row"
        return 1
    fi
    printf 'PASS\t%s|%s 记录 status=%s\n' "$id" "$tgt" "$status"
    return 0
}

# 判定器 B：状态文件「每行要么完整要么不存在」+ 没有半写残留
_n4_judge_integrity() {
    local file="$1"
    local bad=0 line n st fc sc
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        n=$(printf '%s' "$line" | awk -F'|' '{print NF}')
        if [ "$n" != "9" ]; then
            bad=$((bad + 1))
            continue
        fi
        st=$(printf '%s' "$line" | cut -d'|' -f3)
        fc=$(printf '%s' "$line" | cut -d'|' -f4)
        sc=$(printf '%s' "$line" | cut -d'|' -f5)
        case "$st" in healthy|failed) ;; *) bad=$((bad + 1)); continue ;; esac
        case "$fc" in ''|*[!0-9]*) bad=$((bad + 1)); continue ;; esac
        case "$sc" in ''|*[!0-9]*) bad=$((bad + 1)); continue ;; esac
    done < "$file" 2>/dev/null
    if [ "$bad" != "0" ]; then
        printf 'FAIL\t状态文件里有 %s 行不是完整记录（字段数/取值不对）\n' "$bad"
        return 1
    fi
    local tmpf
    tmpf=$(ls "$(dirname "$file")"/*.tmp* 2>/dev/null | head -1)
    if [ -n "$tmpf" ]; then
        printf 'FAIL\t留下半写临时文件: %s\n' "$tmpf"
        return 1
    fi
    printf 'PASS\t每行都是完整记录、无半写残留\n'
    return 0
}

# 判定器 C：生成物与真源**机械一致**（sha256 级，不是目测）
#   用法：_n4_judge_artifact <生成物> <真源 lib/health.sh 所在的产品树>
_n4_judge_artifact() {
    local artifact="$1" tree="$2"
    local ref="$SBX_ROOT/n4/ref_artifact.sh"
    mkdir -p "$SBX_ROOT/n4"
    _run_in_sandbox '
        source "$2/lib/core.sh" >/dev/null 2>&1
        source "$2/lib/health.sh" >/dev/null 2>&1
        health_check_script_body
    ' "$tree" > "$ref" 2>/dev/null
    if [ ! -s "$ref" ]; then
        printf 'FAIL\t真源生成不出参考产物（health_check_script_body 没产出内容）\n'
        return 1
    fi
    local a_sha r_sha diff1
    a_sha=$(tr -d '\r' < "$artifact" 2>/dev/null | sha256sum | cut -d' ' -f1)
    r_sha=$(tr -d '\r' < "$ref" | sha256sum | cut -d' ' -f1)
    if [ "$a_sha" = "$r_sha" ]; then
        printf 'PASS\t生成物与真源逐字一致（sha256=%s）\n' "$a_sha"
        return 0
    fi
    diff1=$(diff <(tr -d '\r' < "$artifact" 2>/dev/null) <(tr -d '\r' < "$ref") 2>/dev/null | head -4 | tr '\n' ' ')
    printf 'FAIL\t生成物与真源不一致（生成物 sha=%s / 真源生成 sha=%s；首个差异: %s）\n' "$a_sha" "$r_sha" "$diff1"
    return 1
}

# 生成物里必须含探测实现（防止「文件被清空/截断」也算通过）
_n4_judge_probe_impl() {
    local artifact="$1" missing=""
    local fn
    for fn in read_rule_file check_connectivity now_us probe_with_latency get_health_status_record; do
        grep -q "^${fn}() {" "$artifact" 2>/dev/null || missing="${missing} ${fn}"
    done
    if [ -n "$missing" ]; then
        printf 'FAIL\t生成物里缺少探测实现函数:%s\n' "$missing"
        return 1
    fi
    printf 'PASS\t生成物含全部探测实现函数\n'
    return 0
}

# ─────────────────────────────────────────────────────────────
# helper · 私有离线镜像（装/升级路径的被测产品树）
# ─────────────────────────────────────────────────────────────
# 产品自己声明要装哪些文件（xwPF.sh 的 LIB_FILES ∪ lib/update.sh 的 UPDATE_LIB_FILES）—— 不写死清单
_n4_product_declared_libs() {
    {
        sed -n 's/^LIB_FILES=(\(.*\))$/\1/p' "$SBX_SRC/xwPF.sh" 2>/dev/null
        sed -n 's/^UPDATE_LIB_FILES=(\(.*\))$/\1/p' "$SBX_SRC/lib/update.sh" 2>/dev/null
    } | tr -d '"' | tr ' ' '\n' | grep -v '^$' | sort -u
}

# 造私有镜像 + 可直接执行的产品树（「GitHub raw」的离线替身）
#   用法：_n4_private_mirror <目录> [历史 sha]
#     · 不给 sha → 用冻结态（$SBX_RUN：路径重定向 + root 模拟）
#     · 给了 sha  → 用那个历史版本的**真实产品文件**（同样路径重定向）
#   冻结点删掉、但产品清单还引用的文件 → 补 n4-del^ 的真实历史文件
# 副作用：被补的文件名写进全局 _N4_MIRROR_PATCHED（逗号分隔）
_N4_MIRROR_PATCHED=""
_n4_private_mirror() {
    local dir="$1" sha="${2:-}"
    _N4_MIRROR_PATCHED=""
    rm -rf "$dir"
    mkdir -p "$dir/lib" "$dir/cmd"

    local name src raw
    # 入口脚本
    if [ -n "$sha" ]; then
        git -C "$SBX_REPO" show "$sha:xwPF.sh" > "$SBX_ROOT/n4/xwPF.raw" 2>/dev/null \
            && sbx_redirect "$SBX_ROOT/n4/xwPF.raw" "$dir/xwPF.sh"
    else
        cp -f "$SBX_RUN/xwPF.sh" "$dir/xwPF.sh"
    fi

    for name in $(_n4_product_declared_libs); do
        local got=0
        if [ -n "$sha" ]; then
            raw="$SBX_ROOT/n4/mirror_raw_$name"
            if git -C "$SBX_REPO" show "$sha:lib/$name" > "$raw" 2>/dev/null && [ -s "$raw" ]; then
                sbx_redirect "$raw" "$dir/lib/$name"
                got=1
            fi
        else
            if [ -f "$SBX_RUN/lib/$name" ]; then
                cp -f "$SBX_RUN/lib/$name" "$dir/lib/$name"
                got=1
            fi
        fi
        if [ "$got" = "0" ]; then
            # 冻结点删了、但产品清单还引用 → 补删除前的真实历史文件（n4-del^）
            raw="$SBX_ROOT/n4/mirror_raw_$name"
            if git -C "$SBX_REPO" show "${_N4_DEL_SHA}^:lib/$name" > "$raw" 2>/dev/null && [ -s "$raw" ]; then
                sbx_redirect "$raw" "$dir/lib/$name"
                _N4_MIRROR_PATCHED="${_N4_MIRROR_PATCHED}${_N4_MIRROR_PATCHED:+,}$name(来自 ${_N4_DEL_SHA}^)"
            fi
        fi
    done
}

# 造一个「旧生成物」（真机踩坑现场：每 4 秒打「健康检查完成」、退出码 0，
# 但最后检查时间停在 7 小时前 → 探测端根本没在工作，全程无报错）
_n4_stale_artifact() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
#!/bin/bash
# 旧生成物（真机踩坑现场：每 4 秒打「健康检查完成」、退出码 0，
# 但最后检查时间停在 7 小时前 → 探测端根本没在工作，全程无报错）
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 健康检查完成"
exit 0
EOF
    chmod +x "$path" 2>/dev/null
    touch -t 202001010000 "$path" 2>/dev/null || true
}

# 生成物的指纹（sha256 + mtime）—— 「内容或 mtime 变了」的判据
_n4_fingerprint() {
    local path="$1" sha mt
    if [ -f "$path" ]; then
        sha=$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1)
        mt=$(stat -c %Y "$path" 2>/dev/null || echo 0)
    else
        sha="none"
        mt="0"
    fi
    printf '%s %s\n' "$sha" "$mt"
}

# 造「历史实现」产品树：冻结态执行副本 + 指定 sha 的 lib/health.sh（同样路径重定向）
# 用法：_n4_prepare_old_tree <sha> <标签>；副作用：树根写进全局 _N4_OLD_TREE
_N4_OLD_TREE=""
_n4_prepare_old_tree() {
    local sha="$1" tag="$2"
    local tree="$SBX_ROOT/n4/tree_$tag"
    _N4_OLD_TREE="$tree"
    rm -rf "$tree"
    mkdir -p "$tree"
    cp -r "$SBX_RUN"/. "$tree"/ 2>/dev/null
    local raw="$SBX_ROOT/n4/old_health_$tag.sh"
    if ! git -C "$SBX_REPO" show "$sha:lib/health.sh" > "$raw" 2>/dev/null || [ ! -s "$raw" ]; then
        echo "取不到 $sha:lib/health.sh" >&2
        return 1
    fi
    sbx_redirect "$raw" "$tree/lib/health.sh"
    return 0
}

# ─────────────────────────────────────────────────────────────
# helper · 升级路径（lib/update.sh 的脚本包更新流程 safe_update_scripts）
# ─────────────────────────────────────────────────────────────
# 造「机器上已装的脚本包」：冻结态文件 + 把 core.sh 的版本号调旧
#   （制造「有新版可装」——否则 safe_update_scripts 会直接判「已是最新」什么也不做）
_n4_upgrade_site() {
    local site="$1"
    rm -rf "$site"
    mkdir -p "$site/install/lib" "$site/install/cmd" "$site/backup" "$site/staging" "$site/lock"
    cp "$SBX_RUN/xwPF.sh" "$site/install/xwPF.sh" 2>/dev/null
    local f
    for f in "$SBX_RUN"/lib/*.sh; do
        [ -f "$f" ] || continue
        cp "$f" "$site/install/lib/$(basename "$f")"
    done
    sed -i 's/^SCRIPT_VERSION=".*"/SCRIPT_VERSION="v2.2.0"/' "$site/install/lib/core.sh" 2>/dev/null
}

# 写升级场景脚本：source 冻结态产品代码 + 假下载源 → 跑 safe_update_scripts
# 用法：_n4_write_upgrade_scenario <场景文件>
#   运行：bash <场景文件> <站点目录> <私有镜像>（两个参数**必须传进来**，
#   否则 site/mirror 是空串 → 更新流程什么也没下载、什么也没装）
_n4_write_upgrade_scenario() {
    local scen="$1"
    cat > "$scen" <<'EOS'
site="$1"
mirror="$2"
export INSTALL_DIR="$site/install"
export LIB_DIR="$site/install/lib"
export CONFIG_DIR="$SBX_ROOT/realm"
export UPDATE_BACKUP_DIR="$site/backup"
export UPDATE_LOCK_DIR="$site/lock"
export UPDATE_STAGING_ROOT="$site/staging"

source "$SBX_RUN/lib/core.sh" >/dev/null 2>&1
source "$SBX_RUN/lib/health.sh" >/dev/null 2>&1
source "$SBX_RUN/lib/rules.sh" >/dev/null 2>&1
source "$SBX_RUN/lib/realm.sh" >/dev/null 2>&1
source "$SBX_RUN/lib/update.sh" >/dev/null 2>&1

# —— 下载边界换成私有镜像（离线替身）——
update_download_to() {
    local url="$1" target="$2" name
    name=$(printf '%s' "$url" | sed 's|.*/||')
    if [ -f "$mirror/$name" ]; then
        cp -f "$mirror/$name" "$target"
    elif [ -f "$mirror/lib/$name" ]; then
        cp -f "$mirror/lib/$name" "$target"
    else
        echo "DL-MISS: $name" >&2
        return 1
    fi
    return 0
}

out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "RESULT:rc=$rc"
echo "RESULT:updated=$(printf '%s' "$out" | grep -c '脚本包已更新')"
echo "RESULT:rolledback=$(printf '%s' "$out" | grep -c '自动回滚')"
echo "RESULT:regen=$(printf '%s' "$out" | grep -c '重新生成健康检查脚本')"
EOS
}

# ─────────────────────────────────────────────────────────────
# T85 · 生成物必须重新生成
# ─────────────────────────────────────────────────────────────
case_T85_probe_artifact_regenerated_on_install_and_update() {
    h_case_begin "T85" "装/升级路径必须用真源重新生成探测端生成物（health_check.sh）" \
        "沙箱 + 私有离线镜像 + 预置的「旧生成物」" \
        "xwPF.sh install（装） / safe_update_scripts（升）" \
        "两条路径跑完后 health_check.sh 的内容或 mtime 必须变，且与 lib/health.sh 真源的生成物 sha256 逐字一致"

    local priv="$SBX_ROOT/n4/mirror"
    local artifact
    artifact="$(_n4_probe_script)"
    local j

    # ──────────────────────────────
    # ① 装路径：xwPF.sh install
    # ──────────────────────────────
    _n4_private_mirror "$priv"
    h_log "私有镜像已就绪: $priv（补齐的历史文件: ${_N4_MIRROR_PATCHED:-（无）}）"

    _n4_stale_artifact "$artifact"
    local before after
    before=$(_n4_fingerprint "$artifact")
    h_log "装路径 · 旧生成物指纹: $before"

    local out rc
    out=$(SBX_MIRROR="$priv" bash "$priv/xwPF.sh" install </dev/null 2>&1)
    rc=$?
    h_log "装路径 · install rc=$rc"
    h_log "装路径 · 输出尾部: $(printf '%s' "$out" | sed -e 's/\x1b\[[0-9;]*m//g' | tail -6 | tr '\n' ' ' | cut -c1-240)"

    # 前置：装路径必须真的跑到「脚本安装完成」，否则后面的断言是「没跑起来」而不是「没重新生成」
    h_check_contains "$out" "脚本安装完成" "装路径：脚本安装环节跑到了（前置：否则判红无意义）"

    after=$(_n4_fingerprint "$artifact")
    h_log "装路径 · 新生成物指纹: $after"
    local b_sha b_mt a_sha a_mt
    b_sha=$(printf '%s' "$before" | cut -d' ' -f1); b_mt=$(printf '%s' "$before" | cut -d' ' -f2)
    a_sha=$(printf '%s' "$after" | cut -d' ' -f1);  a_mt=$(printf '%s' "$after" | cut -d' ' -f2)
    if [ "$b_sha" != "$a_sha" ] || [ "$b_mt" != "$a_mt" ]; then
        h_pass "装路径：health_check.sh 的内容或 mtime 变了（内容 $b_sha → $a_sha / mtime $b_mt → $a_mt）"
    else
        h_fail "装路径：health_check.sh 的内容或 mtime **都没变**（sha=$a_sha mtime=$a_mt）—— 装路径没经过生成写点，生成物是「早就生成好的旧货」"
    fi

    j=$(_n4_judge_artifact "$artifact" "$SBX_RUN")
    h_log "装路径 · 机械一致性判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "装路径：生成物与 lib/health.sh 真源的生成物逐字一致（sha256）"

    j=$(_n4_judge_probe_impl "$artifact")
    h_log "装路径 · 探测实现判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "装路径：生成物里含探测实现函数"

    # ──────────────────────────────
    # ② 升路径：lib/update.sh 的脚本包更新流程（safe_update_scripts）
    # ──────────────────────────────
    local site="$SBX_ROOT/n4/site_upd"
    local scen="$SBX_ROOT/n4/site_upd.sh"
    _n4_upgrade_site "$site"
    _n4_write_upgrade_scenario "$scen"

    _n4_stale_artifact "$artifact"
    before=$(_n4_fingerprint "$artifact")
    h_log "升路径 · 旧生成物指纹: $before"

    out=$(bash "$scen" "$site" "$priv" 2>&1)
    h_log "升路径 · 输出: $(printf '%s' "$out" | grep -a '^RESULT:' | tr '\n' ' ')"
    h_log "升路径 · 输出尾部: $(printf '%s' "$out" | sed -e 's/\x1b\[[0-9;]*m//g' | tail -5 | tr '\n' ' ' | cut -c1-240)"

    # 前置：升级流程必须真的换了脚本包
    h_check_contains "$out" "RESULT:updated=1" "升路径：脚本包更新流程跑到了（前置：否则判红无意义）"

    after=$(_n4_fingerprint "$artifact")
    h_log "升路径 · 新生成物指纹: $after"
    b_sha=$(printf '%s' "$before" | cut -d' ' -f1); b_mt=$(printf '%s' "$before" | cut -d' ' -f2)
    a_sha=$(printf '%s' "$after" | cut -d' ' -f1);  a_mt=$(printf '%s' "$after" | cut -d' ' -f2)
    if [ "$b_sha" != "$a_sha" ] || [ "$b_mt" != "$a_mt" ]; then
        h_pass "升路径：health_check.sh 的内容或 mtime 变了（内容 $b_sha → $a_sha / mtime $b_mt → $a_mt）"
    else
        h_fail "升路径：health_check.sh 的内容或 mtime **都没变**（sha=$a_sha mtime=$a_mt）—— 升级路径没经过生成写点，生成物是「早就生成好的旧货」"
    fi

    j=$(_n4_judge_artifact "$artifact" "$SBX_RUN")
    h_log "升路径 · 机械一致性判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "升路径：生成物与 lib/health.sh 真源的生成物逐字一致（sha256）"

    # ──────────────────────────────
    # ③ 负向对照（判定器有牙齿）
    # ──────────────────────────────
    # (a) 绿侧：真源没坏时判定器必须判绿（否则判定器恒红 = 假绿）
    local good="$SBX_ROOT/n4/good_artifact.sh"
    _n4_gen_probe "$SBX_RUN" "$good"
    j=$(_n4_judge_artifact "$good" "$SBX_RUN")
    h_log "负向对照 (a) · 绿侧判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "负向对照 (a)：真源没坏时判定器判绿（判定器不是恒红）"

    # (b) 红侧：把真源的探测实现改坏（副本里改）→ 判定器必须抓到不一致
    local badtree="$SBX_ROOT/n4/bad_source_tree"
    rm -rf "$badtree"
    mkdir -p "$badtree/lib"
    cp -r "$SBX_RUN"/. "$badtree"/ 2>/dev/null
    sed -i 's|local timeout="${3:-3}"|local timeout="${3:-99}"|' "$badtree/lib/health.sh" 2>/dev/null
    local inj
    inj=$(grep -c 'local timeout="${3:-99}"' "$badtree/lib/health.sh" 2>/dev/null)
    h_log "负向对照 (b)：已把真源副本的探测超时改坏（命中 $inj 处）"
    h_check_ge 1 "$inj" "负向对照 (b) 自检：真源破坏确实注入了（破坏手法生效）"

    j=$(_n4_judge_artifact "$good" "$badtree")
    h_log "负向对照 (b) · 红侧判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "FAIL" "负向对照 (b)：真源与生成物不一致时判定器必须判红"
    h_check_contains "$j" "不一致" "负向对照 (b)：判红原因指到「不一致」"

    # (c) 真实缺陷版（n4-pre = f59e389）：它的装路径**也不**重新生成 → 判定器必须抓到旧产物
    #     ★ 用**真实历史实现**跑同一套判定器，不是人造破坏。
    local priv_pre="$SBX_ROOT/n4/mirror_pre"
    _n4_private_mirror "$priv_pre" "$_N4_PRE_SHA"
    _n4_stale_artifact "$artifact"
    before=$(_n4_fingerprint "$artifact")
    out=$(SBX_MIRROR="$priv_pre" bash "$priv_pre/xwPF.sh" install </dev/null 2>&1)
    after=$(_n4_fingerprint "$artifact")
    h_log "负向对照 (c) · 缺陷版 ($_N4_PRE_SHA) 装路径前后指纹: $before → $after"
    b_sha=$(printf '%s' "$before" | cut -d' ' -f1); b_mt=$(printf '%s' "$before" | cut -d' ' -f2)
    a_sha=$(printf '%s' "$after" | cut -d' ' -f1);  a_mt=$(printf '%s' "$after" | cut -d' ' -f2)
    if [ "$b_sha" = "$a_sha" ] && [ "$b_mt" = "$a_mt" ]; then
        h_pass "负向对照 (c)：缺陷版（$_N4_PRE_SHA）确实没重新生成生成物（坏情况确实发生）"
    else
        h_fail "负向对照 (c)：缺陷版（$_N4_PRE_SHA）竟然重新生成了生成物 —— 缺陷版选错了，负向对照失去证明力"
    fi
    j=$(_n4_judge_artifact "$artifact" "$SBX_RUN")
    h_log "负向对照 (c) · 判定器判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "FAIL" "负向对照 (c)：判定器在缺陷版留下的旧产物上必须判红"
}

# ─────────────────────────────────────────────────────────────
# T86 · 状态文件每轮原子重建
# ─────────────────────────────────────────────────────────────
case_T86_health_status_rebuilt_atomically_each_round() {
    h_case_begin "T86" "健康状态文件每轮原子重建：只留当前规则的行（删掉的规则不留孤儿行）" \
        "沙箱 rules（两条规则，RULE_ID 连续 1/2）+ 冻结态探测端生成物" \
        "跑一轮探测 → 删掉一条规则 → 再跑一轮" \
        "被删规则的那一行必须从状态文件里消失；文件里只剩当前规则的行；每行要么完整要么不存在、无半写残留"

    local j status_file
    status_file="$(_n4_status_file)"

    # 两条规则，两个**可达**目标（起本地监听 → 探测成功 → 状态 healthy、失败计数 0）
    _n4_listener "$_N4_PORT_A"
    _n4_listener "$_N4_PORT_B"

    _n4_reset_rules
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 1 9501 "127.0.0.1" "$_N4_PORT_A"
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-2.conf" 2 9501 "127.0.0.1" "$_N4_PORT_B"

    _n4_gen_probe "$SBX_RUN" "$(_n4_probe_script)"
    local rc
    _n4_run_round "$(_n4_probe_script)"
    rc=$?
    h_log "第一轮探测 rc=$rc"
    h_log "第一轮之后的状态文件: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    local rows1
    rows1=$(grep -v '^#' "$status_file" 2>/dev/null | grep -c . | tr -d ' ')
    [ -z "$rows1" ] && rows1=0
    h_check_eq "2" "$rows1" "第一轮之后：状态文件里两条规则各一行（恰好 2 行）"

    # 删掉 rule-2，再跑一轮
    rm -f "$SBX_ROOT/realm/rules/rule-2.conf"
    _n4_run_round "$(_n4_probe_script)"
    rc=$?
    h_log "第二轮探测 rc=$rc"
    h_log "第二轮之后的状态文件: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    j=$(_n4_judge_status "$status_file" "1|127.0.0.1:$_N4_PORT_A|healthy|0")
    h_log "状态判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "删掉规则后：状态文件里只剩当前规则的行（恰好 1 行、逐项一致）"

    # 被删规则的那一行必须**消失**
    local orphan
    orphan=$(grep -c "2|127.0.0.1:$_N4_PORT_B|" "$status_file" 2>/dev/null | tr -d ' ')
    [ -z "$orphan" ] && orphan=0
    h_check_eq "0" "$orphan" "删掉的规则不能留在状态文件里（孤儿行数 = 0）"

    # 原子重建：每行要么完整要么不存在 + 没有半写残留
    j=$(_n4_judge_integrity "$status_file")
    h_log "完整性判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "重建后的状态文件：每行都是完整记录、没有半截行、没有半写残留"

    # ── 判定器自检（恒真 = 假绿）：造一份带孤儿行的文件 → 判定器必须判红 ──
    local probe_file="$SBX_ROOT/n4/t86_orphan.conf"
    cat > "$probe_file" <<EOF
# Realm健康状态文件
1|127.0.0.1:$_N4_PORT_A|healthy|0|3|100|0|12|12
2|127.0.0.1:$_N4_PORT_B|healthy|0|3|100|0|12|12
EOF
    j=$(_n4_judge_status "$probe_file" "1|127.0.0.1:$_N4_PORT_A|healthy|0")
    h_log "孤儿行探针判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "FAIL" "判定器自检：文件里留着被删规则的孤儿行时判定器必须判红"
    h_check_contains "$j" "行数" "判定器自检：判红原因指到「行数」"

    # ── 真实缺陷版（n4-pre = f59e389）：它的状态文件**不是**每轮重建 → 判定器必须判红 ──
    local oldtree
    if ! _n4_prepare_old_tree "$_N4_PRE_SHA" "pre"; then
        h_fail "负向对照搭不出缺陷版产品树（取不到 $_N4_PRE_SHA:lib/health.sh）—— 对照跑不起来等于没在证明"
        return
    fi
    oldtree="$_N4_OLD_TREE"
    h_log "缺陷版产品树: $oldtree"

    _n4_reset_rules
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 1 9501 "127.0.0.1" "$_N4_PORT_A"
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-2.conf" 2 9501 "127.0.0.1" "$_N4_PORT_B"
    local oldprobe="$SBX_ROOT/n4/pre_probe.sh"
    _n4_gen_probe "$oldtree" "$oldprobe"
    _n4_run_round "$oldprobe"
    rm -f "$SBX_ROOT/realm/rules/rule-2.conf"
    _n4_run_round "$oldprobe"
    h_log "缺陷版 · 删规则之后的状态文件: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    j=$(_n4_judge_status "$status_file" "1|127.0.0.1:$_N4_PORT_A|healthy|0")
    h_log "缺陷版 · 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "FAIL" "负向对照：缺陷版（$_N4_PRE_SHA）留下孤儿行时，判定器必须判红"
    h_check_contains "$j" "行数" "负向对照：判红原因指到「行数」"
}

# ─────────────────────────────────────────────────────────────
# T87 · 跨轮继承的键 = RULE_ID + 目标地址（组合键）
# ─────────────────────────────────────────────────────────────
case_T87_health_status_inheritance_by_target_address() {
    h_case_begin "T87" "跨轮继承必须用组合键（RULE_ID + 目标地址）：同 ID 新建不继承老 failed；换了 RULE_ID、地址相同也不许拿别人的那行（不串）" \
        "沙箱 rules（RULE_ID 连续）+ 冻结态探测端生成物" \
        "删规则 → 新建规则（换 ID / 同地址）→ 跑一轮探测 → 判状态文件" \
        "同 ID 新建（地址不同）初始 healthy、失败计数 0；换 ID 同地址时新规则不得拿到别人的记录（不串）"

    local j status_file
    status_file="$(_n4_status_file)"
    _n4_listener "$_N4_PORT_A"

    # ──────────────────────────────
    # 场景 A（判据 b）：删掉 rule-1，再新建**同 ID**、**不同地址**的 rule-1
    #   ★ RULE_ID 连续：这里只有一条规则，ID=1 → 不会触发 reorder_rule_ids 重排。
    #   ★ 老记录用**新格式**（host:port）→ 与新规则的地址不同 → 不得继承。
    # ──────────────────────────────
    _n4_reset_rules
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 1 9501 "127.0.0.1" "$_N4_PORT_A"
    cat > "$status_file" <<EOF
# Realm健康状态文件
1|127.0.0.1:$_N4_PORT_A|failed|3|0|100|0
EOF
    _n4_gen_probe "$SBX_RUN" "$(_n4_probe_script)"
    _n4_run_round "$(_n4_probe_script)"
    h_log "场景 A · 第一轮之后: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    rm -f "$SBX_ROOT/realm/rules/rule-1.conf"
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 1 9501 "127.0.0.1" "$_N4_PORT_B"
    _n4_run_round "$(_n4_probe_script)"
    h_log "场景 A · 第二轮之后: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    j=$(_n4_judge_row_status "$status_file" "1|127.0.0.1:$_N4_PORT_B|healthy")
    h_log "场景 A 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "场景 A：同 ID 新建（同 ID、不同地址）不得继承老规则的 failed —— 初始 healthy"

    # 失败计数必须归零（老规则留下的 failed 不能带过来）
    local fc
    fc=$(grep "^1|127.0.0.1:$_N4_PORT_B|" "$status_file" 2>/dev/null | head -1 | cut -d'|' -f4)
    [ -z "$fc" ] && fc="(无)"
    h_check_eq "0" "$fc" "场景 A：同 ID 新建后失败计数必须为 0（不得继承老规则的失败计数）"

    # ──────────────────────────────
    # 场景 B（串的检测）：删掉 rule-2，再新建**不同 ID**、**同一地址**的规则
    #   ★ 用独立规则目录（单条规则，ID=1）→ RULE_ID 连续，不触发 reorder_rule_ids。
    #   ★ 正确口径 = **不串**：新规则不拿老规则（不同 RULE_ID）的那行。
    #     缺陷版（inherit-pre = 9dc5b56，health_status_find_row 只比对地址）→ 会串（拿到 failed）。
    # ──────────────────────────────
    _n4_reset_rules
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-2.conf" 2 9502 "127.0.0.1" "$_N4_PORT_A"
    cat > "$status_file" <<EOF
# Realm健康状态文件
2|127.0.0.1:$_N4_PORT_A|failed|3|0|100|0
EOF
    _n4_gen_probe "$SBX_RUN" "$(_n4_probe_script)"
    _n4_run_round "$(_n4_probe_script)"
    h_log "场景 B · 第一轮之后: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    rm -f "$SBX_ROOT/realm/rules/rule-2.conf"
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 1 9502 "127.0.0.1" "$_N4_PORT_A"
    _n4_run_round "$(_n4_probe_script)"
    h_log "场景 B · 第二轮之后: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    j=$(_n4_judge_row_status "$status_file" "1|127.0.0.1:$_N4_PORT_A|healthy")
    h_log "场景 B 判定（当前实现）: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "场景 B：换了 RULE_ID、地址相同 → 新规则不得拿到别人的那行（不串）"

    # ── 负向对照 1 · 缺陷版（inherit-pre = 9dc5b56）：必须**真的串** ──
    #   ★ 存在性断言：health_status_find_row 在这一版才存在；
    #     函数不存在 → 对照会**静默失效**（返回空、看着像「缺陷不存在」，而且不报错）。
    local pre_tree pre_probe
    if ! _n4_prepare_old_tree "$_N4_INHERIT_PRE_SHA" "inherit_pre"; then
        h_fail "负向对照 1 搭不出缺陷版产品树（取不到 $_N4_INHERIT_PRE_SHA:lib/health.sh）—— 对照跑不起来等于没在证明"
        return
    fi
    pre_tree="$_N4_OLD_TREE"
    pre_probe="$SBX_ROOT/n4/inherit_pre_probe.sh"
    _n4_gen_probe "$pre_tree" "$pre_probe"
    local has_fn
    has_fn=$(grep -c '^health_status_find_row() {' "$pre_probe" 2>/dev/null)
    h_log "负向对照 1 · 缺陷版 ($_N4_INHERIT_PRE_SHA) 的生成物里 health_status_find_row 出现 $has_fn 次"
    h_check_ge 1 "$has_fn" "负向对照 1 自检：被测函数在该版本**存在**（不存在 → 对照会静默失效且不报错）"

    _n4_reset_rules
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-2.conf" 2 9502 "127.0.0.1" "$_N4_PORT_A"
    cat > "$status_file" <<EOF
# Realm健康状态文件
2|127.0.0.1:$_N4_PORT_A|failed|3|0|100|0
EOF
    _n4_run_round "$pre_probe"
    rm -f "$SBX_ROOT/realm/rules/rule-2.conf"
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 1 9502 "127.0.0.1" "$_N4_PORT_A"
    _n4_run_round "$pre_probe"
    h_log "负向对照 1 · 缺陷版第二轮之后: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    j=$(_n4_judge_row_status "$status_file" "1|127.0.0.1:$_N4_PORT_A|healthy")
    h_log "负向对照 1 · 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "FAIL" "负向对照 1：缺陷版（$_N4_INHERIT_PRE_SHA）真串了（拿到别的 RULE_ID 的 failed）→ 判定器必须判红"

    # ── 负向对照 2 · 老实现本来是对的（inherit-ok = f59e389，组合键）→ 必须**不串** ──
    local ok_tree ok_probe
    if ! _n4_prepare_old_tree "$_N4_INHERIT_OK_SHA" "inherit_ok"; then
        h_fail "负向对照 2 搭不出「老实现」产品树（取不到 $_N4_INHERIT_OK_SHA:lib/health.sh）—— 对照跑不起来等于没在证明"
        return
    fi
    ok_tree="$_N4_OLD_TREE"
    ok_probe="$SBX_ROOT/n4/inherit_ok_probe.sh"
    _n4_gen_probe "$ok_tree" "$ok_probe"
    has_fn=$(grep -c '^health_status_find_row() {' "$ok_probe" 2>/dev/null)
    h_log "负向对照 2 · 「老实现」($_N4_INHERIT_OK_SHA) 的生成物里 health_status_find_row 出现 $has_fn 次（0 = 老实现没有这个函数，走的是组合键）"

    _n4_reset_rules
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-2.conf" 2 9502 "127.0.0.1" "$_N4_PORT_A"
    cat > "$status_file" <<EOF
# Realm健康状态文件
2|127.0.0.1:$_N4_PORT_A|failed|3|0|100|0
EOF
    _n4_run_round "$ok_probe"
    rm -f "$SBX_ROOT/realm/rules/rule-2.conf"
    _n4_make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 1 9502 "127.0.0.1" "$_N4_PORT_A"
    _n4_run_round "$ok_probe"
    h_log "负向对照 2 · 「老实现」第二轮之后: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

    j=$(_n4_judge_row_status "$status_file" "1|127.0.0.1:$_N4_PORT_A|healthy")
    h_log "负向对照 2 · 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "负向对照 2：老实现（$_N4_INHERIT_OK_SHA，组合键）跑同一场景**不串**（同一场景必须判绿）"
}

# ─────────────────────────────────────────────────────────────
# T88 · 负向对照：缺陷版真串 + 老实现不串（两侧都验）
# ─────────────────────────────────────────────────────────────
case_T88_negative_control_old_impl() {
    h_case_begin "T88" "负向对照：缺陷版（只比对目标地址）真串 + 老实现（组合键）不串，两侧都要验" \
        "冻结态历史对象（inherit-pre / inherit-ok 的 lib/health.sh）" \
        "同一场景在缺陷版与老实现上各跑一轮" \
        "缺陷版必须判红（串了）；老实现必须判绿（不串）；被测函数在该版本不存在时必须先判红，不许静默失效"

    local j status_file
    status_file="$(_n4_status_file)"
    _n4_listener "$_N4_PORT_A"

    # ── 预检：历史对象必须在本地对象库里（取不到就判红，不许静默跳过）──
    local sha
    for sha in "$_N4_INHERIT_PRE_SHA" "$_N4_INHERIT_OK_SHA"; do
        if ! git -C "$SBX_REPO" cat-file -e "${sha}^{commit}" 2>/dev/null; then
            h_fail "负向对照取不到历史实现：历史对象 $sha 不在本地对象库"
            h_fail "→ 修法1：在 tests/cases/00_common.sh 的 sbx_required_history_shas 里登记对应 key"
            h_fail "→ 修法2：把对象拉进本地库（git fetch --tags origin，或不用 --single-branch 重新克隆）"
            return
        fi
    done
    h_log "负向对照用的历史实现: 缺陷版 $_N4_INHERIT_PRE_SHA / 老实现 $_N4_INHERIT_OK_SHA"

    # ── 判定器自检 · 绿的一侧：符合口径的状态文件 → 判定器必须判绿 ──
    local good="$SBX_ROOT/n4/t88_good.conf"
    cat > "$good" <<EOF
# Realm健康状态文件
1|127.0.0.1:$_N4_PORT_A|healthy|0|3|100|0|12|12
EOF
    j=$(_n4_judge_status "$good" "1|127.0.0.1:$_N4_PORT_A|healthy|0")
    h_log "绿侧判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "PASS" "判定器自检 · 绿侧：符合口径的状态文件必须判绿（判定器不是恒红）"

    # ── 判定器自检 · 红的一侧：留着孤儿行的状态文件 → 判定器必须判红 ──
    local bad="$SBX_ROOT/n4/t88_bad.conf"
    cat > "$bad" <<EOF
# Realm健康状态文件
1|127.0.0.1:$_N4_PORT_A|healthy|0|3|100|0|12|12
2|127.0.0.1:$_N4_PORT_B|healthy|0|3|100|0|12|12
EOF
    j=$(_n4_judge_status "$bad" "1|127.0.0.1:$_N4_PORT_A|healthy|0")
    h_log "红侧判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
    h_check_contains "$j" "FAIL" "判定器自检 · 红侧：留着孤儿行的状态文件必须判红（判定器有牙齿）"

    # ──────────────────────────────
    # 场景：老规则（RULE_ID=2）的记录是 failed → 删掉它 → 新建**不同 RULE_ID、同一地址**的规则
    #   正确口径 = **不串**（新规则不拿老规则那行）；缺陷版 = 串（拿到 failed）。
    # ──────────────────────────────
    local tag tree probe
    for tag in "inherit_pre:$_N4_INHERIT_PRE_SHA:缺陷版:FAIL" "inherit_ok:$_N4_INHERIT_OK_SHA:老实现:PASS"; do
        local t_name="${tag%%:*}"
        local t_rest="${tag#*:}"
        local t_sha="${t_rest%%:*}"
        local t_rest2="${t_rest#*:}"
        local t_label="${t_rest2%%:*}"
        local t_want="${t_rest2##*:}"

        if ! _n4_prepare_old_tree "$t_sha" "$t_name"; then
            h_fail "负向对照搭不出产品树（取不到 $t_sha:lib/health.sh）—— 对照跑不起来等于没在证明"
            return
        fi
        tree="$_N4_OLD_TREE"
        probe="$SBX_ROOT/n4/${t_name}_probe.sh"
        _n4_gen_probe "$tree" "$probe"

        # ★ 存在性断言：被测函数在这一版**必须存在**。
        #   不存在 → 对照会**静默失效**（返回空、看着像「缺陷不存在」，而且不会报错）。
        #   老实现（组合键）本来就没有这个函数 → 它的判据是「没有这个函数、走组合键」。
        local has_fn
        has_fn=$(grep -c '^health_status_find_row() {' "$probe" 2>/dev/null)
        h_log "── $t_label（$t_sha）· 生成物里 health_status_find_row 出现 $has_fn 次"
        if [ "$t_want" = "FAIL" ]; then
            h_check_ge 1 "$has_fn" "存在性断言：缺陷版（$t_sha）里被测函数必须存在（不存在 → 对照会静默失效且不报错）"
        fi

        _n4_reset_rules
        _n4_make_rule "$SBX_ROOT/realm/rules/rule-2.conf" 2 9502 "127.0.0.1" "$_N4_PORT_A"
        cat > "$status_file" <<EOF
# Realm健康状态文件
2|127.0.0.1:$_N4_PORT_A|failed|3|0|100|0
EOF
        _n4_run_round "$probe"
        rm -f "$SBX_ROOT/realm/rules/rule-2.conf"
        _n4_make_rule "$SBX_ROOT/realm/rules/rule-1.conf" 1 9502 "127.0.0.1" "$_N4_PORT_A"
        _n4_run_round "$probe"
        h_log "$t_label · 第二轮之后的状态文件: $(grep -v '^#' "$status_file" 2>/dev/null | tr '\n' ' ')"

        j=$(_n4_judge_row_status "$status_file" "1|127.0.0.1:$_N4_PORT_A|healthy")
        h_log "$t_label · 判定: $(printf '%s' "$j" | cut -f1) —— $(printf '%s' "$j" | cut -f2-)"
        if [ "$t_want" = "FAIL" ]; then
            h_check_contains "$j" "FAIL" "$t_label（$t_sha）：必须判红 —— 同一场景下它真串了（拿到别的 RULE_ID 的 failed）"
            h_check_contains "$j" "failed" "$t_label（$t_sha）：判红原因指到「新规则拿到了 failed」"
        else
            h_check_contains "$j" "PASS" "$t_label（$t_sha，组合键）：必须判绿 —— 同一场景下它不串"
        fi
    done
}
