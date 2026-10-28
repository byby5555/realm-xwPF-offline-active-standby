# Active-Standby（主备模式）状态转换推演

本文档记录 `BALANCE_MODE=active-standby`（主备模式）下，单端口多目标规则
的健康状态变化如何映射到 realm 配置输出。3 目标示例：

- `REMOTE_HOST=10.0.0.1,10.0.0.2,10.0.0.3`
- `REMOTE_PORT=8080`
- `WEIGHTS=1,1,1`（用户最初配置；运行时被主备逻辑覆写为 0/1 列表。
  本例权重不含 0，不触发按权重排序，主备优先级即原始顺序）
- `FAILOVER_ENABLED=true`
- 顺序：10.0.0.1 为主，10.0.0.2 为备1，10.0.0.3 为备2

> **术语口径**：本文的「主备」= **规则级权重主备** —— 同一个端口组内的多个目标之间，
> 靠健康检查翻转权重来切换（主故障切备、主恢复切回），**没有独立进程**。
> 它**不是**已下线的「进程级主备池」（另一个进程自己持有监听口转发的那一套）——
> 后者已随 2026-10-24 的删除整块下线。

## 核心规则

- 所有目标始终保留在 `extra_remotes` 列表里（健康检查独立探测，不依赖权重）。
- `port_weights` 由「优先级最高的 healthy 节点 = 1，其他 = 0」动态决定。
  优先级规则：权重序列含 0 时按权重从高到低排（同权重保持原始顺序）；
  权重不含 0、或权重个数与目标数不一致时，退化为「原始顺序里第一个 healthy 节点」。
- 生成 realm 配置时 `active-standby` 映射为 `roundrobin` 输出。
- 主恢复后立即切回主（严格主备，不退化为多活）。

## 目标形态：每个目标可以自带端口

端口组的「目标」最终是一串 `host:port`。它有两种来源，能表达的形态不同：

| 来源 | 形态 | 例子 | 能表达什么 |
|------|------|------|-----------|
| `REMOTE_HOST` × `REMOTE_PORT` | 多个 host **共用一个端口** | `REMOTE_HOST=10.0.0.1,10.0.0.2` + `REMOTE_PORT=8080` | `10.0.0.1:8080`、`10.0.0.2:8080` |
| `TARGET_STATES` | 每个目标**自带端口** | `TARGET_STATES=10.0.0.1:28081,10.0.0.1:28082` | **同 host 不同端口**（主备跑在同一台机器的两个端口上） |

口径只有一份，住在 `lib/core.sh` 的 `rule_target_endpoints`（唯一真源）：

```
① BALANCE_MODE != off 且 TARGET_STATES 非空  →  用 TARGET_STATES（每项自带 host:port）
② 否则                                        →  REMOTE_HOST 的每个地址 × REMOTE_PORT
```

> ★ **为什么必须同源**：同一组目标要被**两个地方**枚举 ——
> 探测端（`lib/health.sh` 的探测脚本）把结果写进状态文件（行键 = `RULE_ID|host:port`），
> 路由端（`lib/realm.sh` 生成 endpoints）按状态文件决定谁当主、谁当备。
> 两端口径一旦不一致 ⇒ 状态行**匹配不上**配置里的目标 ⇒
> **主备切换静默失效**（不报错、不出日志，界面也看不出来）。
> 所以两边都调 `rule_target_endpoints`，不再各写一份。

### 「同 host 不同端口」的备机怎么配

主备跑在同一台机器的两个端口上时，用 `TARGET_STATES` 表达：

```
TARGET_STATES="127.0.0.1:28081,127.0.0.1:28082"
WEIGHTS="10,0"
BALANCE_MODE="active-standby"
FAILOVER_ENABLED="true"
```

- 主 = `127.0.0.1:28081`，备 = `127.0.0.1:28082`
- 探测端按**各自端口**分开探（`28081` 和 `28082` 是两个独立状态，互不覆盖）
- 路由端也按各自端口生成 `remote` / `extra_remotes`

### 进主备时 `TARGET_STATES` 怎么处理

进主备时**不能无脑清空** `TARGET_STATES` —— 它是「每个目标自带端口」的**唯一**表达方式，
清掉就把用户的意图抹了（而且抹完探测端与路由端口径也对不上）。
判定在 `lib/rules.sh` 的 `auto_enable_active_standby`：

| `TARGET_STATES` 条目数 | 判定 | 处理 |
|------------------------|------|------|
| < 完整目标数（`REMOTE_HOST` 地址数） | 剔除模式的残留（被剔掉的目标没补回来） | **清空** → 主备回到完整目标集 |
| ≥ 完整目标数 | 用户显式写的目标列表 | **保留** |
| 字段不存在 | 没配过 | 补一个空值（走口径 ②） |

## 状态转换表

| 场景 | 10.0.0.1 (主) | 10.0.0.2 (备1) | 10.0.0.3 (备2) | 翻转后 WEIGHTS | realm config |
|------|-----|-----|-----|-----|-----|
| 1. 平时 | healthy | healthy | healthy | `1,0,0` | `balance: roundrobin: 1, 0, 0` |
| 2. 主挂 | failed | healthy | healthy | `0,1,0` | `balance: roundrobin: 0, 1, 0` |
| 3. 主+备1挂 | failed | failed | healthy | `0,0,1` | `balance: roundrobin: 0, 0, 1` |
| 4. 主恢复（紧接场景3后） | healthy | failed | healthy | `1,0,0` | `balance: roundrobin: 1, 0, 0` |
| 5. 备1单挂 | healthy | failed | healthy | `1,0,0` | `balance: roundrobin: 1, 0, 0` |
| 6. 全挂 | failed | failed | failed | `1,0,0` | `balance: roundrobin: 1, 0, 0`（强制保留首节点避免完全断流） |
| 7. 主+备1挂→主恢复 | healthy | failed | failed | `1,0,0` | `balance: roundrobin: 1, 0, 0`（备1仍挂但主恢复即切回） |

## 详细每态推演

### 状态 1：平时（全 healthy）
- `health_status`：`10.0.0.1=healthy, 10.0.0.2=healthy, 10.0.0.3=healthy`
- `port_groups`（不变）：`10.0.0.1:8080,10.0.0.2:8080,10.0.0.3:8080`
- `primary_target = 10.0.0.1:8080`
- 翻转后 `port_weights = 1,0,0`
- 生成 realm JSON：
  ```json
  {
      "listen": "0.0.0.0:8080",
      "remote": "10.0.0.1:8080",
      "extra_remotes": ["10.0.0.2:8080", "10.0.0.3:8080"],
      "balance": "roundrobin: 1, 0, 0"
  }
  ```
- 流量：100% → 10.0.0.1（主）

### 状态 2：主挂（备1 healthy）
- `health_status`：`10.0.0.1=failed, 10.0.0.2=healthy, 10.0.0.3=healthy`
- `port_groups`（不变）：`10.0.0.1:8080,10.0.0.2:8080,10.0.0.3:8080`
- `primary_target = 10.0.0.2:8080`（跳过失败的 10.0.0.1）
- 翻转后 `port_weights = 0,1,0`
- 生成 realm JSON：
  ```json
  {
      "listen": "0.0.0.0:8080",
      "remote": "10.0.0.1:8080",
      "extra_remotes": ["10.0.0.2:8080", "10.0.0.3:8080"],
      "balance": "roundrobin: 0, 1, 0"
  }
  ```
- 流量：100% → 10.0.0.2（备1接管）
- 备注：10.0.0.1 仍在 `remote` 和 `extra_remotes` 列表中（持续被探测），只是 weight=0

### 状态 3：主+备1挂（备2 healthy）
- `health_status`：`10.0.0.1=failed, 10.0.0.2=failed, 10.0.0.3=healthy`
- `port_groups`（不变）：`10.0.0.1:8080,10.0.0.2:8080,10.0.0.3:8080`
- `primary_target = 10.0.0.3:8080`
- 翻转后 `port_weights = 0,0,1`
- 流量：100% → 10.0.0.3（备2接管）

### 状态 4：主恢复（紧接状态3后）
- `health_status`：`10.0.0.1=healthy, 10.0.0.2=failed, 10.0.0.3=healthy`
- `primary_target = 10.0.0.1:8080`（本例按原始顺序选主，所以主恢复立刻被选中）
- 翻转后 `port_weights = 1,0,0`
- 流量：100% → 10.0.0.1（切回主）
- **关键语义：严格主备，不退化为多活**。即便主恢复时备2 健康，仍立即切回主。

### 状态 5：备1单挂（主健康）
- `health_status`：`10.0.0.1=healthy, 10.0.0.2=failed, 10.0.0.3=healthy`
- `primary_target = 10.0.0.1:8080`
- 翻转后 `port_weights = 1,0,0`
- 流量：100% → 10.0.0.1（主未受影响）

### 状态 6：全挂
- `health_status`：`10.0.0.1=failed, 10.0.0.2=failed, 10.0.0.3=failed`
- 正常路径 `primary_target` 为空 → 全 0
- 紧急 fallback：检测到全挂后强制将**优先级最高**的目标权重置 1，其他 0，避免完全断流
- `port_weights = 1,0,0`
- 流量：100% → 10.0.0.1（不健康但仍尝试一次，等待健康恢复后由主备逻辑接管）

### 状态 7：主+备1挂→主恢复，备1仍未恢复
- `health_status`：`10.0.0.1=healthy, 10.0.0.2=failed, 10.0.0.3=failed`
- `primary_target = 10.0.0.1:8080`
- 翻转后 `port_weights = 1,0,0`
- 流量：100% → 10.0.0.1（主恢复立刻切回，不等备1）

## 关键代码位置

> 本表按**函数名**定位，不写行号。
> 行号会随每次代码改动整体漂移（`xwFailover.sh` 抽出 `lib/health.sh` 后一次就整体挪了 50+ 行），
> 读者按行号跳过去常常落到无关代码。需要行号时现查：
> `grep -n '<函数名>' <文件>`。

| 文件 | 位置（函数） | 作用 |
|------|--------------|------|
| `lib/core.sh` | `rule_target_endpoints` | **目标枚举的唯一真源**（探测端与路由端共用）；口径 = `TARGET_STATES` 优先，否则 `REMOTE_HOST × REMOTE_PORT` |
| `lib/rules.sh` | `get_balance_info_display` | 在 UI 中显示 `[主备]` 标签 |
| `lib/rules.sh` | `switch_balance_mode` | 第 4 个选项 `active-standby` |
| `lib/rules.sh` | `configure_port_group_weights` | 权重输入提示，允许 0 |
| `lib/rules.sh` | `validate_weight_input` | 权重范围 0-10、全 0 拒绝、数量必须等于目标数 |
| `lib/rules.sh` | `auto_enable_active_standby` | 进主备时清 `TARGET_STATES`（**只清剔除模式残留**，保留显式的每目标端口列表） |
| `lib/realm.sh` | `generate_endpoints_from_rules` | 故障转移过滤主备分支：保留所有目标 + 翻转 0/1 权重；并把 `active-standby` 映射为 `roundrobin` 输出给 realm |
| `xwFailover.sh` | `toggle_failover_mode` | 开启故障转移时选择剔除 / 主备模式（提示条件含"主备"） |
| `lib/health.sh` | `check_connectivity` | 健康检查的 TCP 探测（`nc` 优先，`bash /dev/tcp` 回退） |
| `lib/health.sh` | `health_emit_function` | 从真源原样抽取函数到探测脚本（第 2 参数指定源文件 —— 用它把 `lib/core.sh` 的共用真源一起带进探测脚本） |
| `lib/health.sh` | `health_check_script_body` | 生成独立的 `health_check.sh`（探测实现由 `lib/health.sh` 的 `health_emit_function` 原样抽取注入，与真源逐字一致，无需手工同步） |
| `lib/health.sh` | `start_health_check_service` | 生成 `realm-health-check.service` / `.timer` 并启停 |
| `lib/health.sh` | `stop_health_check_service` | 停止并清理健康检查服务 |
| `lib/health.sh` | `fast_probe_script_body` | 生成独立的 `fast_probe.sh`（**只观测**：每秒一轮，只写自己的观测文件，不参与切换） |
| `lib/health.sh` | `fast_probe_guard_check` | 快探测生成物的**反向护栏**：产物里出现「写状态文件 / 触发配置重生成」的字样 ⇒ 拒绝安装 |
| `lib/health.sh` | `fast_probe_classify` | 快探测的失败分型（退出码 + stderr 文本 → ok/timeout/refused/unreachable/unknown） |
| `lib/health.sh` | `start_fast_probe_service` | 生成 `realm-fast-probe.service` / `.timer`（`AccuracySec=1s`，否则 1 秒一轮会被对齐到分钟边界） |

> ⚠️ **快探测（1 秒一轮）不改变切换时机**：
> 它是**独立的一条流**（独立脚本 + 独立 timer + 独立观测文件），
> **不写**判定流的状态文件、**不触发**配置重生成 ——
> 切换仍然只由判定流按规则里的 `HEALTH_CHECK_INTERVAL` / `FAILURE_THRESHOLD` 决定。
> 详见 [健康检查与故障转移 §3.5](health-check-and-failover.md#35-快探测流只观测每秒一轮的时延与丢包)。

## 与"剔除模式"（原有）的关键差异

| 维度 | 剔除模式（roundrobin+failover） | 主备模式（active-standby+failover） |
|------|------------------------------|---------------------------------|
| 失败目标 | 从 `port_groups` 中移除 | 保留在 `port_groups` 中 |
| 失败时的 weights | 仅剩健康节点的权重 | 全列表权重被重写为 `0,...,1,...,0` |
| 恢复时机 | 健康检查成功 2 次 + 120s 冷却 | 健康检查成功 2 次 + 120s 冷却（同一机制） |
| 严格切回主 | 不适用（无主备概念） | 是（主恢复立刻切回，不等备机） |
| realm config | `extra_remotes` 列表变短 | `extra_remotes` 列表保持完整 |
| realm `balance` 字段 | `roundrobin: w1, w2`（健康节点权重） | `roundrobin: 0, 1, 0`（0/1 列表） |

## 使用步骤（用户视角）

1. 配置中转规则：监听端口 8080，添加 3 个目标 `10.0.0.1`、`10.0.0.2`、`10.0.0.3`
   （可以是单规则 `REMOTE_HOST=10.0.0.1,10.0.0.2,10.0.0.3`，或拆成 3 条规则）
2. `pf` → "负载均衡管理" → "切换负载均衡模式" → 选 `4. 主备模式 (active-standby)`
3. `pf` → "负载均衡管理" → "开启/关闭故障转移" → 选该端口 → 选 `2. 主备模式`
4. 故障转移服务（systemd timer）按端口组里最小的检查间隔（默认 4 秒）探测所有目标
5. 状态变化时自动调 `pf --restart-service` → `service_restart` → `generate_realm_config`
   → 触发主备权重翻转逻辑 → 重写 `balance: roundrobin: 0/1 列表`

## 自动化测试覆盖

通过 `tests/test_e2e.sh`（11 个场景全过）覆盖：

- 主备模式：1. 平时 / 2. 主挂 / 3. 主+备1挂 / 4. 主恢复 / 5. 备1单挂 / 6. 全挂
- 剔除模式（回归）：7. 全健康 / 8. 主挂 / 9. 主+备1挂 / 10. 全挂 / 11. failover off

另外还有：

- `tests/test_active_standby.sh` —— 权重含 0 自动进主备、选主、故障切换、兜底、反向切回
- `tests/test_connectivity.sh` —— TCP 探测与 `/dev/tcp` 回退，以及探测真源与生成物是否逐字一致
- `tests/cases/27_standby_target_parity_t119.sh` —— **探测端与路由端目标口径一致**（T119）、
  口径漂移的负向对照（T120）、显式每目标端口列表的保留与剔除残留的清空（T121）

完整台架索引见 [文档索引 · 测试台架](README.md#测试台架索引)。
