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
> 生成（`lib/health.sh` 内的一段 heredoc）。**真源只有这一份** ——
> `xwFailover.sh`（规则级故障转移的 CLI）与 `pf` 主脚本都 `source` 同一个文件，
> 不存在第二份实现。
>
> 例外只有一处：生成的 `/etc/realm/health/health_check.sh` 是一份**独立可执行**的脚本
> （systemd 直接调用它，不能依赖 pf 的安装目录）。
> 但它里面的探测逻辑**不是手抄的第二份**：生成时由 `lib/health.sh` 的 `health_emit_function`
> 从 `lib/health.sh` 里**原样抽取** `check_connectivity` 拼进去，
> 所以两边不可能漂移，改探测实现不需要在别处手工同步。
> 台架用例 T28 盯这一条（源实现与生成物里的探测实现必须一致）。
>
> 快探测脚本（`/etc/realm/health/fast_probe.sh`）**同样**只有这一份来源：
> 由 `lib/health.sh` 的 `fast_probe_script_body` 生成，
> 函数实现也由 `lib/health.sh` 的 `health_emit_function` 原样抽取注入。
> 它与判定端是**两条独立的流**（见 §3.5）——只观测，不参与切换。

---

## 1. 本文档讲的是哪一套「故障转移」

本文档讲的**只有一套**故障转移机制：**规则级** —— 同一个端口组内的多个出口之间。

| 机制 | 作用域 | 开关 | 驱动 |
|------|--------|------|------|
| **规则级故障转移**（剔除模式 / 权重主备模式） | 端口组内多目标之间 | `FAILOVER_ENABLED` + `BALANCE_MODE` | `realm-health-check.timer` 周期探测 → 翻转权重 / 剔除目标 → 重写 `/etc/realm/config.json` → 重启 realm |

> ⛔ **已废弃：进程级主备池**
>
> 项目曾有第二套机制 —— **进程级主备池**：一个独立守护进程（`xwpf-failover`）
> 自己持有公开监听口、自己探测目标、自己转发，另有「建池 / 列池 / 删池」与
> 崩溃循环防护（systemd 限流 / drop-in）那一整套。
> **该整块能力已随 2026-10-24 的删除下线**，守护进程、池配置、菜单入口与相关文档都不再提供。
>
> ⚠️ **别把两套「主备」混写**：本文档后面讲的「主备模式（`active-standby`）」是
> **规则级权重主备** —— 它**没有独立进程**，靠健康检查定时器探测并翻转规则里的权重。
> 判定口径：**「同一端口组内多目标之间切换」= 保留路径；「另一个进程持有监听口转发」= 已删除的主备池。**

---

## 2. 健康检查参数

### 2.1 参数表

参数**按端口组**配置，落盘在该端口组下**每一条**中转规则的 `rule-N.conf` 里。

| 参数 | 含义 | 默认值 | 合法范围 | 源码位置 |
|------|------|--------|----------|----------|
| `HEALTH_CHECK_INTERVAL` | 探测间隔（秒） | `4` | `1`-`60` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |
| `FAILURE_THRESHOLD` | 连续失败多少次判定为故障 | `2` | `1`-`10` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |
| `SUCCESS_THRESHOLD` | 连续成功多少次判定为恢复 | `2` | `1`-`10` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |
| `CONNECTION_TIMEOUT` | 单次 TCP 连接超时（秒） | `10` | `1`-`10` | 默认 `lib/rules.sh` 的 `auto_enable_active_standby`、`lib/health.sh` 的 `get_port_failover_params`；范围 `xwFailover.sh` 的 `validate_int_range` |
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
连接超时秒数 [当前 10]:
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

健康检查探测的是**目标的 TCP 端口**（`host:port`），**不是 ping**。
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

每条规则的目标集按**共用口径**枚举（`lib/core.sh` 的 `rule_target_endpoints`，唯一真源）：

```
① BALANCE_MODE != off 且 TARGET_STATES 非空  →  用 TARGET_STATES（每项自带 host:port）
② 否则                                        →  REMOTE_HOST 的每个地址 × REMOTE_PORT
```

每个目标按**它自己的端口**探测（`lib/health.sh` 的 `health_check_script_body`）。

> ★ **为什么口径必须与路由端同源**：路由端（`lib/realm.sh` 的 `generate_endpoints_from_rules`）
> 生成 realm 配置时用的是同一份 `rule_target_endpoints`。两边枚举出的目标集若不一致，
> 状态文件里的目标行就**匹配不上**配置里的目标 ⇒ **主备切换静默失效**
> （不报错、不出日志，界面也看不出来）。

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

> ⚠️ **这 5 个样本是「显示口径」，不要改**：菜单的 `[时延: Xms (均 Yms)]` 用它算均值，
> 台架也锁死了「跑 3 轮累积 3 个样本、跑 7 轮封顶 5 个」。
> **质量观测另开自己的窗口**（见 §3.3.1），两者互不影响。

> 时延是 **TCP 握手耗时**，包含建连开销，不等于纯网络 RTT；
> 跨境链路上通常比 ping 大一个量级（TCP 三次握手 + 内核调度）。

### 3.3.1 质量观测窗口（**只观测，不动作**）

除了上面那个「显示口径」，另有一个**质量观测窗口**，用来长期看一个目标的
稳定程度 —— 窗口默认 **20** 次采样。

窗口大小写在**规则文件**里，**两个写法都生效**：

| 写法 | 角色 | 说明 |
|---|---|---|
| `PROBE_QUALITY_WINDOW="12"` | **规范名（推荐）** | 与 `CONNECTION_TIMEOUT` / `RECOVERY_COOLDOWN` 同一套命名；规则解析器的白名单认它 |
| `probe.quality_window="12"` | 兼容别名 | 点号小写写法**规则解析器认不得**（键名规则只允许大写字母与下划线）⇒ 产品按文本单独兜底读一次；**两个都写时规范名优先** |

⇒ 值不是正整数（如 `abc`、`0`）一律**回退默认 20**，不报错、不中断探测端。
⇒ 生效值会随每行一起记进指标文件（末列 `WINDOW`）⇒ 「配的值有没有真被读到」
可以直接从文件里看出来，不用反推采样条数。

> **台架盯着这件事**：质量观测那一组台架用例里有一条专门盯「值真被读到了」——
> 规则里写 `12` ⇒ 生效 `12`（≠ 默认值）／没配 ⇒ 默认值／兼容别名 ⇒ `12`／
> 非法值 ⇒ 回退；外加一条**注入式负向对照**（把窗口函数换成恒返回默认值的坏实现，
> 同一条断言必须判红）⇒ 「可配」不会悄悄退化成「看起来可配」。

**它记四样东西**（都落在一个**独立文件**里）：

| 量 | 口径 |
|---|---|
| 采样总数 | 窗口内采样次数（**成功与失败各算一次**） |
| 失败次数 | 窗口内探测不通的次数（**不区分 timeout / refused**） |
| 成功样本时延均值 | 窗口内**成功**样本的时延平均（毫秒） |
| 失败样本时延分布 | 窗口内**失败**样本的时延（个数 / 均值 / 最大值，毫秒） |

⇒ **失败率 = 失败次数 / 采样总数**（**比例**；分母随窗口一起滚，不写死）
⇒ 成功时延只用**成功样本**、失败时延只用**失败样本**（两个序列分开存，互不串）
⇒ 失败样本的耗时同样有观测价值（「一直超时」和「秒拒」是两种完全不同的故障形态）

**两套窗口并存，不要合并**：

- `latency_hist`（上限 5）= **显示口径**，给菜单看的平均值分母；
- 质量窗口（默认 20）= **观测口径**，给「这个目标最近稳不稳」看的。

**落盘在独立文件** `/var/lib/realm/quality_metrics.conf`
（**不动** `health_status.conf` —— 后者的形态被台架锁着：每轮原子重建、
只留当前规则的行）。格式：

```
TARGET|RULE_ID|SAMPLE_SEQ|LAT_SEQ|WINDOW|FAIL_LAT_SEQ
```

`SAMPLE_SEQ` 是窗口内最近 N 次采样的**成败位**（`0`=成功 / `1`=失败，逗号分隔）；
`LAT_SEQ` 是各**成功**样本的时延（毫秒，与 `SAMPLE_SEQ` 里的 `0` 一一对应）；
`FAIL_LAT_SEQ` 是各**失败**样本的时延（毫秒，与 `SAMPLE_SEQ` 里的 `1` 一一对应，
追加在**最后一列** ⇒ 前 5 列位置不变，老文件与老读取方式都不受影响）。
存序列而不是存「总数 + 总和」，是为了窗口滚动时能**精确**移除最旧那次样本
（丢最旧的失败样本时，它的时延会跟 `FAIL_LAT_SEQ` 一起被丢，不会错位）。
`WINDOW` 是**这一行生效的窗口大小**（= 规则里配的值；没配 = 默认 20）——
它让「配的值有没有真被读到」可被外部直接核对。

> **窗口是「本轮被采样到的目标」的窗口**：某个目标这一轮没被采到，它的整段窗口
> 会从文件里消失（不留残留行），下次再出现时从零开始。
> 这是「不留陈旧残留」与「跨轮延续」之间的取舍 —— 阶段 1 只观测不动作，
> 保留后者要额外存「上次见到的时间」，收益不抵复杂度。
> 需要跨轮延续时再改。

**⚠️ 硬红线：这些数字不参与任何判定。**

- **不**参与切换 / 权重决策；
- **不**影响探测端对目标的 `status` 判定；
- **不**写进任何影响 realm 配置生成的字段。

菜单里的展示形如：

```
1. 203.0.113.10:8080 [权重: 10] (100.0%) [健康] [时延: 12ms (均 12ms)] [窗口: 失败率 0% (0/20) · 成功时延均值 12ms · 失败时延 -]
```

没有失败样本时，失败时延显示 `-`（不是 `0ms` —— `0ms` 会被读成「失败得很快」）。
老机器上没有这个文件、或还没采样够 ⇒ 显示 `[窗口: -]`（**向后兼容**，缺字段不报错）。

> 「30ms · 10%」这类参考值**仅供人看**，**不作为判据**。

> **时延的单位契约**：探测端的时间源（`lib/health.sh` 的 `now_us`）返回**微秒**，
> 两条取数分支（`EPOCHREALTIME` 与 `date +%s%N`）**必须产出同一个单位** ——
> `date +%s%N` 给的是**纳秒**，换算在 `now_us` 内部完成。
> 换算漏掉时，老 bash 机器（bash 4 + GNU coreutils，如 CentOS 7）上
> 所有时延会被**放大 1000 倍**（显示口径与质量窗口一起错）。

### 3.4 在负载均衡菜单里看时延

`负载均衡管理`（按端口组管理）里，每个目标行会多显示一段时延：

```
1. 203.0.113.10:8080 [权重: 10] (100.0%) [健康] [时延: 12ms (均 12ms)]
2. 203.0.113.11:8080 [权重: 0]  (0.0%)   [健康] [时延: 88ms (均 85ms)]
```

- **时延来源有两级**：优先取**快探测**（§3.5，每秒一轮）；没有快探测数据时
  回落到**判定流**写进状态文件的那份。两者都是 **TCP 握手耗时**，同一个口径 ——
  不会混成两个数字。
- `均` 是最近 5 次样本的平均值（见 §3.3）
- 目标还没被探测过时显示 `-`
- 故障目标显示时延没有意义，直接看 `[故障]` 标记
- 额外两段（都来自快探测，**只观测**）：
  - `[丢包: 5% (1/20)]` —— 窗口内 **SYN 被丢弃**（超时）的采样占比；
    丢包为 0 时**不显示**（不占菜单一行）。「连接被拒」是目标主动拒绝，
    **不算丢包**（那类失败看 `[探测: 拒绝]`）。
  - `[探测: 超时]` / `[探测: 拒绝]` / `[探测: 不可达]` —— 最新一次快探测的失败分型；
    探测成功时不显示。

> ⚠️ `[健康]` / `[故障]` **只取判定流**（状态文件）—— 那是切换判据的数据源。
> 快探测**不参与**判定：它每秒刷新的是「显示」，不是「该不该切」。

菜单里还有一个 **`4. 立即测试所有目标时延`**：现场把所有端口组的目标探一轮，
逐行打印可达性与耗时。这是一次**现场探测**，只显示结果、**不写状态文件**
（避免和后台健康检查抢写同一个文件），页面上的时延仍以后台为准。

实现：`lib/rules.sh` 的 `load_balance_management_menu` 与 `probe_all_targets_latency`。

#### 4.1 探测参数在菜单里可配（`5. 探测参数设置`）

菜单项 4 的两个探测口径参数**可以在菜单里改**（`lib/rules.sh` 的 `menu_probe_settings_menu`）：

| 参数 | 含义 | 取值范围 | 默认 |
|------|------|----------|------|
| 单次探测超时 | 每个目标**每次**探测的预算（秒） | 1-60 | 2 |
| 每目标采样次数 | 每个目标连采几次（报「成功次数/采样次数」） | 1-50 | 3 |

改完**落盘**到 `${CONFIG_DIR}/menu_probe.conf`（默认 `/etc/realm/menu_probe.conf`）：

```bash
# 菜单探测参数（菜单项 5 写入；可直接手改，改完立即生效）
PROBE_TIMEOUT=2
PROBE_SAMPLES=3
```

生效口径（`lib/core.sh` 的 `menu_probe_timeout` / `menu_probe_samples`）：

```
环境变量 MENU_PROBE_TIMEOUT / MENU_PROBE_SAMPLES   ← 最高（临时覆盖 / 台架注入）
  ↓ 没设
配置文件 ${MENU_PROBE_CONF}                        ← 菜单项 5 写入，持久生效
  ↓ 没有
内置默认（2s / 3 次）
```

> ⚠️ 改这两个参数只影响**菜单项 4 的现场探测**，不影响后台健康检查的判定节奏
> （那个由规则里的 `HEALTH_CHECK_INTERVAL` / `CONNECTION_TIMEOUT` 决定）。

### 4.2 菜单显示的优先级顺序

菜单里的目标序号在**主备模式**下按主备优先级排（`1.` = 权重最大的那个目标），
与路由端挑主的顺序**同一份实现**（`lib/core.sh` 的 `port_group_priority_order`）——
详见 [port-groups-and-weights.md §5.3.1](port-groups-and-weights.md#531-菜单里的目标序号也按这个优先级排)。

---

## 3.5 快探测流（**只观测**：每秒一轮的时延与丢包）

### 3.5.1 为什么要两条流

判定流（§3.1~§3.3）按规则里的 `HEALTH_CHECK_INTERVAL` 刷新（默认 4 秒），
而且**它的节奏与切换判据绑在一起**：状态文件既是「显示时延」的来源，
也是「该不该切」的依据。所以**不能**为了刷新显示去改它的节奏 ——
那等于改了切换时机。

⇒ 结论：**两条流，各干各的**。

| | 判定流（health_check.sh） | 快探测流（fast_probe.sh） |
|---|---|---|
| 节奏 | 规则里的 `HEALTH_CHECK_INTERVAL`（默认 4 秒） | **固定 1 秒** |
| 写什么 | 判定流的状态文件 | **自己的**观测文件 |
| 参与切换 | **是**（这就是切换判据） | **否** |
| 触发配置重生成 | 会（状态变化时） | **不会** |
| 用途 | 判定目标健康与否 → 翻转权重 | 刷新菜单里的时延 / 丢包显示 |

### 3.5.2 硬红线：快探测**不参与切换**

- 它**不写**判定流的状态文件；
- 它**不触发**配置重生成；
- 这两条由**反向护栏**兜底：`lib/health.sh` 的 `fast_probe_guard_check` 扫描生成物，
  一旦出现「写状态文件」或「触发配置重生成」的字样 ⇒ **拒绝安装**
  （失败时原来能跑的那份原封不动留着）。
- 切换时机仍然只看规则里的 `HEALTH_CHECK_INTERVAL` / `FAILURE_THRESHOLD`
  ——**1 秒探测只用于检测和显示**。

### 3.5.3 生成物与观测文件

- 生成物：`/etc/realm/health/fast_probe.sh`
  （由 `lib/health.sh` 的 `fast_probe_script_body` 生成；
  函数实现仍由 `lib/health.sh` 的 `health_emit_function` 从真源**机械抽取**注入，
  不存在手工维护的第二份）
- 落盘与自检：`lib/health.sh` 的 `fast_probe_script_regenerate`
  （自检 + 反向护栏都在覆盖旧文件**之前** ⇒ 失败时保留原来能跑的那份）
- 观测文件：`/var/lib/realm/fast_probe.conf`（**独立文件**，不碰判定流的状态文件）

格式（每行一条记录）：

```
TARGET|RULE_ID|RESULT|LAT_MS|TS|RESULT_SEQ|LAT_HIST
```

| 列 | 含义 |
|----|------|
| `TARGET` | 目标地址（host:port，与判定流同口径） |
| `RULE_ID` | 归属规则（组合键的一部分，避免同后端被两条规则共用时串数据） |
| `RESULT` | 最新一次的结果：`ok` / `timeout` / `refused` / `unreachable` / `unknown` |
| `LAT_MS` | 最新一次握手耗时（毫秒） |
| `TS` | 最新一次的时间戳（epoch 秒） |
| `RESULT_SEQ` | 最近 N 次的结果序列（`o`=通 `t`=超时 `r`=拒绝 `u`=不可达 `x`=未知），N = 窗口（默认 20，约 20 秒） |
| `LAT_HIST` | 最近 5 次**成功**样本的握手时延（毫秒，逗号分隔） |

### 3.5.4 失败分型（超时 vs 拒绝）

端口层能分出的失败只有两种，**含义完全不同**：

| 形态 | 判定依据 | 含义 | 算丢包吗 |
|------|----------|------|----------|
| `timeout` | `timeout` 杀掉了内层进程（退出码 **124**） | **SYN 被丢弃** —— 黑洞 / 路径丢包 / 防火墙静默丢包 | **算** |
| `refused` | stderr 里的 `Connection refused` | 目标主动回 RST（服务没起） | 不算 |
| `unreachable` | `Network is unreachable` / `No route to host` | 路由不通 | 不算 |
| `unknown` | 认不出来（含本机 bash 不支持 `/dev/tcp`） | **不猜** | 不算 |

分型规则抽成**纯函数** `lib/health.sh` 的 `fast_probe_classify`（退出码 + stderr 文本 → 类型），
探测本体是 `lib/health.sh` 的 `fast_probe_connect`。
⇒ 台架直接喂退出码与文本测**规则本身**（真机上同一个症状在不同宿主上形态不同，
把断言绑在宿主上必然假红）。

### 3.5.5 单次探测预算

快探测的单次预算是 **2 秒**，**独立**于判定流的 `CONNECTION_TIMEOUT`（默认 10 秒）：

- 判定流要的是「判得准」：真机实测正常目标握手最慢 2274ms ⇒ 预算必须给足；
- 快探测要的是「每秒刷新一次」：预算太长 ⇒ 一个黑洞目标就能把 1 秒的节奏拖成
  `1/预算秒`。

### 3.5.6 资源开销（实测）

单条主备链路（2 个目标）、2 核 / 957MB 的机器上实测：

| 项 | 判定流（4 秒一轮 × 2 目标） | 快探测（1 秒一轮 × 2 目标） |
|----|---------------------------|---------------------------|
| 单次探测耗时 | 2.75ms（`/dev/tcp`） | 2.75ms |
| CPU（占单核） | ≈0.135% | **≈3.25%**（实测 120 轮：单轮子进程 CPU 32.5ms） |
| 网络 | 约 1.25 pps | 约 10 pps |
| 后端新建连接 | 每 4 秒 2 条 | 每秒 2 条 |
| 落盘 | 状态文件 1 份 + 质量窗口 1 份 | 观测文件 1 份（原子重写） |

> **快探测的 CPU 大头是 fork，不是网络。**
> 每轮每个目标原本要 fork 十几次（取段、切字段、找上一轮观测行、
> 命令替换取时间戳/分型/结果序列/时延历史、每目标一次 `date`……）
> ⇒ 优化前实测 **单轮 61ms / 占单核 6.1%**。
> 现在的做法是把热路径上**大部分的 fork 换成 bash 内建**：
> 取段用参数展开；找上一轮观测行用 bash 读循环；时间戳走 `now_us` 的全局出口；
> 分型、结果序列、时延历史各自走全局出口；错误文本用 bash 的 `$(<file)` 读回
> （不 fork 的读法）；`mkdir` 只在目录不存在时才执行；`date` 每轮只取一次。
> 优化后实测 **单轮 32.5ms / 占单核 3.25%**（降约 47%）。
>
> ★ 这些优化**只作用在观测流自己身上**：探测目标、探测频率、失败分型口径、
>   显示口径、切换时机全都**没变**。快探测依旧只观测、不参与切换。
>
> 关键实现位置（供改代码时对照）：
> - `lib/health.sh` 的 `now_us` —— 除打印外另设全局出口 `NOW_US_VALUE`
>   （热路径用它替代 `$(now_us)`，省掉命令替换的 fork）
> - `lib/health.sh` 的 `fast_probe_connect` —— 探测本体（打点、错误文本、分型）
> - `lib/health.sh` 的 `fast_probe_classify` / `fast_probe_seq_push` /
>   `fast_probe_hist_push` —— 纯函数，除打印外各设一个全局出口
> - `lib/health.sh` 的 `fast_probe_script_body` —— 生成物里那段 bash 读循环
>   （取上一轮观测行，替代 `awk`）


---

## 4. systemd unit

### 4.1 `realm-health-check.service`

由 `start_health_check_service` 生成（`lib/health.sh` 的 `start_health_check_service`）：

```ini
[Unit]
Description=Realm Health Check Service
After=network.target
StartLimitIntervalSec=0

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

> `StartLimitIntervalSec=0` 是**关掉 systemd 的启动限流**（默认「10 秒内最多启动 5 次」）。
> 默认间隔 4 秒时用不到它，但把 `HEALTH_CHECK_INTERVAL` 配到 ≤ 2 秒就会撞上限流
> ⇒ 探测被判 `start-limit-hit`（每次都报错）⇒ 实际探测频率掉到限流允许的量级。
> 真机实测（systemd 257）：1 秒一轮时，不加这行 20 秒只跑 10 次。

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

### 4.6 `realm-fast-probe.service` / `.timer`（快探测，只观测）

由 `lib/health.sh` 的 `start_fast_probe_service` 生成（与判定端的 unit **完全独立**）：

```ini
# /etc/systemd/system/realm-fast-probe.service
[Unit]
Description=Realm Fast Probe Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/etc/realm/health/fast_probe.sh
User=root
WorkingDirectory=/etc/realm
StandardOutput=journal
StandardError=journal
SyslogIdentifier=realm-fast-probe

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/realm-fast-probe.timer
[Unit]
Description=Realm Fast Probe Timer
Requires=realm-fast-probe.service

[Timer]
OnBootSec=15s
OnCalendar=*-*-* *:*:0/1
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
```

> ⚠️ **两个坑（都是真机实测踩出来的，不是照抄文档）**：
>
> ① **`StartLimitIntervalSec=0` 必须加**：systemd 默认的**启动限流**是
> 「10 秒内最多启动 5 次」。1 秒一轮的 oneshot 必然撞上限流 ⇒ 服务被判
> `start-limit-hit`（每次都报错）⇒ 探测实际只剩 **0.5 次/秒**。
> 真机实测（systemd 257）：不加这行，20 秒只跑了 10 次。
>
> ② **「1 秒一轮」只能用日历表达式**（`OnCalendar=*-*-* *:*:0/1`），
> **不能**用 `OnUnitActiveSec=1sec`：
> 真机实测（systemd 257 / Debian 13，各复现两轮）——
> `OnUnitActiveSec=1sec + AccuracySec=1s` 的实际间隔是 **约 2 秒**（还有一轮直接 0 次），
> 而 `OnCalendar=*-*-* *:*:0/1 + AccuracySec=1s` 是 **约 1.00 秒**（三轮都稳）。
> 秒位重复 `0/1` 的语义 = 该值及其所有倍数（0,1,2…59）⇒ 每秒。
>
> 另外 **`AccuracySec=1s` 也是必须的**：systemd 默认 `AccuracySec` 是 **1 分钟**，
> 定时器会被对齐到分钟边界 ⇒ 不显式压到 1 秒，节奏根本不是 1 秒。

> 并发保护同判定流：脚本自己 `flock -n`（`/var/lock/realm-fast-probe.lock`），
> 上一轮没跑完就跳过本轮（不排队、不堆积）；systemd 的 `Type=oneshot` 也不会并发拉起。

启停：`lib/health.sh` 的 `start_fast_probe_service` / `stop_fast_probe_service`。
判定端启停时会一并带上快探测（`lib/health.sh` 的 `start_health_check_service` /
`stop_health_check_service`）；**快探测起不来不会让主备开关回滚** ——
它只是显示增强，切换判据在判定流那边。

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

**一行状态只会被一条规则认领**（同一后端被两条规则共用时的关键）：

| 认领顺序 | 说明 |
|----------|------|
| ① `RULE_ID` 与行首旧 `RULE_ID` 一致的候选 | 保住「这行本来是谁的」 |
| ② 还没认领过这个目标的候选 | 规则文件顺序 = `RULE_ID` 升序 |
| ③ 都没有 | 这个目标已经没有规则了 ⇒ 整行丢弃（陈旧行） |

⇒ 状态文件里**不会出现两行相同的 `(RULE_ID, TARGET)`**；
⇒ 也不会出现「一条行被两条规则抢认、另一条规则的状态丢失」——
**状态丢失 = 归零 = 该切不切**（探测端不再把它算成 failed）。

> **★ 候选只认「被健康检查监控」的规则**（`RULE_ROLE=1` + `ENABLED=true` + `FAILOVER_ENABLED=true`，
> 与写端逐字对齐）：状态文件里**只有这几类规则的行** ⇒ 没被监控的规则本来就没有行，
> **不该认领任何行**。
> 不设这道门槛的后果（审稿实测复现）：规则重编号后，一条**没开故障转移**的规则会按
> 「目标地址相同」抢走被监控规则的行 ⇒ 被监控规则的失败状态丢失（归零）= **该切不切**。

> 认领判定按 `(RULE_ID, 目标)` **字段级**比较，不用子串匹配 ——
> `"1|X|"` 是 `"11|X|"` 的子串，用子串匹配会把另一条规则误判成「已认领」，
> 结果反而是丢行。

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

加时延功能之前的状态行还**只有 8 列**（现在是 9 列），即没有 `LATENCY_MS` /
`LATENCY_HISTORY` 两列 —— 这与 `TARGET` 口径**无关**：读取端按**缺字段兼容**处理，
缺这两列就当没有时延数据，不影响状态判定与失败/恢复计数。

早期版本的 `TARGET` 字段还只有 `host`（没有端口），所以**同一 host 上跑不同端口的目标会互相覆盖**
（同一主备组里两个目标都指向同一台机器的不同端口时，最典型）。
现在的 `TARGET` 是 `host:port`，两种格式都能认：

- 探测端（`lib/health.sh` 的 `health_check_script_body`）：先按 `RULE_ID|host:port` 找自己的记录，
  找不到再按旧口径 `RULE_ID|host` 找；找到就**沿用旧记录的状态与计数**，
  写回时写成新格式并顺手删掉同一 host 的旧行 —— 老文件里的 `failed` 不会因为升级被当成「健康」。
- 消费端（`lib/realm.sh` 的 `generate_endpoints_from_rules`）：**按 (RULE_ID, 目标地址) 组合键查**——
  与写端（`target_key="${RULE_ID}|${target_endpoint}"`）同口径。
  旧格式的行按该行 `RULE_ID` 对应规则的 `REMOTE_PORT` 补出端口，入**精确键** `RULE_ID|host:port`。
  **认得出归属时只入精确键，不另外存一份裸 host 的宽键** —— 宽键会把「一个端口的故障」
  传播给同 host 的其他端口：同一主备组里两个目标都是同 host 不同端口时，两个目标会同时被判 failed
  → 走「全部目标都挂了」的兜底 → 保持原主不切备（该切不切的静默失效）。
  **认不出归属**（规则已删、行号式的老记录）时**当无记录**：让健康检查下一轮重新探测、生成精确键。
  ★ **为什么键里必须带 RULE_ID**：同一个后端被**两条规则**共用时，状态文件里本来就有**两行**
  （各带自己的 RULE_ID），只按目标地址建键 ⇒ 后读的行覆盖先读的 ⇒ 两条规则读到**同一个**状态 ⇒
  **双向误切**：真挂了的那条被判成健康（该切不切）、健康的那条被判成故障（不该切却切）。
  归属规则 = 该目标在**本端口组**里归属的那条规则（先声明者为准；端口组的目标列表是跨规则合并的）。
- 展示端（`lib/health.sh` 的 `get_health_status_record`）：按 `TARGET` 字段精确匹配；
  查不到就是查不到，**不**按裸 host 兜底（否则会把同 host 另一个端口的记录显示成这条目标的）。
  ⚠️ 展示端**只拿到目标地址**（调用处没有规则上下文）⇒ 同一后端被两条规则共用时，显示的是
  **文件里第一行**那条的状态 ⇒ 可能显示成另一条规则的状态（**显示口径**，不参与切换判定）。

### 6.5 跨轮继承：状态行怎么找到「自己上一轮的那一行」

探测端每一轮都要回答同一个问题：**这个目标上一轮的状态行在哪？**
找到 ⇒ 沿用它的 `fail_count` / `success_count` / `status`（这才是「连续失败」的计数基础）；
找不到 ⇒ 当作没有记录，从零重新计数。

查找由 `lib/health.sh` 的 `health_status_find_row` 完成，**匹配键 = `(RULE_ID, TARGET)`**，
两个字段都要对上：

| 行格式 | 命中条件 |
|--------|----------|
| 新格式（`TARGET` = `host:port`） | `RULE_ID` 相等 **且** `TARGET` 相等 |
| 旧格式（`TARGET` 只有 `host`） | `RULE_ID` 相等 **且** `TARGET` 等于裸 host（本轮没命中精确键时才用） |

**★ 为什么键里必须同时带 `RULE_ID` 和目标地址**（`lib/health.sh` 的 `health_status_find_row`）：

1. **只按 `RULE_ID` 匹配**：规则 ID 会被复用（删掉一条规则后，下一条规则可能拿到同一个 ID）
   ⇒ 老规则的 `failed` / 失败计数算到新规则头上 ⇒ 新鲜健康的目标一上来就显示「故障」。
2. **只按目标地址匹配**：两条规则共用同一个后端时（同 host 同 port），一条规则的失败状态
   会**过户**给另一条规则 ⇒ 误继承 ⇒ 误切。
3. 组合键同时挡住两个方向：`RULE_ID` 或目标地址**任一**不同 ⇒ 认不出旧行 ⇒ 当成「没有记录」
   ⇒ 从零重新计数。**认不出时的方向是安全方向**（重新计数 = 最多晚几轮才切换），
   不是危险方向（误继承 = 刚建好的目标被判 failed = 误切）。

> 写回时用同一把钥匙：`target_key="${RULE_ID}|${target_endpoint}"`
> （`lib/health.sh` 的 `health_check_script_body`），并顺手删掉同一 host 的旧格式行 ——
> 老文件里的 `failed` 不会因为升级被当成「健康」。
> 这套口径与**消费端**（`lib/realm.sh` 的 `generate_endpoints_from_rules`）同源：
> 切换判定读的必须是同一把钥匙 —— 不能一个按 `RULE_ID` 找、另一个按目标地址找。

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
| 探测对象不可自定义 | 探测目标固定为规则里的目标集（`TARGET_STATES`，或 `REMOTE_HOST × REMOTE_PORT`），不支持换成**独立的**健康端口（探测端口 = 业务端口） |
| 探测端与路由端口径必须同源 | 目标枚举口径只有一份真源（`lib/core.sh` 的 `rule_target_endpoints`），探测端与路由端都调它。老版本两边各写一份，探测只认 `REMOTE_HOST × REMOTE_PORT` 而路由端认 `TARGET_STATES` ⇒ 目标集对不上 ⇒ **主备切换静默失效**（不报错、不出日志） |
| `realm-health-check.service` 是否需要 `After=network-online.target` | 当前只写了 `After=network.target`。开机后立刻探测可能在网络就绪前失败（表现为开机瞬间误判故障）。是否调整待确认 |
| 快探测是**独立的一条流** | 每秒一轮，**只观测**：写自己的观测文件（`/var/lib/realm/fast_probe.conf`），不写判定流的状态文件、不触发配置重生成（由 `lib/health.sh` 的 `fast_probe_guard_check` 反向护栏兜底）。**切换时机不变**，仍按规则里的 `HEALTH_CHECK_INTERVAL` / `FAILURE_THRESHOLD` |
| 端口层的「丢包」只有一种 | TCP 探测只能看到「SYN 被丢弃」（超时）。ICMP 丢包属路径层，`TcpRetransSegs` 是系统累计值、不能按目标拆 ⇒ 菜单里的丢包口径 = **超时采样占比**；目标主动 RST 拒绝（`[探测: 拒绝]`）**不算**丢包 |
| 快探测的节奏由 systemd 决定 | 实测（systemd 257 / Debian 13）：`OnCalendar=*-*-* *:*:0/1` + `AccuracySec=1s` ⇒ 间隔约 1.00 秒；写成 `OnUnitActiveSec=1sec` ⇒ 实际约 2 秒（还有一轮直接不触发）。**并且**必须写 `StartLimitIntervalSec=0`，否则被 systemd 的启动限流（10 秒 5 次）掐成 0.5 次/秒 |
| 快探测的 IPv6 支持 | 目标地址允许 IPv6 字面量（`::1`），但探测走 `bash /dev/tcp` ⇒ 取决于 bash 编译时是否支持；不支持时结果标 `unknown`（**不猜**），判定流不受影响 |
| `journalctl --vacuum-time=7d` 的影响范围 | 该命令清理的是**全系统** journal（不限本服务），在有其它业务日志的机器上影响面较大。是否收窄待确认 |
