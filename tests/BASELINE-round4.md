# 第 4 轮冻结基线报告（realm-xwPF-offline-active-standby）

> 维护者：阿测　　类型：**冻结基线**
> 前序：[`BASELINE-round3.md`](./BASELINE-round3.md)（6df4721 / 4b3b246）

---

## 0. 这次跑的是什么

| 项 | 值 |
|----|----|
| **冻结点 BASE_SHA** | `60070e8642821a093727a0d5f7cbdce2ac9859ed`（短号 `60070e8`） |
| 冻结点标题 | `fix(rules): 关闭 R2-D01 —— set -u 下未定义规则键的致命中断`（2026-10-24 11:47 +0800） |
| 所在分支 | `feat/update-center` |
| **台架版本** | `v2.2.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8)` |
| 产物来源 | `git show $BASE_SHA:<path>`（**不读工作区**） |
| 产物指纹 | [`tests/baseline-manifest.txt`](./baseline-manifest.txt) |
| 跑批命令 | `BASE_SHA=60070e8 bash tests/run_tests.sh --repeat 3` |
| **结果** | **总计 39 条，通过 38，失败 1** |
| **多轮一致性** | **3 轮结果向量完全一致**（唯一红灯恒为 T32） |
| 越界残留 | **0 处** |
| 唯一红灯 | **T32** —— `docs/health-check-and-failover.md` 仍声称「探测逻辑另有一份内联副本 / 两处必须同步」 |

**结果向量（× 3 轮，逐字符相同）：**

```
T01=PASS;…;T31=PASS;T32=FAIL;T33=PASS;T34=PASS;T35=PASS;T36=PASS;T37=PASS;T38=PASS;T39=PASS;
```

---

## 1. 本轮台架变更

### 1.1 T32 收紧为「唯一手写实现 + 机械抽取」

上一轮我把它放宽成「份数 ∈ [1,2]」—— 当时 `1c72634` 还没进冻结点。
现在结构已经收敛，按小编的要求改成 5 条**更严**的不变量：

| # | 断言 | 守什么 |
|---|------|--------|
| 1 | 全仓 `^check_connectivity() {` **手写份数 == 1** | 有人又手抄了一份 → 红 |
| 2 | 这 1 份必须在 `lib/health.sh` | 散落到别处 → 红 |
| 3 | `health_check_script_body()` **所在文件**里仍只有 1 处 | heredoc 里没有第二份手写副本（M4 核心不变量） |
| 4 | **生成物** `health_check.sh` 里恰好 1 份，且与真源**逐字一致** | 抽取失真 → 红 |
| 5 | 仓库里不得再出现「另有一份内联副本 / 两处必须同步」字样 | 文档/注释回潮 → 红 |

> 第 5 条的扫描范围：产品代码 + 面向用户的文档（`lib/**` `cmd/**` `docs/**` `notifications/**` + 顶层 `*.sh` `*.md`），
> 排除 `tests/`（台架自己）与 `reports/`（历史报告）。
> 匹配用**精确短语** `另有一份内联副本|两处必须同步`，
> 避开「**不需要**维护『两处必须**手工**同步』的注释」这类否定句。

### 1.2 新增 T35–T39：M1 / M2 / M5 / M7 / M8 的行为回归

产品行为变了，台架必须跟着长用例，否则改完没人知道对不对。

| 用例 | 覆盖 | 关键断言 |
|------|------|---------|
| **T35** | M1 规则解析唯一化 | 规则文件里塞 `EVIL="$(touch marker)"` / `EVIL2=$(touch marker)` → 走 `read_rule_file` 后 **marker 不得生成**、白名单外的键**不得被赋值**。第二口径：同一份文件被 `source` 时命令**确实会执行** → 证明断言不是空过 |
| **T36** | M2 进主备清空 TARGET_STATES | 进主备后 `TARGET_STATES` 被清空；权重全 >0 不进主备时**原样保留** |
| **T37** | M5 健康检查起不来要回滚 | `ensure_health_check_service` 桩返回 1 → 打印真实原因 + 「已回滚」，且 `BALANCE_MODE`/`FAILOVER_ENABLED`/`TARGET_STATES` **全部回滚**；探测端正常时**不得**回滚 |
| **T38** | M7 PREV_BALANCE_MODE | 进主备记 `PREV_BALANCE_MODE=iphash`；权重改回全 >0 时切回 **iphash**（不是写死 roundrobin）；原模式是 roundrobin 时切回 roundrobin |
| **T39** | M8 二次确认 | 答 `n` → 取消且 `BALANCE_MODE` 不变；回车 → 切主备；第三个参数 `1` → **不再询问**且仍切主备 |

### 1.3 写这 5 条时踩到的两个坑（已写进台架纪律）

1. **不能断言交互提示的文本**。
   bash 的 `read -p` 只在 **stdin 是终端**时才把提示打到 stderr
   （bash 手册原文：*"The prompt is displayed only if input is coming from a terminal."*）。
   沙箱里喂管道 → **提示根本不显示** → 断言「确认切换到主备模式?」必然假红。
   → 改成断言**行为**（答 `n` 会不会取消、回车会不会继续）。
   场景 3 改用询问分支里 `echo` 到 **stdout** 的那句「注意：切到主备模式会同时做三件事」当判据 —— 那句管道里看得到。
2. **对照组要用对函数**。
   「进不进主备」由 `apply_port_group_weight_config` 的**权重判定**决定；
   `auto_enable_active_standby` 本身**不看权重**、只要被调用就会切主备 ——
   拿它当「不进主备」的对照组，第一版就是这么写的，直接得到假红。

---

## 2. 用例表（39 条）

| 编号 | 用例 | 结论 |
|------|------|------|
| T01–T09 | 静态契约类 | ✅ 全绿 |
| T10–T15 | 权重校验与主备规则状态 | ✅ 全绿 |
| T16–T22 | 故障转移运行时 | ✅ 全绿 |
| T23–T25 | 自动进主备 / 选主切换 / 切回轮询 | ✅ 全绿 |
| T26–T28 | 探测函数行为（真源 / 生成物副本 / 两份一致） | ✅ 全绿 |
| T29–T30 | 主备 6 态 + 剔除 5 态端到端 | ✅ 全绿 |
| T31 | `set -u` 下的健壮性 | ✅ 全绿 |
| **T32** | **探测实现：唯一手写真源 + 机械抽取** | ❌ **文档仍声称有两份要手工同步** |
| T33 | 规则缺可选字段时的 `set -u` 健壮性 | ✅ |
| T34 | 文档里的源码引用必须可解析 | ✅ |
| T35 | 规则文件解析不执行其中内容（M1 安全） | ✅ |
| T36 | 进主备时清空 `TARGET_STATES`（M2） | ✅ |
| T37 | 健康检查起不来时回滚主备开关（M5） | ✅ |
| T38 | 切回原负载均衡模式（M7） | ✅ |
| T39 | 含 0 切主备前的二次确认（M8） | ✅ |

---

## 3. 缺陷清单

### 🔴 P2 · 中 · `docs/health-check-and-failover.md` 仍声称「探测逻辑另有一份内联副本 / 两处必须同步」

**证据（T32 现场）：**

```
手写份数分布: lib/health.sh×1
health_check_script_body() 所在文件: lib/health.sh
  过时字样: docs/health-check-and-failover.md:21  > 所以它的探测逻辑在 `lib/health.sh` 里另有一份内联副本。
  过时字样: docs/health-check-and-failover.md:22  > **改动 `check_connectivity` 时两处必须同步**——
  过时字样: docs/health-check-and-failover.md:490 | `lib/health.sh` 已落盘 | …其探测逻辑另有一份内联副本（两处必须同步，…）
FAIL: 仍声称「有两份探测实现要手工同步」的文件数 期望[0] 实际[1]
```

**为什么是问题：** `1c72634` 已经把生成物改成**机械抽取**（`health_emit_function` 从真源原样抽），
仓库里**只有一份手写实现**。文档还写着「另有一份内联副本」「改动时两处必须同步」——
这是在教读者一个**已经不存在的维护负担**，也是给未来埋的「回归温床」
（读者会以为可以手改生成物里的那份）。

**建议改法：**

`docs/health-check-and-failover.md:19-23` 改成：

```
> 例外只有一处：生成的 `/etc/realm/health/health_check.sh` 是一份**独立可执行**的脚本
> （systemd 直接调用它，不能依赖 pf 的安装目录），
> 所以它的探测逻辑在**生成时**由 `lib/health.sh` 的 `health_emit_function` 从真源
> **原样抽取**拼进去 —— 仓库里只有一份手写实现，不存在「两处手工同步」的问题。
> 门禁由 `tests/run_tests.sh` 的 T32（唯一手写份数 + 生成物逐字一致）盯着。
```

`docs/health-check-and-failover.md:490` 表格行改成：

```
| `lib/health.sh` 已落盘 | 健康检查脚本由 `lib/health.sh` 的 `health_check_script_body` 生成，`xwFailover.sh` 与 `pf` 共用同一份实现。生成的 `health_check.sh` 是独立可执行脚本，其探测逻辑在生成时由 `health_emit_function` 从真源原样抽取（无手写副本，无需手工同步；门禁 `tests/run_tests.sh` 的 T32） |
```

> 顺带：`:23` 那句「`tests/test_connectivity.sh` 的 C 组用例专门盯这一条」也过时了 ——
> 那个脚本第 2 轮已改成薄封装，守这条的现在是 `run_tests.sh` 的 T32 / T28。

---

### 🟢 已关闭 · 第 2 轮的 P1（R2-D01）

`60070e8` 已显式关闭（`fix(rules): 关闭 R2-D01`）。
T33 在 `6df4721` 上就已转绿（`read_rule_file` 重写），本轮继续绿。

---

## 4. 口径变更对历史基线的影响（重要）

T32 从「份数 ∈ [1,2]」收紧成「**手写份数 == 1**」后，
**旧冻结点上的 T32 会红** —— 这是**正确的**，不是回归：

| 冻结点 | 结构 | 新版 T32 | 具体红项 |
|--------|------|----------|---------|
| `a9102c1` / `b361ca8` | 真源 + 手写内联副本 = **2 份** | ❌ 红 | ① 手写份数 2≠1 ② 生成脚本所在文件里 2 处 ③ 过时字样 2 个文件 |
| `1c72634` 起 | 唯一手写 + 机械抽取 = **1 份** | ❌ 红（**只剩 ③**） | 结构断言**全过**，只有文档过时 |
| `60070e8`（当前） | 同上 | ❌ 红（**只剩 ③**） | `docs/health-check-and-failover.md` 1 个文件 |

> `1c72634` 那一行很说明问题：**代码结构在 `1c72634` 就已经完全收敛了**
> （手写 1 份、生成脚本所在文件里 1 处），**至今只剩文档没跟上**。
> `84f78a1` 修的是 `read_rule_file` 的归属，没碰探测副本那一段。

→ 结论：**冻结点一变，结论就作废**。老 SHA 的结论仍然有效（当时测的就是老结构），
但用新台架重跑老 SHA，红灯是**如实反映**，不是台架坏了。

---

## 5. 覆盖盲区与待真机清单

### 5.1 仍未覆盖

| 盲区 | 原因 |
|------|------|
| 依赖 `jq` 的整段配置生成 | 本机无 `jq`，未打桩 |
| `lib/update.sh` / `tests/test_update.sh`（更新中心） | 有独立脚本，但**没有台架用例** |
| `xw_realm_OCR.sh` | 一条都没测 |
| 规则文件的真实增删改落盘格式 | 只测了读与生成 |
| 时延测量 + 菜单渲染 | `tests/test_latency.sh` 未并入台架 |
| 真实 realm 消费生成的 `config.json` | 沙箱只生成文本，没有真 realm |
| **交互式提示在真终端的显示** | `read -p` 只在 TTY 显示，台架是管道 → 提示是否好看、是否被截断，属真机项 |

### 5.2 待真机验证

沿用第 2/3 轮清单（CRLF 源在真 Linux 的行为 · systemd timer 真机启停 · 真 realm 流量切换 ·
真 netcat/busybox nc 的 `-z` 差异 · 无 `timeout` 的精简 VPS 上 `/dev/tcp` 回退 ·
真 `flock` 并发 · 真 `bc` 浮点 · `jq` 分支 · 50 条规则性能 · shellcheck），本轮无新增。

---

## 6. 冻结点机制使用说明

```bash
BASE_SHA=<sha> bash tests/run_tests.sh            # 推荐
bash tests/run_tests.sh --base-sha <sha>          # 等价
BASE_SHA=<sha> bash tests/run_tests.sh --repeat 3 # 正式跑批建议连跑 3 轮
```

- SHA 不存在 → **exit 2**，不会偷偷改成读工作区。
- **SHA 一变，旧结论作废，必须重跑。**
- 报告必带四项：冻结点 SHA、冻结点标题、台架版本、产物指纹路径。

**基线链：**

| 轮次 | 冻结点 | 台架 | 结果 |
|------|--------|------|------|
| 第 1 轮 | （工作区快照） | — | 22/22 |
| 第 2 轮 | `a9102c1` | v2.1.0 | 33/34（T33 红） |
| 第 3 轮 | `6df4721` | v2.1.0 | 33/34（T34 红） |
| 第 3 轮·全绿 | `4b3b246` | v2.1.0 | **34/34** |
| **第 4 轮** | **`60070e8`** | **v2.2.0** | **38/39（T32 红）** |

---

## 7. 附：证据位置

| 证据 | 路径 |
|------|------|
| 产物指纹 | `tests/baseline-manifest.txt` |
| 每条用例的 stdout / log / notes / fails / meta | 跑批时的 `$SBX_ROOT/cases/` |
| 完整跑批输出 | 本机 `/tmp/r4_60070e8.txt`（临时文件，不入库） |
| 上一轮报告 | `tests/BASELINE-round3.md` |
| 台架说明 | `tests/TEST-HARNESS.md` |
| 用例索引 | `tests/README.md` |
