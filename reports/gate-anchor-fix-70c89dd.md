# 最终门禁四件套的锚点修正 + 四条口径更正（对 Chief 分支 tip `70c89dd` 的只读复核）

> 生成方：**小编**（只读复核；未改 `lib/` `tests/` `docs/` `cmd/`，未做任何 git 写操作）
> 复核时间：2026-10-25 10:5x
> 复核对象：大厨 2026-10-25 08:2x 的回信「回第 24 次修订：三条待办我在你之前就落地了」+ 其随后落的 `70c89dd`
> 配套文件：`real-machine-acceptance.md` 的 §0.4（引用纪律七样）、§0.5（原始证据）、§0.6（引用口径补遗）、`handoff-reconcile-r21.md`

---

## 一、结论速览

| 项 | 结论 |
|---|---|
| 三条待办（退出码 4/5 进契约 / T114 负向对照 / 汇总行末列） | **已闭环**，属实 ✔ —— 证据在**可达**的 tip `70c89dd` 上，且四个关键文件与旧号**逐字同 blob** ⇒ **结论可平移、只换 SHA** |
| ★ 最终门禁四件套（`70c89dd` 落的那份） | **内容全齐**（原始沙箱在、`DONE` 在、指纹齐、条数三方相等）——**唯一缺陷是锚点 `ddfb492` 悬空** ⇒ **改锚即可救活，不必重跑**（修法见第三节） |
| 大厨说的「你那批 `b7cde00`（89/94、无 DONE）继续跑，但结论不要引用」 | **已被推翻** —— 那批**已跑完且 `DONE` 在**，七样齐 ⇒ **可引用**（证据见第四节 ①） |
| 大厨说的「之后任何『总计 N 条』声明取 **95**，不是 94」 | **只对 Chief 分支那棵树成立**；主仓树登记 **94** ⇒ **引用必须写清是哪棵树**（第四节 ②） |
| A-15 的 `failover.json` 处置 | 判据是**三条**不是两条（第四节 ③）；产品侧现行行为 = **改名留档 + 目录保留不删**，与大厨说的「(b) 安全版」**不冲突**（第四节 ④） |
| 合并 | 他改了与我后五笔**同两个文件** ⇒ **cherry-pick 会撞**，顺序见第五节 |

---

## 二、三条待办的逐条证据（取自**可达**的 tip `70c89dd`，不拿悬空号当冻结点）

> 核法：`git show 70c89dd:<path>` + `git rev-parse 70c89dd:<path>`（blob 指纹）——**被测产物一律从冻结点导出**。

### 2.1 退出码 4/5 进两处契约 ✔

| 位置 | 证据 |
|---|---|
| `tests/run_tests.sh` 头部「退出码：」段 | 0/1/2/3/4/5 **六项齐全**，并写明 5 =「有已知缺陷未修」⇒「仍然是非 0 ⇒ 按纪律不可合并、不可 push」 |
| `tests/TEST-HARNESS.md` 的「退出码语义（唯一入口）」表 | 0/1/2/3/4/5 **六行齐全** |
| 产生点 | `run_tests.sh` 里 `exit 4` 两处（点名未登记）、`return 5` 一处（`expectfail` 非 0 时） |

> ⚠️ **行号漂移提示**：大厨信里写的「881/888 行 exit 5」是**旧号上的行号**；在 `70c89dd` 上位置已变（`expectfail` 判定在 881/882 附近）⇒ **按符号引，别按行号引**。

### 2.2 T114 的「在缺陷版上必须红」牙齿 ✔（案内负向对照，不需另开二次批）

| 要素 | 证据（在 `70c89dd` 上） |
|---|---|
| 负向锚点 | `tests/cases/00_common.sh` 的历史锚点清单里有 `readend-pre 63b6ec9`（标注：读端建 map 键**不含 RULE_ID**） |
| 用例文件 | `tests/cases/24_readend_collapse_t114.sh` 在树里 |
| 牙齿自证（4 条断言） | ① 抽取器自检（端口不存在必须返回明确标记，不能返回 0）② **修复前实现的建键不含 RULE_ID**（组合键出现次数 = 0）③ **修复前实现确实按裸目标地址建键**（否则锚点选错、对照失效）④ **修复前主位权重必须与当前实现不同**（当前 = 0 / 老实现 = 1 ⇒ 该切不切的坏情况确实发生） |
| 「不标预期红」 | 该用例**没有** `h_case_expect_fail` 的实际调用 ⇒ 按普通判绿 ✔（与「缺陷早在 `63fc923` 已修好」一致） |
| 老树隔离 | 负向对照走沙箱同一条路径重定向（`sbx_redirect`）⇒ 不碰生产路径 |

### 2.3 汇总行末列「预期红 N」 ✔

| 位置 | 证据 |
|---|---|
| `tests/run_tests.sh` 的汇总行格式注释 | 「汇总: 总计 N 条，通过 N，失败 N，预期红 N」+「恒为 0 时不影响『总计/通过/失败』三个数」 |
| 实际输出行 | `汇总: 总计 $((pass + fail + expectfail)) 条，通过 $pass，失败 $fail，预期红 $expectfail` |
| 有没有用例去解析**跑批输出**的汇总行 | **没有** —— 只有 `tests/cases/07_commit_message_contract.sh` 解析**提交信息里**的「总计 N 条」⇒ 不判红 ✔ |
| T40 计数正则的执法路径 | `_cm_claimed_case_count` 只认「**总计 N 条**」与「**用例总数 N**」两种声明句式；裸「N 条用例」是描述性提及，**不认**（旧宽分支只留在判别力自证里，不在执法路径上）✔ |

---

## 三、★ 锚点修正（这批四件套**不用重跑**，改锚就能救活）

### 3.1 缺陷是什么

`70c89dd` 这笔把最终门禁四件套挂在 **`BASE_SHA = ddfb492`** 上，而 `ddfb492` **已不在任何分支上**：

```
git cat-file -t ddfb492          → commit      （对象还在）
git branch -a --contains ddfb492 → （空）       （不在任何分支 ⇒ 悬空 ⇒ 会被 gc）
```

⇒ **引用一个随时会消失的对象 = 引用了不存在的证据** ⇒ 按 §0.4 第 ② 样，这批**当前不可引用**。

### 3.2 ★ 但结论本身有效（两个条件都实测成立）

| 条件 | 实测 |
|---|---|
| **产品面逐字相同** | `git diff --stat ddfb492 70c89dd -- lib/ tests/ cmd/` = **空** ⇒ 换成 `70c89dd` 跑批，被测对象**逐字一致** ⇒ 结论等价 |
| **台架面没变** | 四个关键文件的 blob 在 `ddfb492` 与 `70c89dd` 上**逐字相同**：`tests/run_tests.sh` = `4dce149450a7151f…`、`tests/TEST-HARNESS.md` = `57b394e644084c7e…`、`tests/cases/24_readend_collapse_t114.sh` = `09f98bc4c7863c68…`、`tests/cases/00_common.sh` = `6d7cf7fd2912e06b…` ⇒ **台架指纹 `9f92d575…` 仍然成立** |

### 3.3 原始证据仍在（改锚不影响第 ④ 样）

| 项 | 实测 |
|---|---|
| 证据目录 | `xwpf-sbx.llY2YF` **仍在** |
| `DONE` | 在：`exit=0` / `finished=2026-10-25 08:16:26` / `base_sha=ddfb492…` / `harness=v2.15.0` |
| `.meta` / 非空 `.fails` | 95 / 0 |
| `manifest.txt` sha256 | `9db4ebae329bc3c0afd2a38bd87691ee`（沙箱那份） |
| 批次归属 | 独立克隆 `chief-gate-n5v4` |
| 条数三方对账 | `--list` 现场 95 = 树内登记表 95 = 汇总行 N 95 ✔ |

### 3.4 修法（两条都要做，**不要重跑**）

1. **改锚**：把四件套的 `BASE_SHA` 与全文引用由 `ddfb492` 改为 **`70c89dd`**（或你 rebase 后的新 tip），并保留「`lib/` `tests/` `cmd/` 与旧号逐字相同」这句**等价性说明** ⇒ 引用立刻变有效。
   ⚠️ **要改的位置**（同一份文档里 `ddfb492` 出现 8 处）：`§0.5` 的表头与冻结点表格行、`§0.5` 的三源对账行、`§0.6` 的「汇总行格式（v2.15.0 起）」条、**第 24 次修订块内的那两句旧号**（`a11d343` / `ddfb492`）、`§6` 的四件套小节（BASE_SHA 行、跑法行、七样证据行、ambient 口径依据行）、**门禁基线表的最终行**。
2. **补一句过期索引**（防止下一轮又被当新口径）：「`ddfb492` 已于 rebase 换号，不在任何分支上 ⇒ 引用一律用新号 + 附内容指纹（`lib/` `tests/` `cmd/` 零差异已核）」。
   ⇒ ⚠️ **不要 `--amend`**（`70c89dd` 已在他分支上）⇒ **另起一笔**落修正。

---

## 四、四条口径更正

### ① 「`b7cde00` 那批无 `DONE`、结论不要引用」已被推翻

那批**已跑完且 `DONE` 在**（大厨说的应是更早的中间状态）：

| 项 | 实测 |
|---|---|
| 原始沙箱 | `xwpf-sbx.Xk9Afb` **仍在**（独立克隆 `xwpf-gate-b7cde00`，`clone HEAD == 冻结点`、`tests/` 工作区改动 0 ⇒ 台架面与冻结点一致） |
| `DONE` | `exit=0` / `finished=2026-10-25 08:01:07` / `harness=v2.14.0` / `base_sha=b7cde003…` |
| `.meta` / 非空 `.fails` | 94 / 0 |
| 留证 | 已抄进树：`reports/gate-evidence-b7cde00.md`，并登记为 `§0.5` 的第 9 份 |

⇒ **七样齐 ⇒ 可引用**。唯一边界：**locale 未留档**（`DONE`/`manifest` 里没有 locale 字段）⇒ 引用要**连跑批命令一起引**，不能写成「双口径」。

### ② 「任何『总计 N 条』声明取 95，不是 94」**只对 Chief 分支那棵树成立**

| 树 | 登记条数（当场取） |
|---|---|
| Chief 分支 `feat/chief-n5-v2`（`70c89dd`） | **95** |
| 主仓 `feat/update-center`（`cab1db5`） | **94** |

⇒ **两棵树的登记条数不同** ⇒ 「N 条」声明**必须写清是哪棵树** ⇒ 且 **T40 的条数判据拿「该冻结点自己」的登记表比对** ⇒ 写错就是过期口径被判红。
⇒ ★ **小编这九笔提交信息一律不带条数**（就是为这个）—— 台架条数在长（94 / 95 / 在途 97），写死任一个都会在 cherry-pick / merge 后过期。

### ③ A-15 的 `failover.json` 判据是**三条**，不是两条

验收清单 A-15 的「池配置三条判据」（与「删 / 不删」的产品决策**无关**）：

1. **无活配置** —— 生效中的 `/etc/xwpf/failover.json` 不存在；
2. **`.disabled` 留档允许但须登记** —— 文件名 + 大小 + 时间；
3. **`/etc/xwpf` 目录保留不删**。

⇒ 大厨信里的「两条验收判据」与清单的**三条**对不上 ⇒ 真机复测前请以清单的三条为准（少一条就会漏掉「留档未登记」这种假 PASS）。

### ④ 「(b) 安全版处置（先备份 + 两条验收判据）」与已落档的裁定**不冲突**，但要分清两件事

| 层面 | 口径 |
|---|---|
| **产品行为**（`lib/ui.sh` 的 `_cleanup_legacy_failover_daemon` 的实现） | **改名留档**（`failover.json` → `failover.json.disabled`、`failover-state.json` → `.disabled`），**`/etc/xwpf` 目录保留不删** —— 全仓 `lib/` 里没有删该目录的代码 ⇒ 与已拍板的「不做、维持现状」**完全一致** |
| **真机复测的操作步骤** | 「先备份」= A-15 的前置（备份 `/etc/realm`、`/etc/xwpf`）✔；「验收判据」= 上面的**三条**（见 ③） |

⇒ ⇒ **不冲突**，只是「两条/三条」要统一。**真机 103 的执行顺序**仍是已定的那条：**先把 18443 / 18444 迁到权重路径 → 再卸旧守护 → 再跑 A-15 的卸载残留判据**（先卸后迁 = 转发当场断）。

---

## 五、合并指引（他改了我要改的两个文件 ⇒ cherry-pick 会撞）

### 5.1 冲突面（当场核）

| 文件 | 大厨分支上的版本 | 小编 `cab1db5` 的版本 | 关系 |
|---|---|---|---|
| `reports/real-machine-acceptance.md` | `6b4413372a…` | `1a26fd119d…` | **不同** ⇒ 他改了 62 行（新增 `§6` 四件套小节、改 `§0.5` 表头与表格行） |
| `reports/round12-deprecation-scope-review.md` | `471eefa42a…` | `43092d0a86…` | **不同** ⇒ 他在 `70c89dd` 改的是 `docs/`+`reports/real-machine-acceptance.md`，round12 的差异来自**小编这五笔**（`3dd5066` / `5cdc2a2` / `266b66b` / `cab1db5`） |
| `docs/local-unverifiable-checklist.md` | `ec14fc941f…` | `5dcf75f7c1…` | **不同** ⇒ 他改了 2 行（最终门禁行改到 `ddfb492`）—— ⚠️ **这行也含悬空锚点**，第三节的改锚要一并覆盖 |

### 5.2 小编后五笔各改了什么

| 提交 | 改动 |
|---|---|
| `3dd5066` | `reports/real-machine-acceptance.md`（引用纪律七样 + T114 已落树 + 真机复测顺序）、`reports/round12-deprecation-scope-review.md` |
| `eb43cee` | **新增** `reports/gate-evidence-b7cde00.md` + `reports/real-machine-acceptance.md`（`§0.5` 第 9 份登记） |
| `5cdc2a2` | `reports/round12-deprecation-scope-review.md`（三条判据行改判） |
| `266b66b` | `reports/real-machine-acceptance.md`（撤回「同名函数遮蔽」+ 台架在位状态） |
| `cab1db5` | **新增** `reports/handoff-reconcile-r21.md` + `reports/real-machine-acceptance.md`（`§0.6` 补遗④）+ `reports/round12-deprecation-scope-review.md` |

⇒ 五笔**只动 `reports/`**、不碰 `tests/` `docs/` `lib/` `cmd/` ⇒ **与你的台架改动零重叠**；重叠只在 `reports/real-machine-acceptance.md` 与 `reports/round12-deprecation-scope-review.md` 这两个文件上。

### 5.3 建议顺序（**先 pick 再改，别倒过来**）

1. **先**把小编五笔按 `3dd5066 → eb43cee → 5cdc2a2 → 266b66b → cab1db5` 顺序 cherry-pick 到你的分支；
2. **再**落第三节的锚点修正（改 `ddfb492` → 新号 + 补过期索引），此时冲突面最小（你只在同一文件上加段落）；
3. **再**落你的四件套落档修订（若还没落）；
4. `docs/local-unverifiable-checklist.md` 的最终门禁行随第 2 步一起改。

> ⚠️ **不要反过来**（先改再 pick）—— 那样 `real-machine-acceptance.md` 会变成「两套四件套小节并存」，比现在更难解。

---

## 附：本文的复现命令

```bash
# 锚点可达性（空 = 悬空）
git branch -a --contains ddfb492

# 产品面等价（空 = 逐字相同 ⇒ 改锚合法）
git diff --stat ddfb492 70c89dd -- lib/ tests/ cmd/

# 台架面等价（blob 指纹）
git rev-parse 70c89dd:tests/run_tests.sh
git rev-parse 70c89dd:tests/TEST-HARNESS.md
git rev-parse 70c89dd:tests/cases/24_readend_collapse_t114.sh

# 原始证据仍在
cat /c/Users/liwend/AppData/Local/Temp/xwpf-sbx.llY2YF/DONE

# 两棵树的登记条数（当场取，勿用记忆里的数）
git show 70c89dd:tests/run_tests.sh | grep -cE '^\s*"T[0-9]+:'
git show cab1db5:tests/run_tests.sh  | grep -cE '^\s*"T[0-9]+:'
```
