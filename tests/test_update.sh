#!/bin/bash
# 安全更新测试（备份 / sha256 校验 / 验证 / 自动回滚 / 原子性）
# 用法: bash tests/test_update.sh
#
# 测试思路：把「网络边界」换成本地假实现（覆盖 update_realm_latest_tag、
# update_realm_asset_digest、download_from_sources、update_download_to），
# 真实被测的是**安全逻辑**：校验不过不装、装了要能回滚、下载失败不碰现有文件。
#
# 不需要 root，不碰真实的 /usr/local/bin 与 /etc。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"

SANDBOX="$(mktemp -d)"
PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 期望 [$3] 实际 [$2]"; fi; }

mkdir -p "$SANDBOX/install/lib" "$SANDBOX/backup" "$SANDBOX/staging" "$SANDBOX/fake"

export CONFIG_DIR="$SANDBOX"
export HEALTH_STATUS_FILE="$SANDBOX/health/health_status.conf"
export INSTALL_DIR="$SANDBOX/install"
export LIB_DIR="$SANDBOX/install/lib"
export REALM_PATH="$SANDBOX/install/realm"
export UPDATE_BACKUP_DIR="$SANDBOX/backup"
export UPDATE_LOCK_DIR="$SANDBOX/lock"
export UPDATE_STAGING_ROOT="$SANDBOX/staging"

# shellcheck disable=SC1090
source "$REPO/lib/core.sh"
# shellcheck disable=SC1090
source "$REPO/lib/health.sh"
# shellcheck disable=SC1090
source "$REPO/lib/rules.sh"
# shellcheck disable=SC1090
source "$REPO/lib/realm.sh"
# shellcheck disable=SC1090
source "$REPO/lib/update.sh"

# ---- 假的服务层 ----
svc_is_active() { [ -f "$SANDBOX/realm_running" ]; }
svc_start()     { touch "$SANDBOX/realm_running"; }
svc_stop()      { rm -f "$SANDBOX/realm_running"; }

# ---- 造一个「已安装」的现场 ----
make_installed() {
    mkdir -p "$LIB_DIR"
    printf '#!/bin/bash\necho "realm v2.9.3"\n' > "$REALM_PATH"
    chmod +x "$REALM_PATH"
    printf '#!/bin/bash\nif [ "$1" = "--help" ]; then echo "用法"; exit 0; fi\necho "ok"\n' > "$INSTALL_DIR/xwPF.sh"
    chmod +x "$INSTALL_DIR/xwPF.sh"
    printf '#!/bin/bash\nSCRIPT_VERSION="v2.2.1"\n' > "$LIB_DIR/core.sh"
    for f in health.sh rules.sh server.sh realm.sh failover.sh ui.sh update.sh; do
        printf '#!/bin/bash\n# %s\n' "$f" > "$LIB_DIR/$f"
    done
    mkdir -p "$INSTALL_DIR/cmd"
    printf '# daemon\n' > "$INSTALL_DIR/cmd/xwpf-failover.py"
    printf '# service\n' > "$INSTALL_DIR/cmd/xwpf-failover.service"
}

# ---- 造一个假的 release 安装包 ----
make_fake_tarball() {
    local version="$1" out="$2" broken="${3:-false}"
    rm -rf "$SANDBOX/fake/pkg"
    mkdir -p "$SANDBOX/fake/pkg"
    if [ "$broken" = "true" ]; then
        # 不能执行的文件（模拟架构不匹配 / 文件损坏）
        printf 'not an executable\n' > "$SANDBOX/fake/pkg/realm"
        chmod 644 "$SANDBOX/fake/pkg/realm"
    else
        printf '#!/bin/bash\necho "realm %s"\n' "$version" > "$SANDBOX/fake/pkg/realm"
        chmod +x "$SANDBOX/fake/pkg/realm"
    fi
    tar -czf "$out" -C "$SANDBOX/fake/pkg" realm
}

# ---- 覆盖网络边界（真实实现是 curl/jq，这里换成假数据）----
FAKE_TAG="v9.9.9"
FAKE_DIGEST="deadbeef"
update_realm_latest_tag() { echo "$FAKE_TAG"; }
update_realm_asset_digest() { echo "$FAKE_DIGEST"; }
download_from_sources() {
    local url="$1" target="$2"
    [ -f "$SANDBOX/fake/realm.tar.gz" ] || return 1
    cp -f "$SANDBOX/fake/realm.tar.gz" "$target"
}
update_download_to() {
    local url="$1" target="$2"
    local name
    name=$(echo "$url" | sed 's|.*/||')
    if [ "${DOWNLOAD_FAIL_ON:-}" = "$name" ]; then
        return 1
    fi
    if [ "${DOWNLOAD_BREAK_ON:-}" = "$name" ]; then
        printf '#!/bin/bash\nif [ ; then\n' > "$target"   # 故意语法错误
        return 0
    fi
    if [ -f "$SANDBOX/fake/remote/$name" ]; then
        cp -f "$SANDBOX/fake/remote/$name" "$target"
        return 0
    fi
    return 1
}

echo "=============================================="
echo "A. 架构型号推导（版本型号迭代只改这一处）"
echo "=============================================="
asset=$(detect_realm_asset_name)
check "能推出资产名" "$(echo "$asset" | grep -c '^realm-')" "1"
check "资产名以 .tar.gz 结尾" "$(echo "$asset" | grep -c '\.tar\.gz$')" "1"
check "资产名含架构" "$(echo "$asset" | grep -cE 'x86_64|aarch64|armv7')" "1"

echo "=============================================="
echo "B. sha256 不匹配 → 拒绝安装，旧版本一个字节没动"
echo "=============================================="
make_installed
make_fake_tarball "v9.9.9" "$SANDBOX/fake/realm.tar.gz"
FAKE_DIGEST="0000000000000000000000000000000000000000000000000000000000000000"
before=$(cat "$REALM_PATH")
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "$out" | grep -E 'sha256|拒绝' | head -2 | sed 's/^/    /'
check "更新被拒绝（返回非 0）" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "旧二进制没被改动" "$(cat "$REALM_PATH")" "$before"
check "没有产生备份目录" "$(ls -1 "$SANDBOX/backup" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "=============================================="
echo "C. sha256 匹配 → 安装成功 + 旧版本已备份"
echo "=============================================="
real_digest=$(sha256sum "$SANDBOX/fake/realm.tar.gz" | awk '{print $1}')
FAKE_DIGEST="$real_digest"
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "$out" | grep -E 'sha256|已更新' | head -3 | sed 's/^/    /'
check "更新成功（返回 0）" "$rc" "0"
check "新版本已生效" "$(cat "$REALM_PATH")" "$(printf '#!/bin/bash\necho "realm v9.9.9"\n')"
check "生成了备份目录" "$([ "$(ls -1 "$SANDBOX/backup" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "yes"
check "备份里是旧版本" "$(cat "$SANDBOX/backup"/realm-*/usr/local/bin/realm 2>/dev/null || cat "$SANDBOX/backup"/realm-*/$(echo "$REALM_PATH" | sed 's|^/||') 2>/dev/null)" "$before"

echo "=============================================="
echo "D. 新二进制跑不起来 → 拒绝安装，旧版本没动"
echo "=============================================="
make_installed
make_fake_tarball "v9.9.9" "$SANDBOX/fake/realm.tar.gz" "true"
FAKE_DIGEST=$(sha256sum "$SANDBOX/fake/realm.tar.gz" | awk '{print $1}')
before=$(cat "$REALM_PATH")
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "$out" | grep -E '无法执行|放弃' | head -2 | sed 's/^/    /'
check "更新被拒绝（返回非 0）" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "旧二进制没被改动" "$(cat "$REALM_PATH")" "$before"

echo "=============================================="
echo "E. 脚本包下载中途失败 → 现有文件完全没动"
echo "=============================================="
make_installed
rm -rf "$SANDBOX/backup" && mkdir -p "$SANDBOX/backup"
before_core=$(cat "$LIB_DIR/core.sh")
mkdir -p "$SANDBOX/fake/remote"
for f in xwPF.sh core.sh health.sh rules.sh server.sh realm.sh failover.sh ui.sh update.sh; do
    printf '#!/bin/bash\n# new %s\n' "$f" > "$SANDBOX/fake/remote/$f"
done
printf '#!/bin/bash\nSCRIPT_VERSION="v9.9.9"\n' > "$SANDBOX/fake/remote/core.sh"
DOWNLOAD_FAIL_ON="rules.sh"
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "$out" | grep -E '下载|未改动' | head -3 | sed 's/^/    /'
check "更新被拒绝（返回非 0）" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "core.sh 没被替换" "$(cat "$LIB_DIR/core.sh")" "$before_core"
check "没产生备份（失败在备份之前）" "$(ls -1 "$SANDBOX/backup" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "=============================================="
echo "F. 下载到的脚本有语法错误 → 拒绝替换"
echo "=============================================="
DOWNLOAD_FAIL_ON=""
DOWNLOAD_BREAK_ON="core.sh"
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "$out" | grep -E '语法检查' | head -2 | sed 's/^/    /'
check "更新被拒绝（返回非 0）" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "core.sh 没被替换" "$(cat "$LIB_DIR/core.sh")" "$before_core"
DOWNLOAD_BREAK_ON=""

echo "=============================================="
echo "G. 脚本包全部就绪 → 替换 + 备份"
echo "=============================================="
out=$(printf 'y\n' | safe_update_scripts 2>&1); rc=$?
echo "$out" | grep -E '已更新|备份' | head -3 | sed 's/^/    /'
check "更新成功（返回 0）" "$rc" "0"
check "core.sh 已换成新版" "$(grep -o 'SCRIPT_VERSION=\"[^\"]*\"' "$LIB_DIR/core.sh")" "SCRIPT_VERSION=\"v9.9.9\""
check "xwPF.sh 已换成新版" "$(grep -c 'new xwPF.sh' "$INSTALL_DIR/xwPF.sh")" "1"
check "生成了脚本备份" "$([ "$(ls -1 "$SANDBOX/backup" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "yes"

echo "=============================================="
echo "H. 并发保护：锁"
echo "=============================================="
rm -rf "$UPDATE_LOCK_DIR"
mkdir -p "$UPDATE_LOCK_DIR"
echo $$ > "$UPDATE_LOCK_DIR/pid"
update_lock_acquire >/dev/null 2>&1
check "活着的进程持有锁 → 抢锁失败" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"
echo 999999 > "$UPDATE_LOCK_DIR/pid"
update_lock_acquire >/dev/null 2>&1
check "陈旧锁（进程已死）→ 可接管" "$([ $? -eq 0 ] && echo yes || echo no)" "yes"
update_lock_release

echo "=============================================="
echo "I. 静态核对"
echo "=============================================="
check "xwPF.sh 模块清单含 update.sh" "$(grep -c '"update.sh"' "$REPO/xwPF.sh")" "1"
check "主菜单有「检查更新 / 安全更新」" "$(grep -c '检查更新 / 安全更新' "$REPO/lib/ui.sh")" "1"
check "主菜单派发到 update_center_menu" "$(grep -c 'update_center_menu' "$REPO/lib/ui.sh")" "1"
check "更新中心做了 sha256 校验" "$(grep -c 'sha256 校验不通过' "$REPO/lib/update.sh")" "1"
check "更新中心有回滚逻辑" "$([ "$(grep -c 'update_restore_backup' "$REPO/lib/update.sh")" -ge 3 ] && echo yes || echo no)" "yes"
check "更新中心有备份逻辑" "$([ "$(grep -c 'update_backup_dir_create' "$REPO/lib/update.sh")" -ge 2 ] && echo yes || echo no)" "yes"
check "安装路径也用同一套架构映射" "$(grep -c 'asset_name=$(detect_realm_asset_name)' "$REPO/lib/realm.sh")" "1"

echo "=============================================="
echo "J. 版本号归一化（回归：tag 带 v，二进制输出不带 v）"
echo "=============================================="
# 真实 realm 输出 "Realm 2.9.3 [brutal][proxy]..."（**不带** v），
# 而 GitHub release 的 tag 是 "v2.9.6"（**带** v）。
# 直接字符串比较会得出「期望 v2.9.6，实际 2.9.6」的假不一致 → 更新被永远拒绝，
# 「已是最新」也永远判不出来。这条用例锁死这个行为。
check "归一化：v2.9.6 → 2.9.6" "$(update_norm_version 'v2.9.6')" "2.9.6"
check "归一化：2.9.6 → 2.9.6" "$(update_norm_version '2.9.6')" "2.9.6"
check "归一化：V2.9.6 → 2.9.6" "$(update_norm_version 'V2.9.6')" "2.9.6"
check "归一化：空串仍为空" "$(update_norm_version '')" ""

make_installed
# 现场：已装的 realm 输出 "Realm 2.9.3 ..."（无 v），上游 tag 是 "v2.9.6"（有 v）
printf '#!/bin/bash\necho "Realm 2.9.3 [brutal][proxy]"\n' > "$REALM_PATH"
chmod +x "$REALM_PATH"
FAKE_TAG="v2.9.6"
make_fake_tarball "2.9.6" "$SANDBOX/fake/realm.tar.gz"
FAKE_DIGEST=$(sha256sum "$SANDBOX/fake/realm.tar.gz" | awk '{print $1}')

out=$(update_status_display 2>&1)
check "版本对照表显示归一化后的版本号" "$(echo "$out" | grep -c 'realm 主程序.*2\.9\.3 → 2\.9\.6')" "1"

out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "$out" | grep -E '已更新|不符|放弃' | head -2 | sed 's/^/    /'
check "版本号格式不同也能更新成功" "$rc" "0"
check "日志里没有「版本与目标不符」" "$(echo "$out" | grep -c '版本与目标不符')" "0"
check "新二进制已装上" "$(grep -c 'realm 2.9.6' "$REALM_PATH")" "1"

# 再跑一次：应识别为「已是最新」，而不是又去下载一遍
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
check "已是最新时返回 0" "$rc" "0"
check "已是最新时提示跳过" "$(echo "$out" | grep -c '已是最新')" "1"
check "已是最新时没有再次下载" "$(echo "$out" | grep -c '下载:')" "0"

echo "=============================================="
echo "K. 回滚健壮性：恢复失败必须被报出来"
echo "=============================================="
# 旧实现把 cp 的错误静默吞掉了 —— 用户以为回滚成功了，实际还跑着坏版本。
# 而且覆盖**正在运行**的二进制会报 "Text file busy"（ETXTBSY），
# 这正是自动回滚路径上必须先停服务的原因。
BADBAK="$SANDBOX/backup/bad-restore"
mkdir -p "$BADBAK/tmp/nonexistent_dir_xyz"
printf 'x' > "$BADBAK/tmp/nonexistent_dir_xyz/realm"
out=$(update_restore_backup "$BADBAK" 2>&1); rc=$?
echo "$out" | head -2 | sed 's/^/    /'
check "恢复失败时返回非 0" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "恢复失败时打印了原因" "$(echo "$out" | grep -c '恢复失败')" "1"
mkdir -p "$SANDBOX/restore_ok"
printf 'hello' > "$SANDBOX/restore_ok/probe.txt"
update_restore_backup "$SANDBOX/restore_ok" >/dev/null 2>&1
check "恢复成功时返回 0" "$?" "0"

# K2: 正在被执行的二进制不能被 cp 直接覆盖（ETXTBSY），
#     但「临时文件 + mv 覆盖」不受影响 —— 这正是回滚必须用 mv 的原因。
#     本机实测：realm 被健康检查每秒拉起，systemctl stop 只按得住 2 秒。
BUSY="$SANDBOX/busy.sh"
printf '#!/bin/bash\nsleep 3\n' > "$BUSY"
chmod +x "$BUSY"
"$BUSY" >/dev/null 2>&1 &
BUSY_PID=$!
sleep 1
# 注意：ETXTBSY 出现在「**写**到正在被执行的文件」时，
#       从它读出去（cp busy busy.copy）不会触发 —— 探测必须往它身上写。
printf 'x' > "$SANDBOX/busy.src"
if cp -p "$SANDBOX/busy.src" "$BUSY" 2>/dev/null; then
    CP_BUSY=ok
else
    CP_BUSY=fail
fi
if [ "$CP_BUSY" = "fail" ]; then
    # 本机支持 ETXTBSY：直接覆盖会失败，但 mv 覆盖式恢复必须成功
    BAK2="$SANDBOX/backup/busy-bak"
    rel="tmp/$(basename "$SANDBOX")/busy.sh"
    mkdir -p "$BAK2/$(dirname "$rel")"
    printf '#!/bin/bash\necho restored\n' > "$BAK2/$rel"
    out=$(update_restore_backup "$BAK2" 2>&1); rc=$?
    check "ETXTBSY 环境下恢复仍然成功" "$rc" "0"
    check "恢复后的文件内容正确" "$(grep -c 'restored' "$BUSY" 2>/dev/null)" "1"
else
    echo "  [SKIP] 本机不支持 ETXTBSY（无法写正在执行的文件），跳过该用例"
fi
kill "$BUSY_PID" 2>/dev/null
wait "$BUSY_PID" 2>/dev/null
rm -f "$SANDBOX/busy.src"

echo "=============================================="
echo "L. 自动回滚：新版本起不来 → 停服务 → 恢复旧版本 → 再拉起"
echo "=============================================="
make_installed
make_fake_tarball "v9.9.9" "$SANDBOX/fake/realm.tar.gz"
FAKE_TAG="v9.9.9"
FAKE_DIGEST=$(sha256sum "$SANDBOX/fake/realm.tar.gz" | awk '{print $1}')
touch "$SANDBOX/realm_running"          # 服务本来在跑
OLD_BIN=$(cat "$REALM_PATH")
# 让 svc_start 失败（不创建标记）→ 触发「新版本启动失败」分支
svc_start() { return 1; }
out=$(printf 'y\n' | safe_update_realm 2>&1); rc=$?
echo "$out" | grep -E '启动失败|回滚' | head -2 | sed 's/^/    /'
check "新版本起不来时返回非 0" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "旧版本已被恢复" "$(cat "$REALM_PATH")" "$OLD_BIN"
check "日志里有自动回滚" "$(echo "$out" | grep -c '自动回滚')" "1"
svc_start() { touch "$SANDBOX/realm_running"; }

echo "=============================================="
echo "结果: PASS=$PASS FAIL=$FAIL"
echo "=============================================="
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
