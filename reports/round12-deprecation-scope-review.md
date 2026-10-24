# 第 12 轮只读复核：主备池整块废弃删除 · 文档口径重写返工单

> 审稿人：审稿（bot_263632b9af01）　｜　**复核时间**：2026-10-24 21:20–21:50 (+08:00)　｜　**性质**：**只读**复核，未改动 `lib/`、`tests/`、`docs/`、`cmd/`，未做任何 git 写操作
> **触发**：Chief 转达用户裁定 —— 「**主备池模式的都抛弃**」+「旧模式直接抛弃删除就可以了。就是普通的单端口中转，监听双端口或者多端口负载均衡和多端口 10,0 主备模式就可以了。」
> **复核时仓库 HEAD**：`2beb7bd`　｜　**锚点**：被测产物一律取自 `git show <SHA>:<path>`；凡涉及工作区未提交改动，一律标注「**在飞（未提交）**」并单独记账
> **本报告的产出边界**：审稿只写 `reports/**`。`docs/` 的改动由**小编**落地（第二节给出逐条返工单）；`lib/`、`xwPF.sh` 的改动由**小编**落地；`tests/` 由**阿测**落地。
> **组织方式**：按**产品功能模块**分节（转发与建池／主备守护与切换／健康探测端／安装升级／崩溃循环防护／交互菜单／文档与验收），每块说清「现状 → 已知问题 → 待办」。

---

## 〇、结论速览

**🟠 需返工（文档层）—— 代码侧删除已落地且干净，但 `docs/` 131 处 + `README.md` 19 处仍在描述一个已不存在的功能，且有指向已删文件的死链；真机 103 的流量迁移与残留清理尚未做。**

| 功能模块 | 现状 | 已知问题 | 待办 | 严重级 |
|---|---|---|---|---|
| **转发与建池** | 规则级路径完好（单端口中转 / 多端口负载均衡 / 权重 10,0 主备）；`lib/rules.sh` 的 `auto_enable_active_standby` 在 | 无 | 无 | 🟢 |
| **主备守护与切换** | 进程级主备池**已整块删除**（`cmd/xwpf-failover.py` / `.service` / `cmd/README-failover.md` / `lib/failover.sh` 整文件 / `failover.json` 池 / `failover_proxy_menu`） | 删除干净（8 个 `failover_*` 符号全仓 0 命中于代码） | 无 | 🟢 |
| **健康探测端** | **保留**（`lib/health.sh` 真源 + `health_check.sh` 生成物 + `lib/realm.sh` 的 `generate_endpoints_from_rules` 读端）；`xwFailover.sh` 是它的**规则级 CLI**，**不删** | 探测端产物在装/升级时不重新生成（= 静默失效）—— **在飞 N4 正在治** | 提交前改两处（`pkill` 自杀风险 / `failover.json` 改名与验收冲突） | 🟠 |
| **安装升级** | 在飞的 `xwPF.sh` 已把 `failover.sh` 移出模块清单、install/uninstall 都调 `_cleanup_legacy_failover_daemon` | 清理**机制**已在，**真机没跑过** | 真机 103 先迁流量再验残留 | 🔴 |
| **崩溃循环防护** | 随守护进程整块删除（systemd 限流 / drop-in / `Restart` 语义 / 退出码语义） | 文档仍在讲它 | `docs/` 清理 | 🟠 |
| **交互菜单** | `failover_management_menu`（调 `xwFailover.sh`）**保留**；`failover_proxy_menu`（主备池）已删 | 菜单标题写「**故障转移管理 (旧)**」—— 「(旧)」会让人以为是废弃项 | 建议改口径（见第五节） | 🟡 |
| **文档与验收** | 两份守护崩溃报告已加「⛔已废弃」声明；验收清单已重做（A-10 废弃 + A-11~A-15 新增） | `docs/` 131 处 + README 19 处 + 死链 | 按第二节返工单清理 | 🟠 |

---

## 〇之二、⚠️ 复核期间仓库推进了，本报告结论已按最新事实重核（2026-10-24 21:50 更新）

**写这份报告的过程中，仓库被并行推进了 7 笔提交**，本报告的结论**必须**按最新事实读，否则会给出错误的派工：

| 时间序 | 提交 | 内容 | 对本报告的影响 |
|---|---|---|---|
| T1 | `47acf47` | N3 守护进程双地址解析 | 「主备守护与切换」块的对象 |
| T2 | `c6d4fbf` | N3 建池双地址 + 限流后自动 reset-failed | 同上 |
| T3 | `2631637` | 主备状态可观测（菜单展示） | 同上 |
| T4 | `7c5f147` | 双地址口径文档 / 状态字段 / reset-failed 处置 / **本机不可验项清单** | 同上；且**是那个未跟踪文件的来源**（见第五节） |
| T5 | `5d4f8cf` | 权重 10 独占校验 + 探测超时预算 3 → 10 | 与本轮无关（保留路径） |
| T6 | `b2fb847` | **代提审稿的报告**（含本轮的状态声明与验收清单改动） | 已入库 |
| T7 | **`2beb7bd`** | **「删除进程级主备池整块（守护进程/建池/列池），保留规则级故障转移与权重主备」** | 「主备守护与切换」块**已收口** |

### 复核后的结论变化（**显式更正**）

| 原结论 | 现结论 | 依据 |
|---|---|---|
| 🔴 **阻断 1**：三笔 N3 提交与裁定方向相反，须先拍板怎么处理 | ✅ **已消解** —— `2beb7bd` **已把整块删掉**：`cmd/README-failover.md`（423 行）、`cmd/xwpf-failover.py`（579 行）、`cmd/xwpf-failover.service`（64 行）、`lib/failover.sh`（**整个文件 1148 行**）、`lib/ui.sh`（−319 行）全部移除 | `git show --stat 2beb7bd`；`git ls-files` 确认 `cmd/` 下已无 `xwpf-failover*`；`git show HEAD:lib/failover.sh` → **文件不存在** |
| 🔴 **阻断 2**：`xwFailover.sh` 会被误删 | ✅ **判断正确，且产品已正确处理** —— `xwFailover.sh` **仍在仓库里**；`lib/ui.sh` 的 `failover_management_menu`（`lib/rules.sh` 调它）仍用 `xwFailover.sh` 的 `toggle` / `config` / `status`；卸载段仍用 `xwFailover.sh stop` 停健康检查服务 | `git ls-files` / `git show HEAD:lib/ui.sh` / `git show HEAD:lib/rules.sh` |
| 🟠 **必做**：`docs/` 149 处待删 | ⬆️ **升为 131 处 + README 19 处 + README_EN 9 处**，且**性质更急了** —— 因为代码已删，**文档现在描述的是一个不存在的功能**，且**存在死链**（`cmd/README-failover.md` 已被删，但 `docs/health-check-and-failover.md` 仍指向它） | 第二节 |
| 🔴 **阻断 3**：真机 103 删守护会断转发 | ⬆️ **仍然阻断，且更紧迫** —— 删除已落地 ⇒ **残留清理与流量迁移还没做** | 第六节 |
| —（新增） | ⚠️ **新增风险**：代码已删，但 **`docs/` 仍有 131 处**、`README.md` 仍有 19 处 ⇒ **文档与实际功能分裂** | 第二节 |
| —（新增） | ⚠️ **新增悬空文件**：`docs/local-unverifiable-checklist.md` 未跟踪，内容全是已删功能的条目 | 第五节 |

> **★ 本报告的时效性声明**：本报告写作期间仓库在动。**第二节（docs/ 返工单）是本报告当前最有价值、且最有时效性的部分** —— 请以它为准。**第六节（真机顺序）**与**第五节（两个待决问题）**同样有时效性。

---

## 〇、结论速览（截至 `2beb7bd` + 在飞 N4 改动）

**🟠 需返工（文档层）—— 代码侧删除已落地且干净，但 `docs/` 131 处 + `README.md` 19 处仍在描述一个已不存在的功能，且存在指向已删文件的死链；真机 103 的流量迁移与残留清理尚未做。**

| # | 结论 | 严重级 | 依据 |
|---|---|---|---|
| **1** | **代码侧删除已落地且干净**：`cmd/xwpf-failover.*` + `lib/failover.sh` + `lib/ui.sh` 的守护部分全删；**无残留调用**（`failover_install_check` 等 8 个符号全仓 0 命中于代码） | ✅ 已完成 | 第三节 |
| **2** | **`xwFailover.sh` 不是守护进程 —— 判断正确，产品已正确保留**（它是保留路径的健康探测管理入口） | ✅ 已验证 | 第四节 |
| **3** | **`docs/` 131 处 + `README.md` 19 处**仍在讲被删功能；**`docs/health-check-and-failover.md` 的 §1.1 完整描述着 N3 双地址**（作废方向） | 🟠 **必做** | 第五节 |
| **4** | **死链**：`docs/health-check-and-failover.md` 仍指向**已删除**的 `cmd/README-failover.md`；`README.md` 仍列该文件 | 🟠 **必做** | §5.9 |
| **5** | **`docs/health-check-and-failover.md` §1.1 保留双地址叙述 = 把作废方向写进产品文档** | 🔴 **必做** | §5.1 |
| **6** | 两份崩溃循环报告**主题已废弃** → 已加状态声明；负载均衡路径结论**已迁出**到存活验收文档 | ✅ 已做 | 第六节 |
| **7** | 真机验收清单**已重做**：A-10 废弃 + 新增 A-11~A-15 | ✅ 已做 | 第七节 |
| **8** | **真机 103 有转发中断风险**：残留清理已写进 `xwPF.sh` 的 `_cleanup_legacy_failover_daemon`（在飞），但**流量迁移必须先做** | 🔴 **阻断（操作顺序）** | 第八节 |
| **9** | **在飞 N4 改动**（`lib/health.sh` +214 / `lib/update.sh` +24 / `xwPF.sh` +112）方向**正确**（重新生成探测端产物 = 治「静默失效」） | 🟢 方向正确 | §5.10 |
| **10** | 本轮**无 VPS 凭据** ⇒ 两个时间特性的**实测数字仍标「待补」** | ⏳ 待补 | 第九节 |

---

## 〇、结论速览（**原始版本，写于 `2631637` 时**——保留作决策留痕）

**🔴 阻断 —— 在「主备池整块删除」落地之前，有三笔已提交的 N3 双地址实现（`47acf47` / `c6d4fbf` / `2631637`）与用户裁定**方向相反**，且工作区还有 7 个文件在飞改动正在继续加码该方向；必须先裁定「这些提交怎么处理」，再动 docs/。**

| # | 结论 | 严重级 | 依据 |
|---|---|---|---|
| **1** | **三笔已提交 + 7 个在飞文件，全部是 N3 双地址实现 —— 正是用户裁定作废的方向** | 🔴 **阻断** | 第三节 |
| **2** | **`xwFailover.sh` 不是守护进程，是保留路径的健康探测入口 —— 误删会砍掉保留功能** | 🔴 **阻断（防误伤）** | 第四节 |
| **3** | `docs/` 里 **149 处**讲守护进程/崩溃循环防护的内容待删；**逐条返工单见第五节** | 🟠 必做 | 第五节 |
| **4** | 两份崩溃循环报告**主题已废弃** → 已加状态声明；负载均衡路径结论**已迁出**到存活验收文档 | ✅ 已做 | 第六节 |
| **5** | 真机验收清单**已重做**：A-10 废弃 + 新增 A-11~A-15 | ✅ 已做 | 第七节 |
| **6** | **真机 103 有转发中断风险**：守护删后不再监听 `18443`/`18444` ⇒ **必须先迁到权重路径再删** | 🔴 **阻断（操作顺序）** | 第八节 |
| **7** | 本轮**无 VPS 凭据** ⇒ 两个时间特性的**实测数字仍标「待补」** | ⏳ 待补 | 第九节 |

---

## 一、用户裁定的范围界定（审稿的读法，避免后续各说各话）

| 裁定 | 内容 | 机制落点 | 状态 |
|---|---|---|---|
| **作废** | 「主备 active/passive 池」整块 —— 独立守护进程、公开监听口 + 主/备后端、`failover.json` 池机制、崩溃循环防护（systemd 限流 / drop-in / `Restart` 语义 / 退出码语义那套） | `cmd/xwpf-failover.py`、`cmd/xwpf-failover.service`、`lib/failover.sh` 的建池/列池/删池/启停/安装那套、`xwPF.sh` 的 `failover_install_check` 调用 | **删除** |
| **保留** | ① 普通单端口中转 | `lib/rules.sh` 的规则生成 | 保留 |
| **保留** | ② 同端口多目标**负载均衡**（权重 5,5） | `lib/rules.sh` 的 `apply_port_group_weight_config` | 保留 |
| **保留** | ③ 同端口多目标**权重 10,0 主备**（主故障切备、主恢复切回） | `lib/rules.sh` 的 `auto_enable_active_standby` + `lib/health.sh` 的健康检查体（走 realm 规则 `TARGET_STATES`） | 保留 |
| **保留** | ④ **健康探测** | `lib/health.sh` 的 `health_check_script_body`（生成物 `health_check.sh`）+ `lib/realm.sh` 的 `generate_endpoints_from_rules`（读端） | 保留 |

> **⚠️ 命名陷阱（本次裁员最大的误伤来源）**
> **「权重 10,0 主备」保留，「进程级主备池」删除。** 两者都叫「主备」，但**机制完全不同**：
> - 权重主备：**没有独立进程**，靠 `realm-health-check.timer` 拉起生成物探测 → 翻 `WEIGHTS` → 写回 `config.json` → 重启 realm。
> - 进程级主备池：**独立守护进程** `xwpf-failover`，自己持有监听口，自己探测，自己转发。
> ⇒ **文档里凡是出现「主备」二字，必须能一眼看出是哪一套。** 建议统一叫法：**「权重主备」**（保留）与 **「主备池」**（已删除）。

---

## 二、审稿本轮核过的事实（全部可复现）

| 事实 | 核法 | 结果 |
|---|---|---|
| HEAD 已推进到 `2631637` | `git log --oneline -4` | 三笔新提交：**`47acf47` / `c6d4fbf` / `2631637`** |
| 这三笔是什么 | `git show --stat` | ① `cmd/xwpf-failover.py` +288/−29（双地址解析 + 探测结果分类 + 状态文件持久化）② `lib/failover.sh` +124/−16（N3 建池双地址 + 端口判定修正 + 限流后自动 reset-failed）③ `lib/ui.sh` +81/−8（主备状态可观测） |
| 工作区还有在飞改动 | `git status --short` | **7 个文件**：`cmd/README-failover.md`、`cmd/xwpf-failover.service`、`docs/README.md`、`docs/health-check-and-failover.md`、`docs/install-and-upgrade.md`、`docs/troubleshooting.md` + 新增未跟踪 `docs/local-unverifiable-checklist.md` |
| 在飞改动的方向 | `git diff -- docs/health-check-and-failover.md` | 正在把「realm 回环（旧模式）」改写成「**新池用双地址把这个问题修掉了**……探测打真实后端」——**即 N3 方向的文档化** |
| `xwFailover.sh` 的真实角色 | `git show HEAD:xwFailover.sh` + `git grep xwFailover` | **不是守护进程** —— 它加载 `lib/health.sh`（健康探测单一真源），并由 `lib/ui.sh` 用来启停健康检查 timer（`lib/ui.sh` 的 `download_failover_script` / `failover_menu` 段落）⇒ **保留路径的一部分** |
| 保留路径的三处不许删 | `git grep` | `lib/health.sh` 的 `health_check_script_body`、`lib/realm.sh` 的 `generate_endpoints_from_rules`、`tests/cases/04_legacy_merged.sh` —— 团队记忆已登记「都**不许删**」 |
| 崩溃循环防护的代码落点 | `git show HEAD:lib/failover.sh` | `failover_install_check` / `failover_install_files` / `failover_write_crash_loop_guard` / `failover_config_ready` / `failover_service_enable` —— **整块随守护进程删除** |
| 台架对 drop-in 的覆盖 | `grep` 全 `tests/` | `crash-loop` / `StartLimit` / `DROPIN_DIR` **0 处命中** ⇒ 台架**从未**覆盖这块（与本轮裁定一致：不用再补） |
| `docs/` 待删量 | `grep` 计数 | **149 处**（5 个文件）；全仓 `.md` 共 773 处（含 `reports/` 历史留档与 `cmd/README-failover.md`） |

---

## 三、🔴 阻断项 1：三笔已提交 + 7 个在飞文件，与裁定**方向相反**

### 3.1 现象

用户裁定「**主备池模式的都抛弃**」「**N3 双地址解析作废**」（团队记忆已登记），但仓库 HEAD 上**正躺着三笔已提交的 N3 实现**，工作区还有 **7 个文件**在飞改动继续加码同一个方向：

| 提交 / 文件 | 内容 | 与裁定的关系 |
|---|---|---|
| `47acf47` | `cmd/xwpf-failover.py`：双地址解析（转发口 / 探测口分离）+ 探测结果分类 + 状态文件持久化（`/etc/xwpf/failover-state.json`） | ❌ **守护进程内部实现** —— 被删功能的核心代码 |
| `c6d4fbf` | `lib/failover.sh`：N3 建池双地址 + F4 端口判定修正 + **限流后自动 reset-failed** | ❌ **建池路径** + 崩溃循环防护的延伸 —— 两块都在删除范围 |
| `2631637` | `lib/ui.sh`：主备状态可观测（当前主 / 探测目标 / 转发目标 / 连续失败数 / 上次切换时间 + unit failed 可见） | ❌ **菜单里的守护状态展示** —— 删除功能后无对象可展示 |
| 在飞 `cmd/README-failover.md` | 守护进程文档扩写 | ❌ 删除对象的文档 |
| 在飞 `cmd/xwpf-failover.service` | unit 改动 | ❌ 删除对象的 unit |
| 在飞 `docs/health-check-and-failover.md` | 改写为「**新池用双地址把这个问题修掉了**」 | ❌ **在给作废的 N3 写文档** |
| 在飞 `docs/troubleshooting.md` / `docs/install-and-upgrade.md` / `docs/README.md` | 守护与 N3 相关扩写 | ❌ 同上 |
| 在飞新文件 `docs/local-unverifiable-checklist.md` | 待核（可能含 N3 相关条目） | ⚠️ 待核 |

### 3.2 为什么是问题

1. **方向冲突**：这三笔提交实现的是「让进程级主备池更好用」，而用户裁定是「这个功能整体不要了」。⇒ **它们不是「待完善」，而是「待删除或待回退」**。
2. **文档会固化错误方向**：在飞 diff 已经在写「双地址修掉了问题」——若这批 docs 落地，**文档会把一个即将删除的功能描述成产品亮点**，且与 §1 的保留清单矛盾。
3. **静默失效风险**：若只删「新建」路而保留 N3 的双地址解析代码，保留路径（权重主备）的探测语义可能被 N3 的「转发口/探测口分离」污染 —— 权重主备**没有独立进程**，它的探测点就是规则里的目标；一旦守护的解析逻辑被误接到权重路径上，就是「切到不该切的地址」。
4. **合并链污染**：这三笔在 `feat/update-center` 分支上（合并顺序 `#6 → #5 → #4`，自顶向下）⇒ 若不清掉，**会随合并进入 main**。

### 3.3 建议改法（**须 Chief/用户拍板，审稿不自行决定**）

**必须先拿到一个决定，再动 docs/。** 三个选项：

| 选项 | 动作 | 代价 | 适用判断 |
|---|---|---|---|
| **(a) 回退** | `git revert` 三笔（保留历史），或在合并前**重写**掉它们 | 需改写历史（若未 push 可 reset） | 若这三笔**从未被使用过**（无用户依赖）⇒ 回退最干净 |
| **(b) 保留但隔离** | 三笔留着，但**在删除主备池的那一笔里把这块代码整个移除** | 合并历史里留着一段「加了又删」的噪音 | 若这三笔已 push 且**有人依赖**了那段行为 |
| **(c) 原地删除** | 直接在删除那一笔里把相关代码**连根删掉**（不留 N3 痕迹） | 需要小心不要误伤 `lib/health.sh` / `generate_endpoints_from_rules` | 通常与 (b) 合流，最省事 |

**⇒ 审稿的建议：选 (c)（原地删除）+ 合并前 rebase 掉三笔**（若未 push）。理由：功能整体废弃 ⇒ 留一段「实现了双地址又删掉」的代码历史，对**下一个读代码的人**是纯粹的负担（他得先理解 N3 才能理解为什么没有 N3）。

> **⚠️ 无论选哪个，有一条不能省**：删除那一笔**必须显式列出「删了什么」**，否则下一个人会以为「双地址解析」是**不小心漏删**的，而不是**有意废弃**的。⇒ 建议在删除那一笔的 commit message 里写明：「N3 双地址解析随主备池整块删除而废弃（用户裁定 10/24）；保留路径为权重主备 + 健康探测，探测点即规则目标，无转发口/探测口分离概念。」

### 3.4 严重级

**🔴 阻断** —— 在这个决定落地前，**docs/ 的删除动作不应当开工**（否则会写出一套「功能已废弃但文档描述它是亮点」的自相矛盾文档）。

---

## 四、🔴 阻断项 2：防误伤 —— `xwFailover.sh` **不是**守护进程

### 4.1 现象

Chief 的删除清单里有一项：「讲『守护进程』这个程序本身的（`cmd/xwpf-failover.py`、**`xwFailover.sh`**）」。

**但 `xwFailover.sh` 恰恰不是守护进程 —— 它是保留路径的健康探测管理入口。**

### 4.2 证据（`git show HEAD:xwFailover.sh` + `git grep xwFailover`）

| 证据 | 内容 |
|---|---|
| 头部注释 | 「故障转移管理脚本」 |
| 加载什么 | 「健康检查逻辑统一放在 `lib/health.sh`（唯一真源），这里只加载不重复实现」—— 找不到 `lib/health.sh` 就 **`exit 1`** |
| 状态文件 | 直接操作 `/etc/realm/health/health_status.conf` |
| 谁在用 | `lib/ui.sh` 的 `download_failover_script`（下载到 `/etc/realm/xwFailover.sh`）、`lib/ui.sh` 的 `failover_menu`（**「主备池管理」菜单入口**）、`lib/ui.sh` 的卸载段（`bash /etc/realm/xwFailover.sh stop` 停健康检查服务） |
| 它与守护进程的关系 | **没有**。守护进程是 `cmd/xwpf-failover.py`（独立的 Python 守护，自己持有监听口）；`xwFailover.sh` 是 **shell 脚本**，作用是**管理 realm 侧的故障转移/健康检查**（`realm-health-check.timer`） |

### 4.3 为什么是问题（误伤的严重级）

删掉 `xwFailover.sh` ⇒ **保留路径的健康探测入口消失**：
- `lib/ui.sh` 的 `failover_menu`（用户改权重、开/关故障转移的入口）**打不开**；
- 卸载流程里「停健康检查服务」这一步**静默失效**（`if [ -f ... ]; then` 不成立就跳过 ⇒ **不报错、不清理**）；
- ⇒ 用户改了权重，**探测端不更新** ⇒ 权重主备**永远不切换** —— 这正是本项目最核心的「静默失效」形态。

### 4.4 建议改法

1. **`xwFailover.sh` 不删**。它属于「健康探测端」的文件，归入**保留**类。
2. Chief 的删除清单里把 `xwFailover.sh` 从「守护进程程序」一栏**移到「保留」一栏**，并注明理由：**它是健康探测管理脚本，不是进程级主备池的守护进程。**
3. ⚠️ **但要核一件事**（审稿已核到一半）：`xwFailover.sh` 里若**也**含「建池 / 列池 / 删池 / 启停守护」这些**主备池专属**功能 ⇒ 那部分**该删**。⇒ **交小编核**：`xwFailover.sh` 的功能面里，**哪些是健康探测（留）**、**哪些是主备池（删）**，请逐个子命令列出来。**不要整文件删，也不要整文件留。**
4. **连带要核的**：`lib/ui.sh` 里调用 `xwFailover.sh` 的那几处（`failover_menu` / 卸载段）—— 菜单里若混着「建池 / 删池 / 启停守护」入口，**菜单项要删，健康探测相关项要留**。

### 4.5 严重级

**🔴 阻断（防误伤）** —— 误删的后果是「用户改权重但永远不切换」，且**无任何报错**。

---

## 五、docs/ 删除清单（交小编的返工单）

> **纪律**：文档引用写「**文件 的 符号**」，禁「文件:行号」；**不要留两套说法**；删完后**全局搜一遍**关键词确认零残留。
> **本清单基于 HEAD `2631637` + 在飞改动**；在飞改动正在改同样的段落 ⇒ **以本清单为准，在飞那部分直接丢弃**（它写的是 N3 方向）。

### 5.1 `docs/health-check-and-failover.md`（13 处命中）

| 动作 | 位置（符号） | 说明 |
|---|---|---|
| **删** | §1「两种『故障转移』不是一回事」整节 | 讲的是「负载均衡故障转移」vs「主备 active/passive（进程级）」两套对照 ⇒ 后者删除 ⇒ 整节无意义 |
| **删** | §1.1「主备的两种转发路径：默认 = 直连」整节 | 讲直连 vs realm 回环 ⇒ 两种建池方式随主备池删除 ⇒ **整节删**。<br>⚠️ **本节是最高优先级的一处**：它现在**完整保留着 N3 双地址的叙述**（「新池用双地址把这个问题修掉了」「解析口径只有一处：`cmd/xwpf-failover.py` 的 `split_target()`」「守护进程的运行状态落在 `/etc/xwpf/failover-state.json`」）—— **全部指向已删除的文件**，是「作废方向被写进产品文档」的实例 |
| **改** | §0「唯一真源约定」 | 保留，但**删掉**其中讲 `xwFailover.sh` 与「故障转移脚本」并列为两份实现的表述 ⇒ 改成只讲 `lib/health.sh` 一份 |
| **留** | §2 健康检查参数 / §3 探测方式 / §4 systemd unit（`realm-health-check.*`）/ §5 健康状态文件 / §6 状态机 / §7 切换与回切 / §8 命令行接口 / §9 已知边界 | **全部保留** —— 这是健康探测端 + 权重主备的正文 |
| **核** | §7.2「主备模式（`active-standby`）的切换」 | 确认讲的是**权重主备**（`TARGET_STATES` / `WEIGHTS` 翻转）⇒ **保留**；若混入了守护进程描述 ⇒ 只删那部分 |
| **核** | §7.3「剔除模式（legacy）的切换」 | 这里的「legacy」指**剔除模式**（旧版 LB 模式），**不是**主备池旧模式 ⇒ **保留**。⚠️ **防误伤**：与 `tests/cases/04_legacy_merged.sh` 的「legacy」同理，**都不许删** |

### 5.2 `docs/install-and-upgrade.md`（58 处命中 —— 最多的一个）

| 动作 | 位置（符号） | 说明 |
|---|---|---|
| **删** | §2.1 表格的**第 5、6、7 行** + 其下的「为什么 install 不再 `systemctl enable --now`」引用块 | 讲 `failover_install_check` / 只装不启 / 写 drop-in ⇒ 随功能删除 |
| **改** | §2.1 表格的**第 4 行**之后 | 删完 5~7 行后，安装步骤要**重新编号**并确认「只装不启」那段说明**整段消失**（不是改写，是删） |
| **改** | §2.1 末尾「`cmd/` 下载失败不阻断安装」段 | 讲的是守护进程的 `cmd/` 源文件兜底 ⇒ 随功能删除 |
| **改** | §2.2「安装后落盘清单」表格 | **删** `/usr/local/bin/cmd/` 那两行（守护进程源文件副本）；**保留** `xwPF.sh` / `lib/*.sh` / `pf` / `realm` |
| **改** | §2.3「安装后验证」里的「**4. 主备守护进程在跑**」 | **删这条**；其余（脚本就位 / realm 可执行 / 服务已注册）**保留** |
| **改** | §3「离线安装」 | 涉及 `cmd/xwpf-failover.py` 手动放置的部分 ⇒ 删；`lib/` 的离线放置 ⇒ 留 |
| **删** | §4.2「升级守护进程」整节 | 讲 `failover_install_check` / 版本指纹 / `/usr/local/bin/.xwpf-failover-version` ⇒ 全删 |
| **改** | §4.3「升级后必做」的命令块 | **删** `systemctl restart xwpf-failover` 一行；**保留** `daemon-reload` / `restart realm` / `pf --restart-service` |
| **删** | §4.4「限流后 unit 停在 failed —— 什么时候要 `reset-failed`」整节 | 讲限流 / `reset-failed` / `failover_reset_failed_state` ⇒ 全删 |
| **改** | §5「卸载」 | **必须保留并加强**「清理老机器残留」：守护 unit、drop-in 目录、`/etc/xwpf`、`/usr/local/bin/cmd/`、版本指纹文件。⚠️ 这条**不能因为功能删除就一起删掉** —— 见 §5.5 |
| **留** | §1 前置依赖 / §2.0 一键安装 / §4.0 更新中心 / §4.1 升级脚本 / §6 首次初始化 / §7 命令行接口 / §8 相关文档 | 保留 |

### 5.3 `docs/troubleshooting.md`（31 处命中）

| 动作 | 位置（符号） | 说明 |
|---|---|---|
| **删** | §6.8「主备池不切换 —— 先看池是不是『旧格式』」整节 | 讲池的目标串 `|`、守护日志、状态页 ⇒ 随功能删除 |
| **删** | §6.9「守护进程一直 failed / 起不来（systemd 限流）」整节 | 讲 `NRestarts` / `reset-failed` / 限流 ⇒ 随功能删除 |
| **改** | §8.1「主备池的 listen 端口：写配置之前就拦下来」 | 讲主备池的 listen 端口前置校验 ⇒ 随功能删除。**但**：端口冲突本身是通用问题，§8 的其它小节（§8.2 误报端口占用）⇒ **保留** |
| **留** | §1~§6.7、§7（权重）、§8.2、§9、§10、§11、§12 | 保留。⚠️ §11「更新失败」里提到 `ETXTBSY` —— 那是**realm 二进制**的替换（不是守护二进制）⇒ **保留** |
| **改** | 「快速索引」表 | 删掉指向 §6.8 / §6.9 / §8.1 守护专章的条目 |
| ⚠️ **核** | §6「主备不切换或切错目标」整节 | 标题里的「主备」指的是**权重主备**（保留）⇒ **大节保留**；但要核清小节里有没有混守护进程的内容 |

### 5.4 `docs/README.md`（5 处命中）

- 目录 / 索引里指向已删章节的链接**清掉**；
- 保留健康探测与权重相关条目的链接。

### 5.5 ⚠️ 必补（**删除功能时最容易漏的一条**）：卸载要清理老机器残留

用户裁定删功能 ⇒ **删除动作本身必须覆盖「老机器上还留着的东西」**。否则真机上会留下**占着端口的僵尸**。

**必须清理的清单**（交小编写进卸载流程）：

| 对象 | 路径 | 备注 |
|---|---|---|
| 守护 unit | `/etc/systemd/system/xwpf-failover.service` | |
| 守护 drop-in 目录 | `/etc/systemd/system/xwpf-failover.service.d/` | **整目录删**（含历史人工文件） |
| 守护二进制 | `/usr/local/bin/xwpf-failover` | |
| 守护源文件副本 | `/usr/local/bin/cmd/xwpf-failover.py` / `.service` | |
| 版本指纹文件 | `/usr/local/bin/.xwpf-failover-version` | |
| 池配置目录 | `/etc/xwpf/`（含 `failover.json`、`failover-state.json`） | |
| 正在跑的进程 | `xwpf-failover` 进程 | **必须先 `stop` + `disable`，再删文件** |
| 占用的监听端口 | 真机 `18443` / `18444` | ⚠️ 见第八节：**删之前必须先把流量迁走** |

**⇒ 对应验收项**：已写入 `reports/real-machine-acceptance.md` 的 **A-15**。

### 5.6 `cmd/README-failover.md`（75 处命中）与 `cmd/xwpf-failover.service` / `cmd/xwpf-failover.py`

> **⚠️ 事实更新（2026-10-24 21:45）**：这三个文件**已在 `2beb7bd` 里删除**（`cmd/README-failover.md` −423 行、`cmd/xwpf-failover.py` −579 行、`cmd/xwpf-failover.service` −64 行）⇒ **本小节不再是「要删」，而是「确认删干净 + 清理引用」**。

- **删除已完成** ✅：`git ls-files` 确认 `cmd/` 下已无 `xwpf-failover*`；`cmd/README-failover.md` 也已删。
- **仍要做（清理引用）**：
  1. 全局搜 `README-failover` / `xwpf-failover` 的**残留引用**（§5.9 死链表）并清理；
  2. ⚠️ **`tests/` 里若有断言引用这些文件**（例如文档一致性用例断言「`cmd/README-failover.md` 含某段」）⇒ **那些断言会红** ⇒ **交阿测核并同步删断言**。
  3. ⚠️ **`xwPF.sh` 的 `_bootstrap` 与 `lib/update.sh` 的 `UPDATE_CMD_FILES`** 已由在飞改动处理（不再下载 `cmd/`）—— **确认没有别处还在下载或引用 `cmd/`**。
- **`xwFailover.sh` 不在此列** —— 它**保留**（见第四节）。

### 5.7 根目录 `README.md` / `README_EN.md`（19 / 9 处命中）

- **重画两处目录树**（`README.md` 的「~/ 目录结构」与「安装后落盘结构」）：
  - 删 `lib/failover.sh`、整个 `cmd/` 目录、`xwpf-failover` 二进制、`.xwpf-failover-version`、整个 `/etc/xwpf/` 目录、`xwpf-failover.service`；
  - ⚠️ **同时确认新目录树与实际落盘一致** —— `lib/` 现在是 **6 个**模块（原 7 个，删了 `failover.sh`）；`cmd/` 目录**不再存在**。
- 删「主备 active/passive —— 进程级主备热切换（独立守护 xwpf-failover，详见 `cmd/README-failover.md`；守护进程崩溃循环、systemd 限流……）」整条特性；
- 删「相关文档」表里的「主备 active/passive 守护进程」行（**死链**）；
- **保留**「负载均衡」「故障转移（权重翻转）」「主备模式状态转换推演」三条；
- ⚠️ **README_EN.md 必须同步改**（否则中英两版说法不一致）。

---

### 5.8 删除后必须做的三步自检（交小编/阿测）

```bash
# 1) 全局搜残留关键词（应 0 命中；reports/ 与 tests/BASELINE* 是历史留档，可排除）
grep -rn -E 'xwpf-failover|failover\.json|StartLimit|RestartSec|crash-loop-guard|守护进程|主备池' \
  --include='*.md' --include='*.sh' --include='*.service' --include='*.py' \
  . | grep -v '^./reports/' | grep -v '^./tests/BASELINE'

# 2) 保留项必须在（应有命中）
grep -rn -E 'health_check_script_body|generate_endpoints_from_rules|auto_enable_active_standby' --include='*.sh' .

# 3) 台架全过（唯一门禁 tests/run_tests.sh；须引 BASE_SHA + 汇总 + 用例数 + 退出码）
```

> **⚠️ 第 1 步的现状（2026-10-24 21:45 实测）**：`docs/` **131 处** + `README.md` **19 处** + `docs/README.md` **5 处**仍命中；`cmd/README-failover.md` / `cmd/xwpf-failover.py` / `cmd/xwpf-failover.service` 已从 `git ls-files` 消失 ⇒ **代码 0 命中，文档大量命中**。

### 5.9 🟠 新增必做：死链与「菜单 / 文档口径分裂」

删除已落地 ⇒ 出现了两类**新**问题（这是删除动作的必然产物，必须在同一轮清掉）：

**① 死链（指向已删文件）**

| 位置 | 内容 | 修法 |
|---|---|---|
| `docs/health-check-and-failover.md` §1.1 末尾 | 「详见 `cmd/README-failover.md`」—— **该文件已删** | 随 §1 / §1.1 整节删除 |
| `docs/health-check-and-failover.md` §1 表格 | 「`xwpf-failover` 守护进程」一行 | 随 §1 整节删除 |
| `README.md` 的「相关文档」表 | 「主备 active/passive 守护进程」→ `cmd/README-failover.md` | 删该行 |
| `README.md` 的目录树（两处） | `lib/failover.sh` / `cmd/` / `xwpf-failover` / `.xwpf-failover-version` / `/etc/xwpf/` / `xwpf-failover.service` | 全部删，并**重画目录树** |
| `README_EN.md` | 同上（英文版） | 同上 —— ⚠️ **两版必须同步** |

**② 口径分裂：代码已删，菜单入口还在**

`lib/ui.sh` 的 `failover_management_menu` **仍然存在**（`git show HEAD:lib/ui.sh` 可证），它由 `lib/rules.sh` 的菜单调用，作用是调 `xwFailover.sh` 的 `toggle` / `config` / `status` —— 这三个是**保留路径**（开关故障转移 / 改配置 / 看状态），**功能上是对的**。

⚠️ **但它的名字与文案会造成误解**：菜单里若仍出现「**主备池管理**」字样，用户会以为那个池功能还在（已经没了）。⇒ **建议**（交小编核）：把该菜单项的**名称与提示文案**改成不含「主备池」的说法，例如「**故障转移（权重主备）**」或「**负载均衡与故障转移**」。

⇒ **判据**：菜单里**不得**再出现「主备池」「建池」「删池」「启停守护」「守护日志」等字样；**「权重主备」的字样要保留**（那是保留功能）。

### 5.10 🟢 在飞 N4 改动的方向评估（**方向正确，建议放行**）

复核期间工作区有在飞改动（`lib/health.sh` +214 / `lib/update.sh` +24 / `xwPF.sh` +112），审稿已读 diff：

| 在飞改动 | 做什么 | 方向 |
|---|---|---|
| `xwPF.sh` 的 `_cleanup_legacy_failover_daemon` | 停 + disable 老守护、删 unit / drop-in 目录 / 二进制 / 版本指纹、把 `failover.json` **改名留档**（不删）、`daemon-reload` | ✅ **正确**，且与本报告 §5.5 的残留清单**逐条对得上** |
| `xwPF.sh` 的 install / uninstall 分支调它 | 升级路径与卸载路径都清残留 | ✅ **正确**（本报告 §5.5 要求的正是两条路径都清） |
| `xwPF.sh` 的 `LIB_FILES` 去掉 `failover.sh`；`lib/update.sh` 的 `UPDATE_LIB_FILES` 去掉 `failover.sh`、`UPDATE_CMD_FILES` 置空 | 防止下载不存在的文件导致安装/更新失败 | ✅ **正确**，且注释写明了原因 |
| `xwPF.sh` / `lib/update.sh` 调 `health_check_script_regenerate` | **装/升级后重新生成探测端产物** | ✅ **正确** —— 正是 N4「生成物不重新生成 = 静默失效」的治法 |
| `health_migrate_connection_timeout`（探测超时预算 3 → 10） | 抬高探测预算 | ✅ 与团队记忆「探测预算 3s 余量仅 24% → 放宽 10s」一致 |

> **⚠️ 但有三处要提请注意（交小编核，审稿未复跑）**：
> 1. **`pkill -f "xwpf-failover"` 有自杀风险** —— 若该命令行的**自身**含 `xwpf-failover` 字样，`pkill -f` 会匹配到自己 ⇒ shell 被自己杀掉。⇒ 建议改用**精确 PID**（`pgrep -f` 拿 PID 后 `kill`），或用**不含目标串**的模式。
> 2. **`failover.json` 改名留档**（`.disabled`）与「老池仍能在菜单里列出与删除」这条验收项**可能冲突** —— 改名后菜单就读不到它了。⇒ 二者必须对齐：要么改成**内容保留但不再被守护读取**，要么保留原名。**建议**：保留原文件名（守护已不存在，不会有人误读），只删守护相关进程与 unit。
> 3. **在飞改动尚未提交** ⇒ 上面第 1、2 条应在**提交前**改掉，否则就固化了。

---

## 六、reports/ 的处置（已完成）

| 文件 | 动作 | 状态 |
|---|---|---|
| `reports/round3-crashloop-review.md` | **文首加状态声明**：主题功能已废弃删除、仅作历史留档、结论不适用于现版本、**不要**当成待办派工；**并保留一条可迁移的方法论**（异常退出必须非 0） | ✅ 已改 |
| `reports/round3-failover-restart-storm-status.md` | **文首加状态声明**（同上）；**第三节 / 第四节各加「已迁出」指引**；**2.1 小节加「缺陷随功能删除而作废」处置说明**（并把它降格为「静默失败」方法论样本，不留悬空派工） | ✅ 已改 |
| `reports/real-machine-acceptance.md` | **A-5 迁入五步状态迁移链**；**新增 A-6.1 两条时间特性 / A-6.2 取证命令**；**A-10 整节废弃**；**新增 A-11~A-15**；A-1 危险动作移除守护引用；结果记录模板同步 | ✅ 已改 |

**迁入内容的两条纪律**：
1. **每个数写来源**：五步迁移链标了证据目录 `/root/xwpf-evidence-20261024-190720-lb/` 与锚点 `a9102c1`；两个实测数字标「**待补**」并给取证命令。
2. **不混两个口径**：「直连池 8–10 秒切走」与「负载均衡路径检测耗时」曾并列对照 ⇒ 现在**直连池功能已删除，只剩负载均衡路径一条口径** ⇒ 对照表作废，但**「引用检测耗时必须写清哪条路径」的原则保留**（防止将来又长出第二条路径时混用）。

---

## 七、真机验收清单的处置（已完成，摘要）

| 项 | 动作 |
|---|---|
| **A-10** | 整节废弃（状态说明，不占验收位） |
| **A-11** | **新增**：普通单端口中转（无 `WEIGHTS` 行 / `balance` 单值 / 不得误判 failed） |
| **A-12** | **新增**：同端口多目标负载均衡 5,5（权重序列 = 5,5 / **两个后端都收到请求** / 不误进 active-standby） |
| **A-13** | **新增**：权重 10,0 主备（`active-standby` + `FAILOVER_ENABLED=true` + **timer enabled+active** + 杀主翻备 / 恢复翻回 / 回切冷却） |
| **A-14** | **新增**：健康探测端确实在探测（★ **两次读取状态文件、最后检查时间必须不同** / 生成物与真源一致 / 状态文件无已删规则残留行） |
| **A-15** | **新增**：老机器残留清理（守护 / unit / drop-in / 进程 / 占用端口 / `/etc/xwpf` 全清；★ **保留路径不得被误伤**；★ **老池仍能列出与删除**） |
| **A-1** | 「危险动作」里移除 `systemctl enable xwpf-failover` |
| **结果记录模板** | A-10 标废弃；补 A-11~A-15 五行 |

**为什么 A-14 要独立成条**：用户保留的三条路径中，**只有权重主备依赖健康探测** ⇒ 探测端不工作 ⇒ 主备永不切换 ⇒ **静默失效**（不是失败）⇒ 不能并进 A-3 顺带看一眼。

---

## 八、🔴 阻断项 3：真机 103 的操作顺序（**删之前必须先迁流量**）

### 8.1 事实

真机 `103.42.31.186` 现在跑着**两个池**（`/etc/xwpf/failover.json`，709 B）：旧池监听 `0.0.0.0:18443`、直连池监听 `0.0.0.0:18444`；守护进程在跑（pid 63346，见本报告同系列前一轮取证）。

### 8.2 风险

**守护进程一删，就不再监听 `18443` / `18444` ⇒ 依赖这两个端口的转发立刻断。** 而「主备池管理」菜单随功能一起删除 ⇒ **没有「建池」入口可以重建** ⇒ 用户在机器上**没法把流量迁回权重路径**（除非会手工写规则）。

⇒ **顺序错了 = 真机断转发。**

> **⚠️ 事实更新（2026-10-24 21:45）**：代码侧删除**已落地**（`2beb7bd`），在飞的 `xwPF.sh` 也已把 `_cleanup_legacy_failover_daemon` 写好（升级与卸载两条路径都调）⇒ **清理机制已就位**。
> ⇒ **但两件事仍未做，且必须按顺序**：
> ① **流量迁移**（用保留功能的菜单把 `18443` / `18444` 的流量迁到「同端口多目标 + 权重 10,0」）—— **必须先做**；
> ② **在真机上跑一次升级/卸载**，验证 A-15 的六条残留检查全过。
> ⇒ **顺序错了 = 真机断转发**（先清了守护，流量还没迁走）。

### 8.3 建议顺序（**不可颠倒**）

1. **先**在真机上把这两个端口的流量**迁到保留路径**（同端口多目标 + 权重 `10,0`）—— 用**保留功能的菜单**做，不依赖任何被删功能；
2. 验证转发正常（连打几次，确认落到后端）；
3. **再**删守护进程功能 + 跑卸载清理（对应 A-15）；
4. 验证：`18443` / `18444` 不再被占、`/etc/xwpf` 与 unit / drop-in 清空、**保留路径的 timer 与规则仍正常**。

### 8.4 严重级

**🔴 阻断（操作顺序）** —— 这是**删除动作的前置条件**，不是收尾工作。

---

## 九、边界与未覆盖（审稿本轮的能力边界）

1. **本轮全程只读**：仓库侧只做 `git show` / `git diff` / `git grep` / `git status` / `git log`（**未改** `lib/`、`tests/`、`docs/`、`cmd/`、`xwFailover.sh`，**未做任何 git 写操作**）；本轮唯一写入的是 `reports/**`。
2. **在飞改动由他人同时进行**：本轮读 `docs/` 与 `cmd/` 时，工作区正在被编辑（7 个文件）。⇒ 本报告所有「docs/ 现状」判断基于 **HEAD `2631637` + 在飞 diff 的合并观察**；**在飞那部分的方向已被判为作废**（见第三节），不作为删除清单的依据。
3. **【无 VPS 凭据】** 审稿本轮**没有连上 VPS** —— 凭据环境变量在会话压缩后丢失、无 SSH 私钥与 agent、免密登录被拒（`Permission denied (password)`，22 端口可达）⇒ 第三节与第四节的代码级结论**全部在仓库侧完成**，**没有一条是实机结论**。
   ⇒ **两个时间特性的实测数字仍标「待补」**，补齐方式见 `reports/real-machine-acceptance.md` 的 **A-6.2**（在 VPS 上跑一条命令即可）。
   ⇒ 补齐二选一：(a) 用户/Chief 在 VPS 上跑 A-6.2 的命令并贴回；(b) 给审稿一次 VPS 访问（密码走**用户级**环境变量 `VPS_PASS`，审稿只读不改）。
4. **§8 的真机现状**来自**前一轮**的取证（2026-10-24 19:19–19:20），**本轮未复验** —— 那之后守护进程可能被启停过。⇒ 真机动手前**必须先按 A-15 的「升级前快照」重新取证**。
5. **未做**：没有跑台架（`tests/run_tests.sh`）—— 本轮未改动被测产物（只改 `reports/**`），且**台架对崩溃循环防护本就零覆盖**（已核：0 处命中）。
6. **未审**：`lib/failover.sh` 里**除建池/启停/安装那套以外**的函数是否还有保留路径在用 —— 例如 `failover_probe_reachable`、`failover_check_port_listening` 是否被权重主备路径调用。**这一条交小编核**（删除时按调用关系删，别按文件名删）。
7. **台架侧待核**：若 `tests/` 里有断言引用 `cmd/README-failover.md` 或 `cmd/xwpf-failover.*`（例如文档一致性用例），删除文件后**那些断言会红** ⇒ 需同步删断言。**交阿测核。**
8. **Chief 的删除清单里 `xwFailover.sh` 一项已被本报告纠正**（第四节）—— 依据是 `git show HEAD:xwFailover.sh` 的加载逻辑与 `git grep` 的调用点，**不是推测**。

---

## 十、盯住不放的架构隐患

1. **「同名不同机制」是这个项目最大的误伤源。** 本轮已实证两次撞上：
   - 「主备」= **权重主备**（保留）vs **主备池**（删除）—— 名字一样，机制完全不同；
   - 「legacy」= **剔除模式**（保留）vs **realm 回环旧模式**（删除）—— 名字一样，含义不同（`tests/cases/04_legacy_merged.sh` 的 legacy 还指「并入的旧脚本」，**第三种**含义）。
   ⇒ **建议**：删除时**不要按关键词 grep 删除**，要**按调用关系与符号逐个核**。团队记忆已登记「`generate_endpoints_from_rules` 与 `tests/cases/04_legacy_merged.sh` 都不许删」—— 本报告建议**把这条纪律扩展成一张「同名异义对照表」**，进项目文档，随每次删除前核对。

2. **删除功能的最大事故不是「删不掉」，是「删一半」。** §5.5 的残留清单 + §8 的操作顺序，都是为这一条兜底。⇒ **建议把 A-15 设为「删除类改动的必过验收项」**，每次删功能都跑一遍（而不是只在这次跑）。

3. **「静默失败」是本项目反复出现的同一类缺陷。** 已实证的三个同族案例：
   - 崩溃循环防护：`|| true` 吞失败 ⇒ install 报成功 ⇒ 防护没装上；
   - N4：生成物不重新生成 ⇒ 探测端跑的是旧逻辑 ⇒ 静默失效；
   - 本轮预判：卸载时若漏 `stop` 守护进程 ⇒ 端口还被占 ⇒ 用户以为产品坏了。
   ⇒ **共性模式**：**失败被吞 ⇒ 上层报成功 ⇒ 用户以为装上了/配好了**。⇒ **建议**：凡是「装 / 升 / 卸 / 迁」四类动作，**每一步都要有一条「产物确实变了」的正向断言**（不是「命令返回 0」）。

4. **健康探测现在是唯一的切换驱动** —— 权重主备的生命线全压在 `lib/health.sh` 的生成物上。⇒ 删除主备池后，`realm-health-check.timer` 的可用性**从「辅助功能」升级为「核心功能」** ⇒ 建议把 A-14 的三条断言（最后检查时间前进 / 生成物与真源一致 / 无残留行）**升级为门禁必过项**，而不是只在真机验一次。

---

## 附：本报告引用的可复现命令

```bash
# 仓库侧（被测产物一律从冻结点导出）
git log --oneline -6
git show --stat --oneline 47acf47 c6d4fbf 2631637
git status --short
git diff -- docs/health-check-and-failover.md
git show HEAD:xwFailover.sh | head -60
git grep -n 'xwFailover' HEAD -- lib cmd xwPF.sh
git grep -n 'generate_endpoints_from_rules\|health_check_script_body' HEAD -- lib
git show HEAD:lib/failover.sh | grep -n 'failover_install_check\|failover_write_crash_loop_guard\|failover_config_ready\|failover_service_enable'

# docs/ 待删量（分文件）
grep -rn -c -E '守护进程|守护|xwpf-failover|failover\.json|StartLimit|RestartSec|Restart=|drop-in|崩溃循环|限流|主备池|建池|删池|列池|realm 回环|回环' docs/

# 台架对崩溃循环防护的覆盖（应 0 命中）
grep -rn -E 'crash.loop|crash_loop_guard|StartLimit|DROPIN_DIR|dropin' tests/
```
