# 测试台架说明（realm-xwPF-offline-active-standby）

> 本目录由「阿测」维护。台架版本：`v2.1.0 (frozen-base + docs-refs)`。

## 一句话

`bash tests/run_tests.sh` —— 在**沙箱**里跑 34 条回归用例，
被测产物从**冻结点 SHA** 导出（不读工作区），只读仓库、绝不碰 `/etc`、`/usr`、`/var`。
全过退出码 0，有失败非 0。

## 跑法

```bash
bash tests/run_tests.sh                  # 全部用例（BASE_SHA 默认 = 当前 HEAD）
bash tests/run_tests.sh --only T10,T14   # 只跑指定用例
bash tests/run_tests.sh --repeat 3       # 连跑 3 轮，校验结果一致
bash tests/run_tests.sh --list           # 列出用例编号
bash tests/run_tests.sh --clean          # 跑完删掉沙箱

BASE_SHA=a9102c1 bash tests/run_tests.sh            # 指定冻结点（推荐）
bash tests/run_tests.sh --base-sha a9102c1          # 同上
```

---

## 一、冻结点机制（第 2 轮起）

### 为什么要有

仓库是多人并行的：Chief、小编、审稿、阿测同时在同一个工作区改东西。
第 1 轮实测出现过「**第 1 轮红、后 2 轮绿**」的假抖动 ——
根因不是代码在动，而是**跑批读到的工作区文件在跑批过程中被改写了**。
更糟的是，提交信息写着「全过」，但那「全过」引用的是另外三套脚本的 PASS 计数，不是正式门禁。

冻结点把「这次到底测了哪一份代码」**钉死**，结论不再随工作区漂移。

### 怎么用

| 场景 | 做法 |
|------|------|
| Chief 指定冻结点 | `BASE_SHA=<sha> bash tests/run_tests.sh`，报告里写明这个 SHA |
| 小编提交后回归 | 用**同一个** SHA 重跑；若 SHA 变了，旧结论作废，必须重跑 |
| 日常本地跑 | 不指定 `BASE_SHA`，默认取当前 `HEAD`（注意：此时结论只对那一刻的 HEAD 成立） |

### 三条硬规则

1. **被测产物一律从 `git show $BASE_SHA:<path>` 导出，绝不读工作区文件。**
   沙箱里产物分三层：
   - `$SBX_RAW` —— `git show` 的**原始字节**（行尾断言的权威来源）
   - `$SBX_SRC` —— 去 CR 的 **LF 副本**（静态检查用）
   - `$SBX_RUN` —— 再加**路径重定向 + root 模拟**（功能测试用）

   桩（`tests/shims/`）永远取工作区最新版 —— 台架自己不是被测对象。

2. **SHA 不存在就直接 `exit 2`，绝不静默退化成「读工作区」。**
   静默退化 = 结论不可复现 = 比报错更危险。

3. **SHA 一变，旧结论全部作废，必须重跑。**
   报告里必须写上：冻结点 SHA、冻结点标题、台架版本、产物指纹路径。

### 产物指纹

每次跑批都会在沙箱里写一份 `manifest.txt`：

```
repo        : <仓库路径>
BASE_SHA    : a9102c1
BASE_SHA 全 : a9102c1a20719cb808f11f9f5bbe94dbefceab30
BASE 标题   : <冻结点提交标题>
harness     : v2.0.0 (frozen-base)
time        : <跑批时间>
sandbox     : <沙箱路径>

--- 当前工作区 HEAD（仅供对照，不作为被测产物）---
head        : <HEAD>

--- git status --porcelain（跑批时刻的工作区状态）---
<改动清单>

--- sha256（冻结态原始 blob = 本次被测产物）---
<每个文件一行：sha256  path>
```

三份 manifest 对不上 → 被测对象变了 → 结论不可比。

### 台架自身的版本

台架改了（新增用例、修 fixture、换沙箱策略）就把 `run_tests.sh` 里的
`HARNESS_VERSION` **bump 一个号**。旧报告里带着旧台架版本的结论，参考价值要打折。

---

## 二、目录结构

| 文件 | 作用 |
|------|------|
| `run_tests.sh` | **唯一入口**：用例登记表、冻结点解析、沙箱构建、跑批、汇总表、退出码 |
| `lib/harness.sh` | 用例账本与断言助手（`h_check_eq` / `h_check_contains` / `h_check_rc` / `h_check_file` …） |
| `lib/sandbox.sh` | 沙箱构建：冻结态导出、LF 副本、路径重定向、root 模拟、离线镜像、基线 manifest、越界扫描 |
| `cases/00_common.sh` | 用例组公共工具 |
| `cases/01_static_contract.sh` | 静态契约类（T01–T09） |
| `cases/02_weight_active_standby.sh` | 权重校验与主备规则状态（T10–T15） |
| `cases/03_failover_runtime.sh` | 故障转移运行时（T16–T22） |
| `cases/04_legacy_merged.sh` | 第 2 轮从 4 套旧脚本并入的用例（T23–T33） |
| `cases/05_docs_refs.sh` | 文档源码引用一致性（T34，第 3 轮新增） |
| `shims/*` | 外部依赖打桩：`systemctl` `nc` `curl` `wget` `realm` `journalctl` `flock` `bc` `id` `apt-get` |

---

## 三、台架做了什么（以及为什么）

### 1. 冻结态导出

见上文「冻结点机制」。关键点：**静态检查也读冻结态**，不只是功能测试。
读工作区的静态检查在并行改动下同样会给出不可复现的结论。

### 2. LF 副本

仓库 `core.autocrlf=true`，Windows 工作区是 CRLF。直接 `source` 工作区副本在 Linux 语义下会出错，
所以被测产物一律先去 CR（`$SBX_SRC`），执行副本在其基础上再做路径重定向（`$SBX_RUN`）。

行尾断言一律用 `od` 数字节（`sbx_count_cr` / `sbx_count_crlf`），
**不靠 `grep`** —— MSYS 的 `grep` 对含 CR 的模式不可靠（实测 `printf 'a\r\n' | grep -c $'\r'` 返回 0）。

### 3. 路径重定向（防越界）

副本里所有系统绝对路径都被改写到沙箱目录，映射表见 `lib/sandbox.sh` 的 `SBX_PATH_MAP`：
`/etc/realm` `/etc/systemd/system` `/etc/xwpf` `/usr/local/bin` `/var/lock` `/tmp` …
跑完会做一次**越界残留扫描**，把副本里剩下的真实系统绝对路径列出来。

**当前：越界残留 0 处。**

> 第 3 轮的一次决策：`/opt/realm` 原先只剩 1 处越界残留
> （`xwFailover.sh` 的 `find_file_path` 候选数组里的 `"/opt/realm/$filename"`）。
> 它确实只是只读探测点（`[ -f "$path" ]` 判断后 echo 路径），但**没有加进只读白名单**，
> 而是**加进了路径重定向表**（`/opt/realm` → `${SBX}/opt.realm`）。
>
> 理由：`/etc/realm`、`/var/lib/realm`、`/usr/local/realm`、`/tmp` 全都已经重定向，
> 只有 `/opt/realm` 漏网。加白名单 = 把这个口子**永久豁免**，扫描器以后就抓不到同类问题了；
> 改成重定向 = 沙箱彻底密闭（连读都不会碰到真 `/opt/realm`），扫描器回到 0 处，
> 以后任何**新的**真实越界仍然会被抓到。

### 4. root 模拟

Git Bash 的 `EUID` 是 Windows uid（197610），`check_root` 会直接 `exit 1`。
沙箱副本把 `[[ $EUID -ne 0 ]]` 改成 `false`，等价于「以 root 运行」。

### 5. 外部依赖打桩

假 bin 目录放在 `PATH` 最前。`nc` 单独放一份在 `$SBX_BIN_NC`，**默认不进 PATH** ——
这样「机器上没装 nc」是默认状态，需要时用例显式加进来做对照口径。

`curl` / `wget` 桩从**离线镜像**取文件：镜像只放冻结态的内容，
所以「本地有、但没提交」的文件在镜像里是 404 —— 这正是要暴露的问题。
桩会把每次请求的 URL 记进日志，用例据此断言「下载地址是否指向本 fork」。

### 6. 提交信息自查提示

跑批结束会打印「上一条提交信息」的检查提示：
如果它声称「全过 / 全部通过 / 测试通过」，但**没有引用 `run_tests.sh`**，
台架会打出告警 —— 防止第 1 轮那种「引用的不是正式门禁」的提交信息再出现。

---

## 四、已知环境限制

| 限制 | 影响 | 处理 |
|------|------|------|
| MSYS 的 `grep` 对含 CR 的模式不可靠 | 行尾断言不能靠 `grep -c $'\r$'` | 改用 `od` 数字节（`sbx_count_cr` / `sbx_count_crlf`） |
| MSYS 读文件是文本模式 | CRLF 脚本在本机能正常跑，Linux 上会挂 | 该失败模式列为「待真机验证」 |
| 本机 `python3` 是 WindowsApps 占位符 | 监听端口起不来 | 改用真实 `python`（3.11.15） |
| 没有 `jq` / `nc` / `systemctl` / `flock` | 依赖这些的路径需打桩 | 已打桩；依赖 `jq` 的整段配置生成未覆盖 |
| 没有 WSL / Docker / shellcheck | 不能做真机级验证 | 全部列入「待真机验证」清单 |
| PowerShell 转义会坑 bash | `\|\|` / `\"` 被 PS 解析 | 复杂引号一律写成脚本文件再交给 bash 执行 |

---

## 五、退出码与证据

`0` = 全部通过；非 `0` = 有失败（`1`）。冻结点不存在时是 `2`（参数/环境错误，与「有失败」区分开）。

每条用例的 stdout / 断言记录 / 元信息都在
`$SBX_ROOT/cases/<编号>.{stdout,log,notes,fails,meta}`，跑完会打印沙箱路径。

同一产物连跑 3 次的结果向量必须一致（`--repeat 3` 会自动校验并打印）。
**只红一次先怀疑用例本身**：用第二口径交叉验证后再报缺陷。

---

## 六、断言纪律（写新用例时必读）

1. **负向对照**：新断言写完，往冻结态副本里注入一个坏输入，确认它**会红**。
   「怎么写都绿」的断言等于没有断言。
   T34 的负向对照做过 4 组：注入不存在的符号 → 抓；注入不存在的源文件 → 抓；
   注入越界行号 → 抓；把 `auto_enable_active_standby` 改名 → 抓（就是 D-01 那类回归）。
2. **命中数下限护栏**：像「解析 N 处引用」这种用例，正则一坏就是 0 命中 → 断言全过 → 假绿。
   另加一条「命中数 ≥ N」（N 取实测值的 ~1/2）。
3. **防空过护栏不是装饰**：T34 上线时，这条护栏真的拦住了我一次 ——
   我把「去重组数 63」和「出现次数 212」搞混，护栏直接判红，逼我把计数口径分开。
4. **断言行为，不钉实现位置**；**静态检查读冻结态**；
   **不要在文件头快照还没建好的沙箱路径**；**fixture 只参数化不裁剪键集**；
   **一条红灯要能被第二口径交叉验证**。
   （细则见 `tests/README.md` 的「写用例时的几条硬规矩」。）
