#!/bin/bash
# 用例组 09 · 更新中心（第 7 轮新增）
#
# 来源：原独立脚本 tests/test_update.sh（47 项断言）—— 本轮并入唯一入口，
#       原脚本改成薄封装（内部 exec 到 run_tests.sh --only ...），保证「只有一个真源」。
#
# 被测对象：冻结态 $SBX_RUN/lib/update.sh（更新中心唯一真源）
# 网络边界（curl/jq/GitHub API）换成沙箱里的假实现；真实被测的是**安全逻辑**：
#   校验不过不装、装了要能回滚、下载失败不碰现有文件、回滚失败必须被报出来。
#
# 覆盖：
#   T43 版本号归一化 + 「已是最新」判定（release tag 带 v、二进制 --version 不带 v）
#   T44 校验不过一律拒绝安装，旧文件一字节未动（sha256 不符 / 坏包 / 版本不符）
#   T45 回滚健壮性（恢复失败必须报出来 + 非 0；恢复正在运行的二进制必须走 mv 覆盖）
#   T46 自动回滚（新版本起不来 → 停服务 → 恢复旧版本 → 再拉起）
#   T47 脚本包更新（下载失败 / 语法错 → 不替换；全部就绪 → 替换 + 备份）+ 并发锁
#
# 编号说明：T41/T42 已被第 6 轮（权重落盘索引 / 单主语义）占用，本组从 T43 起。
#
# ★ 每条用例都带**负向对照**：往被测副本注入坏输入（改坏归一化 / 去掉校验 / 把回滚变成空操作），
#   确认对应断言**会红**。「怎么写都绿的断言等于没写。」

# ── 沙箱站点（模拟一台「已安装 realm」的机器）────────────────────────────
_upd_site() {
    local site="$1"
    rm -rf "$site"
    mkdir -p "$site/install/lib" "$site/install/cmd" "$site/backup" "$site/staging" "$site/lock" "$site/fake/remote"
    # 已装的 realm：真实输出是 "Realm 2.9.3 [brutal][proxy]"（**不带 v**）
    printf '#!/bin/bash\necho "Realm 2.9.3 [brutal][proxy]"\n' > "$site/install/realm"
    chmod +x "$site/install/realm"
    printf '#!/bin/bash\nSCRIPT_VERSION="v2.2.1"\n' > "$site/install/lib/core.sh"
    local f
    # ★ 假安装目录/假远端镜像的文件清单**从产品自己声明的清单抽**
    #   （lib/update.sh 的 UPDATE_LIB_FILES / UPDATE_CMD_FILES）
    #   原因：产品正在删文件（2beb7bd 删了 lib/failover.sh 与 cmd/xwpf-failover.*）。
    #   台架里写死一份清单 → 产品一改，台架就跟现实脱节（要么假红，要么漏检）。
    local p_libs p_cmds f g
    p_libs=$(sed -n 's/^UPDATE_LIB_FILES=(\(.*\))$/\1/p' "$SBX_SRC/lib/update.sh" 2>/dev/null | tr -d '"' | tr ' ' '\n' | grep -v '^$')
    p_cmds=$(sed -n 's/^UPDATE_CMD_FILES=(\(.*\))$/\1/p' "$SBX_SRC/lib/update.sh" 2>/dev/null | tr -d '"' | tr ' ' '\n' | grep -v '^$')
    # 抽不到就退回一份保守清单（抽不到 = 台架配置问题，必须看得见）
    if [ -z "$p_libs" ]; then
        echo "!! 抽不到产品的 UPDATE_LIB_FILES（lib/update.sh 形态变了？）—— 用保守清单兜底" >&2
        p_libs="core.sh health.sh rules.sh server.sh realm.sh ui.sh update.sh"
    fi
    for f in $p_libs; do
        # ★ core.sh 在上面刚写过（带 SCRIPT_VERSION="v2.2.1"）——
        #   这个循环会把它覆盖成 `#!/bin/bash\n# core.sh` ⇒ 版本号没了
        #   ⇒ T47 的「下载失败时 core.sh 没被替换」「语法错误时 core.sh 没被替换」
        #     两条断言恒为 0（**恒假**，跟产品行为无关）。
        #   ⇒ core.sh 不走这个循环，保留上面那份带版本号的。
        #   ★ 用 case 而不是 `[ "$f" = "core.sh" ] && continue`：
        #     后者在条件不成立时整条命令退出码为 1 ⇒ set -e 下会中止脚本。
        case "$f" in
            core.sh) continue ;;
        esac
        printf '#!/bin/bash\n# %s\n' "$f" > "$site/install/lib/$f"
    done
    printf '#!/bin/bash\n# xwPF\n' > "$site/install/xwPF.sh"
    for f in $p_cmds; do
        printf '# %s\n' "$f" > "$site/install/cmd/$f"
    done
    # 远端脚本包镜像（假 GitHub raw）
    for g in xwPF.sh $p_libs; do
        printf '#!/bin/bash\n# new %s\n' "$g" > "$site/fake/remote/$g"
    done
    printf '#!/bin/bash\nSCRIPT_VERSION="v9.9.9"\n' > "$site/fake/remote/core.sh"
}

# 造一个假的 release 安装包（realm 可执行，版本号由参数决定）
_upd_tarball() {
    local version="$1" out="$2" broken="${3:-false}"
    rm -rf "$site/pkg" 2>/dev/null
    mkdir -p "$site/pkg"
    if [ "$broken" = "true" ]; then
        # 不可执行的文件（模拟架构不匹配 / 文件损坏）
        printf 'not an executable\n' > "$site/pkg/realm"
        chmod 644 "$site/pkg/realm"
    else
        printf '#!/bin/bash\necho "realm %s"\n' "$version" > "$site/pkg/realm"
        chmod +x "$site/pkg/realm"
    fi
    tar -czf "$out" -C "$site/pkg" realm
}

# 场景脚本统一入口：<场景文件> <冻结态目录> <站点目录>
_upd_run() {
    bash "$1" "$SBX_RUN" "$2" 2>&1
}

# 从场景输出里取 RESULT:<key>=<value>
_upd_get() {
    local out="$1" key="$2"
    printf '%s\n' "$out" | grep -a "^RESULT:$key=" | head -1 | sed "s/^RESULT:$key=//"
}

# 场景脚本的公共前导（source 冻结态产品代码 + 覆盖网络边界）
_upd_prelude() {
    cat <<'EOS'
site="$2"
export INSTALL_DIR="$site/install"
export LIB_DIR="$site/install/lib"
export REALM_PATH="$site/install/realm"
export CONFIG_DIR="$site/realm"
export UPDATE_BACKUP_DIR="$site/backup"
export UPDATE_LOCK_DIR="$site/lock"
export UPDATE_STAGING_ROOT="$site/staging"

source "$1/lib/core.sh" >/dev/null 2>&1
source "$1/lib/health.sh" >/dev/null 2>&1
source "$1/lib/rules.sh" >/dev/null 2>&1
source "$1/lib/realm.sh" >/dev/null 2>&1
source "${UPD_LIB_OVERRIDE:-$1/lib/update.sh}" >/dev/null 2>&1

# —— 网络边界换成沙箱里的假实现 ——
FAKE_TAG="v9.9.9"
FAKE_DIGEST="deadbeef"
update_realm_latest_tag() { echo "$FAKE_TAG"; }
update_realm_asset_digest() { echo "$FAKE_DIGEST"; }
download_from_sources() {
    [ -f "$site/fake/realm.tar.gz" ] || return 1
    cp -f "$site/fake/realm.tar.gz" "$2"
}
update_download_to() {
    local url="$1" target="$2" name
    name=$(echo "$url" | sed 's|.*/||')
    [ "${DOWNLOAD_FAIL_ON:-}" = "$name" ] && return 1
    [ "${DOWNLOAD_BREAK_ON:-}" = "$name" ] && { printf '#!/bin/bash\nif [ ; then\n' > "$target"; return 0; }
    [ -f "$site/fake/remote/$name" ] || return 1
    cp -f "$site/fake/remote/$name" "$target"
    return 0
}
# —— 服务层假实现 ——
svc_is_active() { [ -f "$site/realm_running" ]; }
svc_start() { [ "${SVC_START_FAIL:-}" = "1" ] && return 1; touch "$site/realm_running"; }
svc_stop() { rm -f "$site/realm_running"; }
EOS
}

# ─────────────────────────────────────────────────────────────────────
case_T43_version_normalize_and_uptodate() {
    h_case_begin "T43" "版本号归一化 + 「已是最新」判定" \
        "沙箱站点（假 realm 二进制 + 假 release tag）" \
        "safe_update_realm（tag=v2.9.6 / 二进制=Realm 2.9.3）" \
        "归一化后版本比较成立 → 更新成功；再跑一次识别为「已是最新」且不重新下载"

    local site="$SBX_ROOT/upd/t43"
    _upd_site "$site"
    local scen="$SBX_ROOT/upd/t43.sh"

    {
        _upd_prelude
        cat <<'EOS'

echo "RESULT:norm_v=$(update_norm_version 'v2.9.6')"
echo "RESULT:norm_plain=$(update_norm_version '2.9.6')"
echo "RESULT:norm_upper=$(update_norm_version 'V2.9.6')"
echo "RESULT:norm_empty=$(update_norm_version '')"

# 现场：已装 realm 输出 "Realm 2.9.3 ..."（无 v），上游 tag 是 "v2.9.6"（有 v）
FAKE_TAG="v2.9.6"
mkdir -p "$site/pkg"
printf '#!/bin/bash\necho "realm 2.9.6"\n' > "$site/pkg/realm"
chmod +x "$site/pkg/realm"
tar -czf "$site/fake/realm.tar.gz" -C "$site/pkg" realm
FAKE_DIGEST=$(sha256sum "$site/fake/realm.tar.gz" | awk '{print $1}')

out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "RESULT:first_rc=$rc"
echo "RESULT:first_mismatch=$(printf '%s' "$out" | grep -c '版本与目标不符')"
echo "RESULT:first_installed=$(grep -c 'realm 2.9.6' "$REALM_PATH" 2>/dev/null)"

out2=$(printf 'y\n' | safe_update_realm 2>&1); rc2=$?
echo "RESULT:second_rc=$rc2"
echo "RESULT:second_uptodate=$(printf '%s' "$out2" | grep -c '已是最新')"
echo "RESULT:second_download=$(printf '%s' "$out2" | grep -c '下载:')"
EOS
    } > "$scen"

    local out
    out=$(_upd_run "$scen" "$site")
    h_log "$(printf '%s' "$out" | grep -a '^RESULT:' | tr '\n' ' ')"

    h_check_eq "2.9.6" "$(_upd_get "$out" norm_v)" "归一化 v2.9.6 → 2.9.6"
    h_check_eq "2.9.6" "$(_upd_get "$out" norm_plain)" "归一化 2.9.6 → 2.9.6"
    h_check_eq "2.9.6" "$(_upd_get "$out" norm_upper)" "归一化 V2.9.6 → 2.9.6"
    h_check_eq "" "$(_upd_get "$out" norm_empty)" "归一化 空串 → 空串"

    h_check_eq "0" "$(_upd_get "$out" first_rc)" "tag 带 v / 二进制不带 v 时更新成功"
    h_check_eq "0" "$(_upd_get "$out" first_mismatch)" "日志里没有「版本与目标不符」"
    h_check_eq "1" "$(_upd_get "$out" first_installed)" "新二进制已装上"

    h_check_eq "0" "$(_upd_get "$out" second_rc)" "已是最新时返回 0"
    h_check_eq "1" "$(_upd_get "$out" second_uptodate)" "第二次识别为「已是最新」"
    h_check_eq "0" "$(_upd_get "$out" second_download)" "已是最新时没有再次下载"

    # ── 负向对照：把归一化去掉（注入坏输入到被测副本）→ 必须判红 ──
    local broken_site="$SBX_ROOT/upd/t43_broken"
    _upd_site "$broken_site"
    mkdir -p "$broken_site/lib"
    cp "$SBX_RUN/lib/"*.sh "$broken_site/lib/" 2>/dev/null
    sed -i 's|^    v="${v#v}"$|    : 归一化被破坏|; s|^    v="${v#V}"$|    : 归一化被破坏|' \
        "$broken_site/lib/update.sh"
    local inj43
    inj43=$(grep -c '归一化被破坏' "$broken_site/lib/update.sh" 2>/dev/null)
    h_log "负向对照：已从被测副本里去掉版本归一化（$inj43 处）"
    # ★ 破坏手法生效的**正向确认**：注入点没命中 → 症状当然不会出现 → 断言必红 → 会被误当成产品缺陷
    h_check_eq "2" "$inj43" "负向对照自检：归一化破坏确实注入了 2 处（破坏手法生效）"

    {
        # ★ 坏副本必须在 prelude **之前** 指定，否则 prelude 里 source 的还是原版
        #   （site 也要先赋值，否则 $site 为空 → UPDATE_LIB 变成 /lib）
        cat <<'EOS'
site="$2"
export UPD_LIB_OVERRIDE="$site/lib/update.sh"
EOS
        _upd_prelude
        cat <<'EOS'
FAKE_TAG="v2.9.6"
mkdir -p "$site/pkg"
printf '#!/bin/bash\necho "realm 2.9.6"\n' > "$site/pkg/realm"
chmod +x "$site/pkg/realm"
tar -czf "$site/fake/realm.tar.gz" -C "$site/pkg" realm
FAKE_DIGEST=$(sha256sum "$site/fake/realm.tar.gz" | awk '{print $1}')
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "RESULT:broken_rc=$rc"
echo "RESULT:broken_mismatch=$(printf '%s' "$out" | grep -c '版本与目标不符')"
EOS
    } > "$SBX_ROOT/upd/t43_broken.sh"

    local bout
    bout=$(_upd_run "$SBX_ROOT/upd/t43_broken.sh" "$broken_site")
    h_log "负向对照输出: $(printf '%s' "$bout" | grep -a '^RESULT:' | tr '\n' ' ')"
    h_check_eq "1" "$(_upd_get "$bout" broken_rc)" "负向对照：去掉归一化后更新被拒（返回非 0）"
    h_check_eq "1" "$(_upd_get "$bout" broken_mismatch)" "负向对照：日志出现「版本与目标不符」"
}

# ─────────────────────────────────────────────────────────────────────
case_T44_refuse_on_failed_verification() {
    h_case_begin "T44" "校验不过一律拒绝安装，旧文件一字节未动" \
        "沙箱站点（假 release 包 + 假 digest）" \
        "safe_update_realm（sha256 不符 / 坏包 / 版本不符）" \
        "三种校验失败都返回非 0；已装的二进制一个字节都没动；不产生备份目录"

    local site="$SBX_ROOT/upd/t44"
    local scen="$SBX_ROOT/upd/t44.sh"
    _upd_site "$site"

    {
        _upd_prelude
        cat <<'EOS'

mkpkg() {  # $1=版本 $2=坏包?
    rm -rf "$site/pkg"; mkdir -p "$site/pkg"
    if [ "${2:-}" = "broken" ]; then
        printf 'not an executable\n' > "$site/pkg/realm"; chmod 644 "$site/pkg/realm"
    else
        printf '#!/bin/bash\necho "realm %s"\n' "$1" > "$site/pkg/realm"; chmod +x "$site/pkg/realm"
    fi
    tar -czf "$site/fake/realm.tar.gz" -C "$site/pkg" realm
}

ORIG=$(cat "$REALM_PATH")

# (a) sha256 不符
mkpkg "v9.9.9"
FAKE_TAG="v9.9.9"
FAKE_DIGEST="0000000000000000000000000000000000000000000000000000000000000000"
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "RESULT:digest_rc=$rc"
echo "RESULT:digest_unchanged=$(cat "$REALM_PATH" | grep -c 'Realm 2.9.3')"
echo "RESULT:digest_backup=$(ls -1 "$UPDATE_BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ')"

# (b) 新二进制跑不起来（坏包）
mkpkg "v9.9.9" broken
FAKE_DIGEST=$(sha256sum "$site/fake/realm.tar.gz" | awk '{print $1}')
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "RESULT:broken_rc=$rc"
echo "RESULT:broken_unchanged=$(cat "$REALM_PATH" | grep -c 'Realm 2.9.3')"

# (c) 新二进制版本与目标不符
mkpkg "v1.0.0"
FAKE_DIGEST=$(sha256sum "$site/fake/realm.tar.gz" | awk '{print $1}')
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "RESULT:wrongver_rc=$rc"
echo "RESULT:wrongver_unchanged=$(cat "$REALM_PATH" | grep -c 'Realm 2.9.3')"
echo "RESULT:wrongver_msg=$(printf '%s' "$out" | grep -c '版本与目标不符')"
EOS
    } > "$scen"

    local out
    out=$(_upd_run "$scen" "$site")
    h_log "$(printf '%s' "$out" | grep -a '^RESULT:' | tr '\n' ' ')"

    h_check_rc "nonzero" "$(_upd_get "$out" digest_rc)" "sha256 不符时返回非 0"
    h_check_eq "1" "$(_upd_get "$out" digest_unchanged)" "sha256 不符时旧二进制没被改动"
    h_check_eq "0" "$(_upd_get "$out" digest_backup)" "sha256 不符时不产生备份目录"

    h_check_rc "nonzero" "$(_upd_get "$out" broken_rc)" "新二进制跑不起来时返回非 0"
    h_check_eq "1" "$(_upd_get "$out" broken_unchanged)" "新二进制跑不起来时旧二进制没被改动"

    h_check_rc "nonzero" "$(_upd_get "$out" wrongver_rc)" "新二进制版本不符时返回非 0"
    h_check_eq "1" "$(_upd_get "$out" wrongver_unchanged)" "新二进制版本不符时旧二进制没被改动"
    h_check_eq "1" "$(_upd_get "$out" wrongver_msg)" "版本不符时日志说明原因"

    # ── 负向对照：把 sha256 校验改成永远通过 → (a) 必须变成「装上了」→ 断言会红 ──
    local bsite="$SBX_ROOT/upd/t44_broken"
    _upd_site "$bsite"
    mkdir -p "$bsite/lib"
    cp "$SBX_RUN/lib/"*.sh "$bsite/lib/" 2>/dev/null
    sed -i 's|if \[ "$got" != "$digest" \]; then|if false; then  # 负向对照：哈希校验被破坏|' \
        "$bsite/lib/update.sh"
    local inj44
    inj44=$(grep -c '哈希校验被破坏' "$bsite/lib/update.sh" 2>/dev/null)
    h_log "负向对照：已把 sha256 校验改成永远通过（$inj44 处）"
    h_check_eq "1" "$inj44" "负向对照自检：哈希校验破坏确实注入了 1 处（破坏手法生效）"

    {
        cat <<'EOS'
site="$2"
export UPD_LIB_OVERRIDE="$site/lib/update.sh"
EOS
        _upd_prelude
        cat <<'EOS'
rm -rf "$site/pkg"; mkdir -p "$site/pkg"
printf '#!/bin/bash\necho "realm v9.9.9"\n' > "$site/pkg/realm"; chmod +x "$site/pkg/realm"
tar -czf "$site/fake/realm.tar.gz" -C "$site/pkg" realm
FAKE_TAG="v9.9.9"
FAKE_DIGEST="0000000000000000000000000000000000000000000000000000000000000000"
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "RESULT:broken_rc=$rc"
echo "RESULT:broken_installed=$(grep -c 'realm v9.9.9' "$REALM_PATH" 2>/dev/null)"
EOS
    } > "$SBX_ROOT/upd/t44_broken.sh"

    local bout
    bout=$(_upd_run "$SBX_ROOT/upd/t44_broken.sh" "$bsite")
    h_log "负向对照输出: $(printf '%s' "$bout" | grep -a '^RESULT:' | tr '\n' ' ')"
    h_check_eq "0" "$(_upd_get "$bout" broken_rc)" "负向对照：哈希校验被破坏后更新不再被拒"
    h_check_eq "1" "$(_upd_get "$bout" broken_installed)" "负向对照：坏包真的被装上了（说明上一组断言拦得住）"
}

# ─────────────────────────────────────────────────────────────────────
case_T45_restore_backup_robust() {
    h_case_begin "T45" "回滚健壮性：恢复失败必须报出来，恢复正在运行的二进制必须走 mv 覆盖" \
        "沙箱站点 + 真二进制 ETXTBSY 现场" \
        "update_restore_backup（恢复失败 / 恢复成功 / 覆盖正在运行的二进制）" \
        "恢复失败 → 非 0 + 打印原因；恢复成功 → 0；正在运行的二进制必须能恢复成功（mv 覆盖）"

    local site="$SBX_ROOT/upd/t45"
    local scen="$SBX_ROOT/upd/t45.sh"
    _upd_site "$site"

    {
        _upd_prelude
        cat <<'EOS'

# (a) 恢复失败：备份里的路径落在不存在的目录 → cp/mv 都会失败
BADBAK="$site/backup/bad-restore"
mkdir -p "$BADBAK/nonexistent_dir_xyz"
printf 'x' > "$BADBAK/nonexistent_dir_xyz/realm"
out=$(update_restore_backup "$BADBAK" 2>&1); rc=$?
echo "RESULT:fail_rc=$rc"
echo "RESULT:fail_msg=$(printf '%s' "$out" | grep -c '恢复失败')"

# (b) 恢复成功
OKBAK="$site/backup/ok-restore"
mkdir -p "$OKBAK"
printf 'hello\n' > "$OKBAK/probe.txt"
out=$(update_restore_backup "$OKBAK" 2>&1); rc=$?
echo "RESULT:ok_rc=$rc"

# (c) 正在运行的二进制：恢复必须成功（走「临时文件 + mv 覆盖」）
BUSY="$site/busy.bin"
SLEEP_BIN="$(command -v sleep 2>/dev/null || true)"
echo "RESULT:have_real_bin=$([ -n "$SLEEP_BIN" ] && echo yes || echo no)"
if [ -n "$SLEEP_BIN" ] && cp "$SLEEP_BIN" "$BUSY" 2>/dev/null && chmod +x "$BUSY" 2>/dev/null; then
    "$BUSY" 5 >/dev/null 2>&1 &
    BUSY_PID=$!
    sleep 1
    printf 'x' > "$site/busy.src"
    # 注意：不能用 cp -f —— -f 会在打不开目标时先删掉目标再重试，ETXTBSY 会被它掩盖
    cp_err=$(cp "$site/busy.src" "$BUSY" 2>&1)
    if [ -z "$cp_err" ]; then
        echo "RESULT:etxtbsy=none"          # 本机不产生 ETXTBSY → 该子项不适用
    elif printf '%s' "$cp_err" | grep -q "Text file busy"; then
        echo "RESULT:etxtbsy=text-busy"    # Linux 内核语义
    elif printf '%s' "$cp_err" | grep -qi "Device or resource busy"; then
        echo "RESULT:etxtbsy=device-busy"  # Windows 语义（同样拦住，但 mv 也绕不过）
    else
        echo "RESULT:etxtbsy=other:$cp_err"
    fi
    # 恢复：备份里的相对路径必须指向这个正在运行的二进制
    # ★ 相对路径 = $site 去掉**一个**前导斜杠（restore 写的是 "/${rel}"）。
    #   旧写法 "tmp/${site#/}/..." 把 /tmp 拼了两遍 → 目标目录不存在 → 恢复必然失败 →
    #   这一子项其实**什么都没测**（假绿）。第 8 轮由 inode 等价断言把它抓出来后修掉。
    REL="${site#/}/busy.bin"
    echo "RESULT:busy_target_dir=$([ -d "/$(dirname "$REL")" ] && echo ok || echo missing)"
    BAK2="$site/backup/busy-bak"
    mkdir -p "$BAK2/$(dirname "$REL")"
    printf '#!/bin/bash\necho restored\n' > "$BAK2/$REL"
    out=$(update_restore_backup "$BAK2" 2>&1); rc=$?
    echo "RESULT:busy_restore_rc=$rc"
    echo "RESULT:busy_msg=$(printf '%s' "$out" | grep -c '恢复失败')"
    echo "RESULT:busy_content=$(grep -c 'restored' "$BUSY" 2>/dev/null)"
    kill "$BUSY_PID" 2>/dev/null
    wait "$BUSY_PID" 2>/dev/null
else
    echo "RESULT:etxtbsy=none"
    echo "RESULT:busy_restore_rc=skip"
    echo "RESULT:busy_msg=skip"
    echo "RESULT:busy_content=skip"
fi

# (d) 【本机可跑的等价断言】恢复必须走「替换」语义（临时文件 + mv 覆盖），
#     而不是「原地 cp 覆写」。
#     为什么必须有它：ETXTBSY 是 **Linux 内核**行为 → Git Bash/Windows 上根本复现不出来，
#     只断言 ETXTBSY 那条在非 Linux 上等于没测（skip ≠ 放过，必须有等价断言兜住）。
#     判据选「inode 是否变化」：原地 cp 覆写 → inode 不变；替换（mv/rename）→ inode 变。
#     这正是「会不会撞 ETXTBSY」的可观测代理 —— 断言的是**效果**，不是命令名。
#     目标选**非运行中**的二进制：运行中的文件在本机会被系统锁住（device-busy），
#     恢复失败与「实现对不对」无关 → inode 判据必须放在不被锁的场景里。
IDLE="$site/idle.bin"
if [ -n "$SLEEP_BIN" ]; then cp "$SLEEP_BIN" "$IDLE" 2>/dev/null; else printf '#!/bin/bash\necho idle\n' > "$IDLE"; fi
chmod +x "$IDLE" 2>/dev/null
REL2="${site#/}/idle.bin"
echo "RESULT:idle_target_dir=$([ -d "/$(dirname "$REL2")" ] && echo ok || echo missing)"
BAK3="$site/backup/idle-bak"
mkdir -p "$BAK3/$(dirname "$REL2")"
printf '#!/bin/bash\necho idle-restored\n' > "$BAK3/$REL2"
ino_before=$(stat -c %i "$IDLE" 2>/dev/null)
out=$(update_restore_backup "$BAK3" 2>&1); rc=$?
ino_after=$(stat -c %i "$IDLE" 2>/dev/null)
echo "RESULT:idle_rc=$rc"
echo "RESULT:idle_inode_before=${ino_before:-none}"
echo "RESULT:idle_inode_after=${ino_after:-none}"
echo "RESULT:idle_content=$(grep -c 'idle-restored' "$IDLE" 2>/dev/null)"
EOS
    } > "$scen"

    local out
    out=$(_upd_run "$scen" "$site")
    h_log "$(printf '%s' "$out" | grep -a '^RESULT:' | tr '\n' ' ')"

    h_check_rc "nonzero" "$(_upd_get "$out" fail_rc)" "恢复失败时返回非 0（不静默吞错误）"
    h_check_ge 1 "$(_upd_get "$out" fail_msg)" "恢复失败时打印了原因（命中行数）"
    h_check_rc "0" "$(_upd_get "$out" ok_rc)" "恢复成功时返回 0"

    local etxt="$(_upd_get "$out" etxtbsy)"
    local brc="$(_upd_get "$out" busy_restore_rc)"
    local bmsg="$(_upd_get "$out" busy_msg)"
    if [ "$etxt" = "text-busy" ]; then
        # Linux 内核语义：mv 改的是目录项，**不受 ETXTBSY 限制** → 恢复必须成功
        h_pass "本机可复现 ETXTBSY（Linux 语义）→ 已验证「直接 cp 覆盖被内核挡住、mv 覆盖不受影响」"
        h_check_rc "0" "$brc" "ETXTBSY 环境下恢复仍然成功（走 mv 覆盖）"
        h_check_eq "1" "$(_upd_get "$out" busy_content)" "恢复后文件内容正确"
    elif [ "$etxt" = "device-busy" ]; then
        # Windows 语义：运行中的 exe 被锁，**任何**替换工具（含 mv/rename）都绕不过
        #   → 唯一能要求的是「不许静默失败」：要么成功，要么明确报出失败原因并返回非 0
        h_log "本机是 Windows 语义（cp 报 Device or resource busy）：直接 cp 覆盖运行中的 exe 被系统挡住，"
        h_log "  但 mv 改的是目录项 → **可以替换运行中的可执行文件**（本机实测 busy_restore_rc=0）。"
        h_log "  → 这正好证明「必须走 mv 覆盖」：cp 会被挡、mv 不会。"
        h_log "  （若某平台连 mv 也失败，则退化为「不许静默失败」：要么成功，要么明确报出原因并返回非 0。）"
        if [ "$brc" = "0" ]; then
            h_pass "覆盖正在运行的二进制成功"
            h_check_eq "1" "$(_upd_get "$out" busy_content)" "恢复后文件内容正确"
        else
            h_log "mv 覆盖也被系统拒绝（rc=$brc）→ 断言它必须**明确报出失败原因**而不是静默"
            h_check_rc "nonzero" "$brc" "覆盖失败时返回非 0"
            h_check_ge 1 "$bmsg" "覆盖失败时打印了原因（命中行数）"
        fi
    else
        h_log "本机不产生 ETXTBSY（$etxt）→「覆盖正在运行的二进制」这一子项**不适用**"
        h_pass "ETXTBSY 场景不适用（本机不复现）"
    fi

    # ── 本机可跑的等价断言：恢复必须走「替换」语义（**不依赖 ETXTBSY**）──
    #   ETXTBSY 是 Linux 内核行为 → 非 Linux 上「skip」等于没测；
    #   这里用 inode 变化做等价判据：原地 cp 覆写 → inode 不变；替换（mv/rename）→ inode 变。
    #   ★ 这一条让「修复前的冻结点 610a076^（直接 cp 覆写）」在本机也能判红。
    local ibefore="$(_upd_get "$out" idle_inode_before)"
    local iafter="$(_upd_get "$out" idle_inode_after)"
    if [ "$(_upd_get "$out" idle_target_dir)" != "ok" ]; then
        # 目标目录在沙箱里不可达 → 这一子项**不适用**，明确跳过（不假装测过）
        h_log "沙箱里恢复目标目录不可达 → 「替换语义」这一子项不适用（明确 skip）"
        h_pass "「替换语义」子项不适用（目标目录不可达）"
    else
    h_check_rc "0" "$(_upd_get "$out" idle_rc)" "恢复一个非运行中的二进制成功"
    h_check_eq "1" "$(_upd_get "$out" idle_content)" "恢复后内容正确"
    if [ -z "$ibefore" ] || [ "$ibefore" = "none" ]; then
        h_log "本机无 stat（inode 判据不适用）→ 只保留「恢复成功 + 内容正确」两条"
        h_pass "inode 判据不适用（本机无 stat）"
    elif [ "$ibefore" != "$iafter" ]; then
        h_pass "恢复走的是「替换」语义（inode 变化 $ibefore → $iafter）—— 不是原地 cp 覆写"
    else
        h_fail "恢复后 inode 未变化（$ibefore → $iafter）—— 疑似原地 cp 覆写，没有走 mv 覆盖"
    fi
    fi

    # ── 负向对照：把回滚函数换成「什么都不做还返回 0」→ 失败必须不再被报出来 ──
    local bsite="$SBX_ROOT/upd/t45_broken"
    _upd_site "$bsite"
    mkdir -p "$bsite/lib"
    cp "$SBX_RUN/lib/"*.sh "$bsite/lib/" 2>/dev/null
    {
        cat <<'EOS'
site="$2"
export UPD_LIB_OVERRIDE="$site/lib/update.sh"
EOS
        _upd_prelude
        cat <<'EOS'
# 负向对照：回滚变成空操作（静默吞错误的老毛病）
update_restore_backup() { return 0; }
echo "RESULT:broken_override=$(declare -f update_restore_backup | grep -c 'return 0')"
BADBAK="$site/backup/bad-restore"
mkdir -p "$BADBAK/nonexistent_dir_xyz"
printf 'x' > "$BADBAK/nonexistent_dir_xyz/realm"
out=$(update_restore_backup "$BADBAK" 2>&1); rc=$?
echo "RESULT:broken_rc=$rc"
echo "RESULT:broken_msg=$(printf '%s' "$out" | grep -c '恢复失败')"
EOS
    } > "$SBX_ROOT/upd/t45_broken.sh"

    local bout
    bout=$(_upd_run "$SBX_ROOT/upd/t45_broken.sh" "$bsite")
    h_log "负向对照输出: $(printf '%s' "$bout" | grep -a '^RESULT:' | tr '\n' ' ')"
    h_check_eq "1" "$(_upd_get "$bout" broken_override)" "负向对照自检：回滚确实被替换成空操作（覆盖生效）"
    h_check_eq "0" "$(_upd_get "$bout" broken_rc)" "负向对照：回滚空操作后不再返回非 0"
    h_check_eq "0" "$(_upd_get "$bout" broken_msg)" "负向对照：回滚空操作后不再报失败原因"
}

# ─────────────────────────────────────────────────────────────────────
case_T46_auto_rollback_on_start_failure() {
    h_case_begin "T46" "自动回滚：新版本起不来 → 停服务 → 恢复旧版本 → 再拉起" \
        "沙箱站点（服务本来在跑 + svc_start 失败）" \
        "safe_update_realm" \
        "新版本起不来 → 返回非 0 + 日志有「自动回滚」+ 旧版本被恢复"

    local site="$SBX_ROOT/upd/t46"
    local scen="$SBX_ROOT/upd/t46.sh"
    _upd_site "$site"

    {
        _upd_prelude
        cat <<'EOS'

rm -rf "$site/pkg"; mkdir -p "$site/pkg"
printf '#!/bin/bash\necho "realm v9.9.9"\n' > "$site/pkg/realm"; chmod +x "$site/pkg/realm"
tar -czf "$site/fake/realm.tar.gz" -C "$site/pkg" realm
FAKE_TAG="v9.9.9"
FAKE_DIGEST=$(sha256sum "$site/fake/realm.tar.gz" | awk '{print $1}')
touch "$site/realm_running"        # 服务本来在跑
OLD_BIN=$(cat "$REALM_PATH")
SVC_START_FAIL=1                  # 让 svc_start 失败 → 触发「新版本启动失败」分支
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "RESULT:rc=$rc"
echo "RESULT:rollback_msg=$(printf '%s' "$out" | grep -c '自动回滚')"
echo "RESULT:restored=$(cat "$REALM_PATH" | grep -c 'Realm 2.9.3')"
echo "RESULT:old_same=$([ "$(cat "$REALM_PATH")" = "$OLD_BIN" ] && echo yes || echo no)"
EOS
    } > "$scen"

    local out
    out=$(_upd_run "$scen" "$site")
    h_log "$(printf '%s' "$out" | grep -a '^RESULT:' | tr '\n' ' ')"

    h_check_rc "nonzero" "$(_upd_get "$out" rc)" "新版本起不来时返回非 0"
    h_check_eq "1" "$(_upd_get "$out" rollback_msg)" "日志里有「自动回滚」"
    h_check_eq "1" "$(_upd_get "$out" restored)" "旧版本已被恢复"
    h_check_eq "yes" "$(_upd_get "$out" old_same)" "恢复后与旧版本逐字节相同"

    # ── 负向对照：把回滚换成空操作 → 旧版本不会被恢复 → 断言必须红 ──
    local bsite="$SBX_ROOT/upd/t46_broken"
    _upd_site "$bsite"
    mkdir -p "$bsite/lib"
    cp "$SBX_RUN/lib/"*.sh "$bsite/lib/" 2>/dev/null
    {
        cat <<'EOS'
site="$2"
export UPD_LIB_OVERRIDE="$site/lib/update.sh"
EOS
        _upd_prelude
        cat <<'EOS'
update_restore_backup() { return 0; }   # 负向对照：回滚空操作
echo "RESULT:broken_override=$(declare -f update_restore_backup | grep -c 'return 0')"
rm -rf "$site/pkg"; mkdir -p "$site/pkg"
printf '#!/bin/bash\necho "realm v9.9.9"\n' > "$site/pkg/realm"; chmod +x "$site/pkg/realm"
tar -czf "$site/fake/realm.tar.gz" -C "$site/pkg" realm
FAKE_TAG="v9.9.9"
FAKE_DIGEST=$(sha256sum "$site/fake/realm.tar.gz" | awk '{print $1}')
touch "$site/realm_running"
OLD_BIN=$(cat "$REALM_PATH")
SVC_START_FAIL=1
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "RESULT:broken_rc=$rc"
echo "RESULT:broken_old_kept=$([ "$(cat "$REALM_PATH")" = "$OLD_BIN" ] && echo yes || echo no)"
EOS
    } > "$SBX_ROOT/upd/t46_broken.sh"

    local bout
    bout=$(_upd_run "$SBX_ROOT/upd/t46_broken.sh" "$bsite")
    h_log "负向对照输出: $(printf '%s' "$bout" | grep -a '^RESULT:' | tr '\n' ' ')"
    h_check_eq "1" "$(_upd_get "$bout" broken_override)" "负向对照自检：回滚确实被替换成空操作（覆盖生效）"
    h_check_eq "no" "$(_upd_get "$bout" broken_old_kept)" "负向对照：回滚空操作后旧版本没被恢复（说明本用例拦得住）"
}

# ─────────────────────────────────────────────────────────────────────
case_T47_scripts_update_and_lock() {
    h_case_begin "T47" "脚本包更新（下载失败/语法错 → 不替换；全部就绪 → 替换+备份）+ 并发锁" \
        "沙箱站点 + 假远端脚本包" \
        "safe_update_scripts / update_lock_acquire" \
        "下载中途失败与语法错误都不碰现有文件；全部就绪才替换并备份；活锁抢不到、陈旧锁能接管"

    local site="$SBX_ROOT/upd/t47"
    local scen="$SBX_ROOT/upd/t47.sh"
    _upd_site "$site"

    {
        _upd_prelude
        cat <<'EOS'

# (a) 下载中途失败 → 现有文件一个都不动
before=$(cat "$LIB_DIR/core.sh")
DOWNLOAD_FAIL_ON="rules.sh"
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "RESULT:dlfail_rc=$rc"
echo "RESULT:dlfail_core=$(cat "$LIB_DIR/core.sh" | grep -c 'SCRIPT_VERSION="v2.2.1"')"
echo "RESULT:dlfail_backup=$(ls -1 "$UPDATE_BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ')"

# (b) 下载到的脚本有语法错误 → 拒绝替换
DOWNLOAD_FAIL_ON=""
DOWNLOAD_BREAK_ON="core.sh"
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "RESULT:syntax_rc=$rc"
echo "RESULT:syntax_core=$(cat "$LIB_DIR/core.sh" | grep -c 'SCRIPT_VERSION="v2.2.1"')"
DOWNLOAD_BREAK_ON=""

# (c) 全部就绪 → 替换 + 备份
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "RESULT:ok_rc=$rc"
echo "RESULT:ok_core=$(grep -o 'SCRIPT_VERSION=\"[^\"]*\"' "$LIB_DIR/core.sh" | head -1)"
echo "RESULT:ok_xwpf=$(grep -c 'new xwPF.sh' "$INSTALL_DIR/xwPF.sh")"
echo "RESULT:ok_backup=$(ls -1 "$UPDATE_BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ')"

# (d) 并发锁
rm -rf "$UPDATE_LOCK_DIR"; mkdir -p "$UPDATE_LOCK_DIR"
echo $$ > "$UPDATE_LOCK_DIR/pid"
update_lock_acquire >/dev/null 2>&1; rc=$?
echo "RESULT:lock_live_rc=$rc"
echo "RESULT:has_proc=$([ -d "/proc/$$" ] && echo yes || echo no)"
echo 999999 > "$UPDATE_LOCK_DIR/pid"
update_lock_acquire >/dev/null 2>&1; rc=$?
echo "RESULT:lock_stale_rc=$rc"
update_lock_release
EOS
    } > "$scen"

    local out
    out=$(_upd_run "$scen" "$site")
    h_log "$(printf '%s' "$out" | grep -a '^RESULT:' | tr '\n' ' ')"

    h_check_rc "nonzero" "$(_upd_get "$out" dlfail_rc)" "下载中途失败时返回非 0"
    h_check_eq "1" "$(_upd_get "$out" dlfail_core)" "下载失败时 core.sh 没被替换"
    h_check_eq "0" "$(_upd_get "$out" dlfail_backup)" "下载失败时不产生备份"

    h_check_rc "nonzero" "$(_upd_get "$out" syntax_rc)" "脚本语法错误时返回非 0"
    h_check_eq "1" "$(_upd_get "$out" syntax_core)" "语法错误时 core.sh 没被替换"

    h_check_rc "0" "$(_upd_get "$out" ok_rc)" "全部就绪时返回 0"
    h_check_contains "$(_upd_get "$out" ok_core)" 'SCRIPT_VERSION="v9.9.9"' "core.sh 已换成新版"
    h_check_eq "1" "$(_upd_get "$out" ok_xwpf)" "xwPF.sh 已换成新版"
    h_check_ge 1 "$(_upd_get "$out" ok_backup)" "生成了脚本备份（目录数 ≥ 1）"

    if [ "$(_upd_get "$out" has_proc)" = "yes" ]; then
        h_check_rc "nonzero" "$(_upd_get "$out" lock_live_rc)" "活着的进程持有锁 → 抢锁失败"
    else
        h_log "本机没有 /proc → 「活锁」这一子项**桩能力不足**，无法判定（只断言陈旧锁可接管）"
        h_pass "活锁判定不适用（本机无 /proc）"
    fi
    h_check_rc "0" "$(_upd_get "$out" lock_stale_rc)" "陈旧锁（进程已死）→ 可接管"

    # ── 负向对照：把语法检查去掉 → 坏脚本会被装上 → 断言必须红 ──
    local bsite="$SBX_ROOT/upd/t47_broken"
    _upd_site "$bsite"
    mkdir -p "$bsite/lib"
    cp "$SBX_RUN/lib/"*.sh "$bsite/lib/" 2>/dev/null
    sed -i 's|if ! bash -n "$f" 2>/dev/null; then|if false; then  # 负向对照：语法检查被破坏|' \
        "$bsite/lib/update.sh"
    local inj47
    inj47=$(grep -c '语法检查被破坏' "$bsite/lib/update.sh" 2>/dev/null)
    h_log "负向对照：已去掉脚本语法检查（$inj47 处）"
    h_check_eq "1" "$inj47" "负向对照自检：语法检查破坏确实注入了 1 处（破坏手法生效）"
    {
        cat <<'EOS'
site="$2"
export UPD_LIB_OVERRIDE="$site/lib/update.sh"
EOS
        _upd_prelude
        cat <<'EOS'
DOWNLOAD_BREAK_ON="core.sh"
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "RESULT:broken_rc=$rc"
echo "RESULT:broken_core=$(cat "$LIB_DIR/core.sh" | grep -c 'SCRIPT_VERSION="v2.2.1"')"
echo "RESULT:broken_broken_installed=$(grep -c 'if \[ ; then' "$LIB_DIR/core.sh")"
EOS
    } > "$SBX_ROOT/upd/t47_broken.sh"

    local bout
    bout=$(_upd_run "$SBX_ROOT/upd/t47_broken.sh" "$bsite")
    h_log "负向对照输出: $(printf '%s' "$bout" | grep -a '^RESULT:' | tr '\n' ' ')"
    h_check_eq "1" "$(_upd_get "$bout" broken_broken_installed)" "负向对照：语法坏掉的脚本真的被装上了（说明本用例拦得住）"
}
