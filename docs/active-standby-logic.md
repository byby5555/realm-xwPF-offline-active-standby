# Active-Standby（主备模式）状态转换推演

本文档记录 `BALANCE_MODE=active-standby`（主备模式）下，单端口多目标规则
的健康状态变化如何映射到 realm 配置输出。3 目标示例：

- `REMOTE_HOST=10.0.0.1,10.0.0.2,10.0.0.3`
- `REMOTE_PORT=8080`
- `WEIGHTS=1,1,1`（用户最初配置；运行时被主备逻辑覆写为 0/1 列表。
  本例权重不含 0，不触发按权重排序，主备优先级即原始顺序）
- `FAILOVER_ENABLED=true`
- 顺序：10.0.0.1 为主，10.0.0.2 为备1，10.0.0.3 为备2

## 核心规则

- 所有目标始终保留在 `extra_remotes` 列表里（健康检查独立探测，不依赖权重）。
- `port_weights` 由「优先级最高的 healthy 节点 = 1，其他 = 0」动态决定。
  优先级规则：权重序列含 0 时按权重从高到低排（同权重保持原始顺序）；
  权重不含 0、或权重个数与目标数不一致时，退化为「原始顺序里第一个 healthy 节点」。
- 生成 realm 配置时 `active-standby` 映射为 `roundrobin` 输出。
- 主恢复后立即切回主（严格主备，不退化为多活）。

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
| `lib/rules.sh` | `get_balance_info_display` | 在 UI 中显示 `[主备]` 标签 |
| `lib/rules.sh` | `switch_balance_mode` | 第 4 个选项 `active-standby` |
| `lib/rules.sh` | `configure_port_group_weights` | 权重输入提示，允许 0 |
| `lib/rules.sh` | `validate_weight_input` | 权重范围 0-10、全 0 拒绝、数量必须等于目标数 |
| `lib/realm.sh` | `generate_endpoints_from_rules` | 故障转移过滤主备分支：保留所有目标 + 翻转 0/1 权重；并把 `active-standby` 映射为 `roundrobin` 输出给 realm |
| `xwFailover.sh` | `toggle_failover_mode` | 开启故障转移时选择剔除 / 主备模式（提示条件含"主备"） |
| `lib/health.sh` | `check_connectivity` | 健康检查的 TCP 探测（`nc` 优先，`bash /dev/tcp` 回退） |
| `lib/health.sh` | `health_check_script_body` | 生成独立的 `health_check.sh`（内含一份同源的探测副本，改动需两处同步） |
| `lib/health.sh` | `start_health_check_service` | 生成 `realm-health-check.service` / `.timer` 并启停 |
| `lib/health.sh` | `stop_health_check_service` | 停止并清理健康检查服务 |

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
- `tests/test_connectivity.sh` —— TCP 探测与 `/dev/tcp` 回退，以及两份探测实现的一致性

完整台架索引见 [文档索引 · 测试台架](README.md#测试台架索引)。
