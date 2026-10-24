# 安装、升级与卸载

本文覆盖 xwPF 脚本集的**首次安装、离线安装、升级、卸载、首次初始化**。

> 文中每条命令、路径、默认值都指向**具体函数**（写法：`文件` 的 `函数名`），不写行号 ——
> 行号会随代码改动整体漂移。核对基准是本仓库
> `byby5555/realm-xwPF-offline-active-standby` 的 `main` 分支，而不是上游旧仓库。

---

## 1. 前置依赖

### 1.1 系统与 init

| 项目 | 支持范围 | 源码位置 |
|------|----------|----------|
| 发行版 | Debian / Ubuntu、Alpine、CentOS / RHEL / Rocky / AlmaLinux / Fedora | `lib/core.sh` 的 `_pkg_install` |
| 包管理器 | `apt-get` / `apk` / `dnf` / `yum`（自动探测） | `lib/core.sh` 的 `manage_dependencies` |
| init 系统 | `systemd`（`systemctl`）或 `openrc`（`rc-service`） | `lib/core.sh` 的 `manage_dependencies` |

不支持的发行版会直接退出并提示，不会带着半截配置继续跑。

### 1.2 必备工具

必备工具清单（`lib/core.sh` 的 `REQUIRED_TOOLS`）：

```
curl  wget  tar  grep  cut  bc  jq  openssl  python3
```

安装脚本会自动补齐缺失的工具（`manage_dependencies`，`lib/core.sh` 的 `get_public_ip`），
按检测到的包管理器分别走 `apt-get install -y` / `apk add --no-cache` / `yum|dnf install -y`。

### 1.3 `nc` 不在自动安装清单里 —— 可选，但建议装

- `lib/core.sh` 的 `REQUIRED_TOOLS` 里**没有** `nc`。
- 健康检查（故障转移 / 主备自动切换）做的是 **TCP 端口探测**，
  优先用 `nc -z -w`；**没有 `nc`（或 `nc` 不支持 `-z`，如 busybox）会自动回退到
  `bash /dev/tcp` + `timeout`**，不再把全部目标误判成故障。
- 唯一仍会导致全判故障的情况：系统里**既没有 `nc` 也没有 `timeout`**（`timeout` 属 coreutils，基本都有）。

**建议装上 `nc`**（探测更快、更省进程）：

```bash
# Debian / Ubuntu
apt-get update -qq && apt-get install -y netcat-openbsd
# Alpine
apk add --no-cache netcat-openbsd
# CentOS / RHEL
dnf install -y nmap-ncat || yum install -y nmap-ncat
```

验证：

```bash
command -v nc && nc -h 2>&1 | head -1
```

### 1.4 realm 二进制

| 项目 | 值 | 源码位置 |
|------|-----|----------|
| 安装路径 | `/usr/local/bin/realm` | `lib/core.sh` 的 `REALM_PATH` |
| 支持架构 | `x86_64` / `aarch64` / `armv7` | `lib/realm.sh` 的 `install_realm` |
| libc 区分 | Alpine 用 `musl`，其余 `gnu` | `lib/realm.sh` 的 `install_realm` |
| 兜底版本 | `v2.9.3`（`REALM_VERSION`，取版本失败时使用） | `lib/core.sh` 的 `REALM_VERSION` |

realm 主程序来自 **官方仓库** `zhboner/realm` 的 release，不在本 fork 内 —— 这是上游二进制，与本项目的
脚本分发是两回事：

```
https://github.com/zhboner/realm/releases/download/<版本>/realm-<架构>.tar.gz
```

下载源按顺序尝试 4 个（`lib/realm.sh` 的 `install_realm`）：官方 → `gh-proxy.com` → `ghproxy.net` → `mirror.ghproxy.com`。

---

## 2. 一键安装

```bash
wget -qO- https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwPF.sh | sudo bash -s install
```

或：

```bash
curl -fsSL https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwPF.sh | sudo bash -s install
```

网络受限环境走加速源（加速源本身不是本项目的一部分，失效了就换别的）：

```bash
curl -fsSL https://v6.gh-proxy.org/https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwPF.sh | sudo bash -s install
```

### 2.1 `install` 子命令做了什么

`xwPF.sh` 的主入口 install 分支：

| 步骤 | 动作 | 源码位置 |
|------|------|----------|
| 1 | 校验 root 权限 | `xwPF.sh` 的主入口 install 分支（root 校验写在该分支内） |
| 2 | `_bootstrap`：拉取脚本文件 | `xwPF.sh` 的 `_bootstrap` |
| 3 | `_load_libs`：source 全部模块 | `xwPF.sh` 的 `_load_libs` |
| 4 | `smart_install`（带 `_SKIP_SCRIPT_UPDATE=1`，**不再询问**是否更新脚本） | `lib/realm.sh` 的 `smart_install` |
| 5 | `failover_install_check`：安装/升级 `xwpf-failover` 守护进程 | `lib/failover.sh` 的 `failover_install_check` |
| 6 | **只装不启**：守护已安装但**不启动**。启动入口是「主备池管理 → 启停守护」 | `xwPF.sh` 的主入口 install 分支 |

> **为什么 install 不再 `systemctl enable --now`**：`/etc/xwpf/failover.json` 只有「建立主备池」才会生成。装完就启 → 守护读不到配置 → `sys.exit(1)` → `Restart=always` 每 `RestartSec` 拉一次 → 崩溃循环（根因链见 `reports/round3-crashloop-review.md`）。菜单文案一直写的是「先建池，再启守护」，现在安装流程与它对齐了。

`_bootstrap` 下载的文件清单（`xwPF.sh` 的 `_bootstrap`）：

- `xwPF.sh` → `/usr/local/bin/xwPF.sh`
- `lib/{core,rules,server,realm,failover,ui}.sh` → `/usr/local/bin/lib/`（加载顺序见 `xwPF.sh` 的 `LIB_FILES`）
- `cmd/{xwpf-failover.py,xwpf-failover.service}` → `/usr/local/bin/cmd/`
- 创建软链 `/usr/local/bin/pf` → `/usr/local/bin/xwPF.sh`（`xwPF.sh` 的 `_bootstrap`）

下载是**原子化**的（`xwPF.sh` 的 `_download`）：先下到 `.tmp.$$`，校验非空，再 `mv -f` 覆盖目标。
**故意不使用 `curl -C -` / `wget -c`** —— 断点续传只校验 HTTP Range 起点，不校验本地内容，
远端变长时会把新版本追加到旧内容后面，产出「大小正常但内容损坏」的文件。

`cmd/` 下载失败**不阻断安装**（`xwPF.sh` 的 `_bootstrap`），安装守护进程时 `failover_install_files`
会再从 GitHub raw 兜底（`lib/failover.sh` 的 `failover_install_files`）。

### 2.2 安装后落盘清单

| 路径 | 说明 | 源码位置 |
|------|------|----------|
| `/usr/local/bin/xwPF.sh` | 主入口 | `xwPF.sh` 的 `INSTALL_DIR` |
| `/usr/local/bin/lib/*.sh` | 6 个模块 | `xwPF.sh` 的 `LIB_DIR` |
| `/usr/local/bin/cmd/` | 守护进程源文件副本 | `xwPF.sh` 的 `_bootstrap` |
| `/usr/local/bin/pf` | 快捷命令（软链） | `xwPF.sh` 的 `SHORTCUT_PATH` |
| `/usr/local/bin/realm` | realm 主程序 | `lib/core.sh` 的 `REALM_PATH` |
| `/etc/realm/config.json` | realm 工作配置 | `lib/core.sh` 的 `CONFIG_PATH` |
| `/etc/realm/rules/` | 转发规则目录 | `lib/core.sh` 的 `RULES_DIR` |
| `/etc/systemd/system/realm.service` | realm systemd unit | `lib/core.sh` 的 `SYSTEMD_PATH`、`lib/realm.sh` 的 `depend` |
| `/usr/local/bin/xwpf-failover` | 主备守护进程（0755） | `lib/failover.sh` 的 `XWPF_FAILOVER_BIN`、`lib/failover.sh` 的 `failover_install_files` |
| `/etc/systemd/system/xwpf-failover.service` | 守护进程 unit（0644） | `lib/failover.sh` 的 `XWPF_FAILOVER_UNIT`、`lib/failover.sh` 的 `failover_install_files` |
| `/usr/local/bin/.xwpf-failover-version` | 已装版本指纹（用于判断要不要重装） | `lib/failover.sh` 的 `XWPF_FAILOVER_VERSION_FILE` |
| `/etc/xwpf/` | 守护进程配置目录 | `lib/failover.sh` 的 `XWPF_FAILOVER_CONF_DIR` |

**按需下载**（用到才拉，不占安装体积）：

| 路径 | 何时下载 | 源码位置 |
|------|----------|----------|
| `/etc/realm/xwFailover.sh` | 进入「故障转移管理」菜单 | `lib/ui.sh` 的 `download_failover_script` |
| `/etc/realm/health/health_check.sh` | 开启故障转移时生成 | `lib/health.sh` 的 `start_health_check_service`、`lib/health.sh` 的 `start_health_check_service` |
| `/etc/systemd/system/realm-health-check.service` / `.timer` | 开启故障转移时生成 | `lib/health.sh` 的 `start_health_check_service` |
| `/etc/realm/health/health_status.conf` | 健康检查首次运行时创建 | `lib/health.sh` 的 `health_check_script_body` |
| `/etc/realm/speedtest.sh` | 进入「中转网络链路测试」 | `lib/ui.sh` 的 `download_speedtest_script` |
| `/usr/local/bin/port-traffic-dog.sh` | 进入「端口流量狗」 | `lib/ui.sh` 的 `port_traffic_dog_menu` |
| `/etc/realm/xw_realm_OCR.sh` | 进入配置识别导入 | `lib/ui.sh` 的 `download_realm_ocr_script` |

### 2.3 安装后验证

```bash
# 1. 脚本与模块就位
ls -l /usr/local/bin/xwPF.sh /usr/local/bin/pf
ls -1 /usr/local/bin/lib/
# 期望：core.sh rules.sh server.sh realm.sh failover.sh ui.sh

# 2. realm 可执行
/usr/local/bin/realm --version

# 3. 服务已注册并运行
systemctl status realm --no-pager -l

# 4. 主备守护进程在跑
systemctl status xwpf-failover --no-pager -l

# 5. 进入菜单
pf
```

---

## 3. 离线安装（完全无外网）

### 3.1 在有网的机器上下载

- 主脚本：`https://github.com/byby5555/realm-xwPF-offline-active-standby/raw/main/xwPF.sh`
- 模块目录：`https://github.com/byby5555/realm-xwPF-offline-active-standby/tree/main/lib`
- 守护进程目录：`https://github.com/byby5555/realm-xwPF-offline-active-standby/tree/main/cmd`
- realm 主程序：见 §1.4 的架构表（`zhboner/realm` release）

### 3.2 放置到目标服务器

```
/usr/local/bin/
├── xwPF.sh                ← 主脚本
├── lib/                   ← 必须创建
│   ├── core.sh
│   ├── rules.sh
│   ├── server.sh
│   ├── realm.sh
│   ├── failover.sh
│   └── ui.sh
└── cmd/                   ← 主备守护文件（离线安装必须手动放置）
    ├── xwpf-failover.py
    └── xwpf-failover.service

~/realm-xxx.tar.gz         ← realm 压缩包放任意位置
```

> `cmd/` 这两个文件**离线时必须手动放**。`lib/failover.sh` 的 `failover_install_check`：拿不到 `cmd/xwpf-failover.py`
> 源文件时会提示「未找到 cmd/xwpf-failover.py 源文件, 跳过版本比对」并保持现状不重装。

### 3.3 执行离线安装

```bash
chmod +x /usr/local/bin/xwPF.sh
ln -sf /usr/local/bin/xwPF.sh /usr/local/bin/pf
bash /usr/local/bin/xwPF.sh
```

选 `1. 安装(更新)程序,脚本`，然后：

1. 提示 **是否更新脚本？(y/N):** → 直接回车跳过（离线拉不到远端）
2. 提示 **离线安装realm输入完整路径(回车默认自动下载):** → 输入 realm 压缩包的完整路径

---

## 4. 升级

### 4.0 更新中心（推荐）

主菜单 `9. 检查更新 / 安全更新`（`lib/ui.sh` 的 `show_menu`）→ `update_center_menu`
（`lib/update.sh` 的 `update_center_menu`）：

```
=== 版本对照 ===
  realm 主程序  v2.9.3  → v2.9.6
    架构型号: realm-x86_64-unknown-linux-gnu.tar.gz
  脚本包       v2.2.1  → v2.2.1
```

能查能升的东西：

| 对象 | 当前版本从哪来 | 最新版本从哪来 | 更新动作 |
|------|----------------|----------------|----------|
| realm 主程序 | `realm --version` | GitHub `releases/latest` 的 `tag_name` | `safe_update_realm`（`lib/update.sh`） |
| 脚本包 | `lib/core.sh` 的 `SCRIPT_VERSION` | 远端 `lib/core.sh` 的 `SCRIPT_VERSION` | `safe_update_scripts`（`lib/update.sh`） |
| 架构型号 | `detect_realm_asset_name`（`lib/core.sh`） | 同左 | CPU 架构 + libc（gnu/musl）→ 官方资产名 |

**安全更新的五条纪律**（`lib/update.sh`）：

1. **先下载到 staging，全部校验通过才动现有文件**
   → 下载中断时现有文件一个字节都没被碰过，不会出现「半新半旧」的脚本
2. **更新前备份**到 `/usr/local/bin/.xwpf-backup/<类型>-<时间戳>/`，保留最近 5 份
   （`update_backup_dir_create` / `update_backup_file`）
3. **sha256 校验**：realm 安装包按 GitHub release asset 的 `digest` 校验
   （`update_realm_asset_digest`），对不上直接拒绝安装
4. **更新后验证**：新二进制要能执行**且版本号与目标一致**、脚本要能正常启动；
   验证不过自动回滚（`update_restore_backup`），并把服务恢复到更新前的状态
5. **失败不 exit 整个脚本** → 回到菜单

并发保护：更新期间用 `mkdir` 原子锁（`update_lock_acquire`），进程被 kill 留下的
陈旧锁会自动识别并接管。

> 脚本包更新会替换**正在运行的** `xwPF.sh`。bash 是按需读取脚本文件的，
> 所以更新完成后必须退出当前进程（`update_center_menu` 负责 `exit`），
> 提示「重新运行 pf 后生效」。

### 4.1 升级脚本

```bash
pf
# → 1. 安装(更新)程序,脚本
# → 提示「是否更新脚本？(y/N):」→ y
```

`smart_install`（`lib/realm.sh` 的 `smart_install`）里：

- `_SKIP_SCRIPT_UPDATE` 未设置时，询问是否更新脚本，答 y 走 `_bootstrap()` 重新拉全部脚本文件
- 之后调用 `install_realm()`，realm 主程序**单独**做版本比对：
  `get_latest_realm_version`（`lib/realm.sh` 的 `get_latest_realm_version`）→ `compare_and_ask_update`（`lib/realm.sh` 的 `compare_and_ask_update`）

也可以直接重跑 `install` 子命令（此时**不**再询问是否更新脚本，直接覆盖）：

```bash
curl -fsSL https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwPF.sh | sudo bash -s install
```

### 4.2 升级守护进程

`xwPF.sh install` 的最后一步就是 `failover_install_check`（`lib/failover.sh` 的 `failover_install_check`）：

- 已安装且版本指纹一致 → 跳过
- 版本指纹不一致（fork 更新了 `cmd/xwpf-failover.py`）→ 重新下载并 `install -m 0755` / `install -m 0644`

版本指纹是文件内容哈希（`lib/failover.sh` 的 `failover_file_fingerprint`），记录在 `/usr/local/bin/.xwpf-failover-version`。

### 4.3 升级后必做

```bash
systemctl daemon-reload
systemctl restart realm
systemctl restart xwpf-failover
pf --restart-service   # 重新生成 /etc/realm/config.json 并重启 realm
```

---

## 5. 卸载

分两阶段，菜单内 `8. 卸载服务`（`lib/ui.sh` 的 `show_menu`）：

```bash
pf
# → 8. 卸载服务
```

### 阶段一：Realm 服务与配置（`lib/ui.sh` 的 `uninstall_realm_stage_one`）

1. 停止并禁用 realm 服务
2. 若 `/etc/realm/xwFailover.sh` 存在 → 执行 `xwFailover.sh stop`，停掉健康检查 timer 与 service，
   并删掉 `realm-health-check.{service,timer}` 与 `health_check.sh`
3. 停用 `xwpf-failover` 守护（`systemctl disable --now`）
4. `pkill` 掉残留的 `realm` / `xwpf-failover` 进程
5. 删除：`/usr/local/bin/realm`、`/etc/realm`（含 `rules/`、`health/`）、`/etc/systemd/system/realm.service`、
   `/etc/init.d/realm`、`/etc/systemd/system/realm-web.service`
6. 按名字清理 `/var/log`、`/tmp`、`/var/tmp` 下的 realm 残留文件
7. 删除 `/lib/systemd/system/xwpf-failover.service`、`/etc/systemd/system/xwpf-failover.service`、
   `/etc/xwpf/failover.json`
8. 删除 `/etc/sysctl.d/90-enable-MPTCP.conf` 并执行 `ip mptcp endpoint flush`

### 阶段二：脚本文件（`lib/ui.sh` 的 `uninstall_script_files`）

- `/usr/local/bin/xwPF.sh`
- `/usr/local/bin/lib/`（整目录）
- `/usr/local/bin/cmd/`（整目录）
- `pf` 快捷方式：扫描 `/usr/local/bin`、`/usr/bin`、`/bin`、`/opt/bin`、`/root/bin`，
  删除内容含 `xwPF` 的同名文件或软链

> 阶段二可以单独取消 —— 取消后脚本仍在，`pf` 还能继续用。

### 手工兜底（菜单不可用时）

```bash
systemctl stop realm xwpf-failover realm-health-check.timer 2>/dev/null
systemctl disable realm xwpf-failover realm-health-check.timer 2>/dev/null
rm -f /etc/systemd/system/realm.service \
      /etc/systemd/system/xwpf-failover.service \
      /etc/systemd/system/realm-health-check.service \
      /etc/systemd/system/realm-health-check.timer
rm -rf /etc/realm /etc/xwpf /usr/local/bin/lib /usr/local/bin/cmd
rm -f /usr/local/bin/realm /usr/local/bin/xwPF.sh /usr/local/bin/xwpf-failover /usr/local/bin/pf
systemctl daemon-reload
```

---

## 6. 首次初始化

安装完成后 realm 以**空配置**启动（`start_empty_service`，`lib/realm.sh` 的 `start_empty_service`），
写入 `{"endpoints": []}` 并生成 systemd unit —— 这是为了让脚本能识别「已安装」状态。

真正的初始化是建第一条转发规则：

```
pf
# → 2. 转发配置管理
# → 新建转发规则
```

配置分两个角色（`RULE_ROLE`）：

| 角色 | 含义 | 关键字段 |
|------|------|----------|
| `1` | 中转服务器（客户端侧） | `LISTEN_PORT` / `LISTEN_IP` / `THROUGH_IP` / `REMOTE_HOST` / `REMOTE_PORT` |
| `2` | 服务端服务器（双端 realm 架构） | `LISTEN_PORT` / `FORWARD_TARGET` |

规则落盘在 `/etc/realm/rules/rule-N.conf`，一条规则一个文件。
文件解析走 `read_rule_file`（`lib/health.sh` 的 `read_rule_file`），**只接受白名单里的 KEY**
（白名单变量 `_allowed` 就定义在这个函数里），并且**不使用 `source` / `eval`** —— 手工往规则文件里塞
`$(cmd)` 或反引号不会被执行。

规则创建后规则目录会被打上初始化标记 `/etc/realm/rules/.initialized`（`lib/rules.sh` 的 `init_rules_dir`）。

规则 ID 会按「监听端口 → 角色 → 原 ID」排序重排（`reorder_rule_ids`，`lib/rules.sh` 的 `reorder_rule_ids`），
重排时会同步更新健康状态文件里的 RULE_ID（`sync_health_status_ids`，`lib/rules.sh` 的 `sync_health_status_ids`），
并在动原文件前先打一份 tar 备份到 `/tmp/realm-rules-backup-XXXXXX.tar.gz`。

---

## 7. 命令行接口

| 命令 | 作用 | 源码位置 |
|------|------|----------|
| `pf` | 交互式主菜单 | `lib/ui.sh` 的 `show_menu` |
| `pf --generate-config-only` | 只生成 `/etc/realm/config.json`，不重启、不显示菜单 | `lib/ui.sh` 的 `main` |
| `pf --restart-service` | 重排序规则 → 重新生成配置 → 重启 realm | `lib/ui.sh` 的 `main`、`lib/realm.sh` 的 `service_restart` |
| `xwPF.sh install` | 一键安装（需 root） | `xwPF.sh` 的主入口 install 分支 |
| `xwFailover.sh toggle\|config\|status\|start\|stop\|restart-realm\|help` | 故障转移管理，见 [健康检查与故障转移](health-check-and-failover.md) | `xwFailover.sh` 的 `main` |

---

## 8. 相关文档

- [端口组与权重](port-groups-and-weights.md) —— 配多个出口、权重、主备写法
- [健康检查与故障转移](health-check-and-failover.md) —— 自动切换的参数与链路
- [故障排查手册](troubleshooting.md) —— 装不上、切不动、日志在哪
