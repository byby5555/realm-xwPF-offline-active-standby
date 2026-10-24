# 健康检查与故障转移

本文说明**健康检查参数**、**systemd unit**、**健康状态文件**，以及**切换 / 回切逻辑**。

> 文中每条规则都指向**具体函数**（写法：`文件` 的 `函数名`），不写行号 —— 行号会随代码改动整体漂移。
> 需要行号时现查：`grep -n '<函数名>' <文件>`。

---

## 0. ⚠️ 唯一真源约定

> 健康检查服务逻辑的**唯一真源是 `lib/health.sh`**。
> 不要在其它地方实现第二份健康检查脚本生成逻辑；需要复用就 `source` 它。
>
> **当前状态（已落盘）**：健康检查脚本由 `lib/health.sh` 的 `health_check_script_body`
> 生成（`lib/health.sh` 内的一段 heredoc），`xwFailover.sh` 与 `pf` 主脚本
> 都 `source` 同一个文件，不再各写一份。
>
> 例外只有一处：生成的 `/etc/realm/health/health_check.sh` 是一份**独立可执行**的脚本
> （systemd 直接调用它，不能依赖 pf 的安装目录）。
> 但它里面的探测逻辑**不是手抄的第二份**：生成时由 `lib/health.sh` 的 `health_emit_function`
> 从 `lib/health.sh` 里**原样抽取** `check_connectivity` 拼进去，
> 所以两边不可能漂移，改探测实现不需要在别处手工同步。
> 台架用例 T28 盯这一条（源实现与生成物里的探测实现必须一致）。

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
| `HEALTH_CHECK_INTERVAL` | 探测间隔（秒） | `4` | `1`-`60` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |
| `FAILURE_THRESHOLD` | 连续失败多少次判定为故障 | `2` | `1`-`10` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |
| `SUCCESS_THRESHOLD` | 连续成功多少次判定为恢复 | `2` | `1`-`10` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |
| `CONNECTION_TIMEOUT` | 单次 TCP 连接超时（秒） | `3` | `1`-`10` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |
| `RECOVERY_COOLDOWN` | 恢复冷却期（秒） | `120` | `10`-`3600` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |

取值非法时：

- 读参数时（`validate_positive_int`，`lib/health.sh` 的 `validate_positive_int`）：非数字或 `<= 0` → **回退到默认值**，不报错。
- 改参数时（`validate_int_range`，`xwFailover.sh` 的 `validate_int_range`）：超范围 → **直接报错并拒绝保存**。

### 2.2 修改参数

```
pf
# → 2. 转发配置管理
# → 6. 负载均衡管理
# → 3. 开启/关闭故障转移 → 进入 xwFailover.sh 的 config 子命令
```

`configure_failover_params`（`xwFailover.sh` 的 `configure_failover_params`）逐项提示，回车表示保持当前值：

```
检查间隔秒数 [当前 4]:
失败阈值(连续失败次数) [当前 2]:
成功阈值(连续成功次数) [当前 2]:
连接超时秒数 [当前 3]:
恢复冷却秒数 [当前 120]:
```

保存后会重启 realm，并**按新间隔刷新健康检查定时器**
（`xwFailover.sh` 的 `configure_failover_params`）。

命令行等价用法：

```bash
bash /etc/realm/xwFailover.sh config
```

---

## 3. 探测方式

### 3.1 TCP 端口探测，不是 ping

健康检查探测的是**目标的 TCP 端口**（`REMOTE_HOST:REMOTE_PORT`），**不是 ping**。
探测函数（`lib/health.sh` 的 `check_connectivity`）有两条路：

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

`nc` 不在 `lib/core.sh` 的 `REQUIRED_TOOLS` 里，不会被自动安装，
但**没有 `nc` 也能正常探测** —— 会自动回退到 `bash /dev/tcp`。
旧版本没有回退，系统没装 `nc` 时会把所有目标标记为故障、触发不必要的切换。

> ⚠️ 探测只到 **TCP 握手**这一层：
> 端口通但业务已死（有人应答 SYN 但服务无响应）、或故障发生在**客户端 → 中转机**这一段，
> 探测都发现不了。健康检查探测的是「中转机 → 目标」这一段。

安装 `nc` 见 [安装、升级与卸载 §1.3](install-and-upgrade.md#13-nc-不在自动安装清单里--可选但建议装)。

### 3.2 探测范围

只探测满足以下**全部**条件的规则（`lib/health.sh` 的 `health_check_script_body`）：

- `RULE_ROLE = 1`（中转服务器）
- `ENABLED = true`
- `FAILOVER_ENABLED = true`

每条规则的 `REMOTE_HOST` 按逗号展开成多个目标，每个目标用该规则的 `REMOTE_PORT`
（`lib/health.sh` 的 `health_check_script_body`）。

### 3.3 时延测量（毫秒）

每次探测都会记录**握手耗时**，写进健康状态文件的第 8、9 个字段。

实现（`lib/health.sh` 的 `probe_with_latency`）：

- 打点用 `now_us`：优先 bash 5 的 `EPOCHREALTIME`（不 fork）；回退 `date +%s%N`
  （GNU coreutils；**busybox date 不支持 `%N`**，此时时延列显示 `-`）
- 耗时 = 探测结束 − 探测开始，单位毫秒（向下取整）
- 探测**失败**时也会记录耗时（通常是超时上限值），但状态仍记为 `failed`

时延历史保留**最近 5 次样本**（逗号分隔），用于算平均值 —— 单次握手抖动很大，
只看一个数容易误判。平均值的算法是这 5 个样本的算术平均
（`lib/health.sh` 的 `latency_avg_ms`）。

> 时延是 **TCP 握手耗时**，包含建连开销，不等于纯网络 RTT；
> 跨境链路上通常比 ping 大一个量级（TCP 三次握手 + 内核调度）。

### 3.4 在负载均衡菜单里看时延

`负载均衡管理`（按端口组管理）里，每个目标行会多显示一段时延：

```
1. 203.0.113.10:8080 [权重: 10] (100.0%) [健康] [时延: 12ms (均 12ms)]
2. 203.0.113.11:8080 [权重: 0]  (0.0%)   [健康] [时延: 88ms (均 85ms)]
```

- 数据来自**后台健康检查**写进状态文件的结果，所以会随 timer 持续刷新
  （间隔见 §2.1，默认 4 秒）
- `均` 是最近 5 次样本的平均值（见 §3.3）
- 目标还没被探测过时显示 `-`
- 故障目标显示时延没有意义，直接看 `[故障]` 标记

菜单里还有一个 **`4. 立即测试所有目标时延`**：现场把所有端口组的目标探一轮，
逐行打印可达性与耗时。这是一次**现场探测**，只显示结果、**不写状态文件**
（避免和后台健康检查抢写同一个文件），页面上的时延仍以后台为准。

实现：`lib/rules.sh` 的 `load_balance_management_menu` 与 `probe_all_targets_latency`。

---

## 4. systemd unit

### 4.1 `realm-health-check.service`

由 `start_health_check_service` 生成（`lib/health.sh` 的 `start_health_check_service`）：

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

（`lib/health.sh` 的 `start_health_check_service`）

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

（`get_effective_health_check_interval`，`lib/health.sh` 的 `get_effective_health_check_interval`）

所以只要有一个端口组把间隔设成 1 秒，整个定时器就按 1 秒跑。

### 4.4 启停

```bash
systemctl status realm-health-check.timer
systemctl status realm-health-check.service
journalctl -u realm-health-check.service -f     # 实时日志
journalctl -t realm-health -f                    # 按 SyslogIdentifier 看
```

停止并清理（`stop_health_check_service`，`lib/health.sh` 的 `stop_health_check_service`）：

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
（`lib/health.sh` 的 `health_check_script_body`）：

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

主路径：`/etc/realm/health/health_status.conf`（`lib/health.sh` 的 `HEALTH_STATUS_FILE`）

生成脚本会在几个候选路径里找已有的（`lib/health.sh` 的 `health_check_script_body`）：

```
/etc/realm/health/health_status.conf
/etc/realm/health_status.conf
/var/lib/realm/health_status.conf
```

都找不到就默认用第一个。

**行格式**（`lib/health.sh` 的 `health_check_script_body`、`lib/health.sh` 的 `health_check_script_body`）：

```
RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY
```

| 字段 | 说明 |
|------|------|
| `RULE_ID` | 规则 ID |
| `TARGET` | `host:port`（同一个 host 上的不同端口是不同目标，状态互不覆盖；旧格式只有 host，见 §6.4） |
| `STATUS` | `healthy` / `failed` |
| `FAIL_COUNT` | 连续失败次数 |
| `SUCCESS_COUNT` | 连续成功次数 |
| `LAST_CHECK` | 上次检查的 Unix 时间戳 |
| `FAILURE_START_TIME` | 本次故障开始时间戳（未故障为 `0`） |
| `LATENCY_MS` | 最近一次探测的握手耗时（毫秒）；取不到时间戳或尚未探测时为空 |
| `LATENCY_HISTORY` | 最近 5 次时延样本，逗号分隔（如 `10,12,14`），用于算平均值 |

文件头两行是注释（`lib/health.sh` 的 `health_check_script_body`）：

```
# Realm健康状态文件
# 格式: RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY
```

> 后两个字段是**追加**的，老版本只有 7 个字段。
> 读取方按位置取字段，多出来的字段自动忽略；老文件里时延字段读出来是空 → 显示 `-`。
> 反过来，旧版本读新文件时也不会出错（只读前 7 个字段）。

### 5.2 原子更新

每次更新都是「删掉旧行 → 写临时文件 → `mv` 覆盖」（`lib/health.sh` 的 `health_check_script_body`）：

```bash
grep -v "^${target_key}|" "$HEALTH_STATUS_FILE" > "$HEALTH_STATUS_FILE.tmp"
echo "..." >> "$HEALTH_STATUS_FILE.tmp"
mv "$HEALTH_STATUS_FILE.tmp" "$HEALTH_STATUS_FILE"
```

### 5.3 自清理

| 触发条件 | 行为 | 源码位置 |
|----------|------|----------|
| 文件 > 5 MB | 按行截断，保留最后 2000 行 | `lib/health.sh` 的 `health_check_script_body` |
| 每小时的整点（分钟 = `00`） | `journalctl --vacuum-time=7d` 清 7 天前的 journal | `lib/health.sh` 的 `health_check_script_body` |

### 5.4 规则重排时同步

规则 ID 重排（`reorder_rule_ids`）后，健康状态文件里的 `RULE_ID` 会按
`REMOTE_HOST` / `FORWARD_TARGET` 重新匹配并改写（`sync_health_status_ids`，`lib/rules.sh` 的 `sync_health_status_ids`）。
匹配按「host + 端口」逐个比对（`TARGET` 是 `host:port`，多地址规则要拆开逐个 host 比），
匹配不上的旧行会被丢弃。

---

## 6. 状态机

### 6.1 计数

| 探测结果 | 变化 | 源码位置 |
|----------|------|----------|
| 成功 | `success_count++`，`fail_count = 0` | `lib/health.sh` 的 `health_check_script_body` |
| 失败 | `fail_count++`，`success_count = 0` | `lib/health.sh` 的 `health_check_script_body` |

### 6.2 判定为故障

```
status == healthy  且  fail_count >= FAILURE_THRESHOLD
    → status = failed
    → failure_start_time = 当前时间戳
```

（`lib/health.sh` 的 `health_check_script_body`）

### 6.3 判定为恢复

```
status == failed  且  success_count >= SUCCESS_THRESHOLD
    且  当前时间 - failure_start_time >= RECOVERY_COOLDOWN
    → status = healthy
    → failure_start_time = 0
```

（`lib/health.sh` 的 `health_check_script_body`）

**冷却期是必需的**：连续成功达标但冷却期没到，状态**保持 failed**。
这是防止节点抖动导致频繁切换的关键。

### 6.4 旧格式兼容（缺字段与旧 TARGET 口径）

早期版本的状态文件没有 `FAILURE_START_TIME` 字段，这时会拿 `LAST_CHECK` 顶替
（`lib/health.sh` 的 `health_check_script_body`）。

早期版本的 `TARGET` 字段还只有 `host`（没有端口），所以**同一 host 上跑不同端口的目标会互相覆盖**
（同一主备组里两个目标都指向同一台机器的不同端口时，最典型）。
现在的 `TARGET` 是 `host:port`，两种格式都能认：

- 探测端（`lib/health.sh` 的 `health_check_script_body`）：先按 `RULE_ID|host:port` 找自己的记录，
  找不到再按旧口径 `RULE_ID|host` 找；找到就**沿用旧记录的状态与计数**，
  写回时写成新格式并顺手删掉同一 host 的旧行 —— 老文件里的 `failed` 不会因为升级被当成「健康」。
- 消费端（`lib/realm.sh` 的 `generate_endpoints_from_rules`）：旧格式的行按该行 `RULE_ID`
  对应规则的 `REMOTE_PORT` 补出端口，入**精确键** `host:port`。
  **认得出归属时只入精确键，不另外存一份裸 host 的宽键** —— 宽键会把「一个端口的故障」
  传播给同 host 的其他端口：同一主备组里两个目标都是同 host 不同端口时，两个目标会同时被判 failed
  → 走「全部目标都挂了」的兜底 → 保持原主不切备（该切不切的静默失效）。
  **认不出归属**（规则已删、行号式的老记录）时**当无记录**：让健康检查下一轮重新探测、生成精确键。
- 展示端（`lib/health.sh` 的 `get_health_status_record`）：按 `TARGET` 字段精确匹配；
  查不到就是查不到，**不**按裸 host 兜底（否则会把同 host 另一个端口的记录显示成这条目标的）。

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

`pf --restart-service` 的调用点：`lib/health.sh` 的 `health_check_script_body`。
`service_restart` 的实现：`lib/realm.sh` 的 `service_restart`。

> 注意：健康检查**直接**调 `pf --restart-service`，不走标记文件。

### 7.2 主备模式（`active-standby`）的切换

见 [端口组与权重 §5](port-groups-and-weights.md#5-100-主备写法)。

要点：

- 所有目标**始终保留**在 `remote` + `extra_remotes`（`lib/realm.sh` 的 `generate_endpoints_from_rules`）
  → 健康检查可以持续探测故障目标，主恢复时能立刻切回
- 权重翻转为 **0/1 列表**，只有当前主是 1（`lib/realm.sh` 的 `generate_endpoints_from_rules`）
- 全挂时强制把优先级最高的目标置 1，避免完全断流（`lib/realm.sh` 的 `generate_endpoints_from_rules`）
- `active-standby` 在 realm 配置里映射成 `roundrobin`（`lib/realm.sh` 的 `generate_endpoints_from_rules`）

逐态推演见 [active-standby-logic.md](active-standby-logic.md)。

### 7.3 剔除模式（legacy）的切换

失败目标**从 `port_groups` 里移除**，`extra_remotes` 列表随之变短，
权重同步调整以匹配剩余目标数（`lib/realm.sh` 的 `generate_endpoints_from_rules`）。

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

开启时可以选择模式（`xwFailover.sh` 的 `toggle_failover_mode`）：

```
1. 剔除模式（原有） - 故障目标从负载均衡列表中移除
2. 主备模式 (active-standby) - 严格主备：1 主 N 备按顺序接替，主恢复后切回主
```

开启「主备模式」会把该端口下所有规则的 `BALANCE_MODE` 设为 `active-standby`
（`xwFailover.sh` 的 `toggle_failover_mode`），并启动健康检查服务。

关闭时：如果**没有其它规则**还在用故障转移，才会停掉健康检查服务
（`xwFailover.sh` 的 `toggle_failover_mode`）。

### 7.5 故障转移的前提条件

菜单里只有满足以下**全部**条件的端口组才会出现（`xwFailover.sh` 的 `toggle_failover_mode`、`xwFailover.sh` 的 `toggle_failover_mode`）：

1. 规则类型为中转服务器（`RULE_ROLE=1`）
2. 已启用（`ENABLED=true`）
3. 已启用负载均衡（`BALANCE_MODE != off`）
4. 有**多个**目标服务器

---

## 8. 命令行接口

`/etc/realm/xwFailover.sh`（`xwFailover.sh` 的 `main`）：

| 子命令 | 作用 |
|--------|------|
| `xwFailover.sh toggle` | 交互式开关故障转移（默认） |
| `xwFailover.sh config` | 配置间隔 / 阈值 / 超时 / 冷却 |
| `xwFailover.sh status` | 查看健康状态 |
| `xwFailover.sh start` | 启动健康检查服务 |
| `xwFailover.sh stop` | 停止并清理健康检查服务 |
| `xwFailover.sh restart-realm` | 调 `pf --restart-service` 重启 realm |
| `xwFailover.sh help` | 帮助（`-h` / `--help` 同义） |

```bash
bash /etc/realm/xwFailover.sh status
```

> `xwFailover.sh` 是**按需下载**的，进「故障转移管理」菜单时才会拉到 `/etc/realm/xwFailover.sh`
> （`lib/ui.sh` 的 `download_failover_script`）。没进过菜单的话这个文件不存在。
>
> 它启动时会 `source` `lib/health.sh`（唯一真源）：
> 依次找 `/usr/local/bin/lib/health.sh` → `/etc/realm/lib/health.sh` → 脚本同目录的 `lib/health.sh`。
> 找不到就直接报错退出——**健康检查逻辑只有一份实现**，不存在两份各自漂移的可能。

---

## 9. 已知边界

| 项 | 说明 |
|----|------|
| `lib/health.sh` 已落盘 | 健康检查脚本由 `lib/health.sh` 的 `health_check_script_body` 生成，`xwFailover.sh` 与 `pf` 共用同一份实现。生成的 `health_check.sh` 是独立可执行脚本，其探测逻辑由 `lib/health.sh` 的 `health_emit_function` 原样抽取注入，与真源逐字一致，无需手工同步 |
| 主备优先级按权重排序 | 已实现：主目标 = 权重最大的健康目标（同权重保持原始顺序）。详见 [端口组与权重 §5.3](port-groups-and-weights.md#53-主备优先级与权重的关系) |
| 探测只到 TCP 握手 | 端口通但业务已死、或故障发生在「客户端 → 中转机」这一段，探测都发现不了 → 排查见 [故障排查 §6.7](troubleshooting.md#67-ip-还通但链路不通为什么没切) |
| 探测对象不可自定义 | 探测目标固定为规则里的 `REMOTE_HOST:REMOTE_PORT`，不支持换成独立的健康端口 |
| `realm-health-check.service` 是否需要 `After=network-online.target` | 当前只写了 `After=network.target`。开机后立刻探测可能在网络就绪前失败（表现为开机瞬间误判故障）。是否调整待确认 |
| `journalctl --vacuum-time=7d` 的影响范围 | 该命令清理的是**全系统** journal（不限本服务），在有其它业务日志的机器上影响面较大。是否收窄待确认 |
