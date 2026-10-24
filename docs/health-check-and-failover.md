# 健康检查与故障转移

本文说明**健康检查参数**、**systemd unit**、**健康状态文件**，以及**切换 / 回切逻辑**。

> 文中每条规则都标注了源码位置（`文件:行号`），核对基准是本仓库 `main` 分支。

---

## 0. ⚠️ 唯一真源约定

> 健康检查服务逻辑的**唯一真源是 `lib/health.sh`**。
> 不要在其它地方实现第二份健康检查脚本生成逻辑；需要复用就 `source` 它。
>
> **当前状态（待落盘）**：健康检查脚本目前仍由 `xwFailover.sh` 的 `start_health_check_service`
> 内联生成（`xwFailover.sh:442-630`，一段 heredoc）。`lib/health.sh` 正在由另一条会话从
> `xwFailover.sh` 抽出来，**尚未落盘**。
>
> 本文档描述的是**当前 `main` 分支的实际行为**。等 `lib/health.sh` 落盘后，
> 行为应保持一致；若不一致，以 `lib/health.sh` 为准。

---

## 1. 两种「故障转移」不是一回事

这个项目里有**两套独立机制**，容易混：

| 机制 | 作用域 | 开关 | 说明 |
|------|--------|------|------|
| **负载均衡故障转移**（剔除模式 / 主备模式） | 端口组内多目标之间 | `FAILOVER_ENABLED` + `BALANCE_MODE` | 本文档讲的这一套，由 `realm-health-check.timer` 驱动 |
| **主备 active/passive**（进程级） | 整机级主备热切换 | `xwpf-failover` 守护进程 | 独立守护进程 + realm 回环监听，详见 `cmd/README-failover.md` |

两者互不替代。

---

## 2. 健康检查参数

### 2.1 参数表

参数**按端口组**配置，落盘在该端口组下**每一条**中转规则的 `rule-N.conf` 里。

| 参数 | 含义 | 默认值 | 合法范围 | 源码位置 |
|------|------|--------|----------|----------|
| `HEALTH_CHECK_INTERVAL` | 探测间隔（秒） | `4` | `1`-`60` | 默认 `lib/rules.sh:2718`、`xwFailover.sh:52`；范围 `xwFailover.sh:724` |
| `FAILURE_THRESHOLD` | 连续失败多少次判定为故障 | `2` | `1`-`10` | 默认 `lib/rules.sh:2719`、`xwFailover.sh:53`；范围 `xwFailover.sh:725` |
| `SUCCESS_THRESHOLD` | 连续成功多少次判定为恢复 | `2` | `1`-`10` | 默认 `lib/rules.sh:2720`、`xwFailover.sh:54`；范围 `xwFailover.sh:726` |
| `CONNECTION_TIMEOUT` | 单次 TCP 连接超时（秒） | `3` | `1`-`10` | 默认 `lib/rules.sh:2721`、`xwFailover.sh:55`；范围 `xwFailover.sh:727` |
| `RECOVERY_COOLDOWN` | 恢复冷却期（秒） | `120` | `10`-`3600` | 默认 `lib/rules.sh:2722`、`xwFailover.sh:56`；范围 `xwFailover.sh:728` |

取值非法时：

- 读参数时（`validate_positive_int`，`xwFailover.sh:17-26`）：非数字或 `<= 0` → **回退到默认值**，不报错。
- 改参数时（`validate_int_range`，`xwFailover.sh:28-45`）：超范围 → **直接报错并拒绝保存**。

### 2.2 修改参数

```
pf
# → 2. 转发配置管理
# → 6. 负载均衡管理
# → 3. 开启/关闭故障转移 → 进入 xwFailover.sh 的 config 子命令
```

`configure_failover_params`（`xwFailover.sh:676-815`）逐项提示，回车表示保持当前值：

```
检查间隔秒数 [当前 4]:
失败阈值(连续失败次数) [当前 2]:
成功阈值(连续成功次数) [当前 2]:
连接超时秒数 [当前 3]:
恢复冷却秒数 [当前 120]:
```

保存后会重启 realm，并**按新间隔刷新健康检查定时器**
（`xwFailover.sh:808-812`）。

命令行等价用法：

```bash
bash /etc/realm/xwFailover.sh config
```

---

## 3. 探测方式

### 3.1 TCP 端口探测，不是 ping

健康检查探测的是**目标的 TCP 端口**（`REMOTE_HOST:REMOTE_PORT`），**不是 ping**。
探测函数（`xwFailover.sh:487-515`）有两条路：

```bash
# 方式1: netcat（需支持 -z 探测模式）
if command -v nc >/dev/null 2>&1; then
    if nc -h 2>&1 | grep -q -- '-z' 2>/dev/null; then
        nc -z -w "$timeout" "$target" "$port" >/dev/null 2>&1
        return $?
    fi
fi

# 方式2: bash 内置 /dev/tcp（不依赖 netcat）
if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" bash -c "exec 3<>/dev/tcp/${target}/${port}" >/dev/null 2>&1
    ...
fi
```

`nc` 不在 `REQUIRED_TOOLS` 里（`lib/core.sh:24`）不会被自动安装，
但**没有 `nc` 也能正常探测** —— 会自动回退到 `bash /dev/tcp`。
旧版本没有回退，系统没装 `nc` 时会把所有目标标记为故障、触发不必要的切换。

> ⚠️ 探测只到 **TCP 握手**这一层：
> 端口通但业务已死（有人应答 SYN 但服务无响应）、或故障发生在**客户端 → 中转机**这一段，
> 探测都发现不了。健康检查探测的是「中转机 → 目标」这一段。

安装 `nc` 见 [安装、升级与卸载 §1.3](install-and-upgrade.md#13-nc-不在自动安装清单里--可选但建议装)。

### 3.2 探测范围

只探测满足以下**全部**条件的规则（`xwFailover.sh:554-557`）：

- `RULE_ROLE = 1`（中转服务器）
- `ENABLED = true`
- `FAILOVER_ENABLED = true`

每条规则的 `REMOTE_HOST` 按逗号展开成多个目标，每个目标用该规则的 `REMOTE_PORT`
（`xwFailover.sh:559-580`）。

---

## 4. systemd unit

### 4.1 `realm-health-check.service`

由 `start_health_check_service` 生成（`xwFailover.sh:635-651`）：

```ini
[Unit]
Description=Realm Health Check Service
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/realm/health/health_check.sh
User=root
WorkingDirectory=/etc/realm
StandardOutput=journal
StandardError=journal
SyslogIdentifier=realm-health

[Install]
WantedBy=multi-user.target
```

### 4.2 `realm-health-check.timer`

（`xwFailover.sh:654-666`）

```ini
[Unit]
Description=Realm Health Check Timer
Requires=realm-health-check.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=<effective_interval>sec
Persistent=true

[Install]
WantedBy=timers.target
```

### 4.3 `effective_interval` 怎么算

`OnUnitActiveSec` 用的不是单条规则的间隔，而是：

> **所有「中转 + 已启用 + 已开启故障转移」的规则的 `HEALTH_CHECK_INTERVAL` 里的最小值**，
> 没有这类规则时用 `4`。

（`get_effective_health_check_interval`，`xwFailover.sh:65-80`）

所以只要有一个端口组把间隔设成 1 秒，整个定时器就按 1 秒跑。

### 4.4 启停

```bash
systemctl status realm-health-check.timer
systemctl status realm-health-check.service
journalctl -u realm-health-check.service -f     # 实时日志
journalctl -t realm-health -f                    # 按 SyslogIdentifier 看
```

停止并清理（`stop_health_check_service`，`xwFailover.sh:817-832`）：

```bash
systemctl stop realm-health-check.timer
systemctl disable realm-health-check.timer
systemctl stop realm-health-check.service
systemctl disable realm-health-check.service
rm -f /etc/systemd/system/realm-health-check.timer
rm -f /etc/systemd/system/realm-health-check.service
rm -f /etc/realm/health/health_check.sh
systemctl daemon-reload
```

### 4.5 并发保护

健康检查脚本用 `flock` 抢独占锁，避免上一轮没跑完就叠加下一轮
（`xwFailover.sh:479-484`）：

```bash
exec 200>"$LOCK_FILE"          # /var/lock/realm-health-check.lock
if ! flock -n 200; then
    echo "... [INFO] 健康检查已在运行中，跳过本次检查"
    exit 0
fi
```

---

## 5. 健康状态文件

### 5.1 路径与格式

主路径：`/etc/realm/health/health_status.conf`（`xwFailover.sh:13`）

生成脚本会在几个候选路径里找已有的（`xwFailover.sh:450-462`）：

```
/etc/realm/health/health_status.conf
/etc/realm/health_status.conf
/var/lib/realm/health_status.conf
```

都找不到就默认用第一个。

**行格式**（`xwFailover.sh:537`、`xwFailover.sh:584`）：

```
RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME
```

| 字段 | 说明 |
|------|------|
| `RULE_ID` | 规则 ID |
| `TARGET` | `host:port` |
| `STATUS` | `healthy` / `failed` |
| `FAIL_COUNT` | 连续失败次数 |
| `SUCCESS_COUNT` | 连续成功次数 |
| `LAST_CHECK` | 上次检查的 Unix 时间戳 |
| `FAILURE_START_TIME` | 本次故障开始时间戳（未故障为 `0`） |

文件头两行是注释（`xwFailover.sh:535-538`）：

```
# Realm健康状态文件
# 格式: RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME
```

### 5.2 原子更新

每次更新都是「删掉旧行 → 写临时文件 → `mv` 覆盖」（`xwFailover.sh:612-615`）：

```bash
grep -v "^${target_key}|" "$HEALTH_STATUS_FILE" > "$HEALTH_STATUS_FILE.tmp"
echo "..." >> "$HEALTH_STATUS_FILE.tmp"
mv "$HEALTH_STATUS_FILE.tmp" "$HEALTH_STATUS_FILE"
```

### 5.3 自清理

| 触发条件 | 行为 | 源码位置 |
|----------|------|----------|
| 文件 > 5 MB | 按行截断，保留最后 2000 行 | `xwFailover.sh:464-471` |
| 每小时的整点（分钟 = `00`） | `journalctl --vacuum-time=7d` 清 7 天前的 journal | `xwFailover.sh:473-477` |

### 5.4 规则重排时同步

规则 ID 重排（`reorder_rule_ids`）后，健康状态文件里的 `RULE_ID` 会按
`REMOTE_HOST` / `FORWARD_TARGET` 重新匹配并改写（`sync_health_status_ids`，`lib/rules.sh:51-91`）。
匹配不上的旧行会被丢弃。

---

## 6. 状态机

### 6.1 计数

| 探测结果 | 变化 | 源码位置 |
|----------|------|----------|
| 成功 | `success_count++`，`fail_count = 0` | `xwFailover.sh:583-586` |
| 失败 | `fail_count++`，`success_count = 0` | `xwFailover.sh:599-601` |

### 6.2 判定为故障

```
status == healthy  且  fail_count >= FAILURE_THRESHOLD
    → status = failed
    → failure_start_time = 当前时间戳
```

（`xwFailover.sh:603-609`）

### 6.3 判定为恢复

```
status == failed  且  success_count >= SUCCESS_THRESHOLD
    且  当前时间 - failure_start_time >= RECOVERY_COOLDOWN
    → status = healthy
    → failure_start_time = 0
```

（`xwFailover.sh:587-597`）

**冷却期是必需的**：连续成功达标但冷却期没到，状态**保持 failed**。
这是防止节点抖动导致频繁切换的关键。

### 6.4 旧格式兼容

早期版本的状态文件没有 `FAILURE_START_TIME` 字段，这时会拿 `LAST_CHECK` 顶替
（`xwFailover.sh:569-572`）。

---

## 7. 切换与回切

### 7.1 触发链路

```
systemd timer（每 effective_interval 秒）
  └→ /etc/realm/health/health_check.sh
       ├→ flock 抢锁（跑着就跳过）
       ├→ 读规则 → 展开目标 → 逐个 nc 探测
       ├→ 更新 health_status.conf（原子）
       ├→ 判断状态变化 → config_changed=true
       └→ config_changed 时执行 pf --restart-service
            └→ service_restart
                 ├→ reorder_rule_ids（重排规则 ID + 同步健康状态）
                 ├→ generate_realm_config（重新生成 /etc/realm/config.json）
                 └→ svc_restart（重启 realm）
```

`pf --restart-service` 的调用点：`xwFailover.sh:619-627`。
`service_restart` 的实现：`lib/realm.sh:1042-1062`。

> 注意：健康检查**直接**调 `pf --restart-service`，不走标记文件。

### 7.2 主备模式（`active-standby`）的切换

见 [端口组与权重 §5](port-groups-and-weights.md#5-100-主备写法)。

要点：

- 所有目标**始终保留**在 `remote` + `extra_remotes`（`lib/realm.sh:558-559`）
  → 健康检查可以持续探测故障目标，主恢复时能立刻切回
- 权重翻转为 **0/1 列表**，只有当前主是 1（`lib/realm.sh:525-537`）
- 全挂时强制把优先级最高的目标置 1，避免完全断流（`lib/realm.sh:539-556`）
- `active-standby` 在 realm 配置里映射成 `roundrobin`（`lib/realm.sh:706-711`）

逐态推演见 [active-standby-logic.md](active-standby-logic.md)。

### 7.3 剔除模式（legacy）的切换

失败目标**从 `port_groups` 里移除**，`extra_remotes` 列表随之变短，
权重同步调整以匹配剩余目标数（`lib/realm.sh:561-620`）。

与主备模式的关键差异：

| 维度 | 剔除模式 | 主备模式 |
|------|----------|----------|
| 失败目标 | 从列表移除 | 保留在列表里 |
| 权重 | 只剩健康节点的权重 | 全列表重写为 `0,...,1,...,0` |
| 恢复时机 | 成功 `SUCCESS_THRESHOLD` 次 + 冷却 `RECOVERY_COOLDOWN` | 同左（同一套机制） |
| 严格切回主 | 不适用 | 是（主恢复立刻切回，不等备机） |
| realm `extra_remotes` | 变短 | 保持完整 |

### 7.4 开关故障转移

```
pf
# → 2. 转发配置管理
# → 6. 负载均衡管理
# → 3. 开启/关闭故障转移 → 选端口组
```

开启时可以选择模式（`xwFailover.sh:330-346`）：

```
1. 剔除模式（原有） - 故障目标从负载均衡列表中移除
2. 主备模式 (active-standby) - 严格主备：1 主 N 备按顺序接替，主恢复后切回主
```

开启「主备模式」会把该端口下所有规则的 `BALANCE_MODE` 设为 `active-standby`
（`xwFailover.sh:363-371`），并启动健康检查服务。

关闭时：如果**没有其它规则**还在用故障转移，才会停掉健康检查服务
（`xwFailover.sh:405-425`）。

### 7.5 故障转移的前提条件

菜单里只有满足以下**全部**条件的端口组才会出现（`xwFailover.sh:193-194`、`xwFailover.sh:254`）：

1. 规则类型为中转服务器（`RULE_ROLE=1`）
2. 已启用（`ENABLED=true`）
3. 已启用负载均衡（`BALANCE_MODE != off`）
4. 有**多个**目标服务器

---

## 8. 命令行接口

`/etc/realm/xwFailover.sh`（`xwFailover.sh:892-903`、`xwFailover.sh:914-945`）：

| 子命令 | 作用 |
|--------|------|
| `toggle` | 交互式开关故障转移（默认） |
| `config` | 配置间隔 / 阈值 / 超时 / 冷却 |
| `status` | 查看健康状态 |
| `start` | 启动健康检查服务 |
| `stop` | 停止并清理健康检查服务 |
| `restart-realm` | 调 `pf --restart-service` 重启 realm |
| `help` / `-h` / `--help` | 帮助 |

```bash
bash /etc/realm/xwFailover.sh status
```

> `xwFailover.sh` 是**按需下载**的，进「故障转移管理」菜单时才会拉到 `/etc/realm/xwFailover.sh`
> （`lib/ui.sh:701`）。没进过菜单的话这个文件不存在。

---

## 9. 待验证项

| 项 | 说明 |
|----|------|
| `lib/health.sh` 尚未落盘 | 当前健康检查脚本仍由 `xwFailover.sh` 内联 heredoc 生成（`xwFailover.sh:442-630`）。`lib/health.sh` 落盘后行为应一致；如有差异以 `lib/health.sh` 为准 |
| 主备优先级是否按权重排序 | `lib/realm.sh` 有未提交改动，把主目标判定改为按权重降序。详见 [端口组与权重 §5.3](port-groups-and-weights.md#53-主备优先级与权重的关系) |
| `realm-health-check.service` 是否需要 `After=network-online.target` | 当前只写了 `After=network.target`。开机后立刻探测可能在网络就绪前失败（表现为开机瞬间误判故障）。是否调整待确认 |
| `journalctl --vacuum-time=7d` 的影响范围 | 该命令清理的是**全系统** journal（不限本服务），在有其它业务日志的机器上影响面较大。是否收窄待确认 |
