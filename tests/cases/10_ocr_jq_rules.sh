#!/bin/bash
# 用例组 10 · OCR 导入 / jq 配置生成 / 规则落盘格式（第 7 轮新增）
#
# 覆盖第 2 轮报告里列的 3 个真空白：
#   T48  xw_realm_OCR.sh —— 整条导入链路一条没测过
#        （能不能被 bash 解析、关键子命令入口在不在、从哪下载、跑起来落盘什么格式）
#   T49  依赖 jq 的整段配置生成 —— 本机没 jq，等于「整段路径完全没被测过」
#        （用沙箱 jq 桩把 generate_network_config 与 rules.sh 的 proxy 开关跑起来）
#   T50  规则增删改的落盘格式 —— 增/改/删之后，规则文件能不能被白名单读出、键合不合法
#
# ★ jq 桩的纪律：能力不够必须**显式**报「桩能力不足」+ 退出码 3，
#   绝不允许静默返回空值假装测过（见 tests/shims/jq_impl.py 顶部说明）。
#   所以 T49 里既测「桩能跑通产品的过滤器」，也测「桩遇到不会的语法会喊出来」。
#
# ★ 每条用例都带**负向对照**，且负向对照先验证「破坏手法生效」再信它的红。
#   负向对照一律在**副本**上做（改副本、不碰冻结态、不碰仓库）。

# ══════════════════════════════════════════════════════════════════
# 公共助手
# ══════════════════════════════════════════════════════════════════

# 抽出 read_rule_file 的白名单（从冻结态 lib/health.sh 现场解析，不硬编码）
# ★ 不硬编码的理由：白名单是产品的真源；硬编码一份副本 → 产品加了键，测试却还在用旧清单 → 假绿。
_t50_allowed_keys() {
    sed -n "s/.*_allowed='\([^']*\)'.*/\1/p" "$SBX_SRC/lib/health.sh" 2>/dev/null | head -1
}

# 抽出一个规则文件里的**所有**赋值键（含非法字符的键）
# ★ 注意：不能用 `grep -oE '^[A-Z_][A-Z0-9_]*='` —— 那样只抓得到「合法」的键，
#   非法键（bad-key=1）根本抓不到 → 键合法性断言会假绿。
#   所以这里先抓「= 左边的一整段原文」，再单独判合法性。
_t50_rule_keys() {
    sed -e '/^[[:space:]]*#/d' \
        -e 's/^[[:space:]]*\([^=[:space:]][^=]*\)=.*/\1/p' "$1" 2>/dev/null |
        sed 's/[[:space:]]*$//' | sort -u
}

# 判定：规则文件的键是否合法、是否全在 read_rule_file 白名单内
# 用法：_t50_judge_keys <规则文件> <白名单串>
# 输出："<PASS|FAIL>\t<说明>"
_t50_judge_keys() {
    local file="$1" allowed="$2"
    local k bad="" outside="" n=0
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        n=$((n + 1))
        case "$k" in
            [A-Z_]*) ;;
            *) bad="$bad$k " ;;
        esac
        case " $allowed " in
            *" $k "*) ;;
            *) outside="$outside$k " ;;
        esac
    done < <(_t50_rule_keys "$file")
    if [ -n "$bad" ]; then
        printf 'FAIL\t非法字符键：%s\n' "$bad"
        return 1
    fi
    if [ -n "$outside" ]; then
        printf 'FAIL\t白名单外的键：%s\n' "$outside"
        return 1
    fi
    printf 'PASS\t键名合法且全在白名单内（共 %s 个键）\n' "$n"
    return 0
}

# 判定：OCR 脚本的关键子命令入口是否齐全
# 用法：_t48_check_entries <脚本> ; 输出 "<缺失个数>\t<缺失列表>"
_t48_check_entries() {
    local f="$1" fn missing="" n=0
    for fn in get_gmt8_time generate_rule_id parse_transport_config process_json process_toml; do
        if ! grep -q "^${fn}() {" "$f" 2>/dev/null; then
            missing="$missing$fn "
            n=$((n + 1))
        fi
    done
    printf '%s\t%s\n' "$n" "$missing"
}

# 从产品源码里抽出一个 jq 过滤器（单引号包起来的那个）
# ★ 从**产品源码**抽，而不是把过滤器抄进测试里 ——
#   抄进来 = 测的是我抄的那份，不是产品现在用的那份。
_t49_extract_filter() {
    # $1=文件 $2=定位用的普通文本子串
    awk -v pat="$2" '
        !cap && index($0, pat) > 0 { cap = 1 }
        cap {
            line = $0
            if (started == 0) {
                i = index(line, "\047")
                if (i == 0) next
                started = 1
                line = substr(line, i + 1)
            }
            j = index(line, "\047")
            if (j > 0) { print substr(line, 1, j - 1); exit }
            print line
        }
    ' "$1" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════
# T48 · OCR 导入链路
# ══════════════════════════════════════════════════════════════════
case_T48_ocr_import_chain() {
    h_case_begin "T48" "OCR 导入链路：能解析、入口齐全、来源是本 fork、落盘格式合法" \
        "冻结态 xw_realm_OCR.sh + 沙箱 config.json + 离线镜像（curl 桩）" \
        "bash -n 冻结态 OCR；import_realm_config（下载 + 运行）" \
        "脚本能被 bash 解析；5 个关键入口齐全；下载 URL 指向本 fork；生成的规则文件键名合法且全在 read_rule_file 白名单内"

    local ocr="$SBX_SRC/xw_realm_OCR.sh"
    local ocr_run="$SBX_RUN/xw_realm_OCR.sh"

    # ── (1) 冻结态脚本必须能被 bash 解析 ──
    local nrc=0
    bash -n "$ocr" >/dev/null 2>&1 || nrc=$?
    h_check_eq "0" "$nrc" "冻结态 xw_realm_OCR.sh 的 bash -n 解析"
    local nrc2=0
    bash -n "$ocr_run" >/dev/null 2>&1 || nrc2=$?
    h_check_eq "0" "$nrc2" "沙箱重定向后的 xw_realm_OCR.sh 的 bash -n 解析"

    # ── (2) 关键子命令入口必须齐全 ──
    local miss misslist
    miss=$(_t48_check_entries "$ocr" | cut -f1)
    misslist=$(_t48_check_entries "$ocr" | cut -f2-)
    h_log "缺失的入口: ${misslist:-（无）}"
    h_check_eq "0" "$miss" "OCR 脚本的 5 个关键子命令入口都存在"
    # 命中数下限护栏：解析器坏了 → 命中 0 → 「都存在」会假绿
    local found n
    found=$(grep -cE '^(get_gmt8_time|generate_rule_id|parse_transport_config|process_json|process_toml)\(\) \{' "$ocr" 2>/dev/null || true)
    [ -z "$found" ] && found=0
    h_check_ge 4 "$found" "OCR 关键入口的命中数下限护栏"

    # ── (3) 来源必须指向本 fork ──
    # OCR 脚本自身**不含任何 URL**（实测），所以「脚本里的仓库名 URL 指向本 fork」这条
    # 在脚本层面是空集；真正有意义的是「**下载** OCR 脚本的那个 URL 指向本 fork」。
    # 这里两条都断言：脚本自身不得出现旧仓库名；下载 URL 必须是本 fork。
    local old_url
    old_url=$(grep -c 'zywe03/realm-xwPF' "$ocr" 2>/dev/null || true)
    [ -z "$old_url" ] && old_url=0
    h_check_eq "0" "$old_url" "OCR 脚本里没有旧仓库名残留"

    local dl_url
    dl_url=$(_t49_extract_filter "$SBX_SRC/lib/ui.sh" "script_url=" 2>/dev/null | head -1)
    dl_url=$(sed -n 's/.*script_url="\([^"]*\)".*/\1/p' "$SBX_SRC/lib/ui.sh" | head -1)
    h_log "下载 OCR 脚本的 URL: ${dl_url:-（没找到）}"
    h_check_contains "$dl_url" "byby5555/realm-xwPF-offline-active-standby" "下载 OCR 脚本的 URL 指向本 fork"
    # 扫描范围护栏：确认扫到的是一份完整脚本，不是空文件
    local ocr_bytes
    ocr_bytes=$(wc -c < "$ocr" 2>/dev/null | tr -d ' ')
    h_check_ge 1000 "$ocr_bytes" "OCR 脚本的字节数（扫描范围护栏）"

    # ── (4) 端到端：走产品入口 import_realm_config（下载 → 运行 → 落盘）──
    local cfg="$SBX_ROOT/ocr/config.json"
    local rules="$SBX_ROOT/realm/rules"
    mkdir -p "$(dirname "$cfg")" "$rules"
    cat > "$cfg" <<'EOF'
{
  "network": {"no_tcp": false, "use_udp": true},
  "endpoints": [
    {
      "listen": "0.0.0.0:8080",
      "remote": "1.2.3.4:443",
      "remote_transport": "ws;host=example.com;path=/ws"
    },
    {
      "listen": "0.0.0.0:9090",
      "remote": "5.6.7.8:8443",
      "listen_transport": "ws;host=server.com;path=/s2",
      "extra_remotes": ["9.9.9.9:9443"],
      "balance": "roundrobin: 4, 2, 1"
    }
  ]
}
EOF

    local out
    # ★ OCR 脚本用 `read -p` 从 **stdin** 读配置路径与确认，所以这里喂管道：
    #   第 1 行 = 配置文件路径；第 2 行 = y（确认导入）；第 3 行 = 回车（import_realm_config 收尾）
    out=$(printf '%s\ny\n\n' "$cfg" | _run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/realm.sh" >/dev/null 2>&1
        source "$1/lib/ui.sh" >/dev/null 2>&1
        import_realm_config
    ' 2>&1)
    h_log "OCR 导入输出尾: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
    h_check_contains "$out" "realm配置导入成功" "OCR 导入流程走通（产品入口 import_realm_config）"

    # 生成的规则文件
    local nrule
    nrule=$(ls -1 "$rules"/rule-*.conf 2>/dev/null | wc -l | tr -d ' ')
    h_log "生成的规则文件数: $nrule"
    h_check_ge 2 "$nrule" "生成的规则文件数量下限护栏（多 endpoint + extra_remotes 应 ≥ 2）"

    # ── (5) 每个规则文件的键：合法 + ⊆ read_rule_file 白名单 ──
    local allowed
    allowed=$(_t50_allowed_keys)
    h_log "read_rule_file 白名单键数: $(printf '%s' "$allowed" | wc -w | tr -d ' ')"
    h_check_ge 20 "$(printf '%s' "$allowed" | wc -w | tr -d ' ')" "read_rule_file 白名单的键数下限护栏"

    local f verdict bad_keys=0
    for f in "$rules"/rule-*.conf; do
        [ -f "$f" ] || continue
        verdict=$(_t50_judge_keys "$f" "$allowed")
        h_log "$(basename "$f"): $(printf '%s' "$verdict" | cut -f1) —— $(printf '%s' "$verdict" | cut -f2-)"
        case "$verdict" in
            PASS*) ;;
            *) bad_keys=$((bad_keys + 1)) ;;
        esac
    done
    h_check_eq "0" "$bad_keys" "所有生成的规则文件：键名合法且全在 read_rule_file 白名单内"

    # ── (6) 键数下限护栏（每个文件 ≥ 20 个键）──
    local min_keys=999
    for f in "$rules"/rule-*.conf; do
        [ -f "$f" ] || continue
        n=$(_t50_rule_keys "$f" | wc -l | tr -d ' ')
        [ "$n" -lt "$min_keys" ] && min_keys=$n
    done
    [ "$min_keys" = "999" ] && min_keys=0
    h_check_ge 20 "$min_keys" "生成的规则文件的键数下限护栏（最少的那个文件）"

    # ── (7) read_rule_file 必须能把生成的规则读回来 ──
    local readback
    readback=$(_run_in_sandbox '
        source "$1/lib/health.sh" >/dev/null 2>&1
        for f in "$2"/rule-*.conf; do
            [ -f "$f" ] || continue
            if read_rule_file "$f"; then
                echo "OK $f RULE_ID=$RULE_ID LISTEN_PORT=$LISTEN_PORT"
            else
                echo "FAIL $f"
            fi
        done
    ' "$rules" 2>&1)
    h_log "read_rule_file 回读: $(printf '%s' "$readback" | tr '\n' ' ' | cut -c1-200)"
    local nok nbad
    nok=$(printf '%s' "$readback" | grep -c '^OK ' || true)
    nbad=$(printf '%s' "$readback" | grep -c '^FAIL ' || true)
    h_check_ge 1 "$nok" "read_rule_file 至少成功读回一个生成的规则"
    h_check_eq "0" "$nbad" "read_rule_file 没有读不回来的规则"

    # ── 负向对照 1：把 OCR 里的 process_json 改名 → 入口存在性必须判红 ──
    local broken_ocr="$SBX_ROOT/ocr/broken_ocr.sh"
    sed 's/^process_json() {/process_json_RENAMED() {/' "$ocr" > "$broken_ocr"
    local ren
    ren=$(grep -c '^process_json_RENAMED() {' "$broken_ocr" || true)
    [ -z "$ren" ] && ren=0
    h_check_eq "1" "$ren" "负向对照 1 的破坏手法生效（改名点 == 1）"
    local bmiss
    bmiss=$(_t48_check_entries "$broken_ocr" | cut -f1)
    h_check_ge 1 "$bmiss" "负向对照 1：入口被改名后「入口齐全」必须判红"

    # ── 负向对照 2：注入非法字符键 → 键合法性必须判红 ──
    local badfile="$SBX_ROOT/ocr/bad_rule.conf"
    cp "$rules/rule-1.conf" "$badfile"
    printf 'bad-key=1\n' >> "$badfile"
    local v2
    v2=$(_t50_judge_keys "$badfile" "$allowed")
    h_log "非法键判定: $(printf '%s' "$v2" | cut -f1) —— $(printf '%s' "$v2" | cut -f2-)"
    h_check_contains "$v2" "FAIL" "负向对照 2：注入非法字符键后必须判红"
    h_check_contains "$v2" "非法字符键" "负向对照 2：判红原因指到「非法字符键」"

    # ── 负向对照 3：注入白名单外的合法键 → 白名单判定必须判红 ──
    local outfile="$SBX_ROOT/ocr/outside_rule.conf"
    cp "$rules/rule-1.conf" "$outfile"
    printf 'FOO_BAR="x"\n' >> "$outfile"
    local v3
    v3=$(_t50_judge_keys "$outfile" "$allowed")
    h_log "白名单外键判定: $(printf '%s' "$v3" | cut -f1) —— $(printf '%s' "$v3" | cut -f2-)"
    h_check_contains "$v3" "FAIL" "负向对照 3：注入白名单外的键后必须判红"
    h_check_contains "$v3" "白名单外的键" "负向对照 3：判红原因指到「白名单外的键」"
}

# ══════════════════════════════════════════════════════════════════
# T49 · 依赖 jq 的整段配置生成
# ══════════════════════════════════════════════════════════════════
case_T49_jq_config_generation() {
    h_case_begin "T49" "依赖 jq 的整段配置生成（用沙箱 jq 桩跑通）" \
        "沙箱 config.json + jq 桩（tests/shims/jq）" \
        "generate_network_config / rules.sh 的 proxy 开关（读 + del + 赋值）" \
        "generate_network_config 保留已有 send_proxy；proxy 三步开关都经桩正确；桩遇到不会的语法必须显式报「桩能力不足」+ 退出码 3"

    # ── (1) 冻结态 jq 调用数下限护栏 ──
    # 「jq 调用点」是本条用例的被测对象之一；先把被测对象的**规模**钉住，
    # 免得将来 jq 调用点被删光了，这条用例还「全绿」（那是假绿）。
    local jq_n=0 f
    for f in "$SBX_SRC"/lib/*.sh "$SBX_SRC"/notifications/*.sh "$SBX_SRC"/*.sh; do
        [ -f "$f" ] || continue
        n=$(grep -c 'jq ' "$f" 2>/dev/null || true)
        [ -z "$n" ] && n=0
        jq_n=$((jq_n + n))
    done
    h_log "冻结态 jq 调用点总数: $jq_n"
    h_check_ge 100 "$jq_n" "冻结态 jq 调用点的数量下限护栏"

    # ── (2) generate_network_config：已有 send_proxy 必须被保留 ──
    local cfg="$SBX_ROOT/realm/config.json"
    mkdir -p "$(dirname "$cfg")"
    cat > "$cfg" <<'EOF'
{
  "network": {
    "no_tcp": false,
    "use_udp": true,
    "send_proxy": true,
    "send_proxy_version": 2,
    "accept_proxy": true,
    "accept_proxy_timeout": 5
  }
}
EOF
    local netcfg
    netcfg=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        generate_network_config
    ' 2>&1)
    h_log "generate_network_config 输出: $(printf '%s' "$netcfg" | tr -d '\n' | cut -c1-200)"
    h_check_contains "$netcfg" '"send_proxy":true' "generate_network_config 保留了已有的 send_proxy"
    h_check_contains "$netcfg" '"accept_proxy_timeout":5' "generate_network_config 保留了已有的 accept_proxy_timeout"
    h_check_contains "$netcfg" '"use_udp":true' "generate_network_config 保留了 base_network 的字段"

    # ── (2b) 对照口径：config.json 里没有 send_proxy 时，输出就是 base_network ──
    local cfg2="$SBX_ROOT/realm/config.json"
    printf '%s' '{"network":{"no_tcp":false,"use_udp":true}}' > "$cfg2"
    local netcfg2
    netcfg2=$(_run_in_sandbox '
        source "$1/lib/core.sh" >/dev/null 2>&1
        generate_network_config
    ' 2>&1)
    h_check_not_contains "$netcfg2" 'send_proxy' "对照：config.json 没有 send_proxy 时输出里也不该有"

    # ── (3) rules.sh 的 proxy 三步开关：读 / del / 赋值（过滤器从产品源码现场抽）──
    local rules_src="$SBX_SRC/lib/rules.sh"
    local f_read f_del f_assign
    f_read=$(_t49_extract_filter "$rules_src" "send_proxy // false")
    f_del=$(_t49_extract_filter "$rules_src" "jq 'del(.network.send_proxy)")
    f_assign=$(_t49_extract_filter "$rules_src" "jq '.network.send_proxy = true")
    h_log "读过滤器  : $f_read"
    h_log "del 过滤器: $(printf '%s' "$f_del" | tr '\n' ' ')"
    h_log "赋值过滤器: $(printf '%s' "$f_assign" | tr '\n' ' ')"
    # 护栏：三个过滤器都抽到了（抽不到 = 抽取器坏了，下面全是假绿）
    h_check_ge 1 "$(printf '%s' "$f_read" | wc -c | tr -d ' ')" "读过滤器的抽取结果非空"
    h_check_ge 1 "$(printf '%s' "$f_del" | wc -c | tr -d ' ')" "del 过滤器的抽取结果非空"
    h_check_ge 1 "$(printf '%s' "$f_assign" | wc -c | tr -d ' ')" "赋值过滤器的抽取结果非空"

    local pcfg="$SBX_ROOT/realm/proxy.json"
    cat > "$pcfg" <<'EOF'
{"network":{"send_proxy":true,"send_proxy_version":2,"accept_proxy":true,"accept_proxy_timeout":5,"use_udp":true}}
EOF

    # 读
    local v_read
    v_read=$(jq -r "$f_read" "$pcfg" 2>&1)
    h_log "读的结果: $v_read"
    h_check_eq "true" "$v_read" "proxy 读过滤器：send_proxy 读出 true"

    # del
    local v_del
    v_del=$(jq -c "$f_del" "$pcfg" 2>&1)
    h_log "del 之后: $v_del"
    h_check_not_contains "$v_del" 'send_proxy' "proxy del 过滤器：send_proxy 已被删掉"
    h_check_contains "$v_del" '"use_udp":true' "proxy del 过滤器：其它 network 字段没被误删"

    # 赋值
    local v_assign
    v_assign=$(jq -c "$f_assign" "$pcfg" 2>&1)
    h_log "赋值之后: $v_assign"
    h_check_contains "$v_assign" '"send_proxy":true' "proxy 赋值过滤器：send_proxy 被打开"
    h_check_contains "$v_assign" '"send_proxy_version":2' "proxy 赋值过滤器：send_proxy_version 被写成 2"
    h_check_contains "$v_assign" '"accept_proxy_timeout":5' "proxy 赋值过滤器：accept_proxy_timeout 被写成 5"

    # ── (4) 桩必须显式说「我不会」──
    # 把产品自己的过滤器改造成桩不支持的形态（to_entries → reduce），
    # 桩必须报「桩能力不足」+ 退出码 3，而不是静默返回空值假装成功。
    local badfilter
    badfilter=$(printf '%s' "$(_t49_extract_filter "$SBX_SRC/lib/core.sh" "to_entries | map")" | sed 's/to_entries | map/reduce/')
    local b_out b_rc
    b_out=$(jq -c "$badfilter" "$cfg" 2>&1)
    b_rc=$?
    h_log "桩能力不足探测: rc=$b_rc out=$(printf '%s' "$b_out" | head -1 | cut -c1-120)"
    h_check_eq "3" "$b_rc" "桩遇到不支持的过滤器必须返回退出码 3"
    h_check_contains "$b_out" "桩能力不足" "桩必须显式打印「桩能力不足」"

    # ── 负向对照：拿掉 jq 桩 → generate_network_config 必须退回 base_network（丢 send_proxy）──
    # 这条证明「send_proxy 被保留」这个断言**有牙齿**：
    # 没有 jq 时，产品的兜底分支（|| echo "{}"）会真的走到，send_proxy 就没了。
    local nojq
    nojq=$(PATH="/usr/bin:/bin" bash -c '
        source "$1/lib/core.sh" >/dev/null 2>&1
        generate_network_config
    ' _ "$SBX_RUN" 2>&1)
    h_log "没有 jq 时的输出: $(printf '%s' "$nojq" | tr -d '\n' | cut -c1-200)"
    h_check_not_contains "$nojq" 'send_proxy' "负向对照：没有 jq 桩时 send_proxy 真的丢了（说明上面的断言拦得住）"
    # 注意：没有 jq 时走的是产品里 base_network 的**原始多行字符串**（不是 jq -c 的紧凑形态），
    # 所以这里只断言字段名在，不断言冒号后的空白。
    h_check_contains "$nojq" '"use_udp"' "负向对照：没有 jq 时退回 base_network（仍保留基础字段）"
}

# ══════════════════════════════════════════════════════════════════
# T50 · 规则增删改的落盘格式
# ══════════════════════════════════════════════════════════════════
case_T50_rule_crud_persistence() {
    h_case_begin "T50" "规则增删改的落盘格式：键合法、⊆ 白名单、read_rule_file 读得回" \
        "沙箱 rules 目录 + 冻结态 core/health/rules/server/ui" \
        "create_single_nat_rule（增） / _rule_set_field（改） / delete_rule（删）" \
        "增出来的规则键合法且全在白名单内；改完仍合法且能读回新值；删完文件消失；注入白名单外的键必须判红"

    local rules="$SBX_ROOT/realm/rules"
    rm -rf "$rules"
    mkdir -p "$rules"

    # ── 沙箱里跑一遍「增 → 改 → 删」──
    local out
    out=$(_run_in_sandbox '
        # ★ $1 = 代码根（$SBX_RUN），$2 = 沙箱 realm 目录（额外传进来的）
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/server.sh" >/dev/null 2>&1
        source "$1/lib/ui.sh" >/dev/null 2>&1

        # 造一条中转规则的输入（产品的模板靠这些全局变量）
        SECURITY_LEVEL="standard"
        NAT_LISTEN_IP="::"
        NAT_THROUGH_IP="::"
        REMOTE_IP="1.2.3.4"
        REMOTE_PORT="443"
        TLS_SERVER_NAME="example.com"
        TLS_CERT_PATH=""
        TLS_KEY_PATH=""
        WS_PATH=""
        WS_HOST=""
        RULE_NOTE=""

        # ── 增 ──
        create_single_nat_rule 8080 443 >/dev/null 2>&1
        echo "RESULT:created=$([ -f "$RULES_DIR/rule-1.conf" ] && echo yes || echo no)"

        # ── 改 ──
        _rule_set_field "$RULES_DIR/rule-1.conf" "REMOTE_HOST" "9.9.9.9"
        _rule_set_field "$RULES_DIR/rule-1.conf" "RULE_NOTE" "改过的备注"
        echo "RESULT:edited_host=$(grep -c "^REMOTE_HOST=\"9.9.9.9\"$" "$RULES_DIR/rule-1.conf")"
        echo "RESULT:edited_note=$(grep -c "^RULE_NOTE=\"改过的备注\"$" "$RULES_DIR/rule-1.conf")"

        # 读回
        if read_rule_file "$RULES_DIR/rule-1.conf"; then
            echo "RESULT:read_host=$REMOTE_HOST"
            echo "RESULT:read_port=$LISTEN_PORT"
            echo "RESULT:read_role=$RULE_ROLE"
            echo "RESULT:read_note=$RULE_NOTE"
        else
            echo "RESULT:read_host=FAIL"
        fi

        # ── 删 ──
        delete_rule 1 true >/dev/null 2>&1
        echo "RESULT:deleted=$([ -f "$RULES_DIR/rule-1.conf" ] && echo no || echo yes)"
    ' "$SBX_ROOT/realm" 2>&1)
    h_log "增改删输出: $(printf '%s' "$out" | grep -a '^RESULT:' | tr '\n' ' ')"

    h_check_eq "yes" "$(printf '%s' "$out" | grep -a '^RESULT:created=' | head -1 | sed 's/^RESULT:created=//')" "增：create_single_nat_rule 落盘了 rule-1.conf"
    h_check_eq "1" "$(printf '%s' "$out" | grep -a '^RESULT:edited_host=' | head -1 | sed 's/^RESULT:edited_host=//')" "改：REMOTE_HOST 被改成 9.9.9.9"
    h_check_eq "1" "$(printf '%s' "$out" | grep -a '^RESULT:edited_note=' | head -1 | sed 's/^RESULT:edited_note=//')" "改：RULE_NOTE 被改成新值"
    h_check_eq "9.9.9.9" "$(printf '%s' "$out" | grep -a '^RESULT:read_host=' | head -1 | sed 's/^RESULT:read_host=//')" "读回：read_rule_file 读到改后的 REMOTE_HOST"
    h_check_eq "8080" "$(printf '%s' "$out" | grep -a '^RESULT:read_port=' | head -1 | sed 's/^RESULT:read_port=//')" "读回：read_rule_file 读到 LISTEN_PORT"
    h_check_eq "1" "$(printf '%s' "$out" | grep -a '^RESULT:read_role=' | head -1 | sed 's/^RESULT:read_role=//')" "读回：read_rule_file 读到 RULE_ROLE"
    h_check_eq "yes" "$(printf '%s' "$out" | grep -a '^RESULT:deleted=' | head -1 | sed 's/^RESULT:deleted=//')" "删：delete_rule 之后文件消失"

    # ── 落盘格式：键合法 + ⊆ 白名单（用**改后**的文件判断：改完仍必须合法）──
    # 复现一次「增 + 改」，把文件留在沙箱里做格式判定
    _run_in_sandbox '
        export CONFIG_DIR="$2"
        source "$1/lib/core.sh" >/dev/null 2>&1
        source "$1/lib/health.sh" >/dev/null 2>&1
        source "$1/lib/rules.sh" >/dev/null 2>&1
        source "$1/lib/server.sh" >/dev/null 2>&1
        source "$1/lib/ui.sh" >/dev/null 2>&1
        SECURITY_LEVEL="standard"; NAT_LISTEN_IP="::"; NAT_THROUGH_IP="::"
        REMOTE_IP="1.2.3.4"; REMOTE_PORT="443"; TLS_SERVER_NAME="example.com"
        TLS_CERT_PATH=""; TLS_KEY_PATH=""; WS_PATH=""; WS_HOST=""; RULE_NOTE=""
        create_single_nat_rule 8080 443 >/dev/null 2>&1
        _rule_set_field "$RULES_DIR/rule-1.conf" "REMOTE_HOST" "9.9.9.9"
    ' "$SBX_ROOT/realm" >/dev/null 2>&1

    local rf="$rules/rule-1.conf"
    h_check_file "$rf" "增出来的规则文件"
    local allowed
    allowed=$(_t50_allowed_keys)
    local verdict
    verdict=$(_t50_judge_keys "$rf" "$allowed")
    h_log "落盘格式判定: $(printf '%s' "$verdict" | cut -f1) —— $(printf '%s' "$verdict" | cut -f2-)"
    h_check_contains "$verdict" "PASS" "增改之后的规则文件：键名合法且全在 read_rule_file 白名单内"

    # 键数下限护栏（实测 ~31 键）
    local nkeys
    nkeys=$(_t50_rule_keys "$rf" | wc -l | tr -d ' ')
    h_log "落盘键数: $nkeys"
    h_check_ge 20 "$nkeys" "落盘规则文件的键数下限护栏"

    # ── 负向对照：注入白名单外的键 → 必须判红 ──
    local badfile="$SBX_ROOT/realm/rules/bad-rule.conf"
    cp "$rf" "$badfile"
    printf 'FOO_BAR="x"\n' >> "$badfile"
    local v
    v=$(_t50_judge_keys "$badfile" "$allowed")
    h_log "白名单外键判定: $(printf '%s' "$v" | cut -f1) —— $(printf '%s' "$v" | cut -f2-)"
    h_check_contains "$v" "FAIL" "负向对照：注入白名单外的键后必须判红"
    h_check_contains "$v" "白名单外的键" "负向对照：判红原因指到「白名单外的键」"
}
