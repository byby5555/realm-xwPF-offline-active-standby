# 故障排查手册

按「症状」组织，每条都给出**怎么确认**和**怎么修**。

> 文中每条规则都标注了源码位置（`文件` 的 `函数`），核对基准是本仓库 `main` 分支。

---

## 快速索引

| 症状 | 跳转 |
|------|------|
| realm 服务起不来 | [§1](#1-realm-服务起不来) |
| 改了规则不生效 | [§2](#2-改了规则不生效) |
| 所有目标都被判成故障 | [§3](#3-所有目标都被判成故障) |
| 下载 404 / 脚本拉不下来 | [§4](#4-下载-404--脚本拉不下来) |
| 去哪看日志 | [§5](#5-日志在哪) |
| 主备不切换 / 切错了 | [§6](#6-主备不切换或切错目标) |
| 权重不生效 / 报错 | [§7](#7-权重不生效或报错) |
| 端口冲突 | [§8](#8-端口冲突) |
| 权限 / root 相关 | [§9](#9-权限相关) |

---

## 1. realm 服务起不来

### 1.1 先看状态和日志

```bash
systemctl status realm --no-pager -l
journalctl -u realm -n 100 --no-pager
```

OpenRC 环境（Alpine）没有 journald：

```bash
rc-service realm status
tail -f /var/log/messages
```

（`lib/realm.sh` 的 `svc_status_detail`）

### 1.2 配置生成失败

realm 的 systemd unit 是 `ExecStart=/usr/local/bin/realm -c /etc/realm/config.json`
（`lib/realm.sh` 的 `depend`）。配置坏了服务就起不来。
先单独生成一次配置看报错：

```bash
pf --generate-config-only
```

（`lib/ui.sh` 的 `main`）

### 1.3 realm 二进制损坏或架构不匹配

`install_realm` 会做完整性检查：执行 `${REALM_PATH} --help` 失败就判定文件损坏并重装
（`lib/realm.sh` 的 `install_realm`）。版本查询也做了多命令兼容：`--version` → `-v` → 兜底文案
（`lib/realm.sh` 的 `install_realm`）。

```bash
uname -m                      # x86_64 / aarch64 / armv7l
/usr/local/bin/realm --version
```

架构不在支持列表里会直接退出（`lib/realm.sh` 的 `install_realm`）。
Alpine 必须用 `musl` 后缀的包，脚本已自动区分（`lib/realm.sh` 的 `install_realm`）。

### 1.4 规则文件里有非法内容

规则解析走白名单 + 不用 `eval`（`lib/health.sh` 的 `read_rule_file`）。
但**字段名写错**（不在白名单里）会被**静默忽略**，表现为配置项没生效。

排查：

```bash
cat /etc/realm/rules/rule-1.conf
# 逐条对照 `lib/health.sh` 的 `read_rule_file` 里的白名单（`_allowed`）
```

### 1.5 同一个端口混了中转和服务端规则

`lib/realm.sh` 的 `generate_endpoints_from_rules` 会**跳过**角色冲突的规则并打印警告：

```
警告: 端口 8080 已被角色 1 的规则占用，跳过角色 2 的规则
```

看到这条就说明该端口的规则被丢掉了。

---

## 2. 改了规则不生效

**规则文件只是配置源，realm 跑的是 `/etc/realm/config.json`。**
改完规则必须重新生成配置并重启 realm 才会生效。

菜单里大多数写操作末尾会自动重启（`lib/core.sh` 的 `restart_and_confirm`），
但手工编辑规则文件后不会：

```bash
pf --restart-service
```

等价于 `service_restart`（`lib/realm.sh` 的 `service_restart`），做三件事：

1. `reorder_rule_ids` —— 重排规则 ID，并同步健康状态文件里的 RULE_ID
2. `generate_realm_config` —— 重新生成 `/etc/realm/config.json`
3. `svc_restart` —— 重启 realm 服务

确认配置是否真的更新了：

```bash
jq '.endpoints' /etc/realm/config.json
```

---

## 3. 所有目标都被判成故障

**症状**：健康状态里所有目标都是 `failed`，主备反复乱切，或流量莫名其妙全断。

### 3.1 先看探测日志

```bash
journalctl -u realm-health-check.service -n 50 --no-pager
```

### 3.2 探测方式（重要）

健康检查探测的是**目标的 TCP 端口**（`REMOTE_HOST:REMOTE_PORT`），
**不是 ping**。所以「IP 还能 ping 通」不能证明健康检查应该判定为健康。

探测函数（`lib/health.sh` 的 `check_connectivity`）现在有两条路：

```bash
if command -v nc >/dev/null 2>&1; then
    if nc -h 2>&1 | grep -q -- '-z' 2>/dev/null; then   # nc 必须支持 -z
        nc -z -w "$timeout" "$target" "$port" >/dev/null 2>&1
        return $?
    fi
fi
# 回退：bash 内置 /dev/tcp（不依赖 netcat）
if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" bash -c "exec 3<>/dev/tcp/${target}/${port}" >/dev/null 2>&1
    ...
fi
```

> 旧版本只有 `nc` 一条路，系统没装 `nc` 就 `return 1` → **所有目标被误判成故障**。
> 现在没有 `nc`（或 `nc` 不支持 `-z`）会自动回退到 `bash /dev/tcp`。
> 如果**连 `timeout` 也没有**，就仍然会全判故障 —— 装 `coreutils` 即可。

### 3.3 装 `nc`（推荐，探测更快更省进程）

```bash
apt-get update -qq && apt-get install -y netcat-openbsd   # Debian/Ubuntu
apk add --no-cache netcat-openbsd                          # Alpine
dnf install -y nmap-ncat || yum install -y nmap-ncat       # CentOS/RHEL
```

装完重启健康检查服务：

```bash
systemctl restart realm-health-check.timer
```

### 3.4 其它可能原因

| 原因 | 检查 |
|------|------|
| 目标端口确实不通 | 手动 `nc -z -w3 <目标IP> <目标端口>` |
| 探测的是 TCP 而不是应用层 | 端口通但服务已死（SYN 有人应答但业务无响应）→ 探测无法发现，需人工介入 |
| 目标只监听 127.0.0.1 | 健康检查从本机探测，`REMOTE_HOST` 必须是可达地址 |
| 超时太短 | `CONNECTION_TIMEOUT` 默认 3 秒，跨国链路建议调大（范围 1-10） |
| 失败阈值太小 | `FAILURE_THRESHOLD` 默认 2，网络抖动会误判。调大到 3-5 |

---

## 4. 下载 404 / 脚本拉不下来

### 4.1 本项目所有下载地址

除 realm 主程序来自官方 `zhboner/realm` 外，**本项目自己的脚本全部指向本 fork**：

```
https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/...
```

| 文件 | 下载 URL | 源码位置 |
|------|----------|----------|
| `xwPF.sh` + `lib/*.sh` | `.../main/xwPF.sh`、`.../main/lib/<f>` | `xwPF.sh:12`、`xwPF.sh` 的 `_bootstrap` |
| `cmd/*` | `.../main/cmd/<f>` | `xwPF.sh` 的 `_bootstrap` |
| `xwFailover.sh` | `.../main/xwFailover.sh` | `lib/ui.sh` 的 `download_failover_script` |
| `speedtest.sh` | `.../main/speedtest.sh` | `lib/ui.sh` 的 `download_speedtest_script` |
| `port-traffic-dog.sh` | `.../main/port-traffic-dog.sh` | `lib/ui.sh` 的 `port_traffic_dog_menu` |
| `xw_realm_OCR.sh` | `.../main/xw_realm_OCR.sh` | `lib/ui.sh` 的 `download_realm_ocr_script` |
| `notifications/*` | `.../main/notifications` | `port-traffic-dog.sh:2390` |

### 4.2 主脚本 404 的排查顺序

1. 确认分支名是 `main`（不是 `master`）
2. 确认仓库名拼写完整：`byby5555/realm-xwPF-offline-active-standby`
3. 手动验证：

```bash
curl -fsSLI https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwPF.sh
```

4. 网络受限 → 换加速源：

```bash
curl -fsSL https://v6.gh-proxy.org/https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwPF.sh | sudo bash -s install
```

### 4.3 下载失败的两种后果

| 失败对象 | 后果 | 源码位置 |
|----------|------|----------|
| `xwPF.sh` 或任一 `lib/*.sh` | `_bootstrap` 返回 1 → **整个安装中止** | `xwPF.sh` 的 `_bootstrap`、`xwPF.sh` 的 `_bootstrap`、`xwPF.sh:125` |
| `cmd/*` | **不阻断安装**，只是打印黄色警告 | `xwPF.sh` 的 `_bootstrap` |

`cmd/` 下载失败会在安装守护进程时由 `failover_install_files` 从 GitHub raw 兜底
（`lib/failover.sh` 的 `failover_install_files`）；离线环境下则保留本地已有文件（`lib/failover.sh` 的 `failover_install_files`）。

### 4.4 下载不完整 / 文件损坏

下载是**原子化**的：先下到 `.tmp.$$`，校验非空，再 `mv -f` 覆盖
（`xwPF.sh:30-50`、`lib/realm.sh` 的 `download_from_sources`）。
**故意不用 `curl -C -` / `wget -c`** —— 断点续传只校验 HTTP Range 起点，不校验本地内容，
远端变长时会把新版本追加到旧内容后面，产出「大小正常但内容损坏」的文件。

如果怀疑文件损坏，删掉重下：

```bash
rm -f /usr/local/bin/xwPF.sh /usr/local/bin/lib/*.sh
# 然后重新执行 install
```

---

## 5. 日志在哪

| 服务 | 查看方式 | 源码位置 |
|------|----------|----------|
| realm | `journalctl -u realm -f --no-pager` | `lib/realm.sh` 的 `svc_logs` |
| realm（OpenRC） | `tail -f /var/log/messages` | `lib/realm.sh` 的 `svc_logs` |
| 健康检查 | `journalctl -u realm-health-check.service -f` | `lib/health.sh` 的 `start_health_check_service` |
| 健康检查（按 tag） | `journalctl -t realm-health -f` | `lib/health.sh` 的 `start_health_check_service` |
| xwpf-failover 守护 | `journalctl -fu xwpf-failover` | `lib/failover.sh` 的 `failover_log_follow` |

菜单里也能直接看：`pf` → `5. 查看日志`（realm，实时）、`9. 主备 active/passive` 菜单里的
日志选项（守护进程）。

### 健康状态不是日志

健康状态在**状态文件**里，不在 journal 里：

```bash
cat /etc/realm/health/health_status.conf
# 或
bash /etc/realm/xwFailover.sh status
```

格式：`RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY`
（`lib/health.sh` 的 `health_check_script_body`）。最后两个字段是时延（毫秒）与最近 5 次时延样本。

---

## 6. 主备不切换或切错目标

### 6.1 健康检查服务根本没在跑

```bash
systemctl status realm-health-check.timer
systemctl status realm-health-check.service
```

没在跑就手动起：

```bash
bash /etc/realm/xwFailover.sh start
```

> `xwFailover.sh` 是按需下载的，文件不存在说明从没进过故障转移菜单。

### 6.2 `pf` 命令不在 PATH

健康检查脚本靠 `pf --restart-service` 触发配置重建（`xwFailover.sh` 的 `restart_realm_service`）。
`pf` 不存在 → 状态变了但**配置不重建** → 看起来「不切换」。

```bash
command -v pf || ls -l /usr/local/bin/pf
```

### 6.3 目标数不够

主备至少要有 2 个目标。菜单里只有目标数 > 1 的端口组才会出现
（`xwFailover.sh` 的 `toggle_failover_mode`、`lib/rules.sh` 的 `load_balance_management_menu`）。

### 6.4 `FAILOVER_ENABLED` 没开

规则文件里确认：

```bash
grep -H 'BALANCE_MODE\|FAILOVER_ENABLED' /etc/realm/rules/rule-*.conf
```

应该看到 `BALANCE_MODE="active-standby"` 和 `FAILOVER_ENABLED="true"`。

### 6.5 切到了「错」的目标

主备目标是「主 → 备1 → 备2」按顺序接替，**主恢复就立刻切回主**，不等备机
（`lib/realm.sh` 的 `generate_endpoints_from_rules`）。

**谁当主按权重决定**：端口组权重里含 0 时，按权重从高到低排优先级，
再在优先级顺序里取第一个健康目标当主（`lib/realm.sh` 的 `generate_endpoints_from_rules`）。
同权重保持原始顺序；权重个数与目标数不一致时退化为「原始顺序里第一个健康目标」。

```bash
# 0,10,0  → 第二个目标是主（权重 10 最高）
# 1,0,0   → 第一个目标是主
```

> 对 `1,0,0` 这种标准写法，与旧行为（按原始顺序）结果一致；非标准写法（如 `0,10,0`）结果不同。

### 6.6 全挂时的兜底

所有目标都故障时，配置里会**强制把优先级最高的目标权重置 1**（`lib/realm.sh` 的 `generate_endpoints_from_rules`），
避免完全断流。这个目标是不健康的，只是权重大。

### 6.7 「IP 还通，但链路不通」为什么没切

这是最容易被误解的一条：**健康检查探测的不是「链路」，而是一次 TCP 握手**。

```
客户端 ──链路A──> 中转机 ──链路B──> 目标
                   ↑
              健康检查只看这一段
```

探测点在**中转机上**，目标是 `REMOTE_HOST:REMOTE_PORT`，判定标准只有一个：
**TCP 三次握手能不能完成**。因此：

| 现象 | 健康检查能发现吗 | 原因 |
|------|------------------|------|
| 目标机器宕机 / 网卡 down | ✅ 能 | 握手直接失败 |
| 目标防火墙把端口 drop 了 | ✅ 能 | 握手超时 |
| 中转机 → 目标 这段链路断（中间运营商挂了） | ✅ 能 | 握手失败 |
| **端口还开着，但服务进程死了 / 卡死** | ❌ 不能 | 内核还在应答 SYN，握手照样成功 |
| **客户端 → 中转机 这段链路断** | ❌ 不能 | 探测点在服务端，压根看不到客户端那一段 |
| 目标业务层异常（应用返回 5xx） | ❌ 不能 | TCP 层一切正常 |
| 目标 IP 换了、路由变了 | ❌ 不能 | 端口仍可达 |

所以「IP 还通但链路不通」分两种：

1. **不通的是「中转机 → 目标」这一段** → 健康检查**应该**切。
   没切就按顺序排查 §6.1（定时器在跑吗）、§6.2（`pf` 在 PATH 吗）、
   §6.4（`FAILOVER_ENABLED` 开了吗）、§3.4（失败阈值 / 超时）。
2. **不通的是「客户端 → 中转机」这一段** → 健康检查**永远不会发现**，
   因为它站在中转机内侧探测自己到目标的连通性。这一段需要你自己监控
   （客户端侧探活、或者看 realm 的连接日志）。

> 想让「端口通但服务死」也能被发现，可以把探测目标换成**业务端口**以外的
> 健康端口（业务挂了那个端口也一起关掉），或者在目标侧放一个会随业务
> 存活而关闭的探针端口。当前实现的探测对象是规则里的 `REMOTE_HOST:REMOTE_PORT`，
> 不支持自定义探测端口。

---

## 7. 权重不生效或报错

### 7.1 报错「权重数量不匹配」

权重个数必须**等于**端口组展开后的目标数（`lib/rules.sh` 的 `validate_weight_input`）。
端口组有 3 个目标就填 3 个值。

### 7.2 报错「权重不能全部为 0」

全 0 会让整个端口组没有出口，被拒绝（`lib/rules.sh` 的 `validate_weight_input`）。

### 7.3 报错「权重值 X 超出范围」

取值范围 `0-10`（`lib/rules.sh` 的 `validate_weight_input`）。

### 7.4 填了但 realm 配置里不对

先看规则文件里存的是什么：

```bash
grep -H 'WEIGHTS' /etc/realm/rules/rule-*.conf
```

**坑**：端口组里**第一条**规则存完整列表（`WEIGHTS="1,0,0"`），**其余规则各存一个值**
（`WEIGHTS="0"`）（`lib/rules.sh` 的 `apply_port_group_weight_config`）。
读取端口组权重时带逗号的那份优先（`lib/realm.sh` 的 `generate_endpoints_from_rules`）。
手工编辑请确保第一条是完整列表。

再看生成后的配置：

```bash
jq '.endpoints[].balance' /etc/realm/config.json
```

期望看到 `"roundrobin: 1, 0, 0"`。

### 7.5 权重被重置了

切换负载均衡模式会重置 `WEIGHTS`（`lib/rules.sh` 的 `switch_balance_mode`）：
切到 `off` 会清空，切到 `roundrobin`/`iphash` 会重置为 `1,1,1,...`。

另外，从 `active-standby` 切出时也会重置 —— 因为主备运行时权重已被翻转成 0/1 列表
（`lib/rules.sh` 的 `switch_balance_mode`）。

---

## 8. 端口冲突

创建规则时会检查端口占用（`check_port_usage`，`lib/core.sh` 的 `smart_display_target`）：

```bash
ss -tulnp | grep ":8080 "
```

- 被 **realm** 占用 → 提示「端口 X 已被realm服务占用，支持单端口中转多服务端配置」，**允许继续**
- 被**其它进程**占用 → 提示占用进程信息，并要你确认 `y` 才继续

端口合法性由 `is_valid_port` / `validate_port` 校验：1-65535
（`lib/core.sh` 的 `is_valid_port`、`lib/core.sh` 的 `check_port_usage`）。

---

## 9. 权限相关

| 场景 | 要求 | 源码位置 |
|------|------|----------|
| `pf` / `xwPF.sh install` | root | `lib/core.sh` 的 `generate_complete_config`、`xwPF.sh:123` |
| `xwFailover.sh` | root（`check_root`） | `xwFailover.sh` 的 `check_root` |
| 健康检查脚本 | `User=root`（unit 里写死） | `lib/health.sh` 的 `start_health_check_service` |

非 root 执行会直接退出：

```
错误: 此脚本需要 root 权限运行。
```

---

## 10. 收集信息（报 bug 前先跑这个）

```bash
echo "=== 脚本版本 ==="
grep -E '^SCRIPT_VERSION|^REALM_VERSION' /usr/local/bin/lib/core.sh

echo "=== 服务状态 ==="
systemctl status realm --no-pager -l
systemctl status realm-health-check.timer --no-pager -l
systemctl status xwpf-failover --no-pager -l

echo "=== 规则 ==="
cat /etc/realm/rules/rule-*.conf

echo "=== 健康状态 ==="
cat /etc/realm/health/health_status.conf 2>/dev/null

echo "=== 生成的配置 ==="
cat /etc/realm/config.json

echo "=== 依赖 ==="
for t in curl wget tar grep cut bc jq openssl python3 nc; do
  printf '%-10s %s\n' "$t" "$(command -v $t || echo '缺失')"
done

echo "=== 近期日志 ==="
journalctl -u realm -n 50 --no-pager
journalctl -u realm-health-check.service -n 50 --no-pager
```

> ⚠️ 贴日志前请自行检查里面有没有真实服务器地址、内网 IP 或敏感信息。

---

## 11. 更新失败

更新中心（主菜单 `9. 检查更新 / 安全更新`）失败时，**现有版本不会被破坏** ——
先看它属于哪一类：

| 提示 | 原因 | 怎么办 |
|------|------|--------|
| `sha256 校验不通过，拒绝安装` | 下载到的包与上游对不上（下载损坏 / 代理劫持） | 换个网络或加速源重试；**不要**手工解压安装 |
| `新二进制无法执行或不是有效程序` | 架构不匹配（armv7 拿了 x86_64 的包） | 检查 `detect_realm_asset_name` 推出来的资产名与 `uname -m` 是否匹配 |
| `新二进制版本与目标不符` | 拿到的不是目标版本（代理返回了旧包） | 换个源重试 |
| `新版本启动失败，自动回滚` | 新版 realm 起不来（配置不兼容等） | 已自动回滚到旧版本；看 `journalctl -u realm -n 50` 定位原因 |
| `下载 xxx 失败，现有文件未改动` | 网络/代理问题 | 现有文件完好，直接重试即可 |
| `语法检查失败: xxx` | 下载到的脚本不完整 | 现有文件未动，重试 |
| `另一个更新进程正在运行` | 有人正在更新 | 等它结束；进程被 kill 留下的陈旧锁会自动接管 |
| `获取上游最新版本失败` | 拿不到 GitHub release 信息 | 检查网络；脚本会退回解析 release 页面 |
| `Text file busy` | 直接 `cp` 覆盖了正在运行的二进制 | 改用「拷到临时文件 + `mv` 覆盖」（见下方手工回滚） |
| `恢复失败: /xxx` | 自动回滚时覆盖不到文件 | 按提示手工从备份目录恢复（脚本会打印备份路径） |

### 手工回滚

更新前的备份都在 `/usr/local/bin/.xwpf-backup/`（保留最近 5 份）：

```bash
ls -1dt /usr/local/bin/.xwpf-backup/*/ | head

# 例如把 realm 回滚到某一份
#
# 关键：**不要直接 cp 覆盖** /usr/local/bin/realm ——
# 正在运行的二进制会被内核挡住（ETXTBSY / "Text file busy"）。
# 而 realm 是被健康检查服务拉起来的（每秒一次），
# systemctl stop realm 只能按住 2 秒，cp 照样失败。
# 正确做法：先拷到临时文件，再用 mv 覆盖 ——
# mv 改的是目录项（unlink + link），不受 ETXTBSY 限制。
cp -p /usr/local/bin/.xwpf-backup/realm-20261024-120000/usr/local/bin/realm /tmp/realm.rollback
chmod +x /tmp/realm.rollback
mv -f /tmp/realm.rollback /usr/local/bin/realm
systemctl restart realm
systemctl status realm --no-pager
```

脚本包的回滚同理（把 `scripts-时间戳/` 里的文件拷回原位，同样走「临时文件 + mv」）。

