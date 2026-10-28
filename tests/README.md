# 测试目录

本地回归测试（Git Bash / Linux / macOS 均可跑，**不需要 root**，不会碰真实的 `/etc/realm`）。

## 跑法

```bash
bash tests/test_active_standby.sh   # 主备自动启用 + 优先级选主 + 故障切换
bash tests/test_connectivity.sh     # TCP 探测（含无 netcat 时的 /dev/tcp 回退）
bash tests/test_e2e.sh              # 主备 / 剔除两种故障转移模式的 11 个端到端场景
bash tests/test_set_u.sh            # set -u 下的健壮性（关联数组未定义键）
bash tests/test_latency.sh          # 时延测量 + 负载均衡菜单渲染
bash tests/run_tests.sh             # 离线台架（22 条用例，沙箱 + 外部依赖打桩）
```

前四个脚本都用 `mktemp -d` 建沙箱，结束后自动清理。
`tests/run_tests.sh` 会把仓库产物复制进沙箱再跑，不写仓库、不碰真实 `/etc/realm`。

## `tests/test_active_standby.sh`

在沙箱里造两条中转规则（同端口、两个目标），然后直接调用仓库里的真实函数：

| 覆盖点 | 断言 |
|--------|------|
| 权重校验 | `10,0` 合法；`0,0`（全 0）被拒；数量不匹配被拒；超范围被拒 |
| 含 0 检测 | `weights_contain_zero` 对 `10,0` / `5,5` / `0` 的判定 |
| 自动主备 | 权重写完自动把 `BALANCE_MODE` 改成 `active-standby`、`FAILOVER_ENABLED` 改成 `true`，并补齐 5 个健康检查参数 |
| 选主 | 权重大的当主：`10,0` → `1, 0`；`0,10` → `0, 1` |
| 故障切换 | 主故障 → `0, 1`；主恢复 → `1, 0`（严格主备，不退化为多活） |
| 兜底 | 全挂时强制把优先级最高的目标置 1，保证不断流 |
| 反向切换 | 权重全 > 0 时从主备切回 `roundrobin`，故障转移保持开启 |

断言的是 **`generate_endpoints_from_rules` 真正生成的 realm `balance` 字段**，
不是中间变量，所以覆盖的是「规则文件 → realm 配置」整条链路。

## `tests/test_connectivity.sh`

从 `lib/health.sh` 里**抽出真实的 `check_connectivity`**（以及它生成进
`health_check.sh` 的那份独立副本）单独跑：

| 覆盖点 | 断言 |
|--------|------|
| 回退存在 | `lib/health.sh` 与 `health_check.sh` 里都有 `bash /dev/tcp` 分支 |
| 两份实现一致 | 去掉注释后两份探测实现逐行相同（防止改了一处忘了另一处） |
| 可达端口 | 返回 0 |
| 关闭端口 | 返回 1 |
| 不可达 IP | 返回 1，且耗时不超时失控 |

## `tests/test_e2e.sh`

主备（`active-standby`）与剔除（`roundrobin` 回归）两种故障转移模式的 11 个场景，
断言的是 `generate_endpoints_from_rules` 真正生成的 realm `balance` 字段：

| 场景 | 断言 |
|------|------|
| 1–6 主备 | 平时 `1,0,0`；主挂 `0,1,0`；主+备1挂 `0,0,1`；主恢复回 `1,0,0`；全挂兜底 `1,0,0`（不断流） |
| 7–11 剔除 | 全健康 3 个目标；主挂剩 2 个；主+备1挂剩 1 个；全挂保留 1 个；`failover off` 不做过滤 |

场景编号与 `docs/active-standby-logic.md` 的「自动化测试覆盖」一一对应。

## `tests/test_set_u.sh`

`set -u`（未定义变量即报错）下的健壮性测试。配置生成路径大量使用
`declare -A` 关联数组，旧写法 `${arr[$key]}` 在 `set -u` 下访问未设置的键会
**致命中断整个 shell** —— 结果是 `config.json` 被写成空、realm 起不来，
而界面仍然显示「✓ 生成成功」。

| 覆盖点 | 断言 |
|--------|------|
| 对照组 | 旧写法在 `set -u` 下确实退出非 0；新写法 `${arr[$key]:-}` 退出 0 |
| 生成不中断 | `set -u` 下 `generate_endpoints_from_rules` 退出 0，且无 `unbound variable` |
| 输出一致 | `set -u` 下生成的配置与普通模式逐字节相同，仍产出 `balance` 与全部目标 |
| 其他函数 | `read_rule_file` / `reorder_rule_ids` 在 `set -u` 下成功 |

## `tests/test_latency.sh`

时延（延迟）测量与负载均衡菜单渲染。

| 覆盖点 | 断言 |
|--------|------|
| 时间打点 | `now_us` 返回纯数字微秒、单调递增、量级合理；`EPOCHREALTIME` 与 `date +%s%N` 两条路都可用 |
| 带耗时的探测 | `probe_with_latency` 返回码语义不变；可达端口拿到毫秒数；关闭端口返回非 0 |
| 辅助函数 | `latency_avg_ms` 求平均、`format_latency_display` 格式化、`get_health_status_record` 读记录 |
| 状态文件 | 生成的 `health_check.sh` **真跑一轮**：状态记录 9 个字段、第 8 个是时延、第 9 个是历史 |
| 历史累积 | 跑 3 轮累积 3 个样本，跑满后**最多保留 5 个** |
| 菜单渲染 | 真跑一次负载均衡菜单，输出里必须出现 `[时延: 12ms (均 12ms)]` 与 `[健康]` |

> 菜单渲染这条曾经抓到一个真 bug：状态记录 9 个字段，却按 10 个变量去读，
> 结果把「时延历史」当成了「最近时延」，页面显示成 `[时延: 10,12,14ms]`。
> 静态检查发现不了，只有真跑一遍菜单才暴露。

## `tests/run_tests.sh` —— 离线台架

22 条用例，核心是**沙箱 + 打桩**：把仓库产物按 LF 复制进沙箱、把系统绝对路径
重定向到沙箱目录、把 `systemctl` / `nc` / `curl` / `wget` / `realm` 等外部依赖
换成可预测的替身，然后断言真实实现的行为。

| 文件 | 作用 |
|------|------|
| `tests/lib/sandbox.sh` | 沙箱构建：LF 副本、路径重定向、root 模拟、外部依赖打桩、基线快照 |
| `tests/lib/harness.sh` | 用例框架：断言、证据落盘、汇总 |
| `tests/cases/01_static_contract.sh` | 静态契约（文档声称的文件必须存在、下载地址必须指向本 fork 等） |
| `tests/cases/02_weight_active_standby.sh` | 权重校验与「含 0 → 自动主备」 |
| `tests/cases/03_failover_runtime.sh` | 故障转移运行时行为（健康检查服务、生成物行尾归一化等） |

每条用例的 stdout / notes / fails / meta 都落在沙箱的 `cases/` 目录里，便于复查。

## `tests/shims/` —— 离线替身

给「装一遍 / 跑一遍完整流程」用的假命令，把外部依赖换成本地可控行为：

| 替身 | 作用 |
|------|------|
| `curl` / `wget` | 离线下载桩：按 URL 里的 `/main/`、`/raw/` 取仓库相对路径，到 `$SBX_MIRROR` 本地镜像取文件；取不到返回 404。**每次调用都记录 URL**，可断言「下载地址是否都指向本 fork」 |
| `nc` | 模拟 TCP 探测结果：`$SBX_NC_DOWN` 里每行一个 `host:port`，命中即判连接失败 |
| `systemctl` | 只记录调用；`is-active` / `is-enabled` 返回 3（inactive） |
| `flock` | 假锁（Git Bash 没有 flock） |
| `id` | 永远返回 root |
| `bc` | 只支持 `scale=N; a * b / c` 这一种表达式 |
| `apt-get` / `journalctl` / `realm` | 只记录不执行 |

用法：

```bash
export SBX_LOG_DIR=/tmp/shimlog
export SBX_MIRROR=/path/to/local/mirror
export SBX_NC_DOWN=/tmp/down_targets
export PATH="$PWD/tests/shims:$PATH"
```

> `tests/shims/` 里只放**替身**，不放真实业务逻辑；
> 被测对象始终是仓库里的 `lib/*.sh` 与 `xwFailover.sh`。
