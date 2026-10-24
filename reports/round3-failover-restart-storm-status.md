# xwpf-failover 重启风暴 · 处置状态复核（VPS 103.42.31.186 实测）

> 审稿人：审稿（bot_263632b9af01）　｜　初版时间：2026-10-24 19:20–19:35 (+08:00)　｜　**更新：2026-10-24 20:20（+08:00），补 N2 落地核验**　｜　**再更新：2026-10-24 22:40（+08:00）—— 按 Chief 第 10 轮修正单收口**（并入 A-5 真机结论、两条时间特性、Chief 独立复核结论）　｜　性质：**只读**复核，未改动 `lib/`、`tests/`、`docs/`、`cmd/`，未做任何 git 写操作
> **锚点**：VPS 现场取证于 2026-10-24 19:19–19:20 (+08:00)；落地核验锚点 `12f63f9` + `7c95dca`（复核时 HEAD `7c95dca`），被测产物一律取自 `git show 7c95dca:<path>`；初版结论所依据的产物取自 `git show a7e23fc:<path>`；**Chief 独立复核锚点 `7c95dca`**（被测产物自 `git show 7c95dca:lib/failover.sh` 导出）；**A-5 负载均衡路径锚点 PR #4 = `a9102c1`**（`lib/rules.sh` 的 `auto_enable_active_standby`）；**时间特性的代码口径锚点 `7c95dca`**（`lib/health.sh` 的健康检查体、`lib/failover.sh` 的默认值）
> 前序报告：`reports/round3-crashloop-review.md`（根因链复核）、`reports/round3-vps-live-verification.md`（VPS 实机取证）、`reports/real-machine-acceptance.md`（真机验收清单 —— A-5 的**验收口径**在那里，本文件写的是**实机结果**）

---

## 一、结论（**已更新** —— 上一轮结论当时成立，现已被后续两笔提交推翻）

> **⚠️ 上一轮（本文件初版，19:35）的结论是「产品里没解决」。该结论已被后续两笔提交推翻 —— 下表是复核时 HEAD `7c95dca` 的现状。**

**问题在「这台机器」上早已被摁住；产品侧在 2026-10-24 19:42–20:04 落了两笔（`12f63f9` + `7c95dca`）之后也已解决，且解决得比审稿上一轮的建议更彻底。**

| 层面 | 状态（复核时 HEAD `7c95dca`） | 证据 |
|---|---|---|
| **VPS 103.42.31.186 现场** | ✅ **已止血**，循环被限流掐断 | drop-in `10-crash-loop-guard.conf` 生效；journal 有 `Start request repeated too quickly.`；unit `active (running)`、`NRestarts=0`。**⚠️ 但那台机器上的 drop-in 仍是人工旧版（`Restart=on-failure`），与产品现在的口径不一致** —— 见第八节建议 1 |
| **产品仓库** | ✅ **已修**（`12f63f9` + `7c95dca`） | 主 unit 内联限流三件套 + **install 写 drop-in**（每次重写同一路径）+ install 只装不启 + 退出码语义改造 + 卸载清 drop-in 目录。逐条对账见第二节 |
| **agent 是否还在动这块** | ✅ **在动，且已收口** | `12f63f9`（N2 三处根因）、`7c95dca`（N2 补笔：install 写 drop-in） |
| **上一轮标红的「残留风险」** | ✅ **不存在了** | 不是被绕过，而是**从根上消除**：退出码语义改了（EADDRINUSE 由 exit 0 改为 exit 非 0），`Restart` 保持 `always`。见第五节 |
| **台架覆盖** | ❌ **仍缺** | 两笔提交都写明「台架口径待补（tests/ 归台架 owner，本提交未触碰 tests/）」。**落点条件已具备**（drop-in 路径可指沙箱）—— 见第八节建议 2 |
| **drop-in 写入器本身** | ✅ **行为正确**（**Chief 独立复核**） | 写入返回 0、**5 个键齐全**、无 `.tmp.$$` 半成品、**幂等**、**覆盖同名人工文件**、**不误伤别名字的人工 drop-in**；**「已装且版本一致」这条路径确实也写 drop-in**。详见第二节的「Chief 复核」小节 |
| **drop-in 写入器 · 两处真缺陷** | 🔴 **待修**（**Chief 独立复核**，已派小编） | ① `XWPF_FAILOVER_DROPIN_DIR` 与 `XWPF_FAILOVER_DROPIN_FILE` **可各自独立设置** → 脱节时防护**根本没写进去**；② `failover_install_check` 的「取不到 `cmd/` 源文件」分支 **直接 `return 0` 且不写 drop-in** → 离线老机器永远拿不到产品口径。详见第二节与第八节建议 6 |
| **A-5 负载均衡路径（用户主路径）** | ✅ **真机通**（状态迁移全链打通） | 权重 5,5 → `roundrobin`；10,0 → `active-standby` + `FAILOVER_ENABLED=true`；杀主 → 0,1 → `DBACKUP`；恢复主 → 1,0 → `DPRIMARY`；改回 5,5 → 回到 `roundrobin`。锚点 PR #4 = `a9102c1`。**证据文件逐条见第三节** |
| **两条时间特性** | ⏳ **代码口径已核；实测区间本轮未取到来源** | 检测耗时与回切间隔的**机理与口径**已从 `lib/health.sh` / `lib/failover.sh` 核清（第四节）；**实测数字本轮因无 VPS 凭据未取到**，按纪律标「待补」而不是写无来源的数字 |

---

## 二、N2 落地逐条对账（审稿上一轮的五条建议）

| # | 上一轮建议 | 落地 | 证据（被测产物取自 `git show 7c95dca:<path>`） |
|---|---|---|---|
| 1 | **【必做】** 把防护做进产品（落点 `lib/failover.sh` 的 `failover_install_files`） | ✅ **做了两条路**（比建议更保险） | ① 主 unit `cmd/xwpf-failover.service` 的 `[Unit]` 内联 `StartLimitIntervalSec=60` / `StartLimitBurst=3` / `StartLimitAction=none`（`12f63f9`）。② **`lib/failover.sh` 新增 `failover_write_crash_loop_guard`**（单一真源），落点 `/etc/systemd/system/xwpf-failover.service.d/10-crash-loop-guard.conf`，**每次 install / 升级重写同一路径**（`7c95dca`）。**理由比我的建议更到位**：drop-in 优先级**高于**主 unit → 老机器上人工建的 drop-in 会与主 unit 打架（哪边生效取决于文件名排序，不可预期）→ 同名覆盖、**别的文件名的人工文件保留**（用户主权，产品不越权删）。③ **卸载时一并清 drop-in 目录**（上一轮我建议里写的「卸载时一并删这个 drop-in 目录」也已落地）：`lib/ui.sh` 的卸载段有 `xwpf-failover.service.d` 目录的整目录删除，注释明写「含历史上人工创建的 10-crash-loop-guard.conf」 |
| 2 | **【必做】** `Restart` 保持 `always`，**不要**改成 `on-failure` | ✅ **完全采纳**，并**从根上消除了根因** | unit 与 drop-in 都是 `Restart=always` + `RestartSec=5s`；**且改了退出码语义**：`cmd/xwpf-failover.py` 的 `_main` 返回退出码（**0 = 收到停止信号，非 0 = serve/probe task 抛异常**），`main` 用 `sys.exit(code)` 交出去；`EADDRINUSE` 由 `Pool.serve` 转成 `ListenAddressInUse` 异常（带端口 / errno / 处置建议）→ 必然走非 0 分支。`cmd/README-failover.md` 明写「**不要**改成 `on-failure`」并给出理由 |
| 3 | **【建议】** `pf install` 改成**只装不启** | ✅ **做了，还加了两道闸门** | `xwPF.sh` 的 install 段现在是 `if failover_install_check; then`（**没有** `&& failover_service_enable`），并提示「主备守护已安装但未启动。请先建立主备池，再在『主备池管理 → 启停守护』中启动」。另加：`lib/failover.sh` 的 `failover_config_ready`（**没有池时不允许启守护** —— `failover_service_enable` 的第一件事就是它，不合格直接 return 1 并给处置提示）、`failover_require_listen_port_free`（**写 `failover.json` 之前**拦端口占用）、`failover_check_port_listening` 改三态（空闲 / 占用 / **无法判定**） |
| 4 | **【建议】** `StartLimitAction=none` **显式**写出 | ✅ | unit 与 drop-in 都写了；注释写明理由（默认值可被系统级 `DefaultStartLimitAction=` 覆盖，继承 `reboot`/`poweroff` 会灾难性） |
| 5 | **【建议】** 台架加断言 | ❌ **未做** | 两笔提交均写明「台架口径待补（tests/ 归台架 owner，本提交未触碰 tests/）」。**但落点条件已具备** —— 见第八节建议 2 |

**额外超出我建议的一处（值得记）**：`failover_install_check` 也写 drop-in（`7c95dca` 补笔）—— **已装且版本一致的老机器也补写**。我上一轮只建议了「装 unit 时一并写」（即只在重装路径写），那样**守护已装的老机器永远拿不到产品口径** —— 而 VPS 上那台机器正是这种情况。补笔把这条补上了。

**一处我上一轮没提、现在确认也做了的**：`failover_service_enable` 的闸门（`failover_config_ready`）覆盖的是**所有**启守护路径，不只是 install —— 菜单「主备池管理 → 启用并启动守护」那条路径也走同一个闸门。**这意味着「无池启守护」在任何入口都进不去**，不只是 install 一处。

### 2.1 Chief 独立复核（锚点 `7c95dca`，被测产物自 `git show 7c95dca:lib/failover.sh` 导出）

> 本小节内容来自 **Chief 第 10 轮的独立复核**，审稿未复跑其脚本，仅做**交叉核对与登记**。凡标「Chief 复核」的均为其实测结论。

**① drop-in 写入器本身：行为正确 ✅**

| 复核项 | 结论 |
|---|---|
| 写入返回码 | **0** |
| 落盘内容 | **5 个键齐全**：`StartLimitIntervalSec=60` / `StartLimitBurst=3` / `StartLimitAction=none` / `Restart=always` / `RestartSec=5s` |
| 半成品 | **无 `.tmp.$$` 残留**（先写临时文件再 `mv` 的原子替换成立） |
| 幂等性 | **幂等**（重复写同一路径结果一致） |
| 同名人工文件 | **覆盖**（这是产品口径落地的前提 —— 见第五节 5.1） |
| 别名字的人工 drop-in | **不误伤**（用户主权，产品不越权删） |
| 「已装且版本一致」路径 | **确实也写 drop-in** —— Chief 原先怀疑这条会漏，**实测是通的** |

> 这条与本报告上一轮的自查一致：我先前也从 `lib/failover.sh` 的 `failover_install_check` 读到它在「已装且版本一致」的分支里同样调用 `failover_write_crash_loop_guard`。**两路独立读数一致。**

**② 两处真缺陷（🔴 待修，Chief 已派小编）**

**缺陷 1：`XWPF_FAILOVER_DROPIN_DIR` 与 `XWPF_FAILOVER_DROPIN_FILE` 可各自独立设置 → 脱节时防护根本没写进去**

- 机制：两个变量各自有独立的 `${VAR:-默认}`，**互不校验**。运维（或台架）只设了 `DIR` 而没设 `FILE` 时，`FILE` 仍取默认的 `/etc/systemd/system/xwpf-failover.service.d/10-crash-loop-guard.conf` —— 与被改掉的 `DIR` **不是同一个目录**。
- 后果链：`mkdir -p "$dir"` 在 **`DIR`** 上成功（建出一个脏目录）→ `cat > "$file.tmp.$$"` 在 **`FILE`** 上失败（其所在目录不存在）→ **防护文件根本没落盘**。
- **而且失败被吞掉**：调用点是 `failover_write_crash_loop_guard || true` ⇒ 写失败不报错 ⇒ **install 仍然报成功** ⇒ 用户以为防护已装，实际机器上**没有防护**。
- ⇒ 这是**「假成功」**：比「写不进去」更危险 —— 它连「没装上」这个信号都不给。
- 修法方向：两个变量**必须同源**（要么只暴露 `DIR`、由 `FILE` 派生；要么设了 `FILE` 就强制校验它在 `DIR` 下）；并且**写失败必须让 install 失败**，不能 `|| true` 吞掉。

**缺陷 2：`failover_install_check` 的「取不到 `cmd/` 源文件」分支直接 `return 0` 且不写 drop-in**

- 机制：该分支在取不到 `cmd/` 里的源文件时**提前返回 0**（成功），**没有**走 `failover_write_crash_loop_guard`。
- 关键事实：**drop-in 的内容是内嵌在 `lib/failover.sh` 里的**（`failover_write_crash_loop_guard` 自己 `cat > "$tmp" <<'DROPIN'` 写死内容），**根本不依赖 `cmd/` 源文件**。
- ⇒ 所以「取不到 `cmd/`」**没有任何理由**成为不写 drop-in 的理由。
- 后果：**离线老机器**（`cmd/` 缺失或升级失败）**永远拿不到产品口径的 drop-in** ⇒ 正是本报告第八节建议 1 描述的那类机器 —— 装了新版 `lib/failover.sh` 却仍是旧口径。
- 修法方向：把写 drop-in 提到**与 `cmd/` 取源无关**的位置；或至少在「取不到 `cmd/`」分支里**照样写 drop-in** 再返回非 0。

**③ 审稿的交叉核对**：缺陷 1 的「`|| true` 吞失败」与缺陷 2 的「取不到源就不写」**共同构成同一个失效模式** —— **「静默地没装上防护」**。上一轮我标红的「残留风险」是被产品从根上消除了；但这条**新的「静默失败」通道**是 `7c95dca` 引入的（`|| true` 与提前 `return 0` 都在这一笔的落点附近）。⇒ **建议把「drop-in 写成功」变成 install 的硬断言**，并让台架断言「install 后 drop-in 存在且 5 键齐全」（第八节建议 2）。

---

## 三、A-5 真机结论（负载均衡路径 · **用户主路径**）

> **口径声明（重要）**：本节写的是**用户主路径** —— 用户明确要的是「**负载均衡菜单 + 权重**」这条路径（Chief 10/24 裁定）。「**主备池菜单**」是**次要路径**，两者**不并列**：本节只写主路径；主备池/守护侧（`xwpf-failover`）的实机结论在第五节与第七节。
>
> **锚点**：PR #4 = **`a9102c1`**（`lib/rules.sh` 的 `auto_enable_active_standby` —— 「权重含 0 ⇒ 自动切主备」的实现落点）。
>
> **证据目录**：`/root/xwpf-evidence-20261024-190720-lb/`
>
> **⚠️ 证据完整性声明（必须先看）**：本轮的**观察结果**来自 **Chief 第 10 轮修正单**（实机）；**审稿本轮没有 VPS 凭据**（凭据环境变量在会话压缩后丢失、无 SSH 私钥与 agent、免密登录被拒）⇒ **无法进入该证据目录逐文件取证**。
> ⇒ 因此：**具体证据文件名**与**两个时间特性的实测数字**在本轮标「**待补**」，**不写没有来源的数字**。取证命令见第四节末尾，**在 VPS 上跑一条即可补齐**。

### 3.1 五步状态迁移链

| 步 | 动作（取证命令见 3.2） | **观察结果** | 机制落点（锚点 `a9102c1` / `7c95dca`） |
|---|---|---|---|
| ① | 权重设成 **5,5** | **生效模式 = `roundrobin`，权重 `5,5`** | 权重序列无 0 ⇒ 保持负载均衡模式，不进主备 |
| ② | 权重设成 **10,0** | **生效模式 = `active-standby`，且 `FAILOVER_ENABLED=true`（自动进主备）** | `lib/rules.sh` 的 `auto_enable_active_standby`：权重序列出现 0 ⇒ 规则 `BALANCE_MODE` 改写为 `active-standby` 并打开 `FAILOVER_ENABLED` |
| ③ | **杀主**（主目标监听进程） | **权重翻 `0,1`**，**角色变 `DBACKUP`** | 健康检查连续 `FAILURE_THRESHOLD`（默认 2）次失败 ⇒ 判 `failed` ⇒ 写回权重 `0,1`（备接管） |
| ④ | **恢复主** | **权重翻 `1,0`**，**角色变 `DPRIMARY`** | 连续 `SUCCESS_THRESHOLD`（默认 2）次成功 **且** 已过 `RECOVERY_COOLDOWN`（默认 120）⇒ 严格主备切回 |
| ⑤ | 权重改回 **5,5** | **回到 `roundrobin`** | 权重序列无 0 ⇒ 退出主备形态，回到负载均衡 |

> **角色词的出处**：`DBACKUP` / `DPRIMARY` 这两个标识在**仓库里 0 处命中**（`git grep` 全仓无）⇒ 它们是**真机上的运行时观察词**（realm 侧/健康检查运行时的角色标签），**不是本仓库的常量**。这更加说明第 ③④ 步的观察结果必须靠 VPS 证据坐实 —— 审稿本轮**未取到**，按纪律标待补。

### 3.2 取证命令（每一步都可用同一组命令取数）

```bash
# ① 规则文件里的模式与权重（权威落盘处）
grep -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS)=' /etc/realm/rules/rule-*.conf

# ② realm 实际生效的权重序列
#    ⚠️ realm 不认识 active-standby，底层输出的是 roundrobin —— 比较时按逗号切分取数字序列
jq -r '.endpoints[].balance' /etc/realm/config.json

# ③ 健康状态文件里的角色与状态
grep -v '^#' /etc/realm/health/health_status.conf

# ④ 切换时刻（时间戳来源，用于算检测耗时与回切间隔）
journalctl -u realm-health-check.service -n 60 --no-pager | grep -E 'FAILURE|CONFIG|RECOVERY'
```

> 这组命令与 `reports/real-machine-acceptance.md` 的 **A-5**（主节点断连 → 权重翻 `0,1`）、**A-6**（主节点恢复 → 权重翻回 `1,0`）的验收命令**同源** —— 那两节是**验收口径**（怎么做、期望什么），本节是**实机结果**。

### 3.3 这条链证明了什么

- **「用户要的那条路」在真机上通的**：从「纯负载均衡」到「自动进主备」到「故障接管」到「严格切回」到「退出主备」，**五个状态全部走通**，没有一步卡住。
- **自动进主备**是**产品自己做的**（`auto_enable_active_standby`），不是用户手工开的开关 —— 这正是「用户只要填权重」的产品意图。
- **严格主备**：恢复后是 `1,0`（不是 `1,1`），说明回切**不是**「恢复就均摊」。
- 剩余待补：第 ③④ 步的**具体证据文件名**（见本节开头的证据完整性声明）。

---

## 四、两条时间特性（**每个数都写来源**）

> **本节的纪律**：**拿不到来源的数字不写**。下面凡标「**待补**」的，是审稿本轮**确实没取到**（无 VPS 凭据），**不是**「忘了写」。

### 4.1 ① 硬故障检测耗时

**口径（代码级，锚点 `7c95dca`）** —— 负载均衡路径的检测耗时由 **realm 侧健康检查**决定，由三个参数相乘：

| 参数 | 默认值 | 出处 |
|---|---|---|
| 健康检查周期 `HEALTH_CHECK_INTERVAL` | **4 秒** | `lib/failover.sh` 的默认值；生效值走 `lib/health.sh` 的 `get_effective_health_check_interval` |
| 连续失败阈值 `FAILURE_THRESHOLD` | **2** | `lib/health.sh` 的健康检查体 |
| 单次探测超时 `CONNECTION_TIMEOUT` | **3** | 同上 |

⇒ **理论下限 ≈ 2 个周期 = 8 秒**（再加一次探测本身的耗时）。**实测区间：本轮未取到来源（待补）** —— 按纪律不写无来源的数字。

**⚠️ 口径警告：不要和「直连池 8–10 秒切走」混用。** 那是**另一个守护、另一套参数**：

| | 直连池（`xwpf-failover` 守护） | 负载均衡路径（realm 侧健康检查） |
|---|---|---|
| 谁在探测 | `cmd/xwpf-failover.py` 的池 | `lib/health.sh` 生成的 `health_check.sh`（systemd timer 拉起） |
| 周期参数 | `interval_sec` = **4** | `HEALTH_CHECK_INTERVAL` = **4** |
| 失败阈值 | `fail_threshold` = **2** | `FAILURE_THRESHOLD` = **2** |
| 冷却参数 | `cooldown_sec` = **120** | `RECOVERY_COOLDOWN` = **120** |
| 「8–10 秒切走」指的是 | **这个**守护的池 | **不是它** |
| 切换对象 | 池内主备（转发层面） | 规则权重（`WEIGHTS` 翻转） |

⇒ **两个「8 秒」来源不同、量纲不同、作用对象不同**（一个是守护切池内主备，一个是健康检查翻规则权重）。**写错来源比不写更糟** —— 引用时必须带上「哪个池／哪条路径」。

### 4.2 ② 回切间隔

**机理（代码级，锚点 `7c95dca`）** —— 回切条件在 `lib/health.sh` 的健康检查体里，**三个条件同时成立**才翻回：

```
① status == failed                       （之前确实判过故障）
② success_count >= SUCCESS_THRESHOLD(2)  （连续 2 次探测成功）
③ current_time - failure_start_time >= RECOVERY_COOLDOWN(120)
```

**⇒ 关键机理：③ 的基准是 `failure_start_time`（故障**起始**时刻），不是「恢复时刻」。**

由此推出的三条性质：

1. **回切受冷却期约束，不是「一恢复就立刻切回」** —— 刚判故障就恢复，必须等满 120 秒。
2. **故障持续得越久，恢复后到回切的等待越短** —— 若故障已持续超过 120 秒，恢复后 2 个周期（≈ 8 秒）即回切。
3. ⇒ **「故障发生 → 权重翻回」的总时长 ≈ `RECOVERY_COOLDOWN` + 2 个周期**；而**「主恢复 → 权重翻回」的等待 = 120 − 已流逝的故障时长**（下界为 2 个周期）。

`reports/real-machine-acceptance.md` 的 **A-6** 就是这个约束的**可观测形式**：恢复后**立刻**读权重**应当仍是 `0,1`**（冷却期没到就不许翻），等 `sleep 140`（= 120 冷却 + 2 周期 + 余量）后才翻成 `1,0`。

**实测值 X 秒：本轮未取到来源（待补）** —— 取证方式见 4.3。

### 4.3 补齐「待补」的两条命令（在 VPS 上跑一条即可）

```bash
# 一次性取齐：检测耗时 + 回切间隔 + 全部证据
D=/root/xwpf-evidence-20261024-190720-lb
mkdir -p "$D"
journalctl -u realm-health-check.service --no-pager -o short-iso \
  | grep -E 'FAILURE|CONFIG|RECOVERY' | tee "$D/timeline.log"
grep -v '^#' /etc/realm/health/health_status.conf | tee "$D/health_status.conf"
grep -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS)=' /etc/realm/rules/rule-*.conf | tee "$D/rules.txt"
jq -r '.endpoints[].balance' /etc/realm/config.json | tee "$D/balance.txt"
ls -l "$D"
```

**怎么从 `timeline.log` 算那两个数**：
- **检测耗时** = `[FAILURE] 目标 … 检测失败` 的时间戳 → 权重变成 `0,1` 的那轮 `[CONFIG]` 时间戳的差（**必须是负载均衡路径的这条**，不要用直连池的数）。
- **回切间隔** = `[FAILURE]`（故障起始）→ `[RECOVERY] 目标 … 已恢复健康` 的差；**应当与 `RECOVERY_COOLDOWN=120` 吻合**（误差来自 2 个探测周期与探测耗时）。
- **拿不到 `timeline.log` 的时间戳就写「待补」** —— **不要用 `sleep 140` 这种验收等待值冒充实测值**。

---

## 五、上一轮标红的「残留风险」：**已从根上消除**（不是被绕过）

上一轮我标红的风险是：**现用的 drop-in 把 `Restart=always` 改成了 `on-failure`**，而 `cmd/xwpf-failover.py` 在**端口被占用**时是 **exit 0** → 守护**静默死掉**、systemd 不再拉起、journal 看起来一切正常、转发断了没人知道。

现在的实现把这条链**从源头掐断**了：

| 环节 | 上一轮现状 | 现在 |
|---|---|---|
| 端口被占时的退出码 | **0**（`asyncio.run` 正常返回 → systemd 读成「干净退出」） | **非 0**（`Pool.serve` 抛 `ListenAddressInUse` → `_main` 的 task 异常分支置 `exit_code = 1` → `main` 的 `sys.exit(code)` 交出去） |
| `Restart` 口径 | drop-in 改成 `on-failure` | **保持 `always`**（主 unit + drop-in 都是） |
| 结果 | 静默失效 | **响亮地失败** → 限流 3 次后 systemd 停手 → unit 进 `failed`，可被看见 |

⇒ 上一轮我说的「**改 `Restart` 时必须一起改退出码语义**」，他们的做法是**把退出码语义改对，再保持 `always`** —— 这比我的「保留 always + 限流」更根治。**我上一轮那条 🔴 残留风险，现已不存在。**

### 5.1 新增的残留风险（本次复核新发现，属**运维口径**而非代码缺陷）

产品 drop-in 的覆盖策略是「**同名覆盖，别的文件名保留**」。这带来一条新的、需要运维知道的口径：

> **别的文件名的人工 drop-in 仍然会覆盖产品口径。** 例如机器上有 `/etc/systemd/system/xwpf-failover.service.d/99-custom.conf` 且其中写了 `Restart=on-failure` → **产品写的 `10-crash-loop-guard.conf` 会被它压住**（drop-in 按文件名排序叠加，后者覆盖前者）→ 「响亮地失败」退回「静默消失」的老路。

这不是代码缺陷 —— 是「用户主权」与「防静默失效」之间的**取舍**，且 `cmd/README-failover.md` 已写明「别的文件名的 drop-in 仍会覆盖出厂值，要改本机参数请 `systemctl edit`」。**处置办法是巡检**，不是改代码：见第八节建议 3。

**VPS 103.42.31.186 恰好不在这一类** —— 它的人工 drop-in 文件名就是 `10-crash-loop-guard.conf`，与产品**同名** → 跑一次 `pf install` 即被产品口径覆盖见第八节建议 1。

---

## 六、上一轮结论的原始记录（保留，便于追溯）

> 以下是 2026-10-24 19:35 的原始结论，**当时成立**、现已被 `12f63f9` + `7c95dca` 推翻。

### 6.1 初版结论原文

- **产品仓库**：❌ **未修** —— `cmd/xwpf-failover.service` 的 `Restart=always` + `RestartSec=2s` 从 `f730c8b` 到 HEAD **一字未改**；全仓 + 所有分支搜 `crash-loop-guard` / `service.d` / `StartLimit` → **产品代码 0 处**（只有审稿报告命中）。
- **那个 drop-in 的来历**：⚠️ **人工创建，不是产品生成** —— drop-in mtime `09:43:32`，**早于**已装的 `lib/failover.sh`（`09:58:10`）15 分钟；已装 `lib/failover.sh` 里搜 drop-in → 0 处。
- **一句话**：**这台机器不再烧 CPU，但下一个用户 `pf install` 之后照样中招**；且现用的修法把「响亮的崩溃循环」换成了「安静的转发中断」。

### 6.2 这条判断的「对」与「错」

- **对**：「产品没修」当时属实；「人工 drop-in 不是产品生成」经时间序与已装代码两路独立证据坐实；「改 `Restart` 必须一起看退出码语义」被产品采纳并落实。
- **错在时点**：我把结论**钉在「当时」而没有钉「会怎么变」** —— 产品随后两笔就把它修完了。**教训**：这类「产品侧未修」的结论应当写成「**截至 `<SHA>` 未修**」并**显式指向「谁在改、下一笔是什么」**，否则一落地就变成误导。

### 6.3 初版依据之一：agent 还在不在动这块

初版（19:35）时 agent 在动的是**主备池功能**，不是崩溃循环防护：

| 提交 | 内容 | 与本问题的关系 |
|---|---|---|
| `5cda0da` | 主备池菜单加一行指引（同一端口的主备/负载均衡走「权重配置管理」） | 建池 UX |
| `df9933f` | 主备池建池菜单增加「直连」模式 | 建池功能 |
| `70c7978` | 台架 T32 条件 5 的判定不再依赖宿主 locale | 台架 |
| `02cc0e6` / `1f5059c` / `100976c` | 菜单读入改为 stdin EOF 安全（我上轮报的 N1 忙循环） | **已修** ✓ |

初版判定「防护这一块零提交」的依据：`cmd/xwpf-failover.service` 的 `Restart=` / `RestartSec=` 从 `f730c8b` → `a7e23fc` → `bfc99d3` → `d0366b3` → `14aef0c` 全是 `Restart=always` + `RestartSec=2s`；全仓搜 `crash-loop-guard` / `service.d` / `StartLimit` → 命中的只有我自己的报告；已装到 VPS 的 `/usr/local/bin/lib/failover.sh` 里搜同样关键词 → 0 处。

> **现已被 `12f63f9` + `7c95dca` 推翻**：`RestartSec` 已从 `2s` 改成 `5s`，且 `StartLimit*` 三件套、drop-in 写入、退出码语义改造全部落地（见第二节）。

### 6.4 初版依据之二：为什么判定 drop-in 是人工做的

三条独立证据：

1. **时间序反了**：drop-in 的 mtime 是 `09:43:32`，而已装的 `lib/failover.sh` 是 `09:58:10` —— drop-in **比产品代码还早 15 分钟**。产品代码若会生成这个文件，文件必然不早于代码。
2. **已装产品代码里没有这段逻辑**（上一条，0 处命中）。
3. **主 unit 的 mtime 是 `02:11:42`** —— 正是风暴开始的时间（`NRestarts` 从 0 开始爬的那一刻）。drop-in 是**在风暴之后**、**unit 之外**单独加的。

drop-in 文件头那句「· 在 pf install 落盘 unit 之后创建本文件」描述的是**设计意图**，**不是已实现的自动行为**。这个区分很重要 —— 把它读成「产品已经会生成」就会误判「已修」。

### 6.5 初版依据之三：根因与派单描述的核对

**派单的机制描述当时属实**：`xwPF.sh` 主入口的 `install` 分支第 6 步是 `failover_install_check && failover_service_enable`，而 `lib/failover.sh` 的 `failover_service_enable` 是 `systemctl enable --now "${XWPF_FAILOVER_SERVICE}"`；`docs/install-and-upgrade.md` 的安装流程表第 6 步也写着「`failover_service_enable`：`systemctl enable --now xwpf-failover`」。而 `failover_install_files` **只**装 `xwpf-failover.py` 与 `xwpf-failover.service` 两个文件 —— **不写 drop-in**。

⇒ **链条闭合**：`pf install` → 落 unit（`Restart=always`）→ `enable --now` → 守护起来 → `/etc/xwpf/failover.json` **不存在**（只有建池菜单才写）→ `cmd/xwpf-failover.py` 的 `_main` 读配置失败 → **`sys.exit(1)`** → `Restart=always` ⇒ 每 `RestartSec=2s` 重启一次 ⇒ 默认限流（`DefaultStartLimitIntervalSec=10s` / `Burst=5`）**掐不住**（进程存活 + 2s 间隔 > 10s 窗口 ⇒ 第 6 次尝试落在窗口外）⇒ 无限循环。

**产品内部当时有一处自相矛盾**：

- **菜单文案**（`lib/failover.sh` 的建池收尾提示）写的是：「下一步: 在 [3] 启停守护 中启动 xwpf-failover」/「…并重启 realm」—— **产品自己说的顺序是「先建池，再启守护」**。
- **安装路径**却**先启了守护**（此时池还不存在）→ 守护必然 exit 1 → 必然重启循环。

**这不是「设计如此」，是安装路径与菜单流程的顺序不一致。** 修掉顺序矛盾，等于把这个问题从根上消掉一半。

> **现状**：install 路径已改成只装不启，且「启守护」入口加了 `failover_config_ready` 闸门 —— **顺序矛盾已消除**（第二节建议 3 对账行）。

---

## 七、VPS 现场实测（2026-10-24 11:19–11:20 UTC = 19:19–19:20 +08:00）

> 本节数据取自现场取证，**至今仍然成立**；其中「人工 drop-in 与产品口径不一致」一点已在第二节/第八节指出。

### 7.1 防护确实在，且确实生效

`/etc/systemd/system/xwpf-failover.service.d/10-crash-loop-guard.conf`（374 B，mtime `2026-10-24 09:43:32 +0000`）：

```ini
# realm-xwPF 崩溃循环防护 drop-in：
#   · 在 pf install 落盘 unit 之后创建本文件
#   · 用「删除即停止循环」+「连续 3 次异常即让 systemd 停死」双保险
#   · 60 秒内超过 3 次即被 systemd 停死（保留原配置不再重启）
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Restart=on-failure
RestartSec=5s
```

> **⚠️ 这份是人工旧版**：与产品现在的口径差两处 —— ① `Restart=on-failure`（产品现在是 `always`）；② **没有** `StartLimitAction=none`（产品现在显式写死）。限流三件套的另两键它有，所以现场止住了血；但 `Restart` 口径与产品相反 ⇒ **跑一次 `pf install` 即可被产品同名覆盖**见第八节建议 1。

`systemctl show xwpf-failover` 的生效值（**注意这些是 drop-in 覆盖后的值，与主 unit 原文不同**）：

```
Restart=on-failure          RestartUSec=5s
StartLimitIntervalUSec=1min StartLimitBurst=3   StartLimitAction=none
```

### 7.2 限流真的掐过一次（不是「装了没用」）

```
Oct 24 09:43:43  xwpf-failover.service: Failed with result 'exit-code'.
Oct 24 09:43:48  xwpf-failover.service: Scheduled restart job, restart counter is at 3.
Oct 24 09:43:48  xwpf-failover.service: Start request repeated too quickly.
Oct 24 09:43:48  xwpf-failover.service: Failed with result 'exit-code'.
Oct 24 09:43:48  systemd[1]: Failed to start xwpf-failover.service - xwpf-failover …
```

09:43 时 `/etc/xwpf/failover.json` **还不存在** → 守护读配置失败 → **exit 1** → 重启 3 次 → **限流停死**。**这就是止血的现场**。

这条路径正是 `reports/round3-crashloop-review.md` 的 E.3 方向③（`StartLimitIntervalSec` + `StartLimitBurst` + `StartLimitAction=none`）—— **建议被采纳了**。

### 7.3 现在的状态（稳态）

```
ActiveState=active   SubState=running   UnitFileState=enabled
NRestarts=0          Result=success     ExecMainStatus=0
```

- `/etc/xwpf/failover.json` **存在**（709 B，两个池：`poolA` 监听 `0.0.0.0:18443`、`poolDirect` 监听 `0.0.0.0:18444`）。
- 守护进程在跑（pid 63346），journal 正常输出 `listening on …` 与 `PRIMARY DOWN / RECOVERED` 状态迁移。
- 资源回到健康：`/tmp`（tmpfs 479 M）用 **4.8 M（1%）**、swap **64 M**、load **0.14** —— 与 `reports/round3-vps-live-verification.md` 里止血后的数据一致。
- 今天的 `Starting/Started` 累计 **10512** 次 —— 这是 **02:11→08:24 那场风暴的历史计数**，现在新增为 0。
- **配置缺失的退出码实测 = 1**：`/usr/bin/python3 -u /usr/local/bin/xwpf-failover -c /etc/xwpf/nonexistent.json` → `ERROR failed to read config … No such file or directory` → **退出码 1**。
  > 这条实测打的是**旧版**（VPS 上装的二进制 sha256 `15be865d…` = `f730c8b:cmd/xwpf-failover.py`）。新版把语义又往前推了一步：不仅配置缺失 exit 1，**task 抛异常（包括端口被占）也一律 exit 非 0**（第二节建议 2 对账行）。

---

## 八、建议（下一轮；审稿只出报告与清单，不改 `lib/`、`tests/`）

### 8.1 【必做】VPS 103.42.31.186 口径对齐 —— 跑一次 `pf install` 即可

那台机器上生效的仍是**人工旧版 drop-in**（`Restart=on-failure`，见 5.1）。产品现在的口径是 `Restart=always` + `StartLimitAction=none`。**处置：**

```bash
# 在 103.42.31.186 上（保持只装不启，不会动正在跑的转发）
pf install
# 或走「更新中心 → 升级到最新」

# 核：产品口径是否已覆盖人工文件（同名覆盖）
systemctl cat xwpf-failover | grep -E '^Restart=|^RestartSec=|^StartLimit'
# 期望：Restart=always / RestartSec=5s / StartLimitIntervalSec=60 / StartLimitBurst=3 / StartLimitAction=none

# 核：drop-in 文件的 mtime 已被刷新（不再是 09:43:32 那份人工文件）
ls -l --time-style=full-iso /etc/systemd/system/xwpf-failover.service.d/10-crash-loop-guard.conf
```

**为什么必须做**：产品口径的 `always` + 「异常一律非 0」是**两层纵深**；人工旧版的 `on-failure` 只有一层（退出码语义一坏就静默）。**在这台机器上，退出码语义目前还是旧的**（装的是 `f730c8b` 的二进制），所以「`on-failure` + 旧退出码语义」= **端口被占时静默死掉的老路仍然开着**。

> 升级守护二进制与覆盖 drop-in 是两件事：`pf install` 只保证 drop-in 口径对齐，**二进制版本**要看「更新中心」或手动换装 —— **两件都做，才算完整**。

### 8.2 【必做】台架补断言（上一轮建议 5，仍未做 —— 但**落点条件已具备**）

产品这次把 drop-in 落点写成了可覆盖的变量：

```
XWPF_FAILOVER_DROPIN_DIR="${XWPF_FAILOVER_DROPIN_DIR:-/etc/systemd/system/xwpf-failover.service.d}"
XWPF_FAILOVER_DROPIN_FILE="${XWPF_FAILOVER_DROPIN_FILE:-${XWPF_FAILOVER_DROPIN_DIR}/10-crash-loop-guard.conf}"
```

⇒ **台架可以把落点指到沙箱目录**（不需要 root、不会写真机路径）→ **断言可以落地了**。建议三条：

1. **drop-in 断言**：置 `XWPF_FAILOVER_DROPIN_DIR=<沙箱>` 调 `failover_write_crash_loop_guard` → 断言落盘文件存在，且含 `Restart=always` / `RestartSec=5s` / `StartLimitIntervalSec=60` / `StartLimitBurst=3` / `StartLimitAction=none`。
   > 断言要钉**不变式**（这些键的取值），不要钉「目录里恰好 1 个文件」这类结构。
2. **主 unit 断言**：`cmd/xwpf-failover.service` 的 `[Unit]` 段必须含 `StartLimitIntervalSec` / `StartLimitBurst` / `StartLimitAction=none`；`[Service]` 段必须是 `Restart=always`。
3. **闸门断言**：无 `failover.json` 时 `failover_service_enable` 必须**拒绝**（非 0）—— 这是「装完就启 → 崩溃循环」这条老路的**唯一结构性防线**，值得单独一条。

**为什么值得加**：这三样都是**纯文本键值**，是这轮事故里最容易被下一次 unit 改版无意改掉的东西；没有断言就会静默退化。

### 8.3 【建议】巡检「别的文件名的人工 drop-in」（对应 5.1 的新残留风险）

产品只覆盖**同名**文件。机器上若有 `99-custom.conf` 之类写了 `Restart=on-failure`，会把产品口径压回去。

```bash
# 列出该 unit 的全部 drop-in 与最终生效值
systemctl cat xwpf-failover
systemctl show xwpf-failover -p Restart -p RestartUSec -p StartLimitBurst -p StartLimitAction
```

**判据**：生效值里的 `Restart=` 必须是 `always`。若不是，先看是谁写的 —— 那才是真正要动的东西（人工文件由运维处置，不要让产品去删别人的文件）。

### 8.4 【建议】另一台 VPS `VPS-87` 仍不可达

SSH banner 超时、ping 50% 丢包，**本轮全程没能取到实机证据**。它若也跑着老的 `Restart=always` + `RestartSec=2s` unit 且没有 drop-in，**大概率同样中招**。升级窗口内建议恢复连通后按 8.1 巡一遍。

### 8.5 【建议】文档补一句「升级会覆盖同名 drop-in」

`cmd/README-failover.md` 已经写了「别的文件名的 drop-in 仍会覆盖出厂值」；`docs/install-and-upgrade.md` 的安装流程表第 7 步已列「写崩溃循环防护 drop-in（每次 install / 升级都重写同一路径）」。建议再补半句「**同名人工文件会被覆盖，改本机参数请另起文件名**」—— 这是运维最容易被"人工改过所以是我的"心态坑到的点。

### 8.6 【必做·待修】drop-in 写入器的两处真缺陷（**Chief 复核**，已派小编）

> 详细机制见第二节 2.1 的「Chief 独立复核」小节。此处只给**处置要求**。

**缺陷 1：`XWPF_FAILOVER_DROPIN_DIR` 与 `XWPF_FAILOVER_DROPIN_FILE` 可各自独立设置 → 脱节时防护根本没写进去，且失败被 `|| true` 吞掉、install 仍报成功。**

处置要求（三条都要）：
1. **两个变量必须同源** —— 只暴露 `DIR`（`FILE` 由它派生），或设了 `FILE` 就**强制校验**它位于 `DIR` 之下；不允许两者独立漂移。
2. **写失败必须让 install 失败** —— 去掉 `|| true` 这层吞异常，或至少把「drop-in 没写成功」变成一条**显式的警告 + 非 0 返回**。
3. **补一条自检**：落盘后回读目标文件，确认 **5 个键齐全**（`StartLimitIntervalSec` / `StartLimitBurst` / `StartLimitAction` / `Restart` / `RestartSec`）—— **回读**这一步能把「写了个半截文件」和「写到了别处」都挡住。

**缺陷 2：`failover_install_check` 的「取不到 `cmd/` 源文件」分支直接 `return 0` 且不写 drop-in → 离线老机器永远拿不到产品口径。**

处置要求：把写 drop-in 提到**与 `cmd/` 取源无关**的位置（或在「取不到 `cmd/`」分支里**照样写 drop-in** 再返回非 0）。依据：**drop-in 的内容内嵌在 `lib/failover.sh` 里**（`failover_write_crash_loop_guard` 自己 `cat > "$tmp" <<'DROPIN'`），**不依赖 `cmd/` 源文件** —— 所以「取不到 `cmd/`」不构成不写的理由。

**配套的台架断言**（并入 8.2 的那三条）：
- **断言「install 后 drop-in 存在且 5 键齐全」** —— 这条同时挡住上面两条缺陷（缺陷 1：落到了脏目录/没落盘；缺陷 2：那条路径压根没写）。
- **断言「写失败时 install 必须失败」** —— 注入式：把落点指到一个**不可写**的目录 → install 必须非 0。**这是「静默失败」通道的唯一守卫**，缺了它，上面两条缺陷都能悄悄溜过去。

### 8.7 【建议】把「drop-in 写成功」变成 install 的硬断言（防同类回归）

上一轮我标红的「残留风险」已被产品从根上消除；但 8.6 的两条缺陷说明**「静默地没装上防护」这条通道还在**。建议把 install 的成功条件从「`failover_install_check` 返回 0」升级为「**守护装上 + drop-in 写成功且键齐全**」，并在台架里把「5 键齐全」钉成**不变式**（钉键的取值，**不要**钉「目录里恰好 1 个文件」这类结构）。

---

## 九、边界与未覆盖

1. **本轮全程只读**：仓库侧只做 `git show` / `git grep`（未改 `lib/`、`tests/`、`docs/`、`cmd/`，未做任何 git 写操作）；VPS 侧本轮**未再连**（第二节的落地核验全部在仓库侧完成的），上一轮（19:19–19:20）在 VPS 上只执行了 `systemctl show` / `journalctl` / `ls` / `cat` / `sha256sum` / `pgrep` / `ss` / `df` / `free`，外加**一次**手动运行守护（用**不存在的配置文件路径** `-c /etc/xwpf/nonexistent.json` 与**手动运行时已占端口**两种方式各一次，**没有**改动任何状态文件、**没有**重启/停止任何 unit）。
2. **没有**在 VPS 上复现「配置缺失 + `Restart=always`」的无限循环（该路径已由 `reports/round3-vps-live-verification.md` 取证过），本轮只验证了「现装 drop-in 下会怎样」。
3. **退出码语义的新版行为未实机复跑** —— 新版二进制（`7c95dca:cmd/xwpf-failover.py`）只在**代码层**核过（`_main` 返回 `exit_code`，`main` 交 `sys.exit(code)`，`EADDRINUSE` → `ListenAddressInUse` → task 异常 → 非 0）；**没有**在真机上跑新版二进制做端口占用实测。**「新版端口占用退出码非 0」这一条目前是代码级结论，不是实机结论。**
4. **另一台 VPS `VPS-87` 仍不可达** —— 无实机证据。
5. **未审**：`cmd/xwpf-failover.py` 的探测与切换状态机本身（不在本轮范围）。
6. **未跑门禁**：本轮没有改动被测产物（只改 `reports/**`），不需要重测台架。第 8.2 节的台架断言**尚未有人实现**，本轮也未替台架 owner 写。
7. **【本轮无 VPS 凭据】** 审稿本轮**没有连上 VPS** —— 凭据环境变量在会话压缩后丢失、无 SSH 私钥与 agent、免密登录被拒（`Permission denied (password)`，22 端口可达）。⇒ 第三节的**证据文件名**与第四节两条时间特性的**实测数字**本轮**未取到来源**，按纪律标「待补」并给出取证命令（第四节 4.3），**不写无来源的数字**。
8. **A-5 的观察结果来自 Chief 第 10 轮的实机复核**（修正单给出），**审稿未独立复现**；第三节 3.2 的命令与 `reports/real-machine-acceptance.md` 的 A-5/A-6 同源。
9. **`DBACKUP` / `DPRIMARY` 在仓库里 0 处命中**（全仓 `git grep` 无）⇒ 它们是**真机运行时观察词**，不是本仓库常量；引用它们必须带真机证据。
10. **Chief 复核的结论未由审稿复跑脚本** —— 第二节 2.1 的「写入器行为正确」与「两处真缺陷」是 **Chief 实测**，审稿只做了**交叉核对**（其中「已装且版本一致也写 drop-in」一条与审稿的独立读数一致）与**登记**。**两处缺陷的复现脚本本轮未由审稿执行。**

---

## 十、附：本次用到的可复现命令

```bash
# ── 仓库侧（被测产物一律从冻结点导出） ──
git show 7c95dca:cmd/xwpf-failover.service | grep -E '^Restart=|^RestartSec=|^StartLimit'
git show 7c95dca:lib/failover.sh | grep -n -A3 'XWPF_FAILOVER_DROPIN_DIR='
git grep -n -E 'failover_write_crash_loop_guard|failover_config_ready|failover_service_enable' 7c95dca -- lib xwPF.sh
git show 7c95dca:lib/ui.sh | grep -n 'xwpf-failover.service.d'

# ── 现场（103.42.31.186） ──
# 生效值（注意是 drop-in 覆盖后的）
systemctl show xwpf-failover -p ActiveState -p SubState -p UnitFileState -p NRestarts \
  -p Result -p ExecMainStatus -p Restart -p RestartUSec \
  -p StartLimitIntervalUSec -p StartLimitBurst -p StartLimitAction

# 全部 drop-in（巡检用，见 6.3）
systemctl cat xwpf-failover

# 限流有没有掐过
journalctl -u xwpf-failover --no-pager | grep -c "Start request repeated too quickly"

# 配置文件缺失的退出码（不碰真实配置）
/usr/bin/python3 -u /usr/local/bin/xwpf-failover -c /etc/xwpf/nonexistent.json; echo "rc=$?"

# drop-in 的来历
stat /etc/systemd/system/xwpf-failover.service.d/10-crash-loop-guard.conf
ls -l --time-style=full-iso /usr/local/bin/lib/failover.sh
```
