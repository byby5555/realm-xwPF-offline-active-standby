#!/bin/bash
# 用例组 32 · 更新中心的「是否已是最新」判定：**按内容指纹**，不按版本号
#
# ── 这组用例守的不变量 ─────────────────────────────────────────
#   更新中心判断「脚本包是不是最新」时，**必须看文件内容**，不能只看版本号。
#
# ── 真实触发场景（真机 103.42.31.186 · 2026-10-29）────────────
#   用户反馈：「菜单项 4『立即测试所有目标时延』仍是串行 10s 超时」。
#   查下来：GitHub main 早已是并发实现，但**机器上跑的还是旧代码**。
#   根因不是没部署，而是**部署不了**：
#     · SCRIPT_VERSION 是人工维护的字符串，从 2026-02 起就冻结在 "v2.2.1"，
#       而 lib/*.sh 之后改过几十次 ⇒ 版本号与内容**彻底脱钩**；
#     · safe_update_scripts 只比版本号 ⇒ 每次都判「版本相同 ⇒ 已是最新」
#       ⇒ 直接 return，**一个字节都不更新**；
#     · 用户在「更新中心」看到的是「✓ 脚本包已是最新版本」⇒ 拿到的还是旧代码。
#   ⇒ 「是否最新」必须落到**内容指纹**上（版本号只能给人看）。
#
# ★ 本组复用 09_update_center.sh 的沙箱站点夹具（_upd_site / _upd_prelude）：
#   cases/*.sh 按文件名顺序 source ⇒ 09 在 32 之前 ⇒ 助手函数已可用。

# ── 造一个「版本号相同、内容不同」的远端脚本包 ──
#   已装：core.sh = SCRIPT_VERSION="v2.2.1"
#   远端：core.sh = SCRIPT_VERSION="v2.2.1" + 多一行标记 ⇒ **版本号相同、内容不同**
_t135_make_same_version_new_content() {
    local site="$1"
    printf '#!/bin/bash\nSCRIPT_VERSION="v2.2.1"\n# T135-NEW-CONTENT\n' \
        > "$site/fake/remote/core.sh"
}

# ── 造一个「与已装逐字节一致」的远端脚本包 ──
_t135_make_identical_remote() {
    local site="$1"
    local p_libs f
    p_libs=$(sed -n 's/^UPDATE_LIB_FILES=(\(.*\))$/\1/p' "$SBX_SRC/lib/update.sh" 2>/dev/null | tr -d '"' | tr ' ' '\n' | grep -v '^$')
    if [ -z "$p_libs" ]; then
        echo "!! 抽不到产品的 UPDATE_LIB_FILES（lib/update.sh 形态变了？）—— 用保守清单兜底" >&2
        p_libs="core.sh health.sh rules.sh server.sh realm.sh ui.sh update.sh"
    fi
    cp -f "$site/install/xwPF.sh" "$site/fake/remote/xwPF.sh"
    for f in $p_libs; do
        [ -f "$site/install/lib/$f" ] || continue
        cp -f "$site/install/lib/$f" "$site/fake/remote/$f"
    done
}


case_T135_update_center_judges_by_content_not_version() {
    h_case_begin "T135" "更新中心：版本号相同但**文件内容不同**时必须判为可更新（不许说「已是最新」）" \
        "沙箱站点（已装 v2.2.1 + 远端也是 v2.2.1，但 lib 内容不同）" \
        "update_scripts_digest_of_paths（纯函数）+ safe_update_scripts（真实更新路径）" \
        "内容不同 ⇒ 必须提示可更新并真的替换文件（版本号相同也要更新）；内容完全一致 ⇒ 必须说「已是最新」且不产生备份；负向对照（指纹比对退化成恒等）必须判红"

    # ────────────────────────────── 腿 1：纯函数 ──────────────────────────────
    local dsite="$SBX_ROOT/upd/t135_digest"
    rm -rf "$dsite"
    mkdir -p "$dsite/a/lib" "$dsite/b/lib" "$dsite/c/lib"
    local f
    for f in core.sh rules.sh; do
        printf '#!/bin/bash\nSCRIPT_VERSION="v2.2.1"\n# A\n' > "$dsite/a/lib/$f"
        printf '#!/bin/bash\nSCRIPT_VERSION="v2.2.1"\n# B-DIFFERENT\n' > "$dsite/b/lib/$f"
        cp -f "$dsite/a/lib/$f" "$dsite/c/lib/$f"
    done
    printf '#!/bin/bash\n# A\n' > "$dsite/a/xwPF.sh"
    printf '#!/bin/bash\n# B-DIFFERENT\n' > "$dsite/b/xwPF.sh"
    cp -f "$dsite/a/xwPF.sh" "$dsite/c/xwPF.sh"

    local d_out
    # ★ `_run_in_sandbox` 已经把 $SBX_RUN 作为 $1 传进去了
    #   ⇒ 这里只追加自己的参数 ⇒ $2 = 夹具目录（多传一个会把 $2 顶掉）
    d_out=$(_run_in_sandbox '
        source "$1/lib/core.sh"  >/dev/null 2>&1
        source "$1/lib/update.sh" >/dev/null 2>&1
        echo "D_A=$(update_scripts_digest_of_paths "$2/a/xwPF.sh" "$2/a/lib")"
        echo "D_B=$(update_scripts_digest_of_paths "$2/b/xwPF.sh" "$2/b/lib")"
        echo "D_C=$(update_scripts_digest_of_paths "$2/c/xwPF.sh" "$2/c/lib")"
    ' "$dsite" 2>/dev/null)
    h_log "指纹: $(printf '%s' "$d_out" | tr '\n' ' ')"
    local d_a d_b d_c
    d_a=$(printf '%s\n' "$d_out" | grep -a '^D_A=' | cut -d= -f2)
    d_b=$(printf '%s\n' "$d_out" | grep -a '^D_B=' | cut -d= -f2)
    d_c=$(printf '%s\n' "$d_out" | grep -a '^D_C=' | cut -d= -f2)
    h_check_ge "8" "${#d_a}" "指纹算出来了（长度 ≥ 8）"
    h_check_eq "1" "$([ -n "$d_a" ] && [ "$d_a" != "$d_b" ] && echo 1 || echo 0)" "版本号相同但内容不同 ⇒ 指纹**必须**不同"
    h_check_eq "1" "$([ -n "$d_a" ] && [ "$d_a" = "$d_c" ] && echo 1 || echo 0)" "内容完全一致 ⇒ 指纹必须相同"

    # ─────────────── 腿 2：版本号相同、内容不同 ⇒ 必须真的更新 ───────────────
    local site="$SBX_ROOT/upd/t135"
    local scen="$SBX_ROOT/upd/t135.sh"
    _upd_site "$site"
    _t135_make_same_version_new_content "$site"

    {
        _upd_prelude
        cat <<'EOS'

# 已装 v2.2.1 / 远端也 v2.2.1，但**内容不同** ⇒ 必须判为可更新并真的更新
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "RESULT:a_rc=$rc"
echo "RESULT:a_uptodate=$(printf '%s' "$out" | grep -c '已是最新')"
echo "RESULT:a_hint=$(printf '%s' "$out" | grep -c '版本号相同')"
echo "RESULT:a_digest=$(printf '%s' "$out" | grep -c '内容指纹')"
echo "RESULT:a_core_new=$(grep -c 'T135-NEW-CONTENT' "$LIB_DIR/core.sh" 2>/dev/null)"
echo "RESULT:a_rules_new=$(grep -c 'new rules.sh' "$LIB_DIR/rules.sh" 2>/dev/null)"
echo "RESULT:a_backup=$(ls -1 "$UPDATE_BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ')"
EOS
    } > "$scen"

    local out
    out=$(_upd_run "$scen" "$site")
    h_log "$(printf '%s' "$out" | grep -a '^RESULT:' | tr '\n' ' ')"

    h_check_eq "0" "$(_upd_get "$out" a_uptodate)" "版本号相同但内容不同 ⇒ **不许**判「已是最新」"
    h_check_eq "1" "$(_upd_get "$out" a_hint)" "必须明确提示「版本号相同但内容不同 ⇒ 按内容更新」"
    h_check_ge "1" "$(_upd_get "$out" a_digest)" "必须打印内容指纹（让人看得见判据）"
    h_check_eq "1" "$(_upd_get "$out" a_core_new)" "core.sh 真的被换成了远端版本"
    h_check_eq "1" "$(_upd_get "$out" a_rules_new)" "rules.sh 真的被换成了远端版本"
    h_check_ge "1" "$(_upd_get "$out" a_backup)" "更新前做了备份"

    # ─────────────── 腿 3：内容完全一致 ⇒ 必须说「已是最新」且不动文件 ───────────────
    local site2="$SBX_ROOT/upd/t135_same"
    local scen2="$SBX_ROOT/upd/t135_same.sh"
    _upd_site "$site2"
    _t135_make_identical_remote "$site2"

    {
        _upd_prelude
        cat <<'EOS'

# 已装与远端**逐字节一致** ⇒ 必须判「已是最新」，且**一个文件都不动**
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "RESULT:b_rc=$rc"
echo "RESULT:b_uptodate=$(printf '%s' "$out" | grep -c '已是最新')"
echo "RESULT:b_backup=$(ls -1 "$UPDATE_BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ')"
echo "RESULT:b_changed=$(grep -c 'new core.sh' "$LIB_DIR/core.sh" 2>/dev/null)"
EOS
    } > "$scen2"

    local out2
    out2=$(_upd_run "$scen2" "$site2")
    h_log "$(printf '%s' "$out2" | grep -a '^RESULT:' | tr '\n' ' ')"

    h_check_eq "1" "$(_upd_get "$out2" b_uptodate)" "内容完全一致 ⇒ 判「已是最新」"
    h_check_eq "0" "$(_upd_get "$out2" b_backup)" "判「已是最新」时不产生备份（= 没动任何文件）"
    h_check_eq "0" "$(_upd_get "$out2" b_changed)" "判「已是最新」时已装文件没被替换"

    # ─────────────── 负向对照：把指纹比对退化成「恒等」 ───────────────
    #   退化手法：让 update_scripts_digest_of_paths 永远返回同一个常量
    #   ⇒ 远端与已装的指纹「一样」⇒ 必然判「已是最新」⇒ 腿 2 的两条断言必须红。
    local bsite="$SBX_ROOT/upd/t135_broken"
    _upd_site "$bsite"
    _t135_make_same_version_new_content "$bsite"
    mkdir -p "$bsite/lib"
    cp "$SBX_RUN/lib/"*.sh "$bsite/lib/" 2>/dev/null
    sed -i 's|^update_scripts_digest_of_paths() {|update_scripts_digest_of_paths() { echo "T135NEG-CONSTANT"; return 0;  # 负向对照：指纹比对被破坏|' \
        "$bsite/lib/update.sh"
    local inj135
    inj135=$(grep -c 'T135NEG-CONSTANT' "$bsite/lib/update.sh" 2>/dev/null); inj135=${inj135:-0}
    h_log "负向对照：指纹比对已退化成恒等（$inj135 处）"
    h_check_eq "1" "$inj135" "负向对照自检：指纹退化的注入点命中（破坏手法生效）"

    {
        cat <<'EOS'
site="$2"
export UPD_LIB_OVERRIDE="$site/lib/update.sh"
EOS
        _upd_prelude
        cat <<'EOS'

out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "RESULT:neg_uptodate=$(printf '%s' "$out" | grep -c '已是最新')"
echo "RESULT:neg_core_new=$(grep -c 'T135-NEW-CONTENT' "$LIB_DIR/core.sh" 2>/dev/null)"
EOS
    } > "$SBX_ROOT/upd/t135_broken.sh"

    local bout
    bout=$(_upd_run "$SBX_ROOT/upd/t135_broken.sh" "$bsite")
    h_log "负向对照输出: $(printf '%s' "$bout" | grep -a '^RESULT:' | tr '\n' ' ')"
    h_check_eq "1" "$(_upd_get "$bout" neg_uptodate)" "负向对照：指纹比对被破坏后**确实**判成了「已是最新」（证明上面两条断言拦得住）"
    h_check_eq "0" "$(_upd_get "$bout" neg_core_new)" "负向对照：退化后 core.sh 真的没被更新（说明内容判定这条断言有牙齿）"

    rm -rf "$dsite" "$site" "$site2" "$bsite"
    rm -f "$scen" "$scen2" "$SBX_ROOT/upd/t135_broken.sh"
}
