# 端口组与权重

本文说明**端口组**怎么分组、**权重**怎么写、`1,0,0` 主备写法到底做了什么。

> **术语口径**：本文的「主备」= **规则级权重主备** —— 同一个端口组内的多个目标之间，
> 靠健康检查翻转 `WEIGHTS` 来切换（主故障切备、主恢复切回），**没有独立进程**。
> 它**不是**已下线的「进程级主备池」（另一个进程自己持有监听口转发的那一套）——
> 后者已随 2026-10-24 的删除整块下线。

> 文中每条规则都指向**具体函数**（写法：`文件` 的 `函数名`），不写行号 —— 行号会随代码改动整体漂移。
> 需要行号时现查：`grep -n '<函数名>' <文件>`。

---

## 1. 什么是端口组

**端口组 = 同一个 `LISTEN_PORT` 下、角色为中转服务器（`RULE_ROLE=1`）的全部目标。**

| 要素 | 定义 | 源码位置 |
|------|------|----------|
| 分组键 | `LISTEN_PORT` | `lib/rules.sh` 的 `load_balance_management_menu`、`xwFailover.sh` 的 `toggle_failover_mode` |
| 参与分组 | `RULE_ROLE=1`（中转服务器），`RULE_ROLE=2`（服务端）不参与 | `lib/rules.sh` 的 `load_balance_management_menu`、`xwFailover.sh` 的 `toggle_failover_mode` |
| 目标表示 | `REMOTE_HOST:REMOTE_PORT` | `xwFailover.sh` 的 `toggle_failover_mode`、`xwFailover.sh` 的 `toggle_failover_mode` |
| 可见条件 | 该端口目标数 **> 1** 才算「端口组」并出现在菜单里 | `lib/rules.sh` 的 `load_balance_management_menu`、`xwFailover.sh` 的 `toggle_failover_mode` |

### 1.1 两种加目标的方式

**方式 A：单条规则里写逗号分隔的多个 `REMOTE_HOST`**

```
REMOTE_HOST="10.0.0.1,10.0.0.2,10.0.0.3"
REMOTE_PORT="8080"
```

**方式 B：拆成多条规则，同一个 `LISTEN_PORT`，不同 `REMOTE_HOST`**

两种方式产生的端口组完全等价。菜单里展开 `REMOTE_HOST` 的逗号列表
（`lib/rules.sh` 的 `load_balance_management_menu`、`xwFailover.sh` 的 `toggle_failover_mode`），并按 `host:port` 去重。

> ⚠️ **同一端口不允许混角色。** `lib/realm.sh` 的 `generate_endpoints_from_rules`：同一 `LISTEN_PORT` 上出现不同
> `RULE_ROLE` 的规则时，后来的规则会被**跳过**并打印警告。中转与服务端必须用不同的监听端口。

> 💡 **每个目标端口可以不一样。** 上面两种方式都让所有目标共用 `REMOTE_PORT`。
> 若备机是「同 host 不同端口」（如主 `127.0.0.1:28081` / 备 `127.0.0.1:28082`），
> 要用 `TARGET_STATES` 表达 —— 见 [5.4 目标形态](#54-目标形态每个目标可以自带端口)。

---

## 2. 负载均衡模式（`BALANCE_MODE`）

菜单路径：`pf` → `2. 转发配置管理` → `6. 负载均衡管理` → `1. 切换负载均衡模式`
（`lib/ui.sh` 的 `rules_management_menu`、`lib/rules.sh` 的 `load_balance_management_menu`）

| 选项 | 取值 | 语义 | 菜单标签 | 源码位置 |
|------|------|------|----------|----------|
| 1 | `off` | 关闭负载均衡，只用第一个目标 | `[off]` | `lib/rules.sh` 的 `switch_balance_mode`、`lib/rules.sh` 的 `get_balance_info_display` |
| 2 | `roundrobin` | 轮询，按权重分配 | `[轮询]` | `lib/rules.sh` 的 `switch_balance_mode`、`lib/rules.sh` 的 `get_balance_info_display` |
| 3 | `iphash` | IP 哈希，同一源 IP 固定落到同一目标 | `[IP哈希]` | `lib/rules.sh` 的 `switch_balance_mode`、`lib/rules.sh` 的 `get_balance_info_display` |
| 4 | `active-standby` | 严格主备：1 主 N 备按顺序接替，主恢复后切回主 | `[主备]` | `lib/rules.sh` 的 `switch_balance_mode`、`lib/rules.sh` 的 `get_balance_info_display` |

三种均衡模式最终都写进 realm 配置的 `balance` 字段（`lib/realm.sh` 的 `generate_endpoints_from_rules`）：

```json
"balance": "roundrobin: 1, 0, 0"
```

`active-standby` **本身不写进 realm**，它在生成配置时被映射成 `roundrobin`
（`lib/realm.sh` 的 `generate_endpoints_from_rules`）—— 因为权重已经被翻转成 0/1 列表，
`roundrobin` 就能实现「只有那一个健康节点收流量」。

### 2.1 切换模式会重置权重

`switch_balance_mode`（`lib/rules.sh` 的 `switch_balance_mode`）在写新模式时会**重置 `WEIGHTS`**：

| 从 → 到 | `WEIGHTS` 处理 | `PREV_WEIGHTS` | `TARGET_STATES` | 源码位置 |
|---------|-----------------|-----------------|-----------------|----------|
| `active-standby` → `off` | 清空 | 保留（切回主备时恢复） | 清空 | `lib/rules.sh` 的 `switch_balance_mode` |
| `active-standby` → `roundrobin` / `iphash` | 重置为 `1,1,1,...`（按目标数） | **保留切出前的权重串**（如 `10,0`） | 清空 | `lib/rules.sh` 的 `switch_balance_mode` |
| `roundrobin` / `iphash` → `active-standby` | **恢复 `PREV_WEIGHTS`**（没有则按「第一个 10、其余 0」生成） | 保留 | 按需 | `lib/rules.sh` 的 `switch_balance_mode` |
| `active-standby` → 其它（未列出的） | 清空 | 保留 | 不变 | `lib/rules.sh` 的 `switch_balance_mode` |

> **为什么要暂存（`PREV_WEIGHTS`）**：
> 切到轮询 / IP 哈希时，`WEIGHTS` 会被换成比例分摊的默认值 `1,1,1,...`；
> 但**主备优先级**（`10,0` 这种）是用户资产，不能被一次模式切换抹掉 ——
> 抹掉之后：① 权重菜单显示的「当前权重」变成 `1,1`；
> ② 路由端读到 `1,1`（不含 0）⇒ **不再按 10/0 排主备优先级**，
> 主备退化成「原始顺序里第一个健康目标当主」。
> ⇒ 切出时把权重串存进 `PREV_WEIGHTS`，**切回主备时原样恢复**。
>
> 顺带纠正一条老注释：主备运行时 `WEIGHTS` **不会**被翻成 0/1 列表 ——
> 那份 0/1 列表是**读端内存里**算的（`lib/realm.sh` 生成 endpoint 时翻转），
> **从不写回规则文件**。所以要重置的是「用户填的优先级权重」，
> 而切回时必须把它还回去。

---

## 3. 权重（`WEIGHTS`）

菜单路径：`pf` → `2. 转发配置管理` → `6. 负载均衡管理` → `2. 权重配置管理`
（`lib/rules.sh` 的 `load_balance_management_menu`）

### 3.1 权重即分配概率

权重是**相对比例**，不是绝对值。百分比按 `weight / 总权重` 计算
（`lib/rules.sh` 的 `preview_port_group_weight_config`）：

| 权重 | 目标数 | 实际分配 |
|------|--------|----------|
| `1,1,1` | 3 | 33.3% / 33.3% / 33.3% |
| `3,1` | 2 | 75.0% / 25.0% |
| `2,1,3` | 3 | 33.3% / 16.7% / 50.0% |

最终写进 realm 的是**原始权重值**，不是百分比：

```json
"balance": "roundrobin: 3, 1"
```

（`lib/realm.sh` 的 `generate_endpoints_from_rules`：只有当 `WEIGHTS` 为空时才退化成 `1,1,1,...`。）

### 3.2 校验规则（全部在 `lib/rules.sh` 的 `validate_weight_input`）

| 约束 | 规则 | 报错文案 | 源码位置 |
|------|------|----------|----------|
| 格式 | 只允许数字和逗号，正则 `^[0-9]+(,[0-9]+)*$` | `权重格式错误，请使用数字和逗号，如: 2,1,3` | `lib/rules.sh` 的 `validate_weight_input` |
| **数量** | 权重个数 **必须等于** 目标数 | `权重数量不匹配，需要 N 个权重值，实际输入 M 个` | `lib/rules.sh` 的 `validate_weight_input` |
| 取值范围 | 每个权重 **0-10** | `权重值 X 超出范围，请使用 0-10 之间的数值` | `lib/rules.sh` 的 `validate_weight_input` |
| 全 0 | **不允许**全为 0 | `权重不能全部为 0，至少保留一个大于 0 的权重` | `lib/rules.sh` 的 `validate_weight_input` |

> **数量必须等于目标数**这条最容易踩。比如端口组有 3 个目标，你只填 `1,0` → 直接被拒。
> 目标数按端口组展开后的 `host:port` 个数算。

### 3.3 `WEIGHTS` 怎么落盘

这是实现上的一个细节，**手工改规则文件时必须知道**：

- 端口组里**第一条**规则存**完整权重列表**（如 `WEIGHTS="1,0,0"`）
- 其余规则**各存自己那一个值**（如 `WEIGHTS="0"`）

（`lib/rules.sh` 的 `apply_port_group_weight_config`：`rule_index -eq 0` 存完整串，否则存 `weight_array[target_offset]`。）

读取端口组权重时**只有一份真源**：`port_group_weights_string`
（`lib/core.sh`）—— 「带逗号的那份优先，否则取组内第一条规则的值」。
菜单三处（`load_balance_management_menu`、`switch_balance_mode`、`weight_management_menu`）
与配置预览都走它 ⇒ **界面显示的权重 ≡ 路由端真正用的权重**。
（路由端 `lib/realm.sh` 的 `generate_endpoints_from_rules` 用同一套口径。）

> **磁盘上没有权重配置时，菜单显示「未配置」**，并提示是怎么来的
> （切换模式 / 改端口 / 删目标会清空权重）。
> 老实现会拿「默认相等权重 1,1」显示 ⇒ 用户分不清「我设的就是 1」和「压根没配」，
> 还以为菜单算错了。

---

## 4. 权重 `0` 的含义

**权重 0 = 该目标不分配流量 = 备机。**

`weights_contain_zero`（`lib/rules.sh` 的 `weights_contain_zero`）检测到权重序列里含 0 时，
会发生以下事情：

### 4.1 预览阶段提示

```
检测到权重 0，将自动启用主备模式 (active-standby):
  · 权重 > 0 的目标为主，权重 = 0 的目标为备
  · 自动开启故障转移与健康检查：主故障自动切到备，主恢复后切回主
  · 健康检查探测方式: TCP 连接探测 (目标端口)，不是 ping
```

（`lib/rules.sh` 的 `preview_port_group_weight_config`）

### 4.2 应用阶段自动切主备

`apply_port_group_weight_config`（`lib/rules.sh` 的 `apply_port_group_weight_config`）在写完权重后：

1. 调用 `auto_enable_active_standby`（`lib/rules.sh` 的 `auto_enable_active_standby`），对该端口下**所有**中转规则：
   - `BALANCE_MODE="active-standby"`
   - `FAILOVER_ENABLED="true"`
   - 补齐 5 个健康检查参数（**仅在缺失时写入**，不覆盖已有值，`lib/rules.sh` 的 `_ensure_rule_field_default`）：

     | 字段 | 默认值 | 源码位置 |
     |------|--------|----------|
     | `HEALTH_CHECK_INTERVAL` | `4` | `lib/rules.sh` 的 `auto_enable_active_standby` |
     | `FAILURE_THRESHOLD` | `2` | `lib/rules.sh` 的 `auto_enable_active_standby` |
     | `SUCCESS_THRESHOLD` | `2` | `lib/rules.sh` 的 `auto_enable_active_standby` |
     | `CONNECTION_TIMEOUT` | `10` | `lib/rules.sh` 的 `auto_enable_active_standby` |
     | `RECOVERY_COOLDOWN` | `120` | `lib/rules.sh` 的 `auto_enable_active_standby` |

2. 调用 `ensure_health_check_service` 启动健康检查服务（`lib/rules.sh` 的 `apply_port_group_weight_config`）。
   **没有健康检查服务就永远不会自动切换**，此时会提示：
   `! 健康检查服务未启动，主备不会自动切换，请检查网络或手动执行 pf 故障转移菜单`
3. 重启 realm 服务使配置生效（`lib/rules.sh` 的 `apply_port_group_weight_config`）

### 4.3 权重全部 > 0 时反向切回

如果当前是 `active-standby`，而新配置的权重**全部大于 0**，会自动切回 `roundrobin`
并清空 `TARGET_STATES`（`lib/rules.sh` 的 `apply_port_group_weight_config`），但**保留 `WEIGHTS`**，
且**故障转移保持开启**（故障目标仍会被剔除）：

```
权重全部大于 0，自动切回轮询模式 (roundrobin)...
  故障转移保持开启状态（故障目标会被剔除），如需关闭请用故障转移菜单
```

> ⚠️ 此时的 `WEIGHTS` 是**用户填的比例**（如 `3,1`），不是主备翻转后的 0/1 列表。

---

## 5. `1,0,0` 主备写法

### 5.1 写法与效果

端口组有 3 个目标时，填 `1,0,0`：

| 目标 | 权重 | 角色 |
|------|------|------|
| 目标 1 | `1` | **主** |
| 目标 2 | `0` | 备 1 |
| 目标 3 | `0` | 备 2 |

等价的写法还有 `10,0,0`（主备语义只看「是不是 0」，不看主的具体数值）。

> **`10` 与 `0` 的确切语义**（用户最常问的两个值）：
>
> | 写法 | 含义 |
> |------|------|
> | `10,0` | **10 = 主（全部流量走这条）**，**0 = 备（平时这条链路不承载任何数据）** |
> | `10,0,0` | 一主两备 |
> | `5,5` | 没有 0 ⇒ **不是**主备，是按比例分流（50% / 50%） |
> | `7,3` | 按比例分流（70% / 30%） |
> | `10,5` | **会被拒绝**（`10` 是独占权重，给了它其余必须全是 0） |
> | `0,0` | **会被拒绝**（全 0 ⇒ 整个端口组没有出口） |
>
> 「主故障自动切到 0 权重的备用线路」是这样实现的：
> 读端按权重**从高到低**排优先级，再在排好的顺序里挑第一个**健康**目标当主
> ⇒ 10 权重的主判故障后，0 权重的备自动顶上并承接全部流量；
> 主恢复后按同样的优先级切回主。
> realm 配置也跟着变：主备模式下 `balance` 写的是 0/1 列表
> （当前主 = 1，其余 = 0），realm 用 `roundrobin` 就能实现「只有主收流量」。

步骤：

```
pf
# → 2. 转发配置管理
# → 6. 负载均衡管理
# → 2. 权重配置管理 → 选端口组 → 输入 1,0,0
```

确认后系统会自动完成：`BALANCE_MODE=active-standby` + `FAILOVER_ENABLED=true` +
启动健康检查服务 + 重启 realm。

也可以走显式路径：

```
pf
# → 2. 转发配置管理
# → 6. 负载均衡管理
# → 1. 切换负载均衡模式 → 4. 主备模式 (active-standby)
# → 3. 开启/关闭故障转移 → 选端口组 → 2. 主备模式
```

（`lib/rules.sh` 的 `switch_balance_mode`、`xwFailover.sh` 的 `toggle_failover_mode`）

### 5.2 主备的运行语义

严格主备，**不退化为多活**：

- 所有目标**始终保留**在 realm 的 `remote` + `extra_remotes` 列表里，
  健康检查对所有目标**独立探测**（不依赖权重）
  （`lib/realm.sh` 的 `generate_endpoints_from_rules`、`lib/realm.sh` 的 `generate_endpoints_from_rules`）
- 生成配置时权重被翻转为 **0/1 列表**：只有当前主为 1，其余为 0
  （`lib/realm.sh` 的 `generate_endpoints_from_rules`）
- 主故障 → 第一个健康的备接替（`0,1,0`）
- 主 + 备 1 都挂 → 备 2 接替（`0,0,1`）
- **主恢复 → 立刻切回主**（`1,0,0`），不等备机恢复
- 全部挂 → 强制把优先级最高的目标置 1，避免完全断流
  （`lib/realm.sh` 的 `generate_endpoints_from_rules`）

逐态推演见 [active-standby-logic.md](active-standby-logic.md)。

### 5.3 主备优先级与权重的关系

**主 = 权重最大的那个目标**（权重降序，同权重保持原始顺序）。

- 填 `10,0` → 第一个目标当主，第二个当备。
- 填 `0,10` → **第二个**目标当主，第一个当备。
- 填 `1,0,0` → 第一个当主，后两个按顺序当备 1 / 备 2。

实现（`lib/realm.sh` 的 `active-standby` 分支）：把端口组的**原始权重序列**按降序排一遍，
得到优先级顺序，再在**这个顺序**里找第一个健康目标当主；
最后按**原始目标顺序**生成 0/1 权重，保证权重与端点顺序一一对应。

```bash
# 用户权重 10,0 → 优先级 [目标1, 目标2]
# 目标1 健康 → 权重 1,0    目标1 故障 → 权重 0,1
```

- 全部目标都故障 → 强制把**优先级最高**的目标置 1，避免完全断流。
- 没有有效权重信息（权重个数与目标数不一致）→ 退化为「原始顺序里第一个健康目标」。

对 `1,0,0` 这种标准写法，权重排序与原始顺序一致，行为不受影响。

### 5.4 目标形态：每个目标可以自带端口

端口组的「目标」最终是一串 `host:port`，有两种来源：

| 来源 | 形态 | 例子 |
|------|------|------|
| `REMOTE_HOST` × `REMOTE_PORT` | 多个 host **共用一个端口** | `REMOTE_HOST=10.0.0.1,10.0.0.2` + `REMOTE_PORT=8080` |
| `TARGET_STATES` | 每个目标**自带端口** | `TARGET_STATES=10.0.0.1:28081,10.0.0.1:28082` |

`TARGET_STATES` 是**「同 host 不同端口」的备机唯一的表达方式** —— 比如主备跑在同一台机器的
`28081`（主）和 `28082`（备）两个端口上：

```
TARGET_STATES="127.0.0.1:28081,127.0.0.1:28082"
WEIGHTS="10,0"
```

判定口径只有一份（`lib/core.sh` 的 `rule_target_endpoints`）：

```
① BALANCE_MODE != off 且 TARGET_STATES 非空  →  用 TARGET_STATES
② 否则                                        →  REMOTE_HOST 的每个地址 × REMOTE_PORT
```

探测端（`lib/health.sh`）和路由端（`lib/realm.sh`）都调它 —— 两端口径不一致会导致
状态文件里的目标行匹配不上 realm 配置里的目标，**主备切换静默失效**（不报错、不出日志）。
逐态推演与更多例子见 [active-standby-logic.md](active-standby-logic.md#目标形态每个目标可以自带端口)。

---

## 6. 排查清单

| 现象 | 检查 |
|------|------|
| 权重保存后不生效 | 是否重启了 realm？`pf --restart-service` |
| 权重填了报错「数量不匹配」 | 权重个数必须等于端口组展开后的目标数 |
| 权重主备没切换 | 健康检查服务是否在跑：`systemctl status realm-health-check.timer`；探测日志 `journalctl -u realm-health-check.service -n 50` |
| 权重主备没切换，且**完全没有报错** | 探测端与路由端枚举的目标集可能对不上（老版本缺陷：探测只认 `REMOTE_HOST × REMOTE_PORT`，路由端却按 `TARGET_STATES`）。核对：日志里探测的 `host:port` 与 realm 配置里的 `extra_remotes` 是否一一对应 |
| 权重主备没切换（IP 明明通） | 探测的是 **TCP 端口**不是 ping；IP 通不代表端口通，也不代表业务正常 |
| 所有目标都被判故障 | 探测日志里看报错；`nc` 与 `timeout` 至少要有一个（见[排查手册](troubleshooting.md)） |
| 菜单里看不到端口组 | 该端口目标数必须 > 1，且必须是中转规则（`RULE_ROLE=1`） |
| 菜单显示「当前权重」和实际跑的不一样 | 菜单显示的就是磁盘真值（唯一真源 `port_group_weights_string`）。先 `grep '^WEIGHTS=' /etc/realm/rules/rule-*.conf` 对一下：<br>① 磁盘是 `1,1` ⇒ 权重被**切模式**抹过（老版本切出主备会抹成 1,1 且切回不恢复）→ 重新填一次 `10,0` 即可；<br>② 磁盘是空的 ⇒ 菜单会显示「未配置」（老版本会假装显示 1,1）→ 重新填一次 |
| 权重显示成 `1` | 老版本行为：磁盘上没有权重配置时拿「默认相等权重 1,1」显示。新版本显示「未配置」 |
| 权重主备优先级莫名失效（主备退化成「第一个健康的当主」） | 权重串里**不含 0** ⇒ 读端不按权重排优先级。检查 `WEIGHTS` 是不是被切模式重置成 `1,1` 了 |
| 菜单里时延显示 `-` | 目标还没被探测过，或系统不支持 `%N` 计时（busybox date）。用菜单项 `4. 立即测试所有目标时延` 现场测一轮 |
| 菜单里时延不刷新 | 时延优先取**快探测**（每秒一轮）；快探测没在跑时回落判定流的状态文件（默认 4 秒一轮）。查 `systemctl status realm-fast-probe.timer` 与 `journalctl -t realm-fast-probe -n 50` |
| 菜单里出现 `[丢包: N% (x/y)]` | 端口层的丢包 = **SYN 被丢弃**（超时）的采样占比；目标主动回 RST（`[探测: 拒绝]`）不算丢包。详见 [健康检查与故障转移 §3.5](health-check-and-failover.md#35-快探测流只观测每秒一轮的时延与丢包) |

---

## 7. 已知边界

| 项 | 说明 |
|----|------|
| 主备优先级 | 已实现：按权重降序选主（同权重保持原始顺序）。权重个数与目标数不一致时退化为原始顺序 |
| `TARGET_STATES` 字段用途 | 该字段在规则白名单里（`lib/health.sh` 的 `read_rule_file` 里的 `_allowed` 白名单）。**主备模式下它是有用的**：它是「每个目标自带端口」（同 host 不同端口）的唯一表达方式，探测端与路由端都优先用它枚举目标（口径 = `lib/core.sh` 的 `rule_target_endpoints`）。进主备时只在它是「剔除模式残留」（条目数少于完整目标数）时清空 |
| 全挂兜底 | 所有目标都故障时强制把优先级最高的目标置 1，保证不断流；该目标实际也是不通的，需人工介入 |
| 探测深度 | 只探 TCP 握手。端口通但业务已死、或故障在「客户端 → 中转机」这一段，探测都发现不了 |
