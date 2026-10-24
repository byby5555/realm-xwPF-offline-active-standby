# realm-xwPF-offline-active-standby · 第 1 轮测试基线报告

- 测试员：阿测（bot_c087bd307a2d）
- 报告时间：2026-10-24 10:55 (UTC+8)
- 测试台架：`tests/run_tests.sh`（22 条用例，用例表驱动）
- 台架说明：[`tests/TEST-HARNESS.md`](./TEST-HARNESS.md)
- 被测基线：HEAD `2244886` + 工作区未提交改动，指纹见 [`tests/baseline-manifest.txt`](./baseline-manifest.txt)

---

## 0. 一句话结论

**最终基线上 22/22 用例通过，连跑 3 轮结果完全一致。**
本轮跑批过程中我实测抓到 **7 个缺陷**（含 1 个阻断级），其中 **7 个在我出报告前已被小编并发修复**（仓库在多人同时改，每一处都有跑批留证）。
**仍然存在 3 条文档类缺陷**（见 §3-A），已交给小编。

> ⚠️ **基线可复现性提醒**：本轮跑批期间仓库被并发修改，`lib/health.sh` / `xwFailover.sh` / `lib/rules.sh` 等在跑批过程中被改写。
> 曾经出现过「第 1 轮红、后 2 轮绿」的假抖动，追下去是**被测对象变了**（manifest 的 sha256 对不上），不是用例不稳。
> **结论**：任何回归结论必须带上 `tests/baseline-manifest.txt` 里的 sha256，否则不可比。

---

## 1. 环境与沙箱说明

### 1.1 本机环境（已核实）

| 项 | 实况 |
|----|------|
| shell | Git Bash `C:\Users\liwend\AppData\Local\hermes\git\bin\bash.exe`，GNU bash 5.3.9 (cygwin) |
| Python | 3.11.15（`python` 可用；`python3` 是 WindowsApps 占位符，不可用） |
| 缺失 | 无 WSL 发行版、无 Docker、无 shellcheck、`nc`/`wget`/`systemctl`/`flock`/`bc`/`jq` 都没有 |
| 目标运行环境 | Debian/Ubuntu VPS（systemd、`/etc/realm`、nc、realm 二进制） |

### 1.2 沙箱做了什么

| 措施 | 做法 | 为什么 |
|------|------|--------|
| **LF 副本** | 仓库 `core.autocrlf=true`，工作区是 CRLF；被测产物一律 `tr -d '\r'` 后的 LF 副本 | 直接 source 工作区副本行尾语义不对 |
| **路径重定向** | 副本里 `/etc/realm` `/etc/systemd/system` `/etc/xwpf` `/usr/local/bin` `/var/lock` `/tmp` … 全部改写到 `mktemp -d` 出来的沙箱 | 绝不碰真实 `/etc`、`/usr`、`/var` |
| **越界扫描** | 跑完扫描副本里残留的真实系统绝对路径 | 当前只剩 1 处只读查找 `/opt/realm/$filename` |
| **root 模拟** | 副本里 `[[ $EUID -ne 0 ]]` → `false` | Git Bash 的 `EUID` 是 Windows uid（197610），`check_root` 会直接 exit |
| **外部打桩** | 假 bin 放 `PATH` 最前：`systemctl` `nc` `curl` `wget` `realm` `journalctl` `flock` `bc` `id` `apt-get` | 隔离真实 systemd / 网络 |
| **nc 默认缺席** | `nc` 单独放一份，默认**不进** PATH | 默认模拟「机器上没装 nc」，需要时用例显式加入做对照口径 |
| **离线镜像** | `curl`/`wget` 桩从本地镜像取文件，镜像**只放 `git ls-files` 跟踪的内容** | 模拟 GitHub raw：「本地有但没提交」的文件在这里是 404，正好暴露问题 |
| **基线 manifest** | 每次跑批写 `manifest.txt`：HEAD + `git status` + 每个被测文件 sha256 | 仓库并发改动，基线必须钉死 |

**桩的行为约定**：`systemctl` 记录调用（`is-active`/`is-enabled` 返回 3 = inactive）；`nc` 按 `host:port` 黑名单判失败；`curl`/`wget` 按 URL 里 `/main/` 之后的路径取镜像文件，取不到返回 22/8（模拟 404）。

### 1.3 本机验证 vs 真机验证的边界

| 已在**本机沙箱**验证 | 必须在**真机 VPS** 验证 |
|----------------------|----------------------|
| 权重校验、主备规则字段写入、健康检查 timer 拉起、systemd unit 生成内容与路径一致性、连通性回退逻辑、权重翻转输出、离线下载链路、`--help` 行为、文档与实现一致性 | realm 二进制真实转发、systemd 真实启停与 `journalctl`、真实 `/etc/realm` 落盘、真实 nc/`/dev/tcp` 探测到公网、守护进程 `xwpf-failover` 的 active/passive 热切换、卸载流程 |

---

## 2. 用例表

`bash tests/run_tests.sh --repeat 3` → **总计 22 条，通过 22，失败 0；3 轮结果向量完全一致。**

| 编号 | 用例 | 前置 | 命令 | 期望 | 实际 | 结论 |
|------|------|------|------|------|------|------|
| T01 | 下载地址一致性 | 仓库工作区（只读） | `git grep` 下载类 URL（wget/curl/raw 行） | 全部指向 `byby5555/realm-xwPF-offline-active-standby`，违例 0 条 | 违例 0 条 | PASS |
| T02 | 旧仓库名残留 | 仓库工作区（只读） | `git grep -n -F 'zywe03/realm-xwPF'` | 全仓出现 0 次 | 0 次 | PASS |
| T03 | 行尾检查（索引） | 仓库工作区（只读） | `git ls-files --eol -- '*.sh'` | 全部 `i/lf` | 13 个 `.sh` 全部 `i/lf` | PASS |
| T04 | `xwPF.sh --help` 入口 | 仓库工作区（只读） | `grep -- '--help' xwPF.sh lib/ui.sh` | 入口侧有 `--help` 处理分支 | 命中 5 处 | PASS |
| T05 | `xwFailover.sh help` 与文档 | 沙箱副本（LF+重定向） | `source xwFailover.sh; main help` | help 的 7 个子命令都有文档说明 | 7/7 有说明 | PASS |
| T06 | 健康检查 `/dev/tcp` 回退 | 仓库工作区（只读） | `grep '/dev/tcp' lib/health.sh xwFailover.sh lib/core.sh` | 健康检查实现里有回退 | `lib/health.sh` 命中 5 处 | PASS |
| T07 | 文档声称的测试脚本 | 仓库工作区（只读） | `grep -rn 'test_e2e.sh' docs/` | 文档引用的路径真实存在 | `tests/test_e2e.sh` 存在 | PASS |
| T08 | 文档声明的唯一真源 | 仓库工作区（只读） | `grep -rn 'lib/health.sh' docs/` | `lib/health.sh` 存在 | 存在 | PASS |
| T09 | 仓库里的编译产物 | 仓库工作区（只读） | `git ls-files '*.pyc'` | 不跟踪 `.pyc` | 0 个 | PASS |
| T10 | 权重 `1,0,0` 合法 | 沙箱 core.sh+rules.sh | `validate_weight_input '1,0,0' 3` | 返回码 0 | 返回码 0 | PASS |
| T11 | 权重 `0,0,0` 被拒 | 沙箱 core.sh+rules.sh | `validate_weight_input '0,0,0' 3` | 非 0 + 提示「不能全部为 0」 | 非 0，提示命中 | PASS |
| T12 | 权重数量不符被拒 | 沙箱 core.sh+rules.sh | `validate_weight_input '1,0' 3` | 非 0 + 提示「数量不匹配」 | 非 0，提示命中 | PASS |
| T13 | 权重越界/非法字符被拒 | 沙箱 core.sh+rules.sh | `11,0,0` / `1,0,-1` / `1,0,x` / `10,0,0` | 前三者非 0；`10,0,0` 为 0 | 全部符合 | PASS |
| T14 | 权重 `1,0,0` → 规则进主备态 | 沙箱 rules 目录 | `auto_enable_active_standby 8080` | 写入 `BALANCE_MODE=active-standby`、`FAILOVER_ENABLED=true` + 5 项健康检查参数 | 全部写入 | PASS |
| T15 | 权重含 0 判定 | 沙箱 core.sh+rules.sh | `weights_contain_zero '1,0,0'/'1,1,1'` | 含 0 → 0；全 >0 → 非 0 | RC_ZERO=0 / RC_NOZERO=1 | PASS |
| T16 | 主备 → 健康检查 timer 拉起 | 沙箱 rules + xwFailover.sh + health.sh | `ensure_health_check_service` | 调用 `systemctl enable/start realm-health-check.timer` | enable/start 均命中 | PASS |
| T17 | 健康检查脚本与 systemd unit 一致 | 沙箱生成产物 | 检查 `health_check.sh` / `.service` / `.timer` | `ExecStart` 指向真实脚本、名称路径自洽、产物无 CR | 全部一致，CR=0 | PASS |
| T18 | 无 nc 时的连通性回退 | 沙箱 PATH 不含 nc + 本地监听端口 | `check_connectivity 127.0.0.1 <port>` | 无 nc 时走 `/dev/tcp` 判连通 | 无 nc RC=0；有 nc 对照 RC=0 | PASS |
| T19 | 主备权重翻转 | 沙箱 rules + health_status.conf | `generate_endpoints_from_rules` | 主挂→`0,1,0`；全健康→`1,0,0`；全挂→`1,0,0` | 三态全部符合 | PASS |
| T20 | 安装引导的离线下载 | curl/wget 桩 + 镜像(=GitHub 已跟踪内容) | `_bootstrap` | 下载地址全指向本 fork；xwPF.sh+7 个 lib+2 个 cmd 全部落盘；sha256 一致 | 10 个 URL 全对，10 个文件全落盘，sha256 一致 | PASS |
| T21 | `xwPF.sh --help` 实际行为 | 沙箱 INSTALL_DIR + 假 bin | `bash xwPF.sh --help` | 打印用法并退出，不进交互菜单 | 输出含「用法 / Usage」，正常退出 | PASS |
| T22 | 生成物行尾归一化 | 仓库工作区（只读） | 检查生成 `health_check.sh` 的代码 | 生成前剥掉 CR | 已做 `tr -d '\r'` | PASS |

> T18 的对照口径：先起一个本地监听端口做阳性对照，确认本机 `/dev/tcp` 可用（rc=0），再分别在「PATH 无 nc」「PATH 有 nc 桩」两种情况下调用同一函数，两条路径结论一致才算通过。

---

## 3. 缺陷清单

### A. 最终基线上仍然存在（已交小编修）

#### D-01 · 文档行号引用整体漂移 · 严重级：一般

- **位置**：`docs/active-standby-logic.md`「关键代码位置」表（第 99–110 行）
- **复现步骤**：
  ```bash
  cd realm-xwPF-offline-active-standby
  grep -n '^get_balance_info_display()\|^switch_balance_mode()\|^configure_port_group_weights()\|^validate_weight_input()' lib/rules.sh
  grep -n 'active-standby' lib/realm.sh
  grep -n 'toggle_failover_mode()\|主备模式 (active-standby)' xwFailover.sh
  ```
- **实际**：文档表里 8 条引用**全部**对不上

  | 文档写的 | 文档说的符号 | 实际行号 |
  |---|---|---|
  | `lib/rules.sh 196–217` | `get_balance_info_display` | **240** |
  | `lib/rules.sh 2067–2098` | `switch_balance_mode` | **1968** |
  | `lib/rules.sh 2293–2295` | `configure_port_group_weights` | **2341** |
  | `lib/rules.sh 2316–2340` | `validate_weight_input` | **2401** |
  | `lib/realm.sh 413–528` | 故障转移主备分支 | **477** |
  | `lib/realm.sh 619–637` | 主备→roundrobin 映射 | **709** |
  | `xwFailover.sh 200–201` | 提示条件（含「主备」） | **280** |
  | `xwFailover.sh 237–258` | 选择剔除/主备模式 | **313–331** |

- **期望**：行号指向对应符号（差 1–2 行可接受，整段差 40+ 行不可接受）
- **影响面**：文档是给排障用的，`docs/troubleshooting.md` 大量用 `文件:行号` 指路；读者按行号跳过去看到的是无关代码，误判成本高
- **建议**：要么修行号，要么改成符号名定位（`lib/rules.sh` → `validate_weight_input()`），后者不再随改动漂移

#### D-02 · 文档状态描述过时 · 严重级：一般

- **位置**：`docs/README.md:99`
- **复现步骤**：`grep -rn '尚未落盘' docs/`
- **实际**：仍写着「`lib/health.sh` 正在从 `xwFailover.sh` 抽出，**尚未落盘**；在此之前健康检查脚本仍由 …」
- **期望**：`lib/health.sh` 已经落盘、已被 `xwPF.sh` 的 `LIB_FILES` 引用、已提交进 git（`git ls-files lib/health.sh` 有输出），文档应改成「已落盘」
- **影响面**：读者会以为 `lib/health.sh` 还不存在，`docs/README.md` 同时又宣称它是「唯一真源」——同一份文档里自相矛盾

#### D-03 · 缺测试台架索引 · 严重级：建议

- **位置**：仓库根 `README.md` / `docs/README.md`
- **实际**：`tests/` 下现在有 6 个测试入口（`README.md`、`test_active_standby.sh`、`test_connectivity.sh`、`test_e2e.sh`、`test_set_u.sh`、本轮的 `run_tests.sh`），没有任何一处列出「有哪些测试、怎么跑、各自覆盖什么」
- **期望**：至少在 `docs/README.md` 加一张测试索引表（脚本 → 覆盖点 → 怎么跑）
- **影响面**：多套测试并存且无人维护索引，新人不知道该跑哪个；后续合并测试框架时没有清单可依

### B. 本轮实测抓到、已被小编并发修复（留档作回归点）

> 每一条都有跑批留证（沙箱 `cases/<编号>.{stdout,fails}`），修复后已回归为 PASS。

| 编号 | 严重级 | 缺陷 | 证据 | 现状 |
|------|--------|------|------|------|
| R-01 | **阻断** | `xwPF.sh` 的 `LIB_FILES` 已经包含 `health.sh`，但 `lib/health.sh` **没有提交进 git** → `raw.githubusercontent.com/.../main/lib/health.sh` 404 → 一键安装必然失败 | 跑批日志：`✗ lib/health.sh 下载失败` → `_bootstrap` 返回 1；`xwPF.sh --help` 报「错误: 缺少模块 health.sh」；`git ls-files lib/health.sh` 当时为空 | 已修：文件已提交，T20 现在 10 个文件全部落盘 |
| R-02 | **严重** | 健康检查的 `check_connectivity` 没有 `/dev/tcp` 回退 → 机器没装 nc 时**所有目标判为故障** → 主备永远误判全挂。`docs/install-and-upgrade.md §1.3` 当时还把它写成「已知限制」 | T06：`xwFailover.sh` 命中 0 处；T18 无 nc 场景返回失败 | 已修：回退落到 `lib/health.sh`（命中 5 处），T18 两种 PATH 都判连通 |
| R-03 | 严重 | 6 处「项目开源」链接仍指向旧仓库 `zywe03/realm-xwPF`（`port-traffic-dog.sh` 5 处、`speedtest.sh` 1 处），`port-traffic-dog-README.md` 的下载命令也指向旧仓库 | T02 首次跑批：命中 8 处（其中 2 处是我的用例自身，已排除 `tests/`） | 已修：T01/T02 现在均为 0 |
| R-04 | 一般 | `xwPF.sh` 完全没有 `--help` 分支 → `pf --help` 会掉进交互菜单 | T04 首次跑批命中 0 处；T21 首跑超时（进菜单） | 已修：命中 5 处，T21 正常打印「用法 / Usage」并退出 |
| R-05 | 一般 | `xwFailover.sh help` 的 7 个子命令里只有 3 个在 docs 里有说明（缺 `toggle` `stop` `restart-realm` `help`） | T05 首次跑批：3/7 | 已修：7/7 |
| R-06 | 一般 | 文档声称「通过 `tests/test_e2e.sh`（11 个场景全过）覆盖」，但该文件不存在 | T07：缺失 `test_e2e.sh` | 已修：`tests/test_e2e.sh` 已存在 |
| R-07 | 一般 | 生成 `health_check.sh` 前不做行尾归一化 → 从 CRLF 安装源（Windows 工作区 / 离线打包）生成的脚本带 CR，systemd 执行时报 `$'\r': command not found` | T22 第 1 轮红、第 2/3 轮绿；追查 manifest 发现 `lib/health.sh` 的 sha256 在跑批期间变了 | 已修：`cat << 'EOF' \| tr -d '\r'` / `tr -d '\r' > "$health_service"` |

---

## 4. 覆盖盲区与未测项

### 4.1 本机**没有**覆盖到的（需要真机或补件）

| 盲区 | 原因 | 建议补法 |
|------|------|----------|
| realm 二进制真实转发 / `config.json` 实际生效 | 本机无 realm 二进制、无 Linux | 真机装 realm 后跑一次 `pf` 生成配置并 `realm -c config.json` 起服务 |
| systemd 真实启停、`journalctl` 输出、timer 周期 | 本机无 systemd，只打了桩 | 真机 `systemctl start realm-health-check.timer` + `journalctl -u realm-health-check.service -f` |
| 真实 `/etc/realm` 落盘与卸载清理 | 台架路径重定向，禁止碰真实路径 | 真机走一遍安装 → 卸载，确认无残留 |
| 公网目标连通性探测（nc 与 `/dev/tcp` 对真实主机） | 沙箱只对本地监听端口探测 | 真机用两个真实目标验证「健康 / 故障」切换 |
| 守护进程 `cmd/xwpf-failover.py` 的 active/passive 热切换 | 本轮完全没碰 | 单独立项：双机热备 + 主备切换 + 端口漂移 |
| `lib/failover.sh` 的守护安装/版本比对/升级 | 本轮完全没碰 | 真机装一遍守护，看版本比对与升级路径 |
| 依赖 `jq` 的整段配置生成（`generate_realm_config` 全流程） | 本机无 jq，未打桩 | 装 jq 后把 `generate_realm_config` 纳入沙箱用例 |
| `realm.sh` 的 MPTCP / Proxy / TLS / WS 分支 | 本轮只测了负载均衡与主备 | 按功能域分批补 |
| `port-traffic-dog.sh` / `speedtest.sh` / `xw_realm_OCR.sh` 的功能本体 | 只测了它们的下载地址 | 各自单独立项 |

### 4.2 台架自身的已知限制

- MSYS 的 `grep` 对含 CR 的模式不可靠（实测 `printf 'a\r\n' | grep -c $'\r'` 返回 0）→ 行尾断言一律改用 `od` 数字节
- MSYS 读文件是文本模式 → CRLF 脚本在本机能跑、Linux 上会挂 → 该失败模式（R-07 的同类）本机无法复现，已改为静态核对生成端
- 本机 `python3` 是 WindowsApps 占位符 → 起监听端口改用真实 `python`
- 桩的 `systemctl` 不模拟真实依赖关系（`Requires=` / `WantedBy=`）→ unit 语义只做「文件内容」级别校验

### 4.3 待真机验证清单（逐条给主编排）

1. 一键安装（`curl … | sudo bash -s install`）在**干净 Debian 12** 上跑通，`/usr/local/bin/lib/` 七个模块齐全
2. `pf --help` 在真机上打印帮助并退出，不进菜单
3. 配 3 目标 `1,0,0` → `pf` 走「权重配置管理」→ 自动进主备 + 开启故障转移 → `systemctl status realm-health-check.timer` 为 active
4. `cat /etc/realm/health/health_status.conf` 的行格式与文档一致（`RULE_ID|TARGET|STATUS|FAIL|SUCCESS|LAST_CHECK|FAIL_START`）
5. 拔掉主节点网线 → 连续 2 次失败 → 状态文件变 `failed` → `balance: roundrobin: 0, 1, 0`
6. 主节点恢复 → 连续 2 次成功 + 冷却 120s → 权重翻回 `1, 0, 0`
7. **不装 netcat** 的机器上重复 3–6 → 依赖 `/dev/tcp` 回退能正常切换
8. `journalctl -u realm-health-check.service -f` 有正常输出，且 `journalctl --vacuum-time=7d` 不报错
9. `systemctl stop realm-health-check.timer` + 卸载后，`/etc/systemd/system/realm-health-check.*` 与 `/etc/realm/health/health_check.sh` 都被清掉
10. 守护进程 `xwpf-failover` 单独验证（两台机器、端口漂移、active/passive 切换）

---

## 5. 给下一轮的建议

1. **基线必须带指纹**：每次跑批把 `tests/baseline-manifest.txt` 一起归档，否则并发改动下结论不可比（本轮已实测踩到）。
2. **把「文档行号引用」做成自动化断言**：D-01 这类漂移每改一次代码就复发一次，值得做成一条用例（解析 docs 里的 `文件:行号`，核对那一行是否包含文档所述符号）。
3. **测试入口收敛**：仓库里已有 6 套测试入口，建议统一到一个 `tests/run_tests.sh` 之下（或至少在 docs 里建索引），否则覆盖面没人说得清。
4. **本轮剩下的 3 条缺陷已交小编**；修完我按同一台架回归，回归同样给 3 轮一致性结果。
