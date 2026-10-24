# xwpf-failover 重启风暴 · 处置状态复核（VPS 103.42.31.186 实测）

> 审稿人：审稿（bot_263632b9af01）　｜　初版时间：2026-10-24 19:20–19:35 (+08:00)　｜　**更新：2026-10-24 20:20（+08:00），补 N2 落地核验**　｜　性质：**只读**复核，未改动 `lib/`、`tests/`、`docs/`、`cmd/`，未做任何 git 写操作
> **锚点**：VPS 现场取证于 2026-10-24 19:19–19:20 (+08:00)；落地核验锚点 `12f63f9` + `7c95dca`（复核时 HEAD `7c95dca`），被测产物一律取自 `git show 7c95dca:<path>`；初版结论所依据的产物取自 `git show a7e23fc:<path>`
> 前序报告：`reports/round3-crashloop-review.md`（根因链复核）、`reports/round3-vps-live-verification.md`（VPS 实机取证）

---

## 一、结论（**已更新** —— 上一轮结论当时成立，现已被后续两笔提交推翻）

> **⚠️ 上一轮（本文件初版，19:35）的结论是「产品里没解决」。该结论已被后续两笔提交推翻 —— 下表是复核时 HEAD `7c95dca` 的现状。**

**问题在「这台机器」上早已被摁住；产品侧在 2026-10-24 19:42–20:04 落了两笔（`12f63f9` + `7c95dca`）之后也已解决，且解决得比审稿上一轮的建议更彻底。**

| 层面 | 状态（复核时 HEAD `7c95dca`） | 证据 |
|---|---|---|
| **VPS 103.42.31.186 现场** | ✅ **已止血**，循环被限流掐断 | drop-in `10-crash-loop-guard.conf` 生效；journal 有 `Start request repeated too quickly.`；unit `active (running)`、`NRestarts=0`。**⚠️ 但那台机器上的 drop-in 仍是人工旧版（`Restart=on-failure`），与产品现在的口径不一致** —— 见第六节建议 1 |
| **产品仓库** | ✅ **已修**（`12f63f9` + `7c95dca`） | 主 unit 内联限流三件套 + **install 写 drop-in**（每次重写同一路径）+ install 只装不启 + 退出码语义改造 + 卸载清 drop-in 目录。逐条对账见第二节 |
| **agent 是否还在动这块** | ✅ **在动，且已收口** | `12f63f9`（N2 三处根因）、`7c95dca`（N2 补笔：install 写 drop-in） |
| **上一轮标红的「残留风险」** | ✅ **不存在了** | 不是被绕过，而是**从根上消除**：退出码语义改了（EADDRINUSE 由 exit 0 改为 exit 非 0），`Restart` 保持 `always`。见第三节 |
| **台架覆盖** | ❌ **仍缺** | 两笔提交都写明「台架口径待补（tests/ 归台架 owner，本提交未触碰 tests/）」。**落点条件已具备**（drop-in 路径可指沙箱）—— 见第六节建议 2 |

---

## 二、N2 落地逐条对账（审稿上一轮的五条建议）

| # | 上一轮建议 | 落地 | 证据（被测产物取自 `git show 7c95dca:<path>`） |
|---|---|---|---|
| 1 | **【必做】** 把防护做进产品（落点 `lib/failover.sh` 的 `failover_install_files`） | ✅ **做了两条路**（比建议更保险） | ① 主 unit `cmd/xwpf-failover.service` 的 `[Unit]` 内联 `StartLimitIntervalSec=60` / `StartLimitBurst=3` / `StartLimitAction=none`（`12f63f9`）。② **`lib/failover.sh` 新增 `failover_write_crash_loop_guard`**（单一真源），落点 `/etc/systemd/system/xwpf-failover.service.d/10-crash-loop-guard.conf`，**每次 install / 升级重写同一路径**（`7c95dca`）。**理由比我的建议更到位**：drop-in 优先级**高于**主 unit → 老机器上人工建的 drop-in 会与主 unit 打架（哪边生效取决于文件名排序，不可预期）→ 同名覆盖、**别的文件名的人工文件保留**（用户主权，产品不越权删）。③ **卸载时一并清 drop-in 目录**（上一轮我建议里写的「卸载时一并删这个 drop-in 目录」也已落地）：`lib/ui.sh` 的卸载段有 `xwpf-failover.service.d` 目录的整目录删除，注释明写「含历史上人工创建的 10-crash-loop-guard.conf」 |
| 2 | **【必做】** `Restart` 保持 `always`，**不要**改成 `on-failure` | ✅ **完全采纳**，并**从根上消除了根因** | unit 与 drop-in 都是 `Restart=always` + `RestartSec=5s`；**且改了退出码语义**：`cmd/xwpf-failover.py` 的 `_main` 返回退出码（**0 = 收到停止信号，非 0 = serve/probe task 抛异常**），`main` 用 `sys.exit(code)` 交出去；`EADDRINUSE` 由 `Pool.serve` 转成 `ListenAddressInUse` 异常（带端口 / errno / 处置建议）→ 必然走非 0 分支。`cmd/README-failover.md` 明写「**不要**改成 `on-failure`」并给出理由 |
| 3 | **【建议】** `pf install` 改成**只装不启** | ✅ **做了，还加了两道闸门** | `xwPF.sh` 的 install 段现在是 `if failover_install_check; then`（**没有** `&& failover_service_enable`），并提示「主备守护已安装但未启动。请先建立主备池，再在『主备池管理 → 启停守护』中启动」。另加：`lib/failover.sh` 的 `failover_config_ready`（**没有池时不允许启守护** —— `failover_service_enable` 的第一件事就是它，不合格直接 return 1 并给处置提示）、`failover_require_listen_port_free`（**写 `failover.json` 之前**拦端口占用）、`failover_check_port_listening` 改三态（空闲 / 占用 / **无法判定**） |
| 4 | **【建议】** `StartLimitAction=none` **显式**写出 | ✅ | unit 与 drop-in 都写了；注释写明理由（默认值可被系统级 `DefaultStartLimitAction=` 覆盖，继承 `reboot`/`poweroff` 会灾难性） |
| 5 | **【建议】** 台架加断言 | ❌ **未做** | 两笔提交均写明「台架口径待补（tests/ 归台架 owner，本提交未触碰 tests/）」。**但落点条件已具备** —— 见第六节建议 2 |

**额外超出我建议的一处（值得记）**：`failover_install_check` 也写 drop-in（`7c95dca` 补笔）—— **已装且版本一致的老机器也补写**。我上一轮只建议了「装 unit 时一并写」（即只在重装路径写），那样**守护已装的老机器永远拿不到产品口径** —— 而 VPS 上那台机器正是这种情况。补笔把这条补上了。

**一处我上一轮没提、现在确认也做了的**：`failover_service_enable` 的闸门（`failover_config_ready`）覆盖的是**所有**启守护路径，不只是 install —— 菜单「主备池管理 → 启用并启动守护」那条路径也走同一个闸门。**这意味着「无池启守护」在任何入口都进不去**，不只是 install 一处。

---

## 三、上一轮标红的「残留风险」：**已从根上消除**（不是被绕过）

上一轮我标红的风险是：**现用的 drop-in 把 `Restart=always` 改成了 `on-failure`**，而 `cmd/xwpf-failover.py` 在**端口被占用**时是 **exit 0** → 守护**静默死掉**、systemd 不再拉起、journal 看起来一切正常、转发断了没人知道。

现在的实现把这条链**从源头掐断**了：

| 环节 | 上一轮现状 | 现在 |
|---|---|---|
| 端口被占时的退出码 | **0**（`asyncio.run` 正常返回 → systemd 读成「干净退出」） | **非 0**（`Pool.serve` 抛 `ListenAddressInUse` → `_main` 的 task 异常分支置 `exit_code = 1` → `main` 的 `sys.exit(code)` 交出去） |
| `Restart` 口径 | drop-in 改成 `on-failure` | **保持 `always`**（主 unit + drop-in 都是） |
| 结果 | 静默失效 | **响亮地失败** → 限流 3 次后 systemd 停手 → unit 进 `failed`，可被看见 |

⇒ 上一轮我说的「**改 `Restart` 时必须一起改退出码语义**」，他们的做法是**把退出码语义改对，再保持 `always`** —— 这比我的「保留 always + 限流」更根治。**我上一轮那条 🔴 残留风险，现已不存在。**

### 3.1 新增的残留风险（本次复核新发现，属**运维口径**而非代码缺陷）

产品 drop-in 的覆盖策略是「**同名覆盖，别的文件名保留**」。这带来一条新的、需要运维知道的口径：

> **别的文件名的人工 drop-in 仍然会覆盖产品口径。** 例如机器上有 `/etc/systemd/system/xwpf-failover.service.d/99-custom.conf` 且其中写了 `Restart=on-failure` → **产品写的 `10-crash-loop-guard.conf` 会被它压住**（drop-in 按文件名排序叠加，后者覆盖前者）→ 「响亮地失败」退回「静默消失」的老路。

这不是代码缺陷 —— 是「用户主权」与「防静默失效」之间的**取舍**，且 `cmd/README-failover.md` 已写明「别的文件名的 drop-in 仍会覆盖出厂值，要改本机参数请 `systemctl edit`」。**处置办法是巡检**，不是改代码：见第六节建议 3。

**VPS 103.42.31.186 恰好不在这一类** —— 它的人工 drop-in 文件名就是 `10-crash-loop-guard.conf`，与产品**同名** → 跑一次 `pf install` 即被产品口径覆盖（第六节建议 1）。

---

## 四、上一轮结论的原始记录（保留，便于追溯）

> 以下是 2026-10-24 19:35 的原始结论，**当时成立**、现已被 `12f63f9` + `7c95dca` 推翻。

### 4.1 初版结论原文

- **产品仓库**：❌ **未修** —— `cmd/xwpf-failover.service` 的 `Restart=always` + `RestartSec=2s` 从 `f730c8b` 到 HEAD **一字未改**；全仓 + 所有分支搜 `crash-loop-guard` / `service.d` / `StartLimit` → **产品代码 0 处**（只有审稿报告命中）。
- **那个 drop-in 的来历**：⚠️ **人工创建，不是产品生成** —— drop-in mtime `09:43:32`，**早于**已装的 `lib/failover.sh`（`09:58:10`）15 分钟；已装 `lib/failover.sh` 里搜 drop-in → 0 处。
- **一句话**：**这台机器不再烧 CPU，但下一个用户 `pf install` 之后照样中招**；且现用的修法把「响亮的崩溃循环」换成了「安静的转发中断」。

### 4.2 这条判断的「对」与「错」

- **对**：「产品没修」当时属实；「人工 drop-in 不是产品生成」经时间序与已装代码两路独立证据坐实；「改 `Restart` 必须一起看退出码语义」被产品采纳并落实。
- **错在时点**：我把结论**钉在「当时」而没有钉「会怎么变」** —— 产品随后两笔就把它修完了。**教训**：这类「产品侧未修」的结论应当写成「**截至 `<SHA>` 未修**」并**显式指向「谁在改、下一笔是什么」**，否则一落地就变成误导。

### 4.3 初版依据之一：agent 还在不在动这块

初版（19:35）时 agent 在动的是**主备池功能**，不是崩溃循环防护：

| 提交 | 内容 | 与本问题的关系 |
|---|---|---|
| `5cda0da` | 主备池菜单加一行指引（同一端口的主备/负载均衡走「权重配置管理」） | 建池 UX |
| `df9933f` | 主备池建池菜单增加「直连」模式 | 建池功能 |
| `70c7978` | 台架 T32 条件 5 的判定不再依赖宿主 locale | 台架 |
| `02cc0e6` / `1f5059c` / `100976c` | 菜单读入改为 stdin EOF 安全（我上轮报的 N1 忙循环） | **已修** ✓ |

初版判定「防护这一块零提交」的依据：`cmd/xwpf-failover.service` 的 `Restart=` / `RestartSec=` 从 `f730c8b` → `a7e23fc` → `bfc99d3` → `d0366b3` → `14aef0c` 全是 `Restart=always` + `RestartSec=2s`；全仓搜 `crash-loop-guard` / `service.d` / `StartLimit` → 命中的只有我自己的报告；已装到 VPS 的 `/usr/local/bin/lib/failover.sh` 里搜同样关键词 → 0 处。

> **现已被 `12f63f9` + `7c95dca` 推翻**：`RestartSec` 已从 `2s` 改成 `5s`，且 `StartLimit*` 三件套、drop-in 写入、退出码语义改造全部落地（见第二节）。

### 4.4 初版依据之二：为什么判定 drop-in 是人工做的

三条独立证据：

1. **时间序反了**：drop-in 的 mtime 是 `09:43:32`，而已装的 `lib/failover.sh` 是 `09:58:10` —— drop-in **比产品代码还早 15 分钟**。产品代码若会生成这个文件，文件必然不早于代码。
2. **已装产品代码里没有这段逻辑**（上一条，0 处命中）。
3. **主 unit 的 mtime 是 `02:11:42`** —— 正是风暴开始的时间（`NRestarts` 从 0 开始爬的那一刻）。drop-in 是**在风暴之后**、**unit 之外**单独加的。

drop-in 文件头那句「· 在 pf install 落盘 unit 之后创建本文件」描述的是**设计意图**，**不是已实现的自动行为**。这个区分很重要 —— 把它读成「产品已经会生成」就会误判「已修」。

### 4.5 初版依据之三：根因与派单描述的核对

**派单的机制描述当时属实**：`xwPF.sh` 主入口的 `install` 分支第 6 步是 `failover_install_check && failover_service_enable`，而 `lib/failover.sh` 的 `failover_service_enable` 是 `systemctl enable --now "${XWPF_FAILOVER_SERVICE}"`；`docs/install-and-upgrade.md` 的安装流程表第 6 步也写着「`failover_service_enable`：`systemctl enable --now xwpf-failover`」。而 `failover_install_files` **只**装 `xwpf-failover.py` 与 `xwpf-failover.service` 两个文件 —— **不写 drop-in**。

⇒ **链条闭合**：`pf install` → 落 unit（`Restart=always`）→ `enable --now` → 守护起来 → `/etc/xwpf/failover.json` **不存在**（只有建池菜单才写）→ `cmd/xwpf-failover.py` 的 `_main` 读配置失败 → **`sys.exit(1)`** → `Restart=always` ⇒ 每 `RestartSec=2s` 重启一次 ⇒ 默认限流（`DefaultStartLimitIntervalSec=10s` / `Burst=5`）**掐不住**（进程存活 + 2s 间隔 > 10s 窗口 ⇒ 第 6 次尝试落在窗口外）⇒ 无限循环。

**产品内部当时有一处自相矛盾**：

- **菜单文案**（`lib/failover.sh` 的建池收尾提示）写的是：「下一步: 在 [3] 启停守护 中启动 xwpf-failover」/「…并重启 realm」—— **产品自己说的顺序是「先建池，再启守护」**。
- **安装路径**却**先启了守护**（此时池还不存在）→ 守护必然 exit 1 → 必然重启循环。

**这不是「设计如此」，是安装路径与菜单流程的顺序不一致。** 修掉顺序矛盾，等于把这个问题从根上消掉一半。

> **现状**：install 路径已改成只装不启，且「启守护」入口加了 `failover_config_ready` 闸门 —— **顺序矛盾已消除**（第二节建议 3 对账行）。

---

## 五、VPS 现场实测（2026-10-24 11:19–11:20 UTC = 19:19–19:20 +08:00）

> 本节数据取自现场取证，**至今仍然成立**；其中「人工 drop-in 与产品口径不一致」一点已在第二节/第六节指出。

### 5.1 防护确实在，且确实生效

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

> **⚠️ 这份是人工旧版**：与产品现在的口径差两处 —— ① `Restart=on-failure`（产品现在是 `always`）；② **没有** `StartLimitAction=none`（产品现在显式写死）。限流三件套的另两键它有，所以现场止住了血；但 `Restart` 口径与产品相反 ⇒ **跑一次 `pf install` 即可被产品同名覆盖**（第六节建议 1）。

`systemctl show xwpf-failover` 的生效值（**注意这些是 drop-in 覆盖后的值，与主 unit 原文不同**）：

```
Restart=on-failure          RestartUSec=5s
StartLimitIntervalUSec=1min StartLimitBurst=3   StartLimitAction=none
```

### 5.2 限流真的掐过一次（不是「装了没用」）

```
Oct 24 09:43:43  xwpf-failover.service: Failed with result 'exit-code'.
Oct 24 09:43:48  xwpf-failover.service: Scheduled restart job, restart counter is at 3.
Oct 24 09:43:48  xwpf-failover.service: Start request repeated too quickly.
Oct 24 09:43:48  xwpf-failover.service: Failed with result 'exit-code'.
Oct 24 09:43:48  systemd[1]: Failed to start xwpf-failover.service - xwpf-failover …
```

09:43 时 `/etc/xwpf/failover.json` **还不存在** → 守护读配置失败 → **exit 1** → 重启 3 次 → **限流停死**。**这就是止血的现场**。

这条路径正是 `reports/round3-crashloop-review.md` 的 E.3 方向③（`StartLimitIntervalSec` + `StartLimitBurst` + `StartLimitAction=none`）—— **建议被采纳了**。

### 5.3 现在的状态（稳态）

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

## 六、建议（下一轮；审稿只出报告与清单，不改 `lib/`、`tests/`）

### 6.1 【必做】VPS 103.42.31.186 口径对齐 —— 跑一次 `pf install` 即可

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

### 6.2 【必做】台架补断言（上一轮建议 5，仍未做 —— 但**落点条件已具备**）

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

### 6.3 【建议】巡检「别的文件名的人工 drop-in」（对应 3.1 的新残留风险）

产品只覆盖**同名**文件。机器上若有 `99-custom.conf` 之类写了 `Restart=on-failure`，会把产品口径压回去。

```bash
# 列出该 unit 的全部 drop-in 与最终生效值
systemctl cat xwpf-failover
systemctl show xwpf-failover -p Restart -p RestartUSec -p StartLimitBurst -p StartLimitAction
```

**判据**：生效值里的 `Restart=` 必须是 `always`。若不是，先看是谁写的 —— 那才是真正要动的东西（人工文件由运维处置，不要让产品去删别人的文件）。

### 6.4 【建议】另一台 VPS `87.83.105.109` 仍不可达

SSH banner 超时、ping 50% 丢包，**本轮全程没能取到实机证据**。它若也跑着老的 `Restart=always` + `RestartSec=2s` unit 且没有 drop-in，**大概率同样中招**。升级窗口内建议恢复连通后按 6.1 巡一遍。

### 6.5 【建议】文档补一句「升级会覆盖同名 drop-in」

`cmd/README-failover.md` 已经写了「别的文件名的 drop-in 仍会覆盖出厂值」；`docs/install-and-upgrade.md` 的安装流程表第 7 步已列「写崩溃循环防护 drop-in（每次 install / 升级都重写同一路径）」。建议再补半句「**同名人工文件会被覆盖，改本机参数请另起文件名**」—— 这是运维最容易被"人工改过所以是我的"心态坑到的点。

---

## 七、边界与未覆盖

1. **本轮全程只读**：仓库侧只做 `git show` / `git grep`（未改 `lib/`、`tests/`、`docs/`、`cmd/`，未做任何 git 写操作）；VPS 侧本轮**未再连**（第二节的落地核验全部在仓库侧完成的），上一轮（19:19–19:20）在 VPS 上只执行了 `systemctl show` / `journalctl` / `ls` / `cat` / `sha256sum` / `pgrep` / `ss` / `df` / `free`，外加**一次**手动运行守护（用**不存在的配置文件路径** `-c /etc/xwpf/nonexistent.json` 与**手动运行时已占端口**两种方式各一次，**没有**改动任何状态文件、**没有**重启/停止任何 unit）。
2. **没有**在 VPS 上复现「配置缺失 + `Restart=always`」的无限循环（该路径已由 `reports/round3-vps-live-verification.md` 取证过），本轮只验证了「现装 drop-in 下会怎样」。
3. **退出码语义的新版行为未实机复跑** —— 新版二进制（`7c95dca:cmd/xwpf-failover.py`）只在**代码层**核过（`_main` 返回 `exit_code`，`main` 交 `sys.exit(code)`，`EADDRINUSE` → `ListenAddressInUse` → task 异常 → 非 0）；**没有**在真机上跑新版二进制做端口占用实测。**「新版端口占用退出码非 0」这一条目前是代码级结论，不是实机结论。**
4. **另一台 VPS `87.83.105.109` 仍不可达** —— 无实机证据。
5. **未审**：`cmd/xwpf-failover.py` 的探测与切换状态机本身（不在本轮范围）。
6. **未跑门禁**：本轮没有改动被测产物（只改 `reports/**`），不需要重测台架。第 6.2 节的台架断言**尚未有人实现**，本轮也未替台架 owner 写。

---

## 八、附：本次用到的可复现命令

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
