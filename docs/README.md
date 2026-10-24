# 文档索引

xwPF 是一套跑在 Linux VPS 上的 Bash 转发管理工具。本目录是它的完整使用文档。

---

## 文档清单

| 文档 | 什么时候读 | 内容 |
|------|------------|------|
| **[安装、升级与卸载](install-and-upgrade.md)** | 第一次装机器、换版本、要清干净 | 前置依赖、一键安装、离线安装、升级、卸载、首次初始化、命令行接口 |
| **[端口组与权重](port-groups-and-weights.md)** | 一个端口要转多个出口、想按比例分流、要做主备 | 端口组怎么分组、负载均衡四种模式、权重语义与校验、`1,0,0` 主备写法 |
| **[健康检查与故障转移](health-check-and-failover.md)** | 想让出口挂了自动切走、主挂了自动切备 | 健康检查五项参数、systemd unit、健康状态文件、状态机、切换与回切逻辑 |
| **[故障排查手册](troubleshooting.md)** | 出问题了 | 9 类常见症状的确认方法与修复步骤 + 报 bug 前的信息收集清单 |
| [主备模式状态转换推演](active-standby-logic.md) | 要理解主备每一步怎么翻权重 | 7 个状态的逐态推演、realm 配置输出对比、与剔除模式的差异 |

另有仓库根目录的：

| 文件 | 内容 |
|------|------|
| [../README.md](../README.md) | 中文总览：特性、场景图解、依赖、文件结构 |
| [../README_EN.md](../README_EN.md) | 英文总览 |
| [../cmd/README-failover.md](../cmd/README-failover.md) | **主备 active/passive**（进程级热切换，独立的 `xwpf-failover` 守护进程） |
| [../port-traffic-dog-README.md](../port-traffic-dog-README.md) | 端口流量狗（统计 / 限速 / 通知） |

---

## 推荐阅读顺序

### 路径 A：第一次部署（推荐从这里开始）

```
1. 安装、升级与卸载      ← 装机器、装依赖
2. 端口组与权重          ← 建第一条多出口规则
3. 健康检查与故障转移    ← 配自动切换
```

### 路径 B：只想做端口转发，不管高可用

```
1. 安装、升级与卸载      ← 装机器
2. 端口组与权重 §1-§2   ← 只看端口组和四种模式
```

### 路径 C：已经在用了，出问题了

```
1. 故障排查手册          ← 先按症状查
2. 健康检查与故障转移    ← 需要深挖状态机时
```

### 路径 D：要做严格主备

```
1. 端口组与权重 §4-§5
2. 主备模式状态转换推演   ← 想理解每一步翻权重
3. 健康检查与故障转移 §7 ← 切换与回切
```

---

## 两条不同的「故障转移」

新手最容易混的一点。项目里有**两套独立机制**：

| 机制 | 作用范围 | 开关 | 文档 |
|------|----------|------|------|
| **负载均衡故障转移**（剔除模式 / 主备模式） | 同一个端口组的多个出口之间 | `FAILOVER_ENABLED` + `BALANCE_MODE` | [健康检查与故障转移](health-check-and-failover.md) |
| **主备 active/passive** | 整机级，两台机器热切换 | `xwpf-failover` 守护进程 | [../cmd/README-failover.md](../cmd/README-failover.md) |

两者互不替代，可以同时用。

---

## 文档与源码的对应

文档里的每条规则都指向**具体函数**（写法：`文件` 的 `函数名`），不写行号 ——
行号会随代码改动整体漂移，读者按行号跳过去常常落到无关代码。需要行号时现查：
`grep -n '<函数名>' <文件>`。

| 关注点 | 源码位置 |
|--------|----------|
| 安装流程、文件落盘路径、依赖清单 | `xwPF.sh`、`lib/core.sh` |
| 端口组、负载均衡模式、权重校验 | `lib/rules.sh` |
| realm 配置生成、故障转移过滤、主备权重翻转 | `lib/realm.sh` |
| 菜单结构、按需下载脚本 | `lib/ui.sh` |
| 健康检查脚本、参数、状态机、systemd unit | `lib/health.sh`（唯一真源） |
| 主备守护进程安装与版本比对 | `lib/failover.sh` |

> **唯一真源约定**：健康检查服务逻辑的唯一真源是 `lib/health.sh`。
> 需要复用就 `source` 它，不要在别处实现第二份。

---

## 测试台架

回归测试在 `tests/`，**沙箱运行**：不碰真实 `/etc`、`/usr`、`/var`，不需要 root。

| 入口 | 覆盖点 | 怎么跑 |
|------|--------|--------|
| [../tests/run_tests.sh](../tests/run_tests.sh) | **离线台架主入口，22 条用例（T01–T22）**：下载地址一致性、旧仓库名残留、文档一致性、索引行尾、权重校验、主备规则状态、故障转移运行时（timer / systemd unit / 连通性回退 / 权重翻转 / 离线安装 / `--help`） | `bash tests/run_tests.sh`；`--only T10,T14` 只跑指定用例，`--repeat 3` 连跑 3 轮校验一致性，`--list` 列出编号，`--clean` 跑完删沙箱 |
| [../tests/test_active_standby.sh](../tests/test_active_standby.sh) | 权重含 0 自动进主备、按权重选主、故障切换、全挂兜底、权重全 > 0 时反向切回轮询 | `bash tests/test_active_standby.sh` |
| [../tests/test_connectivity.sh](../tests/test_connectivity.sh) | TCP 探测行为、缺 `nc` 时的 `/dev/tcp` 回退、两份探测实现（`lib/health.sh` 与生成的 `health_check.sh`）是否一致 | `bash tests/test_connectivity.sh` |
| [../tests/test_e2e.sh](../tests/test_e2e.sh) | 主备 + 剔除两种故障转移模式的 11 个端到端场景，断言最终生成的 realm `balance` 字段 | `bash tests/test_e2e.sh` |
| [../tests/test_set_u.sh](../tests/test_set_u.sh) | `set -u` 下关联数组未定义键的健壮性（避免 `config.json` 被写成空、realm 起不来） | `bash tests/test_set_u.sh` |
| [../tests/README.md](../tests/README.md) | 上面 4 个独立脚本的逐项覆盖点与断言说明 | 直接读 |
| [../tests/TEST-HARNESS.md](../tests/TEST-HARNESS.md) | 离线台架的目录结构、沙箱与外部依赖打桩机制、越界扫描 | 直接读 |

> 断言的是**真实实现的行为**（例如 `generate_endpoints_from_rules` 真正生成的 `balance` 字段），
> 不是中间变量 —— 所以覆盖的是「规则文件 → realm 配置」整条链路。

---

## 文档当前状态

本目录文档以**实现**为准：命令、参数、默认值、文件路径逐条对照源码，
并按**函数名**定位（写法见上文「文档与源码的对应」）。

已落地的关键实现：

- 健康检查逻辑已抽到 `lib/health.sh`（**唯一真源**），`xwFailover.sh` 只负责加载、不再重复实现；
  `xwPF.sh` 的 `LIB_FILES` 已包含 `health.sh`，`pf install` 会一并安装
- 健康检查探测优先走 `nc -z -w`；缺 `nc`（或 `nc` 不支持 `-z`，如 busybox）时回退 `bash /dev/tcp`
- 主备选主按权重优先级：权重含 0 时按权重从高到低排，同权重保持原始顺序

对应章节：

- [健康检查与故障转移 §0](health-check-and-failover.md#0--唯一真源约定)
- [健康检查与故障转移 §3](health-check-and-failover.md#3-探测方式)
- [健康检查与故障转移 §9](health-check-and-failover.md#9-已知边界)
- [端口组与权重 §5.3](port-groups-and-weights.md#53-主备优先级与权重的关系)
- [端口组与权重 §7](port-groups-and-weights.md#7-已知边界)
