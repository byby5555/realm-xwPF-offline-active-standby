# 第 2 轮冻结基线报告（realm-xwPF-offline-active-standby）

> 维护者：阿测　　类型：**冻结基线**（代表「本轮修改前」的真实状态，供小编改完后对比）
> 本文件只描述**被测产物在冻结点 `a9102c1` 上的状态**，不描述台架本身在工作区里的最新形态。

---

## 0. 这次跑的是什么

| 项 | 值 |
|----|----|
| **冻结点 BASE_SHA** | `a9102c1a20719cb808f11f9f5bbe94dbefceab30`（短号 `a9102c1`） |
| 冻结点标题 | `docs: 源码引用升级为函数级 + 补「IP 通但链路不通」排查专章`（2026-10-24 10:59:39 +0800） |
| **台架版本** | `v2.1.0 (frozen-base + docs-refs)` |
| 跑批时间 | 2026-10-24 11:39 +0800 |
| 产物来源 | `git show $BASE_SHA:<path>`（**不读工作区**） |
| 产物指纹 | [`tests/baseline-manifest.txt`](./baseline-manifest.txt)（每个被测文件的 sha256；该文件已指向最新一轮基线） |
| 跑批命令 | `BASE_SHA=a9102c1 bash tests/run_tests.sh --repeat 3` |
| **结果** | **总计 34 条，通过 33，失败 1** |
| **多轮一致性** | **3 轮结果向量完全一致**（唯一红灯恒为 T33） |
| 唯一红灯 | **T33** —— `lib/realm.sh:411` 未保护读 `$TARGET_STATES` |

> ⚠ 跑批期间仓库 HEAD 已被前移：`b361ca8` → `27fc74a`（`feat(latency): 负载均衡页面显示时延 + 立即测试所有目标`），
> 工作区还有 `lib/update.sh`、`tests/test_update.sh` 等未提交改动。
> **本报告的结论只对 `a9102c1` 成立** —— 这正是冻结点机制存在的理由。
>
> 📌 **后续状态**：T33 这条红灯在 `6df4721`（`feat/update-center` 分支 HEAD）上**已经转绿** ——
> `read_rule_file` 被重写成「白名单逐行解析 + 缺键回落空串」，不再 `source` 规则文件，
> 未定义变量的根因被从底层消除。详见 [`BASELINE-round3.md`](./BASELINE-round3.md)。

> ⚠ 跑批期间仓库 HEAD 已被前移：`b361ca8` → `27fc74a`（`feat(latency): 负载均衡页面显示时延 + 立即测试所有目标`），
> 工作区还有 `lib/update.sh`、`tests/test_update.sh` 等未提交改动。
> **本报告的结论只对 `a9102c1` 成立** —— 这正是冻结点机制存在的理由。

---

## 1. 台架变更说明（第 2 轮）

### 1.1 目录结构

```
tests/
├── run_tests.sh              ← 唯一入口（用例登记表 + 冻结点解析 + 跑批 + 汇总）
├── lib/
│   ├── harness.sh             ← 用例账本与断言助手（未改）
│   └── sandbox.sh             ← 沙箱构建：冻结态导出 / LF 副本 / 路径重定向 / root 模拟 / 打桩 / manifest
├── cases/
│   ├── 00_common.sh          ← 新增：用例组公共工具（去重后）
│   ├── 01_static_contract.sh  ← 重写：全部改读冻结态
│   ├── 02_weight_active_standby.sh ← 去重（公共函数移到 00_common.sh）
│   ├── 03_failover_runtime.sh        ← 去重（公共函数移到 00_common.sh）
│   ├── 04_legacy_merged.sh   ← 新增：第 2 轮从 4 套旧脚本并入的用例（T23–T33）
│   └── 05_docs_refs.sh      ← 新增：第 3 轮的文档源码引用一致性（T34）
├── shims/*                   ← 打桩（未改，永远取工作区最新版）
├── test_{active_standby,connectivity,e2e,set_u}.sh ← 改为薄封装（转发 --only）
├── README.md                 ← 重写：唯一入口声明 + 34 条用例索引 + 旧脚本映射
├── TEST-HARNESS.md           ← 重写：冻结点机制说明（含「Chief 怎么指定 SHA」）
├── BASELINE-round1.md        ← 第 1 轮报告（保留）
├── BASELINE-round2.md        ← 本文件
└── baseline-manifest.txt     ← 本轮产物指纹
```

### 1.2 关键机制变更

| 变更 | 第 1 轮 | 第 2 轮 |
|------|---------|---------|
| 被测产物来源 | 仓库**工作区**文件 | **`git show $BASE_SHA:<path>`** |
| 静态检查读哪 | 工作区 | **冻结态** |
| 行尾检查口径 | `git ls-files --eol`（查的是索引） | 对冻结态 **raw blob 数字节数 CR** |
| 入口 | 5 套脚本并存 | **只有 `run_tests.sh`**，其余薄封装 |
| 基线锚点 | manifest 记 HEAD | manifest 记 **BASE_SHA + 每个文件 sha256** |
| 台架版本 | 无 | `v2.0.0 (frozen-base)`，写在 banner 与 manifest 里 |
| 提交信息自查 | 无 | 跑批末尾打印「声称全过但没引用 run_tests.sh」告警 |

---

## 2. A–D 逐项交付

### A. 修三处错误期望

| 用例 | 第 1 轮的错误 | 本轮改法 | 依据 |
|------|--------------|---------|------|
| **T20** 安装引导的离线下载 | 断言里带 `\|\| echo 0`，`grep -c` 未命中时会输出 `0` **再输出一次 `0`** → 期望值永远对不上 → **恒红** | 计数统一收口到 `h_count` / `h_count_pipe`（未命中就返回干净的 `0`）；断言改成「落盘文件逐个存在」+「下载内容与冻结态副本 sha256 一致」，**不再断言管道返回码** | `tests/lib/harness.sh` 的 `h_count`/`h_count_pipe`；T20 现断言 10 个必装文件 + 1 个 sha256 |
| **T07** 文档声称的测试脚本 | 要求**两个路径同时存在**（`tests/test_e2e.sh` 与另一个），而文档只声明了一个 → 永远缺一个 | 改成「**只按文档里实际写出的路径核对**：反引号里提到的相对路径去同一棵树里找；文档没声明就不判失败」 | 用例从「我以为文档写了什么」变成「文档写了什么就核什么」 |
| **T06** 无 nc 时的健康检查 | 断言钉在「实现放在哪个文件」（`grep` 某个文件里有没有 `/dev/tcp` 分支）→ 重构即假红 | 改成**端到端行为断言**：跑生成的 `health_check.sh`（PATH 不含 nc），断言**健康状态文件里写出 `healthy`** | T06 现在只依赖「行为正确」，不依赖「实现放在哪」 |

### B. 合并为唯一入口

- 4 套旧脚本的用例全部并入 `tests/run_tests.sh`，编号 T23–T33。
- 旧脚本**不删**（避免打断别人的调用习惯），改成薄封装，内部 `exec bash run_tests.sh --only ...`：

| 旧脚本 | 转发到 |
|--------|--------|
| `tests/test_active_standby.sh` | `--only T10,T11,T12,T13,T14,T15,T23,T24,T25` |
| `tests/test_connectivity.sh` | `--only T06,T18,T26,T27,T28` |
| `tests/test_e2e.sh` | `--only T19,T29,T30` |
| `tests/test_set_u.sh` | `--only T31` |

- `tests/test_latency.sh` **未并入**（覆盖时延测量与菜单渲染，依赖 `now_us` / `EPOCHREALTIME`），仍为独立脚本。
- `tests/README.md` 已重写为索引（D-03）：声明唯一入口、列出 34 条用例与覆盖点、给出旧脚本映射表、补 5 条「写用例的硬规矩」。
- 配套：跑批末尾打印**提交信息自查**提示 —— 上一条提交信息若声称「全过 / 全部通过 / 测试通过」但没引用 `run_tests.sh`，台架直接告警。

### C. 冻结点机制

- `run_tests.sh` 支持 `BASE_SHA` 环境变量与 `--base-sha` 参数，**默认取当前 HEAD**。
- SHA 不存在 → **直接 `exit 2`**，绝不静默退化成「读工作区」。
- 被测产物一律 `git show $BASE_SHA:<path>` 导出，分三层：
  `$SBX_RAW`（原始字节，行尾断言用）/ `$SBX_SRC`（LF 副本，静态检查用）/ `$SBX_RUN`（LF + 路径重定向 + root 模拟，功能测试用）。
- 桩（`tests/shims/`）**永远取工作区最新版** —— 台架自身不是被测对象。
- 报告头输出：**冻结点 SHA + 冻结点标题 + 当前 HEAD（仅供对照）+ 台架版本 + 产物来源**；
  汇总行输出：**BASE_SHA + 台架版本 + 产物指纹路径**。
- 规则：**SHA 一变，旧结论全部作废，必须重跑。**

### D. 静态断言

- **T32（已按事实改写）**。原始要求是「全仓 `check_connectivity() {` 出现次数 == 1」，
  但在冻结点 `a9102c1` 上**这个数不是 1**，而且 ==1 也不该成立 —— 实测与文件自述如下：

  | 位置 | 是什么 |
  |------|--------|
  | `lib/health.sh:33` | **真源**，主程序调用 |
  | `lib/health.sh:143` | 在 `health_check_script_body()` 的 heredoc（`lib/health.sh:98` `cat << 'EOF' \| tr -d '\r'`）里 → **生成到 `/etc/realm/health/health_check.sh` 的内联副本** |

  `lib/health.sh` 文件头自己写着：
  > 生成的 `/etc/realm/health/health_check.sh` 是一份**独立可执行**的脚本（systemd 直接调用它，不能依赖 pf 的安装目录），
  > 所以它的探测逻辑在下面 `health_check_script_body` 里另有一份内联副本，**改动 `check_connectivity` 时两处必须同步**。

  → 这份副本是**设计要求的**，不是「逐字重复的脏拷贝」；
  → 曾经存在的**第 3 份**（`lib/failover.sh`）已在 `4558e65 fix(robustness): …探测函数分层` 里删掉。

  因此把断言改成**真正想守的不变量**（比 ==1 更严）：

  1. 全仓 `check_connectivity() {` **总数 == 2**（多一份 = 有人又抄了一份 → 红；在「3 份」的老状态下同样红）
  2. 这 2 份**必须都在 `lib/health.sh`**（散落到别处 → 红）
  3. 第 2 份**必须落在 `health_check_script_body()` 之内**（位置对 → 绿）
  4. 两份**必须逐字一致**（漂移 → 红；T28 从生成物侧再校一次）

- 提交信息自查提示：见 B 段末尾。

---

## 3. `BASE_SHA=a9102c1` 的用例表（34 条）

| 编号 | 用例 | 结论 | 实际 |
|------|------|------|------|
| T01 | 下载地址一致性 | ✅ | 下载地址指向旧仓库的条数 = 0 |
| T02 | 旧仓库名残留 | ✅ | 旧仓库名出现次数 = 0 |
| T03 | 行尾检查（提交态） | ✅ | 提交态含 CR 的 .sh 文件数 = 0 |
| T04 | xwPF.sh --help 入口 | ✅ | 入口侧 --help 命中 5 处 |
| T05 | xwFailover.sh help 与文档一致性 | ✅ | help 子命令中有文档说明的数量 = 7 |
| T06 | 无 nc 时的健康检查（端到端行为） | ✅ | 无 nc 时探测结果写入健康状态文件 命中[healthy] |
| T07 | 文档声称的测试脚本 | ✅ | 文档引用的测试脚本缺失清单 =（空） |
| T08 | 文档声明的唯一真源 | ✅ | 唯一真源 lib/health.sh 存在 (health.sh) |
| T09 | 仓库里被跟踪的编译产物 | ✅ | 被跟踪的编译产物数量 = 0 |
| T10 | 权重 1,0,0 合法 | ✅ | `validate_weight_input '1,0,0' 3` 返回码 0 |
| T11 | 权重 0,0,0 必须被拒绝 | ✅ | 拒绝提示文案 命中[全部为 0] |
| T12 | 权重数量与目标数不符必须被拒绝 | ✅ | 拒绝提示文案 命中[数量不匹配] |
| T13 | 权重越界/非法字符必须被拒绝 | ✅ | `validate_weight_input '10,0,0' 3`（边界合法）返回码 0 |
| T14 | 权重 1,0,0 → 规则进入主备态 | ✅ | RECOVERY_COOLDOWN 命中[RECOVERY_COOLDOWN="120"] |
| T15 | 权重含 0 的主备判定 | ✅ | 全大于 0 判定 命中[RC_NOZERO=1] |
| T16 | 主备 → 健康检查 timer 被拉起 | ✅ | systemctl 调用里有 start 命中[start] |
| T17 | 健康检查脚本与 systemd unit 一致 | ✅ | 生成脚本里的 CR 字节数 = 0 |
| T18 | 无 nc 时的连通性回退 | ✅ | 有 nc 时 check_connectivity 结果（对照口径）命中 |
| T19 | 主备权重翻转 | ✅ | 全挂时的兜底权重 命中[roundrobin: 1, 0, 0] |
| T20 | 安装引导的离线下载 | ✅ | 下载的 xwPF.sh 与仓库副本的 sha256 = bcebc48e… |
| T21 | xwPF.sh --help 实际行为 | ✅ | --help 输出含 Usage 说明 命中[Usage] |
| T22 | 生成物行尾归一化 | ✅ | 生成前有行尾归一化 |
| T23 | 权重含 0 → 自动进主备 | ✅ | RECOVERY_COOLDOWN 已补齐 命中[RECOVERY_COOLDOWN=] |
| T24 | 主备优先级选主与切换 | ✅ | 全挂(10,0) → 兜底第一个 命中[roundrobin: 1, 0…] |
| T25 | 权重全 >0 → 自动切回轮询 | ✅ | 故障转移保持开启 命中[FAILOVER_ENABLED="true"] |
| T26 | 探测函数行为（入口加载的那份） | ✅ | 超时受控（2s ≤ 6s） |
| T27 | 生成的 health_check.sh 里的探测副本行为 | ✅ | 生成副本 → 关闭端口判定失败 未命中[RC=0] |
| T28 | 两份探测实现必须一致 | ✅ | 源实现与生成脚本内联副本一致 |
| T29 | 主备模式 6 态端到端 | ✅ | 场景6 全挂兜底（不断流） 命中[roundrobin: 1…] |
| T30 | 剔除模式 5 态端到端 | ✅ | 场景11 failover off → 不过滤，3 个都在 = 3 |
| T31 | set -u 下的健壮性 | ✅ | set -u 下输出与普通模式一致 |
| T32 | 探测实现结构（单一真源 + 生成物一致） | ✅ | 真源与生成物里的探测实现逐字一致 |
| **T33** | **规则缺可选字段时的 set -u 健壮性** | ❌ | **缺可选字段时 set -u 下不致命中断 期望返回码 0，实际 1** |
| T34 | 文档里的源码引用必须可解析 | ✅ | 函数级引用 63 组全部可解析；行号引用 27 处目标均存在 |

**3 轮结果向量（完全一致）：**

```
T01=PASS;T02=PASS;…;T33=FAIL;T34=PASS;   （× 3 轮，逐字符相同）
```

---

## 4. 缺陷清单（按严重级）

### 🔴 P1 · 中 · `lib/realm.sh:411` 未保护读 `$TARGET_STATES`，`set -u` 下致命中断

> 📌 **状态更新（第 3 轮）**：这条红灯**已在上游被另一条路径修掉**，缺陷单可以撤。
> `6df4721`（`feat/update-center` 分支 HEAD）的 `1c72634「规则解析唯一化」`把 `read_rule_file`
> 从「unset 全部键 → `source` 规则文件」重写成「**白名单逐行解析 + 每个白名单键统一赋值**」：
> ```bash
> for _key in $_allowed; do
>     printf -v "$_key" '%s' "${_rule_vals[$_key]:-}"
> done
> ```
> → 文件里没写的键**回落成空串**（不再是「未定义」），未定义变量的根因从底层被消除。
> 实测 T33 在 `6df4721` 上已转绿。下面的分析保留，作为「这类坑是怎么来的」的记录。

**证据（冻结点 a9102c1，T33 现场）：**

```
/tmp/xwpf-sbx.LfdWqn/run/lib/realm.sh: line 411: TARGET_STATES: unbound variable
RC=1
```

**机理：**

- `read_rule_file`（`lib/health.sh:179-186`）会**先 `unset` 掉全部规则键，再 `source` 规则文件**：
  ```bash
  unset RULE_ID RULE_NAME RULE_ROLE LISTEN_PORT … unset TARGET_STATES WEIGHTS CREATED_TIME
  source "$rule_file"
  ```
- 所以「**规则文件里没写某个键**」 = 「**该变量未定义**」。
- `lib/realm.sh:411` 直接引用，没有默认值：
  ```bash
  if [ "$BALANCE_MODE" != "off" ] && [ -n "$TARGET_STATES" ]; then
  ```

**影响面（已全仓扫描冻结态）：** 同类「`read_rule_file` unset 过、别处直接引用（没有 `:-` 默认值）」的写法
在冻结态里共 **229 处**，遍布 `lib/realm.sh` / `lib/rules.sh` / `lib/ui.sh` / `lib/health.sh` /
`lib/server.sh` / `xwFailover.sh` / `xw_realm_OCR.sh`。按变量分布：

| 变量 | 无保护引用处数 | 变量 | 无保护引用处数 |
|------|--------------|------|--------------|
| `RULE_ROLE` | 42 | `WEIGHTS` | 16 |
| `LISTEN_PORT` | 25 | `WS_PATH` | 15 |
| `REMOTE_HOST` | 24 | `WS_HOST` | 14 |
| `ENABLED` | 18 | `RULE_NAME` | 10 |
| `SECURITY_LEVEL` | 10 | `TLS_SERVER_NAME` | 10 |
| `REMOTE_PORT` | 8 | `BALANCE_MODE` | 8 |
| `TARGET_STATES` | 7 | `TLS_CERT_PATH` | 7 |
| `TLS_KEY_PATH` | 7 | `FORWARD_TARGET` | 4 |
| `RULE_ID` | 2 | `FAILOVER_ENABLED` | 2 |

（`LISTEN_IP` / `THROUGH_IP` / `HEALTH_CHECK_INTERVAL` / `FAILURE_THRESHOLD` / `SUCCESS_THRESHOLD` /
`CONNECTION_TIMEOUT` / `RECOVERY_COOLDOWN` / `CREATED_TIME` 这 8 个**已经**带默认值，不在此列。）

**为什么仍然算缺陷：** 仓库里已经有过一次同类修复 ——
`4558e65 fix(robustness): 关联数组读取加默认值`（82 处 `${arr[$key]}` → `${arr[$key]:-}`），
说明「`set -u` 下不得致命中断」是团队自己认下的契约；
而 `4558e65` 当时的用例 fixture 恰好带了 `TARGET_STATES=""`，所以这条漏掉了。

**建议修法（小编）：** 把「读可能不存在的规则键」统一改成带默认值，例如

```bash
if [ "$BALANCE_MODE" != "off" ] && [ -n "${TARGET_STATES:-}" ]; then
```

同类位置：`lib/realm.sh:411,413`、`lib/rules.sh:690,738,771,970`、
`lib/realm.sh:391,400`、`lib/rules.sh:1806,1808,1809,2234,2238,2478-2488`、
`lib/rules.sh:965-971`、`lib/health.sh:211` 等。

**当前是否影响线上：** ❌ 否。产品代码目前**没有**启用 `set -u`
（已全仓确认：`set -u` 只出现在 `tests/` 里）。所以这是**健壮性缺口**，不是线上崩溃。

**回归方式：** 小编改完后，用**同一个**冻结点或新 SHA 重跑 `run_tests.sh`，
T33 应转绿，且 T31 / T28 / T32 不得转红。

---

### 🟡 P2 · 低 · 台架自身的两处误报（已在本轮修掉，非产品缺陷）

| 编号 | 问题 | 根因 | 修法 |
|------|------|------|------|
| 台架-1 | T01/T02/T04/T05/T07/T08 **假绿**（读不到任何文件 → 0 命中 → 判过） | 用例文件在**沙箱建好之前**被 source，文件头把路径快照成变量时 `$SBX_SRC` 还是空的 | 文件头不再快照路径；用例函数体内直接用 `"$SBX_SRC"`（已在 README「硬规矩」第 3 条写死） |
| 台架-2 | T27 恒红 | `_run_in_sandbox` 的参数错位：多传了一个 `_`，导致内层 `$2` 指向字面量 `_`，`source` 的是不存在的文件 | 去掉多余参数，内层 `$2` 正确指向提取出的探测函数文件 |

> 这两条属于「用例自己的缺陷」，已在第 2 轮修掉；列在这里是为了让审稿知道它们**曾经存在过**。

---

### 🟢 P3 · 信息 · 「探测实现 3 份拷贝」的判断在冻结点上已过时

原始需求写的是「全仓 `check_connectivity() {` 出现次数 == 1（`lib/health.sh` 内 2 份逐字重复 + `lib/failover.sh` 第 3 份）」。
**在 `a9102c1` 上实测：全仓共 2 份，都在 `lib/health.sh`，且第 2 份是生成脚本的内联副本（见 D 段）。**
第 3 份（`lib/failover.sh`）已在 `4558e65`「探测函数分层」中删除。

→ 断言已改写为更严的 4 条（总数 == 2 / 集中在 `lib/health.sh` / 第 2 份在生成函数体内 / 两份逐字一致）。
**这条不是产品缺陷，是需求前提过时。**

---

### 🔵 P4 · 信息 · 冻结点机制的必要性实证

跑批（11:18:21 起，约 9 分钟）期间，仓库 HEAD 从 `b361ca8` 前移到 `27fc74a`，
工作区新增 `lib/update.sh`、`tests/test_update.sh` 并改了 `lib/core.sh`、`lib/realm.sh`、`lib/ui.sh`、`xwPF.sh`。
若按第 1 轮的「读工作区」方式跑，这 9 分钟里测的就是**两个不同的代码**。
本次结论之所以可信，正是因为被测产物锚定在 `a9102c1`。

---

## 5. 覆盖盲区与待真机清单

### 5.1 台架内**未覆盖**的盲区

| 盲区 | 为什么没覆盖 | 影响 |
|------|--------------|------|
| 依赖 `jq` 的整段配置生成 | 本机没有 `jq`，也没打桩 | `lib/rules.sh` 里走 jq 的分支完全没测 |
| `lib/update.sh`（小编新增的更新功能） | 不在冻结点 `a9102c1` 里 | 需在新 SHA 上单独补用例 |
| 时延测量 + 负载均衡菜单渲染 | `tests/test_latency.sh` 未并入台架 | 覆盖在独立脚本里，门禁不认 |
| `xw_realm_OCR.sh` | 冻结态里存在但台架没有用例 | 一条都没测 |
| 规则文件的**真实增删改**（`add_rule` / `delete_rule` / `update_rule` 的落盘结果） | 只测了读与生成 | 落盘格式的回归靠 T20/T23 间接覆盖 |
| 多规则同端口的真实 realm 配置生成 | 沙箱里只生成 `config.json` 文本 | 没有真 realm 去消费它 |

### 5.2 待**真机**验证清单（本机无法覆盖）

| # | 待验证项 | 本机为什么不行 | 验证方式 |
|---|---------|--------------|---------|
| 1 | **CRLF 源在真 Linux 上的行为** | MSYS 读文件是文本模式，会吞掉 CR，本机永远「看起来正常」 | 把 `core.autocrlf=true` 的工作区拷到 Linux，`source` 一遍 |
| 2 | systemd timer 真机启停 | `systemctl` 是桩，只记录不执行 | 真机 `systemctl enable --now realm-health-check.timer` |
| 3 | 真 realm 转发（健康状态变化 → 流量真的切走） | 没装 realm，也没有真流量 | 真机 + 造一个挂掉的后端 |
| 4 | `nc` 桩与真 `netcat` 的 `-z` 行为差异 | 桩只模拟「命中即失败」 | 真机装 netcat / busybox nc 各跑一遍 T18 |
| 5 | `/dev/tcp` 回退在**真精简 VPS**（无 timeout 命令）上的行为 | 本机有 `timeout` | 找一个 `busybox` + 无 coreutils 的镜像 |
| 6 | `flock` 真锁语义（并发跑两份健康检查） | `flock` 是假锁 | 真机并发触发 timer |
| 7 | `bc` 真实表达式的浮点行为 | 桩只支持 `scale=N; a*b/c` | 真机跑权重计算路径 |
| 8 | 依赖 `jq` 的配置生成分支 | 本机无 jq | 装 jq 后重跑并新增用例 |
| 9 | 大规模规则（几十条）下的性能与内存 | 沙箱里只有 1–3 条 | 真机灌 50 条规则跑一遍 |
| 10 | shellcheck 静态检查 | 本机没装 | `shellcheck tests/*.sh tests/**/*.sh` |

---

## 6. 冻结点机制使用说明（Chief 怎么给我指定 SHA）

### 6.1 一句话

```bash
BASE_SHA=<sha> bash tests/run_tests.sh
```

跑批输出里会带上这个 SHA，报告里必须原样写出来。

### 6.2 完整用法

```bash
# 指定冻结点（推荐；环境变量与参数等价）
BASE_SHA=a9102c1 bash tests/run_tests.sh
bash tests/run_tests.sh --base-sha a9102c1

# 正式跑批建议连跑 3 轮，校验结果向量一致
BASE_SHA=a9102c1 bash tests/run_tests.sh --repeat 3

# 只跑某几条
BASE_SHA=a9102c1 bash tests/run_tests.sh --only T31,T33

# SHA 不存在 → 直接 exit 2（不会偷偷改成读工作区）
BASE_SHA=deadbeef bash tests/run_tests.sh   # 退出码 2
```

### 6.3 给 Chief 的操作建议

1. **提测时把 SHA 一起给。** 例：「请回归 `a9102c1`」，而不是「请回归最新」。
2. **回归时用同一个 SHA。** 小编修完后，若提交产生了新 SHA，**旧结论作废**，必须在新 SHA 上重跑整套。
3. **报告必须带这四项**：冻结点 SHA、冻结点标题、台架版本、产物指纹路径。
   台架输出里已经全有，直接抄。
4. **看结论前先对指纹。** `tests/baseline-manifest.txt` 里有每个被测文件的 sha256；
   两次跑的 manifest 对不上 → 被测对象变了 → 结论不可比。
5. **台架自己也带版本号**（`v2.0.0 (frozen-base)`）。台架改了会 bump，
   旧台架版本下的结论参考价值要打折。

### 6.4 现状

| 项 | 值 |
|----|----|
| 本轮冻结点 | `a9102c1a20719cb808f11f9f5bbe94dbefceab30` |
| 跑批时 HEAD | `27fc74a8d05f88ea6cb99eb3eb1552ee0ed39b20`（仅供对照，**不作为被测产物**） |
| 已知红灯 | T33（P1，`lib/realm.sh:411`） |
| 门槛 | 本轮 34 条中 **33 条通过**；T33 转绿后为 34/34（已在 df4721\ 上达成，见 BASELINE-round3.md） |

---

## 7. 附：证据位置

| 证据 | 路径 |
|------|------|
| 产物指纹 | `tests/baseline-manifest.txt` |
| 每条用例的 stdout / log / notes / fails / meta | 跑批时的 `$SBX_ROOT/cases/`（本机：`/tmp/xwpf-sbx.LfdWqn/cases/`） |
| 完整跑批输出 | 本机 `/tmp/r2_final.txt`（临时文件，不入库） |
| 第 1 轮报告 | `tests/BASELINE-round1.md` |
| 台架说明 | `tests/TEST-HARNESS.md` |
| 用例索引 | `tests/README.md` |
