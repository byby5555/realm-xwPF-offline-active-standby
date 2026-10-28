> **归档说明**：本报告基线锚定 `2244886`，后续结论以 `a9102c1` 及之后为准（Chief 已逐条复核：B1 已被 `4558e65` 修复，B2 / B4 / 假绿 / 探测函数三份拷贝在 `a9102c1` 仍成立）。
>
> ⚠️ **审稿实测更正（归档时补，不改动下方任何原始结论）**：上述括注中的「**假绿**」一项，审稿在归档时按「唯一门禁」口径复测后**已不成立** —— `tests/run_tests.sh` 在 `a9102c1` 上实测 **22 条全过、退出码 0**（详见下方附录 A-1）。B2 / B4 / 探测函数三份拷贝**复测仍成立**。行号引用在 `a9102c1` 及之后的漂移见附录 A-4。

# realm-xwPF-offline-active-standby · 第 1 轮基线审查报告

审稿人：审稿（bot_263632b9af01）　｜　审查时间：2026-10-24 10:32–10:48 (+08:00)　｜　性质：只读审查，未改动任何项目文件、未提交

---

## 一、审查结论（一句话）

**需返工。** 主备自动切换的端到端链路在提交态**跑不通**（健康检查脚本生成不出来、systemd timer 不落地），另有 3 处「同一逻辑两份实现」未收敛、1 处规则文件 `source` 注入面、1 处 CRLF 会静默掐断健康检查；测试台架正式入口 `tests/run_tests.sh` 实测 **22 条通过 16 失败 6（退出码 1）**，与提交信息里「全过」的声明不是同一套脚本。

**可以合并的前提**：下面「必须修改清单」第 1–5 条全部关闭。其余可后续优化。

---

## 二、快照锚点（务必先看这一段）

| 对象 | 标识 |
|---|---|
| 审查基线 | `HEAD = 2244886e0d86de99253f4780ee4e2f13227ffa0e`（`feat(standby): 权重含 0 自动进主备 + 自动开启主备路由`） |
| 分支 | `feat/auto-standby-on-zero-weight`（已推 `origin/feat/auto-standby-on-zero-weight`）；`main` 仍停在 `c45973b` |
| 工作区 | 仅 `tests/cases/01_static_contract.sh`、`tests/lib/sandbox.sh` 未提交修改 + 10 个未跟踪 `_check*.sh`/`_run.sh` 临时脚本 |
| 语法基线 | `bash -n` 遍历全部 tracked `.sh`：**0 失败**（作者自述属实） |

> ⚠️ **过程风险（须上报 Chief）**：本次审查期间（10:32→10:48）工作区被另一会话持续改写——新增 `lib/health.sh`、删除 `tests/run.sh`、改 4 个 docs、新增 `_check3..9` 临时脚本、并于 10:41:49 直接提交了 `2244886`。**审查对象是一个每分钟都在移动的活体**。本报告所有结论均锚定上述 SHA；若要复审，必须先冻结 commit 再让我看，否则结论会互相打架。
> 另注：`2244886` 之前我的部分中间观察已被该提交修复（如旧仓库名残留 6 处、runner ID 错位），本报告只列**在 2244886 仍成立**的问题。

---

## 三、实测证据（我真跑了，不是看自述）

用 Git Bash 5.3.9 实跑仓库自带台架：

```
tests/run_tests.sh      → EXIT=1   总计 22 条，通过 16，失败 6
tests/test_active_standby.sh → EXIT=0  PASS=27 FAIL=0
tests/test_connectivity.sh   → EXIT=0  PASS=9  FAIL=0
tests/test_e2e.sh            → EXIT=0  PASS=11 FAIL=0
bash -n (全部 tracked .sh)   → 0 failures
```

**红/绿两套并存**：提交信息验证的是后三个独立脚本（确实全绿），而**同一提交引入、且 `tests/README.md` 指定的正式入口 `tests/run_tests.sh` 是红的**。失败用例：`T07 / T16 / T17 / T20 / T22`（+1 条计数口径不一致）。

---

## 四、逐条问题

### 【阻断 B1】主备「自动切换」端到端跑不通：健康检查脚本根本没生成

- **位置**：`lib/rules.sh:2735-2750`（`ensure_health_check_service`）、`xwFailover.sh:37-53`（lib/health.sh 三路探测）、`lib/ui.sh:699-714`（`download_failover_script`）
- **现象**：T16 FAIL——`systemctl enable/start realm-health-check.timer` 一次都没被调用；T17 FAIL——`/etc/realm/health/health_check.sh`、`realm-health-check.service`、`realm-health-check.timer` **三个产物全部缺失**。
- **为什么是问题**：这条链是「权重含 0 自动进主备」的**唯一探测端**。`ensure_health_check_service` 要求 `/etc/realm/xwFailover.sh` 先存在；不存在时调 `download_failover_script`，而它**在运行时从 fork 的 `main` 分支下载**（`lib/ui.sh:700`）。`main` 目前停在 `c45973b`，该分支的 xwFailover.sh 还没有 health.sh 探测逻辑。下载失败 → 函数 `return 1` → 调用点只打印一行黄色警告 → **端口组已经是 active-standby、FAILOVER_ENABLED=true，但没有任何东西在探测，主挂了永远不切**。这是「静默降级」，不是「失败」。
- **建议改法**：
  1. `ensure_health_check_service` 失败时**必须回滚**主备开关（或至少把 `FAILOVER_ENABLED` 置回 false），不能让用户停在「以为有主备、实际没有」的状态；
  2. 别在运行时拉 `main` 分支，改为调用**本地已安装**的 `/usr/local/bin/lib/health.sh` 里的生成函数（`lib/health.sh:82` `health_check_script_body`），彻底去掉对 xwFailover.sh 版本的依赖；
  3. `bash "$failover_script" start` 的输出不要全吞（现在 `>/dev/null 2>&1`），失败时把 stderr 落到 journal 或 `/var/log/realm-health.log`。
- **严重级**：**阻断**（功能不成立，且失败不可见）

### 【阻断 B2】规则文件用 `source` 解析：命令注入面，且同一逻辑两份实现

- **位置**：`xwFailover.sh:65-72`（`read_rule_file` → `source "$rule_file"`）、`xwFailover.sh:75-91`（`read_rule_file_for_health_check` → `source "$rule_file"`）
- **对照（唯一正确的一份）**：`lib/rules.sh:206-238` —— 白名单逐行解析，明确注释「绝不使用 source / eval，文件内的 `$(cmd)`、反引号、换行注入全部不再被执行」。
- **现象**：`xwFailover.sh` 至今仍用 `source` 解析规则文件；它生成的 `/etc/realm/health/health_check.sh` 里也是同一段 `source`。
- **为什么是问题**：
  1. **注入**：`health_check.sh` 由 systemd 以 **root** 拉起，里面的 `source "$rule_file"` 会执行规则文件里的任何命令替换/反引号。规则文件的 `RULE_NAME`/`WS_PATH`/`TLS_SERVER_NAME` 等字段是用户可填内容。lib 侧已经把这条路堵了，故障转移侧却还开着。
  2. **单一真源**：同一个「读规则文件」有 3 份实现，**两份不安全、一份安全**——安全的那份被绕过了。
- **建议改法**：把 `lib/rules.sh:206-238` 的白名单实现提到 `lib/health.sh`（或 `lib/core.sh`）作为唯一真源，`xwFailover.sh` 与生成的 `health_check.sh` 全部改用它，**删除两处 `source` 版**。`read_rule_file_for_health_check` 与 `read_rule_file` 的区别只是「先 unset 一批变量」，可以用同一个函数 + 一份待清空变量清单实现。
- **严重级**：**阻断**（安全 + 单一真源）

### 【阻断 B3】CRLF 会静默掐断整条健康检查（这条就是行尾污染的真实后果）

- **位置**：`xwFailover.sh`（生成 health_check.sh 的那一份）、仓库根目录**无 `.gitattributes`**、`core.autocrlf=true`
- **现象**：T22 FAIL——「CRLF 源连 health_check.sh 都没生成出来（脚本在 CRLF 下直接跑挂了）」。
- **为什么是问题**：这正是审查清单第 1 项「行尾污染」的真实代价——**不是风格问题，是功能失效**。任何 CRLF 检出（Windows 全量检出、或手工 scp 覆盖、或 `autocrlf=input` 的机器）下，`xwFailover.sh` 解析异常 → `start_health_check_service` 不执行 → health_check.sh 不生成 → 主备永不自动切换，而且**全程无报错**。
  注意 `tests/cases/03_failover_runtime.sh` 的 T03（`git ls-files --eol`）在本机**永远绿**（autocrlf=true 保证索引必为 LF），所以现有台架**测不出**这个风险——只有 T22 用真实 CRLF 副本才暴露。
- **建议改法**：
  1. 加 `.gitattributes`：`*.sh text eol=lf`、`*.py text eol=lf`、`*.service text eol=lf`、`*.md text eol=lf`；
  2. `bootstrap` 下载后统一规整行尾（下载即 `sed -i 's/\r$//'`），别指望检出端；
  3. T03 补一条「工作区副本不得含 CR」的反向断言，别只看索引。
- **严重级**：**阻断**

### 【阻断 B4】`auto_enable_active_standby` 不清 `TARGET_STATES` → 主备目标列表可能来自陈旧剔除结果

- **位置**：`lib/rules.sh:2695-2731`（`auto_enable_active_standby`：只写 `BALANCE_MODE` / `FAILOVER_ENABLED` + 5 个健康参数，**没有动 `TARGET_STATES`**）
- **对照**：同文件 `lib/rules.sh:2656-2657`（切回 roundrobin 分支）**明确清空了** `TARGET_STATES`。
- **现象/为什么是问题**：`lib/realm.sh:411-413` —— `BALANCE_MODE != off` 且 `TARGET_STATES` 非空时，目标列表**直接取 `TARGET_STATES` 而不是 `REMOTE_HOST`**。该端口历史上若跑过「剔除模式」（`lib/rules.sh:587 sync_target_states_for_port` 会写 `TARGET_STATES`），残留值会让主备模式拿到一份陈旧的目标列表：备机丢失、权重索引与目标错位、且不会有任何提示。
- **建议改法**：`auto_enable_active_standby` 落盘时同步 `sed -i "s|^TARGET_STATES=.*|TARGET_STATES=\"\"|"`，与 2657 行保持同一口径。
- **严重级**：**阻断**（主备切到一份不完整的目标集合）

### 【需返工 R1】`lib/health.sh` 内部仍有**两份** `check_connectivity`，作者自己在注释里承认

- **位置**：`lib/health.sh:18-44`（共用实现）与 `lib/health.sh:128-154`（`health_check_script_body` 的 heredoc 内联副本）
- **作者自述**：`lib/health.sh:8-11` ——「生成的 health_check.sh 是一份**独立可执行**的脚本……所以它的探测逻辑在下面 health_check_script_body 里另有一份内联副本，**改动 check_connectivity 时两处必须同步**」。
- **为什么是问题**：抽取前有 4 份探测实现，抽取后是 3 份（`lib/health.sh` ×2 + `lib/failover.sh:105-110` `failover_probe_reachable`）。「唯一真源」只做到一半，且把「必须手工同步两处」写进了注释——这正是回归的温床。`tests/test_connectivity.sh` 那句「lib/health.sh 与 health_check.sh 的探测实现一致」目前是**人工核对**，不是自动守卫。
- **建议改法**（三选一，按推荐度排序）：
  1. **让生成脚本直接 source 已安装的 lib/health.sh**：生成的 `health_check.sh` 首行 `. /usr/local/bin/lib/health.sh`，把 `check_connectivity` / `read_rule_file` 从 heredoc 里删掉 → 全仓只剩 1 份。前提是安装/升级/卸载三条路径都要把 `lib/health.sh` 与 `health_check.sh` 当同一对文件管（安装时 `lib/` 已在 `/usr/local/bin/lib/`，条件天然满足）。
  2. **函数体变量化**：把探测实现抽成 `PROBE_FUNC_BODY` 变量，heredoc 分片拼接。仍是两份文本，但由同一变量生成，**结构上不可能不同步**。
  3. 兜底：加一条 CI 守卫断言 `lib/health.sh` 内 `check_connectivity() {` 出现次数恒为 1。
- **严重级**：**需返工**

### 【需返工 R2】`lib/failover.sh` 的探测是第三种写法，没跟上

- **位置**：`lib/failover.sh:105-110`
- **现象**：`failover_probe_reachable()` 只用 `timeout 3 bash -c "</dev/tcp/${host}/${port}"`，**硬编码超时 3 秒**、**没有 nc 分支**、**没做 `command -v timeout` 兜底**。
- **为什么是问题**：与 `lib/health.sh` 的语义已经分叉——同一个「目标是否可达」问题，现在有两套不同超时、不同手段、不同失败语义的实现。而 `cmd/xwpf-failover.py` 的守护进程正是在这条链上做主备判定（`lib/failover.sh:362 / 484`）。
- **建议改法**：`failover_probe_reachable` 改为转调 `check_connectivity "$host" "$port" "${CONNECTION_TIMEOUT:-3}"`，并把 `lib/health.sh` 加进 `lib/failover.sh` 的依赖顺序。
- **严重级**：**需返工**

### 【需返工 R3】文档行号引用大面积失效（脚本全量校验）

- **位置**：`docs/health-check-and-failover.md:47-51`、`docs/port-groups-and-weights.md:151-172`、`docs/install-and-upgrade.md:351`、`docs/troubleshooting.md:105`
- **现象**：我写脚本把 docs/README 里所有 `文件:行号` 形式的引用逐条回查：
  - 对 `HEAD=2244886`：**19 处**指向文件末尾之外（如 `lib/rules.sh:2695-2730`，而该文件只有 2374 行；`lib/realm.sh:1042-1062`，而该文件只有 1023 行）；
  - 对重构后的工作区：另有 **13 处**失效（如 `xwFailover.sh:724-728`，重构后该文件只剩 645 行）。
- **为什么是问题**：文档引用的是**一个从未作为提交存在过的中间态行号**——写文档时按的是工作区，提交时按的是另一个状态。用户按文档定位会扑空，排障时更误导。
- **建议改法**：文档**只写函数名不写行号**（`validate_weight_input` 而不是 `lib/rules.sh:2401`）；若坚持要行号，加一条测试守护引用有效性——这类漂移本可以被自动拦下。
- **严重级**：**需返工**（低成本，但影响排障）

### 【需返工 R4】仓库内**两套测试台架**，正式入口是红的，验收用的是另一套

- **位置**：`tests/run_tests.sh`（README 指定的正式入口，22 条，**红**）vs `tests/test_active_standby.sh` + `tests/test_connectivity.sh` + `tests/test_e2e.sh`（提交信息用来验收的三套，绿）
- **现象**：`2244886` 的提交信息写「tests/test_active_standby.sh 27 项、tests/test_connectivity.sh 9 项、tests/test_e2e.sh 11 个场景全过」——这三套我实测确实全过。**但同一提交引入并写进 `tests/README.md` 的 `tests/run_tests.sh` 实测 22 条通过 16 失败 6，退出码 1**。
- **为什么是问题**：验收对象与交付物不是同一个东西。Chief 看到的「全过」对不上仓库里文档化的入口。另有两套台架 = 两份用例编号体系、两份沙箱约定，后续必然继续漂移。
- **建议改法**：合并为**一套**（保留 `tests/run_tests.sh` 作为唯一入口，把另三套的场景并入 `tests/cases/`），提交信息里的验收口径改为「`tests/run_tests.sh` 全绿」。
- **严重级**：**需返工**

### 【需返工 R5】6 条红用例里，至少 3 条是**测试自己写错**，不是产品缺陷（假红）

- **T20**（`tests/cases/03_failover_runtime.sh:287-294`）：`bad=$(... | grep -c . || echo 0)` —— `grep -c .` 命中 0 条时**先打印 "0" 再以退出码 1 触发 `|| echo 0`**，于是 `bad="0\n0"`，断言 `"0"` 必然不等 → **恒红**。真实检查结论是 0 条违例。
- **T07**（`tests/cases/01_static_contract.sh:202-205`）：要求 `test_e2e.sh` **和** `tests/test_e2e.sh` **两个路径都存在**才算过。但文档 `docs/active-standby-logic.md:135` 引用的是 `tests/test_e2e.sh`（实际存在）→ **期望写错导致恒红**。
- **T06**（`tests/cases/01_static_contract.sh:164-176`）：断言 `grep -c '/dev/tcp' xwFailover.sh == 1`。抽取后该逻辑已迁到 `lib/health.sh`，xwFailover.sh 里是 0 → **断言钉在「实现放在哪个文件」上**，重构必红。
- **建议改法**：T20 去掉 `|| echo 0`（或改 `$(... || true)` 后单独计数）；T07 只校验**文档实际引用到的那个路径**；T06 改成断言「探测实现存在于**唯一**真源文件」+「全仓 `check_connectivity() {` 出现次数 == 1」，把位置约束换成唯一性约束。
- **严重级**：**需返工**（测试自身缺陷，但会让真回归被噪声淹没）

### 【需返工 R6】README 同一文件里两种互斥的主备语义

- **位置**：`README.md:266` vs `README.md:270`
- **现象**：266 行写「严格主备：1 主 N 备**按顺序接替**。健康检查对所有目标独立探测（**不依赖权重**）」；270 行写「直接用**权重含 0** 触发主备（推荐）……填 `1,0,0`（1=主，0=备）」。**同一文件、相隔 4 行，描述的是两种不同的主备选主算法。**
- **为什么是问题**：实现已改成**按权重降序选主**（`lib/realm.sh:489-513`）。按 266 行理解的用户会按「原始顺序」排障，按 270 行理解的用户按「权重」排障——两者结论可能相反。`docs/active-standby-logic.md` 也只改了 2 行（该提交 `docs/active-standby-logic.md | 2 +-`），大概率没跟上。
- **建议改法**：以权重语义为准，统一改写 266 行；明确写出「权重只决定**优先级**，不决定分流比例；同一时刻只有一个主承载流量」。
- **严重级**：**需返工**（文档误导会直接带偏排障）

### 【需返工 R7】「权重含 0」会静默改写负载均衡模式，并拉起常驻守护进程

- **位置**：`lib/rules.sh:2624-2638`
- **现象**：只要权重序列**含任一 0**，就自动执行 `auto_enable_active_standby`（切 active-standby + 开故障转移 + `ensure_health_check_service` 拉 systemd timer）。
- **为什么是问题**：在本次改动之前，`2,0,3` 在轮询模式下是**完全合法**的语义（「第二台不分流量」）。现在同样一次输入会把端口组从 roundrobin/iphash 改成主备、打开故障转移、并在机器上常驻一个 systemd timer。**这是一个老配置下的合法操作，现在变成了模式切换 + 静默副作用**，而用户只是去改了个权重。
- **建议改法**：自动切换前**必须二次确认**（当前只有 `preview_port_group_weight_config:2543-2548` 打印提示，`apply` 直接执行）；或限定「仅当该端口原本不是负载均衡模式时才自动切」；把「本次改动会改变该端口的负载均衡模式与故障转移开关」写进确认提示。
- **严重级**：**需返工**

### 【需返工 R8】切回分支把 `BALANCE_MODE` 一律写成 `roundrobin`，`iphash` 被抹掉

- **位置**：`lib/rules.sh:2656`
- **现象**：`sed -i "s/^BALANCE_MODE=.*/BALANCE_MODE=\"roundrobin\"/" "$mode_rule_file"` —— 无条件覆盖。
- **为什么是问题**：用户在 iphash 模式下把权重改成全正 → 被静默改成 roundrobin。`iphash` 是 `lib/rules.sh:249` 明确支持的模式，用户没要求改它。
- **建议改法**：只在当前模式是 `active-standby` 时改写（此处的前置判断已经是 active-standby，**但真正改写时没有保留原模式**）；正确做法是恢复成**进入主备前**记下的原模式，或在确认时让用户选目标模式。
- **严重级**：**需返工**

### 【建议 S1】权重落盘按**规则序号**，与展示给用户的**目标索引**错位

- **位置**：`lib/rules.sh:2575-2598`（`apply_port_group_weight_config` 用 `rule_index` 取 `weight_array[rule_index]`）vs `lib/rules.sh:2242-2267`（展示的 `targets` 是把每条规则的 `REMOTE_HOST` 按逗号展开后的**目标**序列）
- **现象/为什么是问题**：一条规则的 `REMOTE_HOST` 写多个地址时，`rule_index ≠ 目标索引`。举例：规则A `REMOTE_HOST="1.1.1.1,2.2.2.2"`、规则B `"3.3.3.3"`，目标数 3、用户填 `5,3,0` → 落盘变成 A=`"5,3,0"`、B=`"3"`（B 的真实权重是 0，落成 3）。运行期靠 A 的全量串还能算对，但**落盘数据模型已经错位**；之后删除目标时 `lib/rules.sh:547-573 remove_target_from_states` 按目标索引重算权重，错位会被放大。
- **建议改法**：全量权重只存一份（规则索引 0），其余规则的 `WEIGHTS` 存**自己那个目标**的权重（按目标索引取，不是按规则索引取）；或干脆改为端口组级唯一权重表。
- **严重级**：建议（边缘但真实）

### 【建议 S2】`nc` 能力探测靠 `nc -h | grep -z` 字符串匹配，且每探测一次多 fork 两个进程

- **位置**：`lib/health.sh:24-28`
- **现象**：每个目标的每次探测都先跑一次 `nc -h` + 一次 `grep`，只为确认 nc 支持 `-z`。健康检查默认 4 秒一轮、每轮每目标各探一次。
- **为什么是问题**：一是**帮��文本格式探测**很脆（各家 nc 的 usage 文本排版不同，且 `-h` 在某些实现上不是帮助开关）；二是徒增进程数（而这正是 nc 相对 /dev/tcp 的卖点）。
- **建议改法**：脚本启动时探测一次并缓存结果；或反过来——**以 `bash /dev/tcp` 为主路径**（脚本本来就是 bash，`/dev/tcp` 必然可用），nc 只作可选加速。
- **严重级**：建议

### 【建议 S3】全仓无 `set -e` / `set -u` / `pipefail`，错误被静默吞掉

- **位置**：全仓（仅 `port-traffic-dog.sh:3` 有 `set -euo pipefail`）；典型吞错点 `lib/rules.sh:2746` `bash "$failover_script" start >/dev/null 2>&1`
- **为什么是问题**：没有 errexit，`ensure_health_check_service` 这类关键步骤失败也不会中断，加上 `>/dev/null 2>&1` 就彻底静默——这正是 B1 的放大器。
- **建议改法**：不要求全仓开 `set -e`（风险太大），但**关键失败路径必须可见**：把 stderr 写日志 + 返回非 0 + 调用点据此回滚。
- **严重级**：建议

### 【建议 S4】工作区卫生：10 个临时脚本 + 2 个未提交改动

- **位置**：`tests/_check.sh` … `_check10.sh`、`tests/_run.sh`（均未跟踪）；`tests/cases/01_static_contract.sh`、`tests/lib/sandbox.sh` 未提交修改
- **为什么是问题**：临时调试脚本留在 `tests/` 根下、且文件名以下划线开头（不像正式用例）；更关键的是**审查基线在漂移**（本轮我被改了 6 次）。
- **建议改法**：临时脚本移出仓库或加 `.gitignore`；给 `_check*` 这类一次性脚本固定放到 `tests/scratch/`；合并前提交或丢弃当前的 2 个改动。
- **严重级**：建议

### 【建议 S5】`lib/health.sh` 与 `lib/core.sh` 重复定义同一组路径常量

- **位置**：`lib/health.sh:13-16`（`CONFIG_DIR`/`HEALTH_DIR`/`HEALTH_STATUS_FILE`/`HEALTH_LOCK_FILE`）vs `lib/core.sh:76-79`（`CONFIG_DIR`/`HEALTH_STATUS_FILE`）
- **为什么是问题**：同一常量两个真源。`lib/health.sh` 用 `${X:-默认}` 兜底所以不会炸，但**默认值一旦分叉就会静默不一致**——健康检查读 A 路径、生成配置读 B 路径时，症状是「主备就是不切」，极难排查。
- **建议改法**：`lib/health.sh` 不再自带默认值，只做「若未定义则用 `lib/core.sh` 的值」；或把路径常量统一收到 `lib/core.sh`，`lib/health.sh` 只引用。
- **严重级**：建议

### 【建议 S6】`ensure_health_check_service` 运行时从 `main` 分支拉 xwFailover.sh → 版本漂移

- **位置**：`lib/rules.sh:2735-2749` → `lib/ui.sh:699-714`
- **为什么是问题**：本地 `lib/` 是安装时从同一分支拉的，但 xwFailover.sh 是**运行时**拉的。若本地装的是特性分支、远端 `main` 还是旧版，两者版本不同；更糟的是 `xwFailover.sh` 现在硬依赖 `lib/health.sh`（`xwFailover.sh:47-53` 找不到直接 `exit 1`），旧版 xwFailover.sh 根本没有这套逻辑 → B1 的具体成因。
- **建议改法**：按 B1 建议 2，改为调用本地 `lib/health.sh` 的生成函数，彻底去掉运行时下载。
- **严重级**：建议（但它是 B1 的技术根因，建议与 B1 一起改）

---

## 五、三个专项回答

### 专项 1：健康检查逻辑当前散落在哪几处？抽出 `lib/health.sh` 后会不会留下两份拷贝？收敛方案？

**散落位置（HEAD=2244886 实际状态）：**

| # | 位置 | 内容 | 抽取后状态 |
|---|---|---|---|
| 1 | `lib/health.sh:18-44` | `check_connectivity`（nc → /dev/tcp 回退） | 新的共用真源 |
| 2 | `lib/health.sh:128-154` | `check_connectivity`（`health_check_script_body` 的 heredoc 内联副本） | **仍在，两份** |
| 3 | `lib/failover.sh:105-110` | `failover_probe_reachable`（硬编码 timeout 3，只有 /dev/tcp） | **未动，第三份** |

**规则文件解析另有三份：** `lib/rules.sh:206-238`（白名单，安全）/ `xwFailover.sh:65-72`（source）/ `xwFailover.sh:75-91`（source）。

**会不会留两份拷贝？会。** 抽取把连通性探测从 4 份降到 3 份，**没有做到唯一真源**；作者在 `lib/health.sh:8-11` 用注释把「两处必须手工同步」固化了下来。健康检查的**服务管理**部分（`start_health_check_service` / `stop_health_check_service` / unit 生成）确实干净地搬进了 `lib/health.sh`，`xwFailover.sh` 改成 source 它——**这部分收敛是成功的，dedupe 没问题**；问题只出在「生成的 health_check.sh 必须是独立可执行脚本」这个约束上。

**收敛方案（按推荐度）：**

1. **首选：让生成的 health_check.sh source 已安装的真源。**
   `health_check.sh` 首行 `. /usr/local/bin/lib/health.sh`，从 heredoc 里删掉 `check_connectivity` 与 `read_rule_file` 两个副本。`lib/` 本来就装在 `/usr/local/bin/lib/`（`xwPF.sh:8` `LIB_DIR="$INSTALL_DIR/lib"`），路径条件天然满足；`xwFailover.sh:37-45` 已经有现成的三路探测逻辑可复用。
   - 前置条件：安装/升级/卸载三条路径都要把 `lib/health.sh` 与 `/etc/realm/health/health_check.sh` 当同一对文件管理（升级时必须重新生成 health_check.sh，卸载时必须一起删）。
   - 风险：`health_check.sh` 从「自包含」变成「依赖一个文件」，systemd 侧的失败模式从「跑不起来」变成「source 失败」——必须让 `source` 失败时**响亮退出**（`set -e` 或显式检查）。
2. **次选：函数体变量化。** 探测实现抽成 `PROBE_FUNC_BODY` 变量，heredoc 分片拼接。仍是两份文本，但由同一变量生成，**结构上不可能不同步**。改动量比方案 1 小。
3. **兜底（无论选哪个都要做）：加自动守卫。** 断言「全仓 `check_connectivity() {` 出现次数 == 1」「`lib/failover.sh` 不再自带探测实现」，把这条纪律写进 CI 而不是注释里。

**另外必须一并做的（B2）：** 把 `lib/rules.sh:206-238` 的白名单解析提升为唯一真源，删掉 xwFailover.sh 两处 `source` 版。否则「健康检查唯一真源」只统一了探测函数，解析函数仍分叉。

### 专项 2：主备权重语义的缺口（缺口定位到具体行）

**当前状态（HEAD=2244886）：**

| 环节 | 位置 | 状态 |
|---|---|---|
| 全 0 权重是否允许 | `lib/rules.sh:2401-2438` | ✅ 已拒绝（`2431-2435`：`total_weight -eq 0` 直接返回 1，提示「不能全部为 0」）——**本次提交已修好 Chief 提的这个缺口** |
| `1,0,0` → `BALANCE_MODE` | `lib/rules.sh:2695-2731` `auto_enable_active_standby` | 写入 `BALANCE_MODE="active-standby"` ✅ |
| `1,0,0` → `FAILOVER_ENABLED` | 同上 | 写入 `FAILOVER_ENABLED="true"` ✅ |
| `1,0,0` → 端口组优先级顺序 | `lib/realm.sh:489-513` | 按权重**降序**稳定排序，`0,10` → 第二个当主 ✅ |
| 选主后生成的实际权重 | `lib/realm.sh:525-537` | 强制压成 `1,0,0`（只留一个主） |
| 触发条件 | `lib/rules.sh:2624` | **任意含 0 即触发** |

**仍存在的缺口（6 个）：**

1. **缺口 A（阻断，B4）**：`auto_enable_active_standby`（`lib/rules.sh:2695-2731`）**不清 `TARGET_STATES`**，而 `lib/realm.sh:411-413` 会用 `TARGET_STATES` 覆盖 `REMOTE_HOST` → 主备目标列表可能来自陈旧剔除结果。对照 `lib/rules.sh:2656-2657` 切回分支是清了的。
2. **缺口 B（需返工，R7）**：触发条件是「**含 0**」而不是「**需要主备**」。`2,0,3` 在轮询模式下原本合法，现在会静默切模式 + 开故障转移 + 拉常驻 timer。
3. **缺口 C（需返工，R8）**：切回分支 `lib/rules.sh:2656` 无条件写 `roundrobin`，`iphash` 被抹。
4. **缺口 D（需返工，R6）**：**多主语义未定义**。UI 文案 `lib/rules.sh:2380` 说「权重>0 的目标当主，权重=0 的目标当备」（复数主），实现 `lib/realm.sh:525-537` 只保留一个主 —— 用户填 `5,3,0` 时第二台的真实流量被静默丢弃。README:266 写的也是「1 主 N 备」。**文案、实现、文档三方不一致。**
5. **缺口 E（建议，S1）**：权重落盘用 `rule_index`（`lib/rules.sh:2575-2598`），展示用的是目标索引（`lib/rules.sh:2242-2267`）→ 一条规则多地址时错位。
6. **缺口 F（阻断，B1）**：以上全部依赖健康检查服务真的被拉起来，而 `ensure_health_check_service`（`lib/rules.sh:2735-2750`）在提交态跑不通（T16/T17 红）→ **权重语义实现得再对，运行时也不会切换**。

**建议的语义定义（供小编对齐文档）：**
> 权重序列 = 目标优先级。含 0 → 该端口组进入 active-standby 严格主备：按权重降序排列，**同一时刻只有一个主承载 100% 流量**，其余为备（权重 0）。权重值本身不表示分流比例。至少一个目标权重 > 0（全 0 拒绝）。目标数与权重个数不符时按原始顺序退化处理。

### 专项 3：`health_check.sh` 落地路径 `/etc/realm/health/` 与 systemd unit 名称是否一致？

**一致，核对结果如下：**

| 项目 | 生成代码 | 文档 | 结论 |
|---|---|---|---|
| 脚本路径 | `xwFailover.sh` / `lib/health.sh:87` → `/etc/realm/health/health_check.sh` | `docs/install-and-upgrade.md:145` | ✅ 一致 |
| `HEALTH_DIR` | `/etc/realm/health` | 同上 | ✅ 一致 |
| service unit | `/etc/systemd/system/realm-health-check.service` | `docs/health-check-and-failover.md:133` | ✅ 一致 |
| timer unit | `/etc/systemd/system/realm-health-check.timer` | `docs/health-check-and-failover.md:155` | ✅ 一致 |
| unit 引用关系 | timer 的 `Requires=realm-health-check.service` | 同上 | ✅ 一致 |
| `ExecStart` | 指向生成脚本真实路径 | 同上 | ✅ 一致 |
| 状态文件 | `/etc/realm/health/health_status.conf` | — | ✅ 与 `lib/core.sh:79` 一致 |
| 锁文件 | `/var/lock/realm-health-check.lock` | `docs/health-check-and-failover.md:212` | ✅ 一致 |

**但落地路径有一个真问题（属 R6/S6）：**
`xwFailover.sh` 装在 **`/etc/realm/`**，而它依赖的 `lib/health.sh` 装在 **`/usr/local/bin/lib/`** —— **跨目录依赖**，靠 `xwFailover.sh:37-45` 的三路探测兜底。好在兜不住时是**显式 `exit 1` 并打印「缺少 lib/health.sh，请先执行 pf install」**（`xwFailover.sh:50-53`），不是静默降级——这点设计是对的，予以肯定。

**真正会出事的是 B1 + B3 的组合**：若 `/etc/realm/xwFailover.sh` 是运行时从 `main` 分支拉的旧版，它根本不认识 `lib/health.sh`；若它是 CRLF 版，它连 `start` 都跑不起来。**两条路都通向「主备不切换且无报错」。**

---

## 六、必须修改清单（给小编的返工单，按此顺序做）

| # | 事项 | 位置 | 级别 | 验收标准 |
|---|---|---|---|---|
| 1 | 修 `ensure_health_check_service`：改为调用本地 `lib/health.sh` 生成函数，不再运行时下载 xwFailover.sh；失败必须回滚主备开关并留日志 | `lib/rules.sh:2735-2750`、`lib/ui.sh:699-714` | 阻断 | `tests/run_tests.sh` 的 T16/T17 转绿 |
| 2 | 删除 `xwFailover.sh` 两处 `source` 规则文件解析，改用白名单真源 | `xwFailover.sh:65-72`、`75-91`、`lib/rules.sh:206-238` | 阻断 | 全仓 `source "$rule_file"` 归零；新增用例断言 |
| 3 | 加 `.gitattributes`（`*.sh text eol=lf` 等）+ bootstrap 下载后统一去 CR | 仓库根、`.gitattributes`、`xwPF.sh:31-51` | 阻断 | T22 转绿；新增「工作区副本无 CR」断言 |
| 4 | `auto_enable_active_standby` 落盘时清空 `TARGET_STATES` | `lib/rules.sh:2695-2731` | 阻断 | 新增用例：先制造非空 `TARGET_STATES`，再调 `auto_enable_active_standby`，断言 `TARGET_STATES=""` |
| 5 | `lib/health.sh` 去重：按专项 1 的方案 1 或 2 收敛到 1 份；`lib/failover.sh:105-110` 改调 `check_connectivity` | `lib/health.sh:18-44`、`128-154`、`lib/failover.sh:105-110` | 需返工 | 全仓 `check_connectivity() {` 出现次数 == 1（加断言） |
| 6 | 权重含 0 的自动切模式加二次确认，或限定「仅非 LB 模式才自动切」 | `lib/rules.sh:2624-2638` | 需返工 | 新增用例：roundrobin 端口填含 0 权重 → 断言未自动改模式（除非确认） |
| 7 | 切回分支保留原模式，不得把 `iphash` 写成 `roundrobin` | `lib/rules.sh:2656` | 需返工 | 新增用例：iphash 端口填全正权重 → 断言模式不变 |
| 8 | 统一 README 与 docs 的主备语义（权重=优先级，不是分流比例；同时只有一个主） | `README.md:266`、`README.md:270`、`README_EN.md` 对应段、`docs/active-standby-logic.md` | 需返工 | 全文检索无「按顺序接替」「不依赖权重」与权重语义并存 |
| 9 | 修 T07 / T20 / T06 三条测试自身的错误期望；把另三套脚本并入 `tests/run_tests.sh`，只留一套台架 | `tests/cases/01_static_contract.sh:164-205`、`tests/cases/03_failover_runtime.sh:287-294` | 需返工 | `bash tests/run_tests.sh` 退出码 0，且是仓库唯一入口 |
| 10 | 清理 docs 里失效的行号引用，改为引用函数名 | 5 个文档文件，共 19+13 处 | 需返工 | 全部引用可在对应文件中定位到目标符号 |

---

## 七、建议优化清单（可后续，不挡合并）

1. `lib/health.sh:24-28`：nc 能力探测改为启动时缓存一次；或以 `/dev/tcp` 为主、nc 只作加速。
2. `lib/rules.sh:2575-2598`：权重落盘改用目标索引，消除与展示序列的错位。
3. `lib/health.sh:13-16` vs `lib/core.sh:76-79`：路径常量收敛到一处。
4. 关键失败路径不要 `>/dev/null 2>&1`（`lib/rules.sh:2746`），至少写日志。
5. `tests/` 下 `_check*.sh`/`_run.sh` 临时脚本移出仓库或加 `.gitignore`。
6. `xwFailover.sh:62-63`：重构后残留的空注释 `# 连通性检查`（函数已搬走），顺手删掉。
7. `docs/health-check-and-failover.md:439` 已自问「是否要改 `After=network-online.target`」——建议改（开机瞬间误判故障），但属于独立议题。
8. 给 `.gitattributes` 之外再补一条 `git ls-files --eol` 的 CI 门禁（工作区 + 索引双查）。

---

## 八、盯住不放的架构隐患

1. **「唯一真源」目前靠注释维持，而不是靠结构维持。** `lib/health.sh:8-11` 那句「改动 check_connectivity 时两处必须同步」，本质是把回归风险写进注释。下一轮改探测逻辑时，几乎必然漏改一处——而漏改的后果是「健康检查用旧逻辑判断故障」，线上表现为莫名切换或莫名不切换。**建议把「唯一真源」做成 CI 可断言的硬约束。**
2. **安全实现与不安全实现并存，且不安全的那条在生产链路上。** lib 侧已经堵上 `source` 注入，故障转移侧还开着；由 systemd 以 root 拉起。安全修复必须**全链路同时**落地，否则「加固了主程序、旁路了守护进程」等于没加固。
3. **运行时从 `main` 分支拉脚本 = 版本漂移的长期温床。** 本地 lib 是安装时快照、xwFailover.sh 是运行时拉取、health_check.sh 又是运行时生成——**同一次主备决策涉及三个不同时间点的代码**。建议长期把 xwFailover.sh 变成安装期产物。
4. **规则文件是「代码」还是「数据」的边界没有定死。** 现在一半按数据解析（lib 白名单）、一半按代码执行（source）。这个边界不定死，任何一次「顺手 source 一下」都会重新开出注入面。
5. **主备功能有三层开关**（`BALANCE_MODE` / `FAILOVER_ENABLED` / 健康检查服务是否真在跑），当前**没有任何一层会校验另外两层的一致性**。B1 已经演示了「开关都开着、探测端不存在」的状态。应该有启动时自检：开了主备就必须有健康的 timer，并在状态页显示「探测端：运行中 / 未运行」。
6. **审查基线在漂移。** 本轮审查期间工作区被并行会话改了 6 次、HEAD 移动 1 次。**建议引入「冻结点」机制**： Chief 指定一个 commit SHA，审稿只对该 SHA 出结论，改动后重新排队，而不是边改边审。

---

## 九、我没验证的部分（诚实声明）

1. **未在真实 Linux 上验证**：本机无 WSL / Docker，只有 Git Bash 5.3.9。`/dev/tcp` 回退在真机上的行为、systemd timer 的实际启停、`nc` 各发行版帮助文本是否真含 `-z`（T18 在沙箱里因 Git Bash 无 `/dev/tcp` 而无法完成对照），**均未经真实 Debian/Ubuntu 验证**。上线前请在最小化 Debian 上至少跑一次：装 netcat-openbsd / 不装 netcat 两条路径各验一轮。
2. **`nc -h` 能力探测的实际兼容性未实测**：不同发行版 nc 的 usage 文本排版不同，本报告按「脆弱探测」定性，**没有断言它一定失效**。建议在目标机实测 `nc -h 2>&1 | grep -q -- '-z'` 的返回值。
3. **未审 `cmd/xwpf-failover.py`（246 行）与 `lib/failover.sh` 的守护逻辑细节**，本轮只覆盖到「探测实现分叉」这一层。
4. **未审 `port-traffic-dog.sh`（2459 行）、`speedtest.sh`（1287 行）、`xw_realm_OCR.sh`**，本轮只核了它们的下载地址与旧仓库名残留。
5. **提交信息里「重构前后生成的 health_check.sh 逐字节一致（6720 bytes）」未复现验证**——缺重构前版本作对照。

---

*审稿人：审稿（bot_263632b9af01）　｜　基线：`2244886`　｜　本报告未改动仓库任何文件。*

---

# 附录 A　归档期复测与新发现（2026-10-24，审稿补记）

> 本附录为归档时补记，**不改动上方第 1~9 节的任何原始结论**。
> 所有结论均标注了成立的 SHA。

## A-1　「假绿」一项实测已不成立（对 `a9102c1` 成立）

**口径**：唯一入口 `tests/run_tests.sh`，**从干净 clone + `git checkout <SHA>` 导出被测产物**（不使用工作区文件），逐 SHA 实测。

| SHA | 退出码 | 汇总 | 失败用例 |
|---|---|---|---|
| `2244886` | 1 | 22 条 / 通过 14 / 失败 **8** | T02 T05 T06 T07 T16 T17 T20 T22 |
| `a9102c1` | **0** | 22 条 / **全过** | — |
| `9d49653` | 0 | 22 条 / **全过** | — |

**结论**：第 1 轮报告 R4 / R5 指出的「正式入口是红的」在 `a9102c1` 上**已被 `4558e65` 修掉**——该提交把 T02（加 `':(exclude)tests'` 排除自我匹配）、T05（help 文档一致性）、T07（按文档实际引用路径校验）、T16/T17（健康检查服务生成）、T20（下载地址计数 `|| echo 0` 缺陷）、T22（CRLF 生成物）一并修好。

**但请注意：门禁全绿 ≠ 第 1 轮的缺陷已修。** 截至 `a9102c1`，下列三条**复测仍成立**：

| 第 1 轮编号 | 结论 | `a9102c1` 复测 | 证据 |
|---|---|---|---|
| **B2** 规则文件用 `source` 解析 | 成立 | **仍成立** | `xwFailover.sh` 中 `source "$rule_file"` 仍在 **第 68、89 行**，共 2 处 |
| **B4** `auto_enable_active_standby` 不清 `TARGET_STATES` | 成立 | **仍成立** | `lib/rules.sh:2695` 的函数体内**不含** `TARGET_STATES` |
| **R1** 探测函数三份拷贝 | 成立 | **仍成立** | `lib/health.sh` 的 `check_connectivity` 仍在 **第 33 行与第 143 行**各一份；`lib/failover.sh:105` 的 `failover_probe_reachable` 仍在 |

**新出现的风险（比第 1 轮更隐蔽）**：T06 被从「`xwFailover.sh` 里 `/dev/tcp` 命中次数 == 1」改写为「`lib/health.sh` + `xwFailover.sh` 合计 ≥ 1 处」（`tests/cases/01_static_contract.sh:179-184`）。这个改法本身是对的（第 1 轮 R5 建议的就是「别钉在实现放哪个文件上」），**但它把「唯一性」这条约束一起丢了** —— 现在**没有任何断言**能发现探测函数又变成了两份。也就是说：**门禁从「红着守错指标」变成了「绿着守不到点」**。

## A-2　唯一性守卫仍未落地（对 `a9102c1` / `9d49653` 成立）

团队铁律 #4 要求「`tests/run_tests.sh` 静态断言 `check_connectivity() {` 出现次数 == 1」。

**实测**：在 `a9102c1` 与 `9d49653` 的 `tests/` 全目录检索，**不存在任何针对 `check_connectivity` 定义数量的断言**。

**影响**：`lib/health.sh` 里那两份逐字相同的 `check_connectivity`（第 33 行 / 第 143 行）现在是**完全无人看守的**。下次改探测逻辑只改一处 → 一半目标用新逻辑、一半用旧逻辑 → 症状是「有的节点误判故障、有的节点永不切换」，**极难定位**。

**建议**（交 Chief 路由给阿测/小编）：在 `tests/run_tests.sh` 里加一条静态断言，例如「`lib/health.sh` 内 `check_connectivity() {` 出现次数 == 1，且 `lib/failover.sh` 内不出现 `check_connectivity() {` 定义」。

## A-3　归档过程中新发现的问题（本轮新登记，均未改动代码）

### A-3-1　健康状态的 key **只有 host、没有端口** → 同 host 多端口互相覆盖（对 `a9102c1` / `9d49653` 成立）

**位置**：写入端 `lib/health.sh:216-219`（`target_key="${RULE_ID}|${target}"`，`target` 是**裸 host**）；读取端 `lib/realm.sh:360`（`health_status["$host"]="$status"`）。

**现象**：探测是按 `host:REMOTE_PORT` 做的（`lib/health.sh:238` `check_connectivity "$target" "$REMOTE_PORT"`），但**状态文件里不记端口**，读取端又只用 **host** 做 map 的 key。

**为什么是问题**：两条规则指向**同一台机器的不同端口**时（很常见：一台服务器上跑多个转发端口），状态文件里有两行不同 `RULE_ID` 但 host 相同；读取端按 host 建 map → **后写的那行覆盖前一行** → 两个目标共用一个状态 → **其中一个的故障会连累另一个**，或坏的那个被判成好的。

**影响面**：直接决定真机验收的用例设计 —— **A-5/A-6 必须用两个不同的 host**（本清单用 `127.0.0.1` / `127.0.0.2`），**不能用同一 IP 的两个端口**，否则验出来的是 key 冲突，不是主备切换。

**另注**：文档 `docs/health-check-and-failover.md:243` 把第 2 字段写成 `TARGET`，**未说明它不含端口**，属文档表述缺口。

### A-3-2　测试台架硬依赖「被测目录是 git 仓库」→ 无法对安装产物/解包包做验收（对 `a9102c1` 成立）

**位置**：`tests/lib/sandbox.sh:107 / 127 / 153` —— 枚举待测文件用的是 **`git ls-files`**。

**现象（审稿亲历）**：最初用 `git archive <SHA>` 导出干净产物再跑台架，结果是 **22 条里 16 条红**，失败模式全是「函数 command not found」「落盘文件缺失」—— 因为导出目录**没有 `.git`**，`git ls-files` 返回空，**沙箱里什么都没拷进去**。

**为什么是问题**：这不是产品缺陷，但**直接限制了验收形态**：
- 台架**只能**对 git 检出做验证，**不能**对「下载下来的安装产物」「离线包」「解包目录」做验证；
- 而真机验收的产物恰恰是**安装后落盘的文件**（`/usr/local/bin/lib/*.sh` 等），不是 git 检出 → **两者之间存在一段台架覆盖不到的区间**（下载、落盘、行尾、权限、路径重写）。

**建议**：台架增加「无 git 模式」—— `git ls-files` 失败时回退到 `find . -name '*.sh'` 枚举；或增加一个「对落盘产物做验收」的入口（指定 `INSTALL_DIR` 而非仓库目录）。这条直接服务于 A-1 的覆盖面。

### A-3-3　落盘文件**未**做 CRLF 归一（对 `a9102c1` / `9d49653` 成立）

**位置**：`xwPF.sh:31-51`（`_download`）、`xwPF.sh:70-73`（下载 lib 到 `$LIB_DIR`）—— **下载后直接 `mv`，不做任何行尾处理**。

**背景**：`4558e65` 修的是 **heredoc 生成物**（18 处改为写前 `tr -d '\r'`），即「生成出来的 health_check.sh / unit / 规则文件」不再带 CR。这**不等于**「落盘的源文件是 LF」。

**为什么是问题**：若安装源本身是 CRLF（Windows 工作区打包的离线包、或人工 scp 覆盖），则 `/usr/local/bin/lib/*.sh` 带 CR → 被 `source` 时**变量值带尾随 `\r`** → `[ "$ENABLED" = "true" ]` 这类比较**全部失配** → 症状是「界面显示已启用、配置却是空的、realm 起不来」。`4558e65` 的提交信息自己也点出了这个机制（"被 source 时变量值带 \r 的规则文件（会让 BALANCE_MODE 的每次比较都失配）"），但**修的是生成端，不是安装端**。

**建议**：`_download` 落盘后统一 `tr -d '\r'`，或加 `.gitattributes`（`* text eol=lf`）并在安装时校验。**真机验收项 A-1 第 3 步的「落盘文件含 CR 数 == 0」就是针对这一条。**

## A-4　行号引用漂移表（归档时实测，不改 `docs/`、`lib/`）

对第 1 轮报告正文里出现的 `文件:行号` 引用逐条回查：

| 报告中的引用 | 在 `a9102c1` | 在 `9d49653` | 说明 |
|---|---|---|---|
| `xwFailover.sh:724-728` | **越界**（该文件仅 634 行） | **越界**（634 行） | 该引用源自第 1 轮 R3 中转述的 docs 旧引用；docs 侧已由 `b361ca8`（D-01）改为函数级引用 |
| `lib/rules.sh:2746` | **越界**（该文件 2742 行） | 有效 | 报告 S3 引用；该行应改为 `ensure_health_check_service` 函数名 |
| `lib/ui.sh:699-714` | 有效，但函数已移到 **636 行** | 636 行 | `download_failover_script` 上移 |
| `lib/health.sh:18-44` / `128-154` | 定义实际在 **33** / **143** 行 | 33 / **240** | 报告 R1 的区间引用需按上表换算 |
| `lib/health.sh:82`（`health_check_script_body`） | 实际 **97** | **194** | 同上 |
| `lib/health.sh:13-16`（路径常量） | 实际 13-16 附近已随函数位移 | — | 同上 |
| `lib/failover.sh:105-110` | **105**（未变） | 105（未变） | ✅ 仍有效 |
| `xwFailover.sh:65-72` / `75-91` | **65 / 75**（未变） | 65 / 75 | ✅ 仍有效（B2 证据） |
| `lib/rules.sh:206-238` | **206**（未变） | 206 | ✅ 仍有效 |
| `lib/rules.sh:2401-2438` | **2401**（未变） | **2464** | 随更新中心改动位移 |
| `lib/rules.sh:2695-2731` | **2695**（未变） | **2758** | 同上 |
| `lib/rules.sh:2735-2750` | **2735**（未变） | **2798** | 同上 |
| `lib/realm.sh:489-513` / `525-537` | 有效 | 有效（`generate_endpoints_from_rules` 起点 335→320） | ✅ 仍有效 |
| `tests/cases/01_static_contract.sh:164-176` / `202-205` | 有效（T06 现为 164-185） | 同左 | ✅ 仍有效 |
| `tests/cases/03_failover_runtime.sh:287-294` | 有效 | 有效 | ✅ 仍有效 |

**结论**：第 1 轮报告正文共 62 处 `文件:行号` 引用，其中 **2 处越界**（`xwFailover.sh:724-728`、`lib/rules.sh:2746`）、**约 12 处行号已位移**。

**按纪律**：以上**只登记在附录**，**未改动 `docs/` 或 `lib/`**。建议后续把第 1 轮报告的引用统一改成**函数名级**（与 `b361ca8` 对 docs 做的 D-01 改造同思路），否则每挪一次代码就要重修一遍引用。
