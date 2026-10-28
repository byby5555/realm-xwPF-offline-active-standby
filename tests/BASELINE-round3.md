# 第 3 轮冻结基线报告（realm-xwPF-offline-active-standby）

> 维护者：阿测　　类型：**冻结基线**（当前最新的冻结点）
> 前序：[`BASELINE-round2.md`](./BASELINE-round2.md)（a9102c1，D-01/D-02/D-03 修复前）

---

## 0. 这次跑的是什么

| 项 | 值 |
|----|----|
| **冻结点 BASE_SHA** | `6df472181cbd058a1092899edd3abc98cf091e59`（短号 `6df4721`） |
| 冻结点标题 | `fix(update): 回滚失败必须被报出来 + 自动回滚前先停服务`（2026-10-24 11:34:36 +0800） |
| 所在分支 | `feat/update-center` |
| **台架版本** | `v2.1.0 (frozen-base + docs-refs)` |
| 跑批时间 | 2026-10-24 11:46:50 +0800 |
| 产物来源 | `git show $BASE_SHA:<path>`（**不读工作区**） |
| 产物指纹 | [`tests/baseline-manifest.txt`](./baseline-manifest.txt)（每个被测文件的 sha256，**已指向本轮**） |
| 跑批命令 | `BASE_SHA=6df4721 bash tests/run_tests.sh --repeat 3` |
| **结果** | **总计 34 条，通过 33，失败 1** |
| **多轮一致性** | **3 轮结果向量完全一致**（唯一红灯恒为 T34） |
| 唯一红灯 | **T34** —— docs 里的函数级引用指向了错误的源文件 |

> 跑批期间 HEAD 已前移到 `4b3b2468`（代提交测试台架 v2.1.0 与审稿报告）。
> **本报告结论只对 `6df4721` 成立。**

### 与上一轮（a9102c1）的对比

| 用例 | a9102c1 | 6df4721 | 变化原因 |
|------|---------|----------|---------|
| T33 规则缺可选字段时的 `set -u` 健壮性 | ❌ 红 | ✅ **绿** | 上游 `read_rule_file` 重写（见下） |
| T34 文档源码引用 | ✅ 绿 | ❌ **红** | 新增用例，抓到 docs 引用漂移 |
| 其余 32 条 | ✅ | ✅ | 无变化 |
| 越界残留 | 1 处 | **0 处** | `/opt/realm` 改路径重定向（台架侧） |

**T33 转绿的原因（`1c72634`「规则解析唯一化」）** ——
`read_rule_file` 从「unset 全部键 → `source` 规则文件」重写成「白名单逐行解析 + 每个白名单键统一赋值」：

```bash
for _key in $_allowed; do
    printf -v "$_key" '%s' "${_rule_vals[$_key]:-}"
done
```

→ 文件里没写的键**回落成空串**（不再是「未定义」），未定义变量的根因从底层被消除。
**第 2 轮的 P1 缺陷单（R2-D01）到此可以关闭。**

### 0.1 最终基线（全绿）

R3-D01 修完后，在当时的 HEAD 上出了一份**全绿基线**：

| 项 | 值 |
|----|----|
| 冻结点 | `4b3b2468ba8b483215534c9e683487f236357e02`（`test: 代提交测试台架 v2.1.0 与审稿报告`） |
| 跑批命令 | `BASE_SHA=4b3b246 bash tests/run_tests.sh --repeat 3` |
| **结果** | **总计 34 条，通过 34，失败 0** |
| **多轮一致性** | **3 轮结果向量完全一致** |
| 越界残留 | **0 处** |

> `tests/baseline-manifest.txt` 现在指向这份全绿基线（`4b3b246`）。
>
> 其后 `60070e8 fix(rules): 关闭 R2-D01` 又动了 `lib/{health,realm,rules,server}.sh`，
> 我做了**定向回归**（T01–T09 + T31–T34 共 13 条）：**13/13 全绿**，无回退。
> 该提交自述「只加了默认值与注释，行为等价（解析器已保证这些键有值）」，与实测一致。

---

## 1. 台架变更说明（第 3 轮）

| 变更 | 说明 |
|------|------|
| **新增 T34** | 文档源码引用一致性（`cases/05_docs_refs.sh`） |
| **T32 放宽** | 从「总数 == 2」改成「**总数 ∈ [1,2]**」+「生成物里恰好 1 份且与真源逐字一致」—— 兼容 `6df4721` 起的**单一真源**新结构（`health_emit_function` 自动抽取注入，不再手工维护内联副本） |
| **`/opt/realm` 路径重定向** | 越界残留 1 处 → **0 处**（见下） |
| **新增 `h_check_ge`** | 「命中数 ≥ N」护栏，防「正则坏掉 → 0 命中 → 假绿」 |
| 台架版本 | `v2.0.0` → **`v2.1.0 (frozen-base + docs-refs)`** |

### 关于 `/opt/realm`：不补白名单，改成路径重定向

`xwFailover.sh` 的 `find_file_path` 候选数组里有 `"/opt/realm/$filename"`（只读探测点，只做 `[ -f "$path" ]` 判断）。

**决定：加进 `SBX_PATH_MAP`（`/opt/realm` → `${SBX}/opt.realm`），不加白名单。**

理由：

- `/etc/realm`、`/var/lib/realm`、`/usr/local/realm`、`/tmp` **全都已经在重定向表里**，只有 `/opt/realm` 漏网。
- 加白名单 = 把这个口子**永久豁免**，扫描器以后就抓不到同类问题了。
- 改成重定向 = 沙箱彻底密闭（连读都不会碰到真 `/opt/realm`），扫描器回到 **0 处**，
  以后任何**新的**真实越界仍然会被抓到。
- 沙箱行为无变化：该目录在沙箱里同样不存在 → `find_file_path` 的结果与之前一致。

---

## 2. T34 · 文档源码引用一致性

### 为什么要有

D-01 把 docs 里的「文件:行号」升级成了「文件 的 函数名」，行号漂移这个病根就此消除。
但**行号本身**还会漂 —— 只要文档里还留着 `lib/core.sh:24` 这种写法，
`core.sh` 一改它就悄悄指错地方，**而且没有任何测试会发现**。

T34 分两层：

| 层 | 对象 | 断言 |
|----|------|------|
| A | 函数级引用 `` `lib/rules.sh` 的 `auto_enable_active_standby` `` | 该符号必须在这个文件里有定义（函数 `name()` **或**变量赋值 `name=` 都算）；**0 未解析** |
| B | 剩余的行号引用 `lib/core.sh:24` | 目标文件必须存在、行号必须在范围内（**0 失效**）；并把每一处指向的**行内容**打进日志当**漂移哨兵** |

**防空过护栏**：解析到的函数级引用处数必须 **≥ 100**（实测 211 / 212 / 219 三个 SHA）。
没有这条，正则一坏就是 0 命中 → 断言全过 → **假绿**。

> 这条护栏上线时真的拦住了我一次：我把「去重组数 63」和「出现次数 212」搞混，
> 护栏直接判红，逼我把两个计数口径分开。

### 负向对照（证明它有牙齿）

往冻结态副本里注入坏输入，确认断言会红：

| 对照 | 注入内容 | 结果 |
|------|---------|------|
| 基准 | 无 | 出现 212 / 去重 63 / 文件缺失 0 / 符号未定义 0 / 行号失效 0 |
| 1 | `` `lib/core.sh` 的 `no_such_function_xyz` `` | 符号未定义 0 → **1** ✅ |
| 2 | `` `lib/nope_not_exist.sh` 的 `some_func` `` | 文件缺失 0 → **1** ✅ |
| 3 | `lib/core.sh:99999` | 行号失效 0 → **1** ✅ |
| 4 | 把 `auto_enable_active_standby` 改名 | 符号未定义 1 → **2** ✅ ← **这就是 D-01 那类回归** |

---

## 3. `BASE_SHA=6df4721` 的用例表（34 条）

| 编号 | 用例 | 结论 |
|------|------|------|
| T01–T09 | 静态契约类 | ✅ 全绿 |
| T10–T15 | 权重校验与主备规则状态 | ✅ 全绿 |
| T16–T22 | 故障转移运行时 | ✅ 全绿 |
| T23–T25 | 自动进主备 / 选主切换 / 切回轮询 | ✅ 全绿 |
| T26–T28 | 探测函数行为（真源 / 生成物副本 / 两份一致） | ✅ 全绿 |
| T29–T30 | 主备 6 态 + 剔除 5 态端到端 | ✅ 全绿 |
| T31 | `set -u` 下的健壮性 | ✅ 全绿 |
| T32 | 探测实现结构 | ✅ 真源与生成物里的探测实现逐字一致 |
| T33 | 规则缺可选字段时的 `set -u` 健壮性 | ✅ **已转绿**（对照口径 + 主口径都过） |
| **T34** | **文档里的源码引用必须可解析** | ❌ **函数级引用指向的符号未定义数 = 1** |

**3 轮结果向量（完全一致）：**

```
T01=PASS;…;T32=PASS;T33=PASS;T34=FAIL;   （× 3 轮，逐字符相同）
```

**T34 现场：**

```
函数级引用: 出现 219 处 / 去重 67 组 (file+symbol)
符号未定义: lib/rules.sh->read_rule_file
FAIL: 函数级引用指向的符号未定义数 期望[0] 实际[1]
行号引用（去重后）: 27
```

---

## 4. 缺陷清单（按严重级）

### ✅ P2 · 中 · R3-D01 已修复 —— docs 里 `read_rule_file` 的归属文件写错了

> **状态：已修复。** 小编在 `84f78a1 docs: 修正规则解析器的文档指向（实现已迁到 lib/health.sh）` 里
> 按建议改掉了两处。实测 `BASE_SHA=84f78a1 bash tests/run_tests.sh --only T34` → **PASS**。
> 下面的分析保留，作为「这类漂移是怎么被抓住的」的记录。

**证据（修复前，T34 在 6df4721 上的现场）：**

```
符号未定义: lib/rules.sh->read_rule_file
```

**真相：** `read_rule_file` 的**唯一实现**在 `lib/health.sh:37`，
`lib/rules.sh:203` 自己都写着「read_rule_file 的唯一实现位于 lib/health.sh（白名单逐行解析，全程不用 source 规则文件）」。
但 docs 里有两处还写着 `lib/rules.sh`：

| 位置 | 原文 |
|------|------|
| `docs/install-and-upgrade.md:373` | 文件解析走 `read_rule_file`（**`lib/rules.sh` 的 `read_rule_file`**），只接受白名单里的 KEY |
| `docs/troubleshooting.md:71` | 规则解析走白名单 + 不用 `eval`（**`lib/rules.sh:204`**、**`lib/rules.sh` 的 `read_rule_file`**） |

**建议改法：**

```
docs/install-and-upgrade.md:373
- （`lib/rules.sh` 的 `read_rule_file`）
+ （`lib/health.sh` 的 `read_rule_file`）

docs/troubleshooting.md:71
- （`lib/rules.sh:204`、`lib/rules.sh` 的 `read_rule_file`）
+ （`lib/health.sh` 的 `read_rule_file`）
```

⚠ 第二处里的 `lib/rules.sh:204` 是**三重过时**，不能简单换成行号：

1. 文件错了 → 白名单常量已随 `read_rule_file` 搬到 `lib/health.sh`；
2. **符号已经不存在了** —— `_READ_RULE_ALLOWED_KEYS` 在 `6df4721` 上已被改成
   `read_rule_file` 里的 `local _allowed='...'`（`lib/health.sh:40`），全仓 grep 不到这个常量名；
3. 行号也漂了 —— `lib/rules.sh:204` 现在是一行注释。

→ 建议直接**只保留函数级引用**，把行号去掉。

> 📌 **实际修复（84f78a1）**：
> ```diff
> -文件解析走 `read_rule_file`（`lib/rules.sh` 的 `read_rule_file`），**只接受白名单里的 KEY**
> +文件解析走 `read_rule_file`（`lib/health.sh` 的 `read_rule_file`），**只接受白名单里的 KEY**
> -（`lib/rules.sh:204`），并且**不使用 `source` / `eval`**
> +（白名单变量 `_allowed` 就定义在这个函数里），并且**不使用 `source` / `eval`**
> ```
> T34 实测已转绿。
>
> 💡 **这个口径的固有边界**（值得记一笔）：`_allowed` 是**函数内局部变量**，
> 用「文件 的 符号」口径引用它时，grep 在文件顶层找不到定义 → T34 会判未定义。
> 所以文档里引用函数内局部变量时，**只能写成散文**（「白名单变量 `_allowed` 就定义在这个函数里」），
> 不能用统一口径。这类引用 T34 覆盖不到，属于该口径的已知盲区。

---

### 🟡 P2 · 低 · docs 里剩余 27 处行号引用仍会漂（其中 2 处**已经漂了**）

T34 的漂移哨兵把 27 处行号引用逐个打了出来（这是 `6df4721` 上的实际指向）：

| 文档里的引用 | 现在指向什么 | 状态 |
|-------------|------------|------|
| `lib/failover.sh:652-676` | `failover_pool_delete_all() {`（**清空所有池**） | 🔴 **已漂到无关函数**。文档说的是「版本指纹是文件内容哈希」，正确位置是 `lib/failover.sh:665-689`（`failover_file_fingerprint`） |
| `lib/rules.sh:204` | 一行注释（白名单常量已不存在） | 🔴 **已漂**（见上） |
| `xwPF.sh:53-100` | 空行区（`_bootstrap` 现在在 55） | 🟡 漂了 2 行 |
| `xwPF.sh:103-118` | 空行区（`_load_libs` 现在在 105） | 🟡 漂了 2 行 |
| `xwPF.sh:122-129` | `# 主入口`（`case` 现在在 123） | 🟡 漂了 1 行 |
| `xwPF.sh:16` / `:30-50` | 注释行 | 🟡 指的是注释与范围，需人工定口径 |
| `xwPF.sh:123` `:125` `:126` `:128` `:129` | 安装流程各步 | 🟡 需人工定口径（建议改成对应函数名） |
| `port-traffic-dog.sh:2390` | `local base="https://raw..."` | 🟡 需人工定口径 |

**16 处直接指向具名符号的，改成同一口径即可**（T34 的解析器已经支持变量赋值，改完立刻全覆盖）：

| 文档里的引用 | 那一行的符号 | 建议改成 |
|-------------|------------|---------|
| `lib/core.sh:24` | `REQUIRED_TOOLS` | `lib/core.sh` 的 `REQUIRED_TOOLS` |
| `lib/core.sh:4` | `REALM_VERSION` | `lib/core.sh` 的 `REALM_VERSION` |
| `lib/core.sh:74` | `REALM_PATH` | `lib/core.sh` 的 `REALM_PATH` |
| `lib/core.sh:76` | `CONFIG_PATH` | `lib/core.sh` 的 `CONFIG_PATH` |
| `lib/core.sh:77` | `SYSTEMD_PATH` | `lib/core.sh` 的 `SYSTEMD_PATH` |
| `lib/core.sh:78` | `RULES_DIR` | `lib/core.sh` 的 `RULES_DIR` |
| `lib/failover.sh:10` | `XWPF_FAILOVER_BIN` | `lib/failover.sh` 的 `XWPF_FAILOVER_BIN` |
| `lib/failover.sh:12` | `XWPF_FAILOVER_UNIT` | `lib/failover.sh` 的 `XWPF_FAILOVER_UNIT` |
| `lib/failover.sh:13` | `XWPF_FAILOVER_CONF_DIR` | `lib/failover.sh` 的 `XWPF_FAILOVER_CONF_DIR` |
| `lib/failover.sh:16` | `XWPF_FAILOVER_VERSION_FILE` | `lib/failover.sh` 的 `XWPF_FAILOVER_VERSION_FILE` |
| `lib/failover.sh:652-676` | `failover_file_fingerprint`（在 665） | `lib/failover.sh` 的 `failover_file_fingerprint` |
| `xwPF.sh:12` | `REPO_RAW_URL` | `xwPF.sh` 的 `REPO_RAW_URL` |
| `xwPF.sh:7` | `INSTALL_DIR` | `xwPF.sh` 的 `INSTALL_DIR` |
| `xwPF.sh:8` | `LIB_DIR` | `xwPF.sh` 的 `LIB_DIR` |
| `xwPF.sh:9` | `SHORTCUT_PATH` | `xwPF.sh` 的 `SHORTCUT_PATH` |
| `xwPF.sh:53-100` | `_bootstrap` | `xwPF.sh` 的 `_bootstrap` |

**建议的下一步：** 这 27 处全部改成函数级/符号级口径后，我在 T34 里再加一条硬断言
「docs 里不应再出现 `文件:行号` 形式的源码引用」—— 那时行号漂移就被彻底免疫了。

---

### 🟢 P3 · 已关闭 · 第 2 轮的 P1（R2-D01）

`lib/realm.sh` 未保护读 `$TARGET_STATES` → 已被 `1c72634` 的 `read_rule_file` 重写修复，
T33 在 `6df4721` 上已转绿。缺陷单关闭，详见 `BASELINE-round2.md` 的状态注记。

---

### 🔵 P4 · 台架侧 · 已改

`/opt/realm` 越界残留 —— 已改成路径重定向，越界残留归零。详见本文第 1 节。

---

## 5. 覆盖盲区与待真机清单

### 5.1 台架内仍未覆盖

| 盲区 | 原因 |
|------|------|
| 依赖 `jq` 的整段配置生成 | 本机无 `jq`，未打桩 |
| `lib/update.sh`（更新中心）/ `tests/test_update.sh` | 冻结点里已有，但**没有台架用例**（只有独立脚本） |
| `xw_realm_OCR.sh` | 一条都没测 |
| 规则文件的真实增删改落盘格式 | 只测了读与生成 |
| 时延测量 + 菜单渲染 | `tests/test_latency.sh` 未并入台架 |
| 真实 realm 消费生成的 `config.json` | 沙箱只生成文本，没有真 realm |

### 5.2 待真机验证（沿用第 2 轮，未变）

CRLF 源在真 Linux 的行为 · systemd timer 真机启停 · 真 realm 流量切换 ·
真 netcat/busybox nc 的 `-z` 差异 · 无 `timeout` 的精简 VPS 上 `/dev/tcp` 回退 ·
真 `flock` 并发 · 真 `bc` 浮点 · `jq` 分支 · 50 条规则性能 · shellcheck。

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

**当前基线链：**

| 轮次 | 冻结点 | 结果 |
|------|--------|------|
| 第 1 轮 | （工作区快照） | 22/22 |
| 第 2 轮 | `a9102c1` | 33/34（T33 红） |
| 第 3 轮 | `6df4721` | 33/34（T34 红） |
| 第 3 轮·全绿基线 | `4b3b246` | **34/34** |

---

## 7. 附：证据位置

| 证据 | 路径 |
|------|------|
| 产物指纹 | `tests/baseline-manifest.txt`（本轮 `6df4721`） |
| 每条用例的 stdout / log / notes / fails / meta | 本轮 `$SBX_ROOT/cases/`（`/tmp/xwpf-sbx.xGZfqY/cases/`） |
| 完整跑批输出 | 本机 `/tmp/r3_6df4721.txt`（临时文件，不入库） |
| 上一轮报告 | `tests/BASELINE-round2.md` |
| 台架说明 | `tests/TEST-HARNESS.md` |
| 用例索引 | `tests/README.md` |
