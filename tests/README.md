# 测试目录

本地回归测试（Git Bash / Linux / macOS 均可跑，**不需要 root**，不会碰真实的 `/etc/realm`）。

> **第 2 轮起本目录只有一个入口：`bash tests/run_tests.sh`。**
> 其它 `tests/test_*.sh` 全部退化成**薄封装**（内部 `exec` 到 `run_tests.sh --only ...`），
> 保留它们只是为了不打断别人的调用习惯 —— 它们**不是独立门禁**，跑出来的结论与主入口完全同源。
> 「全过」这个词只认 `run_tests.sh` 的输出。

---

## 跑法

```bash
# 主入口（唯一）
bash tests/run_tests.sh                      # 跑全部 34 条用例
bash tests/run_tests.sh --only T06,T18       # 只跑指定用例
bash tests/run_tests.sh --repeat 3           # 连跑 3 轮，校验结果向量一致
bash tests/run_tests.sh --list               # 列出用例编号
bash tests/run_tests.sh --clean              # 跑完删掉沙箱

# 冻结点（第 2 轮新增，强烈建议正式跑批时显式指定）
BASE_SHA=a9102c1 bash tests/run_tests.sh
bash tests/run_tests.sh --base-sha a9102c1   # 等价写法
```

退出码：`0` = 全部通过；非 `0` = 有失败。

### 冻结点机制（一句话）

被测产物一律从 `git show $BASE_SHA:<path>` 导出，**不读工作区文件**。
`BASE_SHA` 默认取当前 `HEAD`；正式跑批请显式指定，报告里必须写上这个 SHA。
**SHA 一变，旧结论全部作废，必须重跑。**

细节见 [`tests/TEST-HARNESS.md`](./TEST-HARNESS.md)。

---

## 用例清单（34 条）

| 编号 | 用例 | 覆盖点 |
|------|------|--------|
| **静态契约（读冻结态，不执行）** | | |
| T01 | 下载地址一致性 | 所有下载地址指向 `byby5555/realm-xwPF-offline-active-standby`，旧仓库名 0 条 |
| T02 | 旧仓库名残留 | 全仓 `zywe03/realm-xwPF` 出现次数 = 0 |
| T03 | 行尾检查（提交态） | 冻结态 raw blob 里每个 `.sh` 的 CR 字节数 = 0（提交态必须 LF） |
| T04 | xwPF.sh --help 入口 | `xwPF.sh` / `lib/ui.sh` 里存在 `--help` 处理分支 |
| T05 | xwFailover.sh help 与文档一致性 | `help` 列出的 7 个子命令在 docs/README 都有说明 |
| T07 | 文档声称的测试脚本 | 文档里反引号写出的测试脚本路径必须真实存在（文档没声明就不判失败） |
| T08 | 文档声明的唯一真源 | 被文档称为「唯一真源」的 `lib/health.sh` 必须存在于同一棵树里 |
| T09 | 仓库里被跟踪的编译产物 | 不跟踪 `.pyc` / `__pycache__` |
| T32 | 探测实现结构 | 全仓 `check_connectivity() {` 份数 **∈ [1,2]**（1 = 已收敛为单一真源；2 = 真源 + 生成脚本内联副本；**>2 = 有人又抄了一份 → 红**），且副本全部集中在 `lib/health.sh`；**生成出来的 `health_check.sh` 里恰好 1 份，且与真源逐字一致** |
| **权重校验与主备规则状态** | | |
| T10 | 权重 `1,0,0` 合法 | `validate_weight_input` 返回 0 |
| T11 | 权重 `0,0,0` 必须被拒绝 | 返回非 0 + 「不能全部为 0」提示 |
| T12 | 权重数量与目标数不符必须被拒绝 | 返回非 0 + 数量不匹配提示 |
| T13 | 权重越界/非法字符必须被拒绝 | `11,0,0` / `1,0,-1` / `1,0,x` 非 0；`10,0,0` 边界合法 |
| T14 | 权重 `1,0,0` → 规则进入主备态 | 规则被写成 `BALANCE_MODE=active-standby` + `FAILOVER_ENABLED=true` + 补齐 5 个健康检查参数 |
| T15 | 权重含 0 的主备判定 | `weights_contain_zero` 对 `1,0,0` / `5,5` / `0` 的判定 |
| **故障转移运行时** | | |
| T16 | 主备 → 健康检查 timer 被拉起 | 规则进主备后健康检查 timer 被创建/启用 |
| T17 | 健康检查脚本与 systemd unit 一致 | `ExecStart` 指向生成的 `health_check.sh` |
| T18 | 无 nc 时的连通性回退 | PATH 里没有 `nc` 时走 `bash /dev/tcp` 仍判连通；加回 `nc` 桩作第二口径 |
| T19 | 主备权重翻转 | 主挂 → `0,1`；主恢复 → `1,0`（严格主备，不退化为多活） |
| T20 | 安装引导的离线下载 | 离线镜像里能取到全部功能脚本（缺一个就红） |
| T21 | xwPF.sh --help 实际行为 | 真跑一次 `--help`，输出里有用法 |
| T22 | 生成物行尾归一化 | 生成到磁盘的脚本/unit 文件行尾是 LF（od 数字节判定） |
| **第 2 轮从 4 套独立脚本并入** | | |
| T23 | 权重含 0 → 自动进主备 | 多规则场景下自动启用主备并补齐参数 |
| T24 | 主备优先级选主与切换 | 权重大的当主；主故障 → 切备；全挂兜底强制保留最高优先级目标 |
| T25 | 权重全 >0 → 自动切回轮询 | `BALANCE_MODE` 回到 `roundrobin`，故障转移保持开启 |
| T26 | 探测函数行为（入口加载的那份） | 从健康检查入口加载探测实现：可达端口通、关闭端口不通、不可达 IP 失败且耗时受控 |
| T27 | 生成的 `health_check.sh` 里的探测副本行为 | 从生成物里提取内联副本单独调用，同样要能走 `/dev/tcp` 回退 |
| T28 | 两份探测实现必须一致 | 源实现 vs 生成脚本内联副本，归一化后逐行相同（防漂移） |
| T29 | 主备模式 6 态端到端 | 与 `docs/active-standby-logic.md` 状态表一一对应（平时/主挂/主+备1挂/主恢复/全挂兜底） |
| T30 | 剔除模式 5 态端到端 | 全健康 3 个目标 / 主挂剩 2 / 主+备1挂剩 1 / 全挂保留 1 / `failover off` 不过滤 |
| T31 | `set -u` 下的健壮性 | 对照组证明旧写法致命、新写法安全；`set -u` 下生成配置不中断、输出与普通模式一致 |
| T33 | 规则缺可选字段时的 `set -u` 健壮性 | 规则文件缺 `TARGET_STATES` 等可选键时不得致命中断（读变量必须带默认值） |
| **文档源码引用（第 3 轮新增）** | | |
| T34 | 文档里的源码引用必须可解析 | ① 函数级引用 `` `lib/rules.sh` 的 `auto_enable_active_standby` `` → 该符号必须在这个文件里有定义（函数 `name()` 或变量赋值 `name=` 都算）；函数改名/移动/删除一律红。② 剩余的行号引用（`lib/core.sh:24` 这类）→ 目标文件必须存在、行号必须在范围内；并把每一处指向的行内容打进日志当**漂移哨兵**，下次跑批对比即知有没有漂 |

> T06（无 nc 时的健康检查）是一次**端到端行为断言**：跑生成的 `health_check.sh`，
> 看健康状态文件里有没有写出 `healthy` —— 不断言「实现放在哪个文件」，避免重构即假红。

---

## 旧脚本 → 薄封装映射

第 2 轮把原来 4 套独立脚本的用例并入 `run_tests.sh`，脚本本身保留为薄封装：

| 旧脚本 | 现在转发到 | 原覆盖点 |
|--------|-----------|---------|
| `tests/test_active_standby.sh` | `run_tests.sh --only T10,T11,T12,T13,T14,T15,T23,T24,T25` | 权重校验 / 含 0 检测 / 自动主备 / 选主 / 故障切换 / 兜底 / 反向切换 |
| `tests/test_connectivity.sh` | `run_tests.sh --only T06,T18,T26,T27,T28` | `/dev/tcp` 回退 / 两份实现一致 / 可达端口 / 关闭端口 / 不可达 IP |
| `tests/test_e2e.sh` | `run_tests.sh --only T19,T29,T30` | 主备 6 态 + 剔除 5 态端到端 |
| `tests/test_set_u.sh` | `run_tests.sh --only T31` | 对照组 + 生成不中断 + 输出一致 + 其他函数健壮 |

`tests/test_latency.sh` 不在并入范围（它覆盖时延测量与菜单渲染，需要 `now_us` / `EPOCHREALTIME`），
仍保留为独立脚本，需要时单独跑。

---

## 目录结构

| 文件 | 作用 |
|------|------|
| `run_tests.sh` | **唯一入口**：用例登记表、冻结点解析、沙箱构建、跑批、汇总表、退出码 |
| `lib/harness.sh` | 用例账本与断言助手（`h_check_eq` / `h_check_ge` / `h_check_contains` / `h_check_rc` / `h_check_file` …） |
| `lib/sandbox.sh` | 沙箱构建：冻结态导出、LF 副本、路径重定向、root 模拟、离线镜像、基线 manifest、越界扫描 |
| `cases/00_common.sh` | 用例组公共工具（`_run_in_sandbox` / `_make_rule` / `_make_failover_rule` / `_make_minimal_rule` / `_start_listener` …） |
| `cases/01_static_contract.sh` | 静态契约类（T01–T09） |
| `cases/02_weight_active_standby.sh` | 权重校验与主备规则状态（T10–T15） |
| `cases/03_failover_runtime.sh` | 故障转移运行时（T16–T22） |
| `cases/04_legacy_merged.sh` | 第 2 轮从 4 套旧脚本并入的用例（T23–T33） |
| `cases/05_docs_refs.sh` | 文档源码引用一致性（T34，第 3 轮新增） |
| `shims/*` | 外部依赖打桩：`systemctl` `nc` `curl` `wget` `realm` `journalctl` `flock` `bc` `id` `apt-get` |
| `BASELINE-round*.md` | 冻结基线报告（每轮一份，代表「那时的真实状态」） |
| `baseline-manifest.txt` | **当前**冻结基线的产物指纹（BASE_SHA + 每个被测文件的 sha256） |

每条用例的 stdout / log / notes / fails / meta 都落在沙箱的 `cases/` 目录里，便于复查。

---

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
> 被测对象始终是冻结态里的 `lib/*.sh` 与 `xwFailover.sh`。

---

## 写用例时的几条硬规矩

1. **断言行为，不钉实现位置**。不要断言「函数在哪个文件里」，要断言「跑出来的结果是什么」。
   （T06 就是这么从「钉文件」改成「钉行为」的。）
2. **静态检查读冻结态**，不要读工作区，也不要用 `git ls-files --eol`（查的是索引，不是冻结态）。
3. **不要在文件头把沙箱路径快照成变量**。用例文件是在沙箱建好**之前**被 source 的，
   那时 `$SBX_SRC` 还是空的 —— 快照下来会变成「读不到任何文件 → 0 命中 → 判过」的假绿。
   一律在用例函数体内直接用 `"$SBX_SRC"`。
4. **fixture 只做参数化，不裁剪键集**。规则文件要写全官方键集（见 `lib/server.sh` 的模板），
   否则 `read_rule_file` 的 `unset` 会让缺失的键变成未定义变量。
5. **一条红灯要能被第二口径交叉验证**。先确认「是不是用例自己错了」，再报缺陷。
6. **新断言必须有负向对照**。写完先往冻结态副本里注入一个坏输入，确认它**会红** ——
   「怎么写都绿」的断言等于没有断言。T34 的负向对照做过 4 组：
   注入不存在的符号 → 抓；注入不存在的源文件 → 抓；注入越界行号 → 抓；
   把 `auto_enable_active_standby` 改名 → 抓（这就是 D-01 那类回归）。
7. **命中数要有下限护栏**。像 T34 这种「解析 N 处引用」的用例，
   正则一坏就是 0 命中 → 断言全过 → 假绿。所以另加一条「命中数 ≥ N」的断言（N 取实测值的 ~1/2）。
