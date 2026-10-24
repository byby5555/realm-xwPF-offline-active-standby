# realm-xwPF 真机验收清单（Debian / Ubuntu VPS）

> 产出：审稿（bot_263632b9af01）　｜　生成时间：2026-10-24　｜　基线 SHA：`a9102c1`
> **修订（2026-10-24，第 2 次）**：**A-4 一节按 N1 落地后的口径改写** —— 字段数 **7 → 9**（`LATENCY_MS` / `LATENCY_HISTORY` 是后加的）；「TARGET 只有 host、没有端口」由「不判 FAIL，但要登记」改为**判 FAIL**；新增 **A-4.1 旧格式兼容登记**（升级瞬间的老文件**不必手工删**）。A-3 / A-5 两处引用同一旧事实的表述一并更正。**A-4 一节的锚点推进到 `bfc99d3`（N1-R1）**，其余各节仍以 `a9102c1` 为基线。
> **修订（2026-10-24，第 3 次）**：按 Chief 派单复核 A-4 判据 —— ① 字段数判据确认为 **9**（以冻结态 `a7e23fc` 的 `lib/health.sh` 的 `health_check_script_body` 为准，第 2 次修订已改到位）；② 「末字段是时间戳」已改到第 6/7 字段，并区分「时延历史为空」与「时延历史是数字列表」两种合法形态；③ **TARGET 判据由「一律判 FAIL」改为三档分级**（裸 host 是**旧格式**不是设计：归属已失效的孤儿行**有条件接受 + 登记**；归属可确定却没迁移、或裸 host 占多数，仍**判 FAIL**），并补「裸 host 残留对同 host 多端口场景的影响」对照表。**新增 A-X（旧格式状态文件 + 新代码 → 仍能正确切换）与 A-Y（同 host 两个端口 → 状态互不覆盖）两节**。全文的「文件:行号」引用按纪律改成「文件 的 符号」。**本节锚点：`a7e23fc`**（消费端与展示端的行为以 `bfc99d3` 为准，见 A-4 锚点说明）。
> **修订（2026-10-24，第 4 次）**：入库前收口 —— ① **A-X / A-Y 的锚点 SHA 写全**（被测产物 `a7e23fc`、期望所依据的行为 `bfc99d3`、复核时 HEAD `14aef0c`；原先「HEAD 不带 SHA」的浮动写法已改成 `a7e23fc..14aef0c`）；② **T01 预检**：用**逐字复刻 T01「下载地址一致性」** 的脚本在工作区扫（含未提交文件），**违例 0 条**（T01 扫 `.md` 且**不排除 `reports/`**，本文件与其它审稿报告里出现的下载类 URL 全部指向本 fork `byby5555/realm-xwPF-offline-active-standby`；引用 systemd 源码处一律写成「仓库路径 + tag」而非 raw URL，故 T01 抓不到）；③ 全文「文件:行号」引用复查 = **0 处**。
> **修订（2026-10-24，第 5 次）**：新增 **A-Z（非交互环境里 pf 必须快速退出且输出量有上限）** —— 这是 N1（stdin EOF 忙循环）事故的**验收条目**：非 TTY 下必须**自己**退出（退出码 ≠ 124）、退出码 0、输出字节数有上限、输出非空且命中入口提示语。同时把「交互式提示的真终端显示」一条的适用范围写清：**TTY 下不受影响**。
> **修订（2026-10-24 21:20，第 6 次）—— 按用户裁定「主备池模式的都抛弃」重做**：
>   ① **A-10（`xwpf-failover` 进程级热切换）整节废弃删除**，改为状态说明（不占验收位）；
>   ② **迁入**「负载均衡路径真机结论」的五步状态迁移链 → **A-5**；「两条时间特性」（检测耗时机理 + 回切 120 秒冷却）→ **A-6.1**；取证命令 → **A-6.2**（从已废弃的 `reports/round3-failover-restart-storm-status.md` 迁出）；
>   ③ **新增四条保留路径验收面**：**A-11 单端口中转**、**A-12 负载均衡 5,5**、**A-13 权重 10,0 主备**（杀主翻备 / 恢复翻回 / 回切冷却）、**A-14 健康探测端确实在探测**（含「最后检查时间必须随轮次前进」与「生成物与真源一致」）；
>   ④ **新增 A-15 老机器残留清理**（升级后守护 / unit / drop-in / 占用端口清干净，且**保留路径不被误伤**）；
>   ⑤ A-1 的「危险动作」里 `systemctl enable xwpf-failover` 已移除（该动作随功能废弃）。
> **⚠️ 命名陷阱（本清单反复强调）**：**权重 10,0 主备**（走 realm 规则 `TARGET_STATES`，`realm-health-check.timer` 驱动，**保留**）**≠** 进程级主备池（独立守护进程 + `failover.json`，**已删除**）。两者都叫「主备」，文档与验收里**不许混写**。
> **实测数字纪律**：两个时间特性的**实测区间**标「**待补**」—— 审稿本轮**无 VPS 凭据**，拿不到来源就不写（A-6.2 给出补齐命令）。
> **修订（2026-10-24 21:50，第 7 次）—— 按 Chief 裁定收敛后的口径微调**：
>   ① **A-13 升为「主备切换可靠性」重心项**：新增 **R1~R4 四条附加判据**（切换耗时可复现且写来源 / 备机不跟着挂 / 恢复后不立刻翻回 / 切换无需人工干预），并把「切换耗时」与 A-14（探测端确实在探测）**明确联动** —— 裁掉进程级主备池后，**权重主备是唯一的主备机制**，其命脉全压在探测端上。
>   ② **A-15 的判据改用 Chief 给的精确清单**：**7 个路径逐条**（守护二进制 / 守护 unit / drop-in 目录 / `failover.json` / `failover-state.json` / 版本指纹 / 守护源文件副本）+ **18443 与 18444 不再被监听** + 无残留进程 + **保留路径未被误伤**。
>   ③ **A-6.1 补一条**：直连池功能已删除 ⇒ 现版本只剩负载均衡路径一条口径，**不再需要分清两个「8 秒」**；但「引用检测耗时必须写清哪条路径」的原则保留。
> **修订（2026-10-24 22:1x，第 8 次）—— 新增 A-16（状态文件残留 + RULE_ID 过户）**：
>   ① **新增 A-16「删除规则后，健康状态不得残留、不得过户给别的规则」** —— 4 条硬判据（无孤儿行 / 不跨地址继承 / 同地址不出现两行 / 取样前探测端已跑过一轮）+ 可直接粘贴的取证命令。
>   ② **A-16 的判据按代码事实写成三档，而不是一刀切**：经核对 `lib/health.sh` 的健康检查体（每轮**整份原子重建**，只为被监控目标写行）、`lib/health.sh` 的 `health_status_find_row`（**按目标地址**继承，**刻意设计**，代码注释写明「RULE_ID 会被复用」）、`lib/rules.sh` 的 `sync_health_status_ids`（规则增删时**按目标地址过户**、无主行**整行丢弃**）、`lib/health.sh` 的 `get_health_status_record`（按 target **取第一行就退出**）—— ⇒ **同地址状态被继承 = 符合设计，不判 FAIL**；**真正的 FAIL 是「同一地址出现两行」与「跨地址继承」**。 ⚠️ **此记录已被后续修订改向**（第 11 次、第 12 次）：组合键口径下 **「同地址但不同 RULE_ID」不继承** ⇒ 判据 3 已改向；且 **「同一地址出现两行」本身不再是缺陷**（两条不同规则合法共用同一后端时本就应两行）。
>   ③ **Chief 真机实测的两条数据已登记并归因**（来源标注为 Chief 实测，审稿未独立复现）：状态文件 **4 行里 3 行是孤儿**；删规则后其行 `3|127.0.0.1:18081` 被改写成 `1|127.0.0.1:18081`。⇒ 前者归因 **A-13.0**（真机规则形态不对 ⇒ 探测端从未工作 ⇒ 状态文件是历史遗留 ⇒ **不另开缺陷单**）；后者符合设计 ⇒ 判为**通过**。
>   ④ A-13.1 失败排查表里那条「查 `RULE_ID` 归属（见 A-16）」的**交叉引用至此可解析**。
> **修订（2026-10-24 22:0x，第 9 次）—— 按 Chief 真机 103 完整跑通的主备切换数据补齐**（来源：**Chief 真机实测**，审稿未独立复现）：
>   ① **新增 A-17（★ 阻断级，全清单最高风险项）**：`balance` 字段格式非法 ⇒ **realm panic** ⇒ **全站转发断**（不是单 endpoint 断）。含四种写法的真机对照表、**生成器侧核查结论**（当前 `lib/realm.sh` **不会**产出那两种非法形态）、形态判据、**「realm 必须还活着」红线**、转发实测、负向对照。
>   ② **A-13.1 改写为 Chief 的五步判据链**（停主 → 状态变 `failed` → 探测调 `pf --restart-service` → `balance` 翻转 → **实连落到备后端**），并**修掉「实连」的测法**：**「TCP 连得上」不能当通过**（realm 接受连接后可能立刻断）⇒ 正确测法是**后端回一行标识、客户端读那一行**（Chief 第一轮判成「两边都没流量」，**实际是测法错了，产品本身是好的**）。
>   ③ **新增 A-13.4（分诊）**：「**切换失败**」与「**切换没发生**」必须能区分 —— 前者查 realm 日志有无 panic / 是否全断（阻断级），后者查状态文件里目标有没有变 `failed`（静默失效，形态不对）。
>   ④ **A-6.1 ② 回切间隔：待补 → 实测约 2 分钟**（从恢复那刻算，`[RECOVERY]` 出现时刻）⇒ **本清单最后一个「待补」数字已补齐**。**A-6.1 ①** 补「相比已删的守护进程路径 8–10 秒，**慢 3–4 倍**」。（**后于第 11 次细化为 Chief 的精确值：检测耗时 30 秒 / 回切 119 秒**）
>   ⑤ **A-16 补 Chief 第三条实测**（`reorder_rule_ids` 重排 RULE_ID：`rule-5`/ID=5 → `rule-3`/ID=3）**并附显式口径更正**：Chief 观测的「按需替换 ⇒ 被删规则的行永远留着」**精确对应 `9dc5b56^`（N4 之前）**的实现（审稿已对 git 历史核实，**Chief 没测错**）；**`9dc5b56` 起改为整份原子重建** ⇒ 孤儿行会被一次抹掉 ⇒ **判据 1 在新代码上应当转绿**，并给出判别命令。
>   ⑥ **A-13.2 R1** 补实测来源与 3–4 倍差值。
> **修订（2026-10-24 22:0x，第 10 次）—— 按 Chief 第 12 轮裁定与实现复核**：
>   ① **A-15 两处判据更正（避免真机误判 FAIL）** —— 对着 HEAD `1190d4c` 核过 `lib/ui.sh` 的 `_cleanup_legacy_failover_daemon`：清理策略是**改名留档**（`failover.json` → `failover.json.disabled`）⇒ **原路径确实不存在**（Chief 的 7 路径判据成立 ✅），但 **`/etc/xwpf/` 目录会留下**。⇒ 原命令块第 5 项「`/etc/xwpf` 必须不存在」**会假红** ⇒ 改为「**里面不得有活配置**，`.disabled` 留档允许但**必须登记**」。
>   ② **A-15 失败排查表「老池列不出来也删不掉」一行作废** —— 池管理入口 `failover_proxy_menu`（建池/列池/删池）已随 `2beb7bd` **整块删除** ⇒ 「列出/删除老池」这个能力**本就不存在** ⇒ **不是缺陷**。⇒ 原判据「老池必须仍能列出与删除」是审稿在功能下线前的推断，**现已作废**。
>   ③ **A-13.1 补一条预期现象**：权重翻转要**重启 realm**（`pf --restart-service` → `service_restart`）⇒ **切换瞬间有几秒转发中断** —— **机制固有代价、不是缺陷**，验收**不得因此判 FAIL**，但**必须写进验收记录**（它决定客户端要容忍多长的不可用窗口）。
>   ④ **菜单标题已裁定**（Chief 选 (b)）⇒ `=== 故障转移管理（规则级） ===`；并已核实**屏幕上没有第二处含「旧」的说明文字**（只有标题行 + 一处代码注释）—— 见 `reports/round12-deprecation-scope-review.md` 的 §5.8。
>   ⑤ **新增 `reports/docs-local-unverifiable-checklist-rewrite.md`** —— `docs/local-unverifiable-checklist.md` 的**完整重写稿**（Chief 裁定 (b)，含他指定的 5 条），交小编落地。
> **修订（2026-10-24 22:1x，第 11 次）—— 按 Chief 的精确实测数 + 产品侧 3 处待修项**：
>   ① **两个实测值换成 Chief 的精确数**：**故障检测耗时 30 秒**（kill epoch `1792850569` → `[FAILURE]` epoch `1792850599`）、**回切间隔 119 秒**（恢复 epoch `1792850599` → `[RECOVERY]` epoch `1792850718`；回切后 `balance` = `"roundrobin: 1, 0"`，实连 3 次全落主）。来源均标「Chief 真机实测，审稿未独立复现」。**判定口径不变**：不把「必须是 119/120 秒」当判据，硬判据仍是「恢复后立刻读权重仍在备上」+「回切发生在故障起始 + 120 秒之后」。
>   ② **⚠️ 给 30 秒绑了前提**：这次实测是在**超时预算仍为 3 秒**的口径下测的；产品正把预算抬到 10 秒 ⇒ **失败判定必然更慢** ⇒ **30 秒在新代码下可能不再成立** ⇒ 实测值必须连同当时的 `CONNECTION_TIMEOUT` 一起记，**不得当判据**。
>   ③ **新增 A-18「待产品修复后验证」**：Chief 在冻结点 `1190d4c` 上核出的 3 处产品侧问题（**继承键只按目标地址、`target_key` 是死变量** / **产物重生成失败没 fail fast、升级路径不写日志不返非 0** / **新建规则超时预算仍是 3 秒**）—— 审稿**已独立复核，三条全部核实成立** ⇒ **依赖它们的判据只登记现象，不判 PASS/FAIL**。
>   ④ **🔄 更正 A-16 判据 3 的方向**：审稿原写「同地址状态被继承 = 刻意设计 = 不判 FAIL」（依据是 `health_status_find_row` 的注释）—— **Chief 的发现 ① 推翻了这一判读**（⚠️ **本条等于第 11 次修订，已被第 12 次的实现复核再次改向**）：那段注释的**上一行**就在构造 `target_key="${RULE_ID}|${target_endpoint}"` 组合键，只是**查表时没传进去** ⇒ **代码自相矛盾**，「刻意设计按地址」不成立，是**组合键的意图没落地** ⇒ **正确口径是组合键** ⇒ **修复后「同地址被继承」判 FAIL**。
>   ⑤ **A-17 补覆盖缺口声明**：**权重 0 与 `iphash` 策略的组合尚未实测** ⇒ 不得写成已验；未测组合**登记为「未覆盖」**，不判 PASS。
>   ⑥ **按「断言钉不变式、不钉结构/份数」自查并软化**：把 A-6 / A-13.1 / A-13.2 R3 里**写死 `0,1` / `roundrobin: 1, 0`** 的判据改成**「主位 ↔ 备位」这个关系**；字面量只作**参考形态**。
> **修订（2026-10-24 22:4x，第 12 次）—— 组合键修复落地后重核，🔄 A-16 判据再改向**：
>   ① **HEAD 已推进到 `43c135a`（`fix(health): 状态继承键改回 (RULE_ID, 目标地址) 组合键`）** ⇒ 审稿**逐端独立核过**：`health_status_find_row` 现在是 **4 参**、匹配处有 `if [ "$_rid" != "$rule_id" ]; then continue; fi`、调用点传了 `$RULE_ID`、生成物里的抽取副本一致 ⇒ **「`target_key` 是死变量」的缺陷已消除** ✅。
>   ② **🔴 但读端没跟上**：`lib/realm.sh` 的 `generate_endpoints_from_rules` 建键仍是 `health_status["$_row_target"]`（**不含 RULE_ID**）⇒ **两条规则共用同一后端时同一个 key 被后读覆盖** ⇒ 切换判断可能拿到别处的 failed ⇒ **误继承 = 误切** ⇒ **新增 A-16 判据 5（读端归属）**，A-18 第 ① 项状态改为「**跨轮读端 ✅ / 读端 ❌**」。
>   ③ **🔄 A-16 判据 3 再改向**：组合键口径下 **同地址但不同 RULE_ID ⇒ 不继承** ⇒ 「同地址被继承」= **缺陷方向**（修复后判 FAIL）；同时 **「同一地址出现两行」本身不再是缺陷**（两条不同规则合法地指向同一后端时本就该两行）⇒ 判据改成 **「同一条规则（RULE_ID）对同一个 target 不得两行」**，并**撤销**原先「状态文件行数 == 被监控目标数」这条**钉份数**的判据。
>   ④ **预算落点已精确定位**（更正一处流传的路径）：新建规则的 `.conf` 模板在 **`lib/server.sh` 的两处**（`CONNECTION_TIMEOUT="3"`）⇒ **落盘就是 3**；而 `lib/rules.sh` 的 `_ensure_rule_field_default … "10"` **只在字段缺失时补** ⇒ **模板里已有 3 ⇒ 补缺不会覆盖** ⇒ **修模板才是真修**。
>   ⑤ **台架不补「崩溃循环防护」用例**（阿测已确认）：那一整块（守护进程 / `StartLimit` / `DROPIN_DIR` / `crash.loop`）已随进程级主备池**整块删除** ⇒ 补了就是**测一个不存在的东西 = 给假信号** ⇒ **全仓 0 命中是符合现状、不是覆盖空洞**。⇒ 记此一条，免得下一轮又把它当成待补。
> **修订（2026-10-24 22:5x，第 13 次）—— 三处待修项落地后复核 + 台架方向更正**：
>   ① **② fail fast 已修**（复核实锤）：安装路径 `xwPF.sh` 失败时 → 醒目错误 + **可执行修复步骤** + **写日志**（`health_regenerate_log_failure` → `/var/log/xwPF/health-regenerate.log`）+ 「安装中断」+ **`exit 1`**；升级路径 `lib/update.sh` → **先用 grep 判「能力是否存在」**（老版本/降级不算失败），失败时同样写日志 + 修复步骤。
>   ② **③ 超时预算已修**（`05b5ebb`）：`lib/server.sh` 两处模板、`lib/rules.sh` 的探测调用、`xw_realm_OCR.sh` 全改成 10；`lib/health.sh` 侧本来就是 10 ⇒ **全仓再无 3 秒落点**（剩下四处是**老规则文件 3→10 的迁移模式**，保留对）；还顺手同步了 3 份 docs 的口径。
>   ③ **⇒ 由此产生的直接后果**：**预算从 3 秒抬到 10 秒 ⇒ 失败判定必然更慢 ⇒ 「检测耗时 30 秒」是旧口径下的过期实测值 ⇒ 真机必须重测**。已在 A-6.1 ① 的前提框与 A-13.2 R1 标明。
>   ④ **① 状态 = 「跨轮读端 ✅ / 读端 ❌」** ⇒ 读端 `lib/realm.sh` 的 `generate_endpoints_from_rules` 建键仍不含 RULE_ID ⇒ **仍需修** ⇒ 新增 **A-16 判据 5**（读端归属）。
>   ⑤ **新增 A-18.4 台架用例 ↔ 验收项对照表**（T63–T88 编号占用登记 + 映射 + **T86/T87 的方向更正**）。
>   ⑥ **已通过 Bot 通道回复阿测**：纠正 T87 方向（**同 RULE_ID + 同目标地址 ⇒ 应当继承**）、更正「同一 target 两行」的判据（改按 **(RULE_ID, TARGET)** 组合去重）、更正预算落点路径（是 `lib/server.sh` 的模板、且**补缺逻辑不覆盖已有值**）、确认崩溃循环防护**不补**、提醒「实连」测法与「不要钉字面量」。
> 适用范围：本机无 WSL / Docker / systemd / realm，下列全部项**只能在真实 Linux VPS 上验**。
> 本清单只做**验收**，不修改 `lib/`、`tests/`、`docs/`、`xwFailover.sh`；发现问题登记缺陷单交 Chief 路由。

---

## 0. 通用约定

### 0.1 验收环境基线（每台机器先跑一次并存档）

```bash
mkdir -p ~/realm-acceptance
{
  echo "=== 时间 ==="; date -Is
  echo "=== OS ==="; cat /etc/os-release | head -3
  echo "=== 内核/架构 ==="; uname -a
  echo "=== bash ==="; bash --version | head -1
  echo "=== systemd ==="; systemctl --version | head -1
  echo "=== 关键依赖 ==="
  for t in curl wget tar grep cut bc jq openssl python3 nc timeout flock; do
    printf '%-10s %s\n' "$t" "$(command -v $t || echo MISSING)"
  done
  echo "=== realm ==="; realm version 2>/dev/null || echo "NO_REALM"
} | tee ~/realm-acceptance/baseline.txt
```

### 0.2 记录方式

- 每项单独存一份：`~/realm-acceptance/A<编号>.log`，命令输出直接 `| tee -a` 追加。
- 结论只写 **PASS / FAIL / BLOCKED** 三态 + 一句话现象。
  - **BLOCKED**：前置不满足（例如该机没装 realm），不算失败，但必须写明缺什么。
- **禁止**用「基本正常」「看起来 OK」这类不可判定结论。

### 0.3 全局危险动作提醒（先读）

| 动作 | 风险 | 纪律 |
|---|---|---|
| `pf` 里的任何会写配置的菜单项 | 重启 realm → 转发中断 | 业务机先 `cp -a /etc/realm /etc/realm.bak.$(date +%s)` |
| 卸载（`8. 卸载服务`） | **删除 /etc/realm 全部配置与规则** | 先备份；确认是测试机 |
| 改 `iptables`/`ufw` | 可能锁死 SSH | **只允许在 loopback 上拦**；绝不拦 22 端口；拦完必须 `iptables -L` 留证 |
| 改 `/usr/bin/nc` 文件名 | 系统级 | 见 A-7，**同一命令块内改回** |
| `systemctl stop realm` | 转发全断 | 验收窗口内进行 |
| 杀进程（模拟节点故障） | 低危 | 用 `kill $PID` 精确杀，不用 `pkill -f python` |

---

## A-1　一键安装落盘

**验收目标**：一条命令安装后，主脚本、7 个 lib 模块、cmd 守护文件全部落盘；**落盘文件不含 CR**；`pf` 快捷命令可用。

**前置**：干净的 Debian/Ubuntu VPS（root），可访问 GitHub raw；未装过 realm-xwPF。

**命令**

```bash
# 1) 安装
wget -qO- https://raw.githubusercontent.com/byby5555/realm-xwPF-offline-active-standby/main/xwPF.sh | sudo bash -s install

# 2) 落盘清单
ls -l /usr/local/bin/pf /usr/local/bin/xwPF.sh
ls -l /usr/local/bin/lib/
ls -l /usr/local/bin/cmd/
readlink -f /usr/local/bin/pf

# 3) 【关键】行尾自检：任何文件含 CR 即 FAIL
for f in /usr/local/bin/xwPF.sh /usr/local/bin/lib/*.sh /usr/local/bin/cmd/*; do
  if grep -q $'\r' "$f"; then echo "FAIL-CRLF: $f"; else echo "OK: $f"; fi
done

# 4) 语法自检（落盘产物能解析）
for f in /usr/local/bin/xwPF.sh /usr/local/bin/lib/*.sh; do bash -n "$f" && echo "SYNTAX-OK: $f"; done

# 5) 依赖齐备性
for t in curl wget tar grep cut bc jq openssl python3; do
  printf '%-10s %s\n' "$t" "$(command -v $t || echo MISSING)"
done
```

**期望结果（可判定）**

1. 安装输出含 `=== 脚本安装完成 ===`，且 `lib/` 下 **7 个**文件齐全：`core.sh health.sh rules.sh server.sh realm.sh failover.sh ui.sh`。
2. `/usr/local/bin/pf` → 解析到 `/usr/local/bin/xwPF.sh`。
3. **第 3 步全部输出 `OK:`，没有任何 `FAIL-CRLF:`**。
4. 第 4 步全部 `SYNTAX-OK`。
5. 第 5 步 **无 `MISSING`**（`nc` 不在必需清单内，缺它不算 FAIL）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 出现 `FAIL-CRLF:` | 安装源被 CRLF 污染（Windows 打包的离线包）。查 `curl -sI <raw url> \| grep -i content-length` 与下载字节；**这是第 1 轮报告 B3 的残余风险**，`4558e65` 只归一了 heredoc 生成物，没归一落盘文件 |
| `lib/` 少文件 | 看安装日志里哪一行 `✗ lib/xxx.sh 下载失败`；多半是 raw 路径拼错或分支不含该文件 |
| `bash -n` 报错 | 同样是 CRLF 或文件被截断（`_download` 的原子替换失败） |
| `MISSING: jq` | `jq` 在 `lib/core.sh` 的 `REQUIRED_TOOLS` 里，应由安装器自动装；自动装失败要走 `docs/install-and-upgrade.md` 的离线装法 |

**危险动作**：`install` 会覆盖 `/usr/local/bin/lib/*`、重建 `pf` 软链、**触发 `smart_install`（可能改 `/etc/realm` 配置）**。业务机先备份 `/etc/realm`。
> **修订（2026-10-24 21:20）**：原文此处写「并 `systemctl enable xwpf-failover`」—— 该动作属**已废弃删除**的守护进程功能，已从本句移除。⚠️ 但**卸载/升级时仍要处理老机器上的残留**（守护进程 / unit / drop-in / 占用端口）—— 见 **A-15**。

---

## A-2　`pf --help` 实际行为

**验收目标**：三种 `--help` 写法都打印用法并**以 0 退出**，不落进交互菜单。

**前置**：A-1 已完成。

**命令**

```bash
for a in "--help" "-h" "help"; do
  echo "===== pf $a ====="
  timeout 10 pf $a; echo "EXIT=$?"
done
```

**期望结果（可判定）**

1. 三次都输出用法文本（包含 `Usage` 或 `用法` 之一）。
2. 三次 `EXIT=0`。
3. 输出中**不出现主菜单项**（`负载均衡管理` / `主备 active/passive`）——出现即说明掉进了交互菜单。
4. 三次输出**在 10 秒内**返回（`timeout` 不触发）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 出现菜单项或超时（124） | `--help` 未被 `xwPF.sh` 的 `case` 命中，掉进 `main "$@"` → 查 `xwPF.sh` 的 `case "${1:-}"` 分支 |
| 退出码非 0 | 用法文本里 `main` 返回值未归一 → 查 `main` 的收尾 |
| 某一种写法能出、另一种不能 | 三种写法未对齐（`--help` / `-h` / `help` 必须等价） |

**危险动作**：无（只读）。**注意**：`pf help` 若被误改成进入菜单，输入流必须用 `</dev/null` 兜住，否则会挂住终端。

---

## A-3　权重 `1,0` 自动进主备并拉起 timer

**验收目标**：把端口组权重填成含 0 → 规则自动变 `active-standby` + `FAILOVER_ENABLED=true`，健康检查脚本与 systemd timer/service 全部落地。

**前置**：realm 已装且能起；A-1 通过；两个可连通目标（本机用 `127.0.0.1` / `127.0.0.2` 造，见 A-5）。

> ⚠️ 本项用**两个不同的 host**（`127.0.0.1` / `127.0.0.2`），是为了把「主备切换」与「同 host 多端口」两件事**解耦**，不是产品限制。健康状态文件的 `TARGET` 口径自 N1 落地起是 `host:port`（key = `RULE_ID|host:port`），**同 host 的不同端口不再互相覆盖**；「key 不含端口」是 N1 修复**之前**的旧行为，已在 `a7e23fc` / `bfc99d3` 修掉 —— 历史登记见 `reports/round1-baseline-review.md` 附录 A-3-1，现状口径见 A-4。

**命令（白盒，直接驱动产品代码路径，最可复现）**

```bash
sudo bash <<'EOF'
set -e
R=/etc/realm/rules
mkdir -p "$R"

cat > "$R/rule-9001.conf" <<'C'
RULE_ID=9001
RULE_ROLE=1
RULE_NAME=acc-a
SECURITY_LEVEL=standard
LISTEN_PORT=8443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=8443
ENABLED=true
BALANCE_MODE="roundrobin"
FAILOVER_ENABLED="false"
WEIGHTS="1,0"
C

cat > "$R/rule-9002.conf" <<'C'
RULE_ID=9002
RULE_ROLE=1
RULE_NAME=acc-b
SECURITY_LEVEL=standard
LISTEN_PORT=8443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.2
REMOTE_PORT=8443
ENABLED=true
BALANCE_MODE="roundrobin"
FAILOVER_ENABLED="false"
WEIGHTS="0"
C

source /usr/local/bin/lib/core.sh
source /usr/local/bin/lib/health.sh
source /usr/local/bin/lib/rules.sh
source /usr/local/bin/lib/ui.sh
apply_port_group_weight_config 8443 "1,0"
EOF
```

**验收断言**

```bash
echo "--- 规则文件 ---"
grep -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS)=' /etc/realm/rules/rule-9001.conf /etc/realm/rules/rule-9002.conf

echo "--- 生成物 ---"
ls -l /etc/realm/health/health_check.sh /etc/systemd/system/realm-health-check.service /etc/systemd/system/realm-health-check.timer
grep -c $'\r' /etc/realm/health/health_check.sh /etc/systemd/system/realm-health-check.*   # 必须为 0

echo "--- timer ---"
systemctl is-enabled realm-health-check.timer
systemctl is-active  realm-health-check.timer
systemctl show realm-health-check.timer -p OnUnitActiveUSec
systemctl cat realm-health-check.service | grep -E 'ExecStart|SyslogIdentifier'

echo "--- realm 侧看到的权重 ---"
jq -r '.endpoints[] | select(.listen_port==8443 or .listen==8443) | .balance' /etc/realm/config.json 2>/dev/null \
  || jq -r '.endpoints[].balance' /etc/realm/config.json
```

**期望结果（可判定）**

1. 规则文件里：`BALANCE_MODE="active-standby"`、`FAILOVER_ENABLED="true"`、`WEIGHTS="1,0"`（第 1 条规则存全量、第 2 条存单值）。
2. `/etc/realm/health/health_check.sh` **存在**，且 `grep -c $'\r'` 结果为 **0**。
3. `/etc/systemd/system/realm-health-check.service` 与 `.timer` **都存在**，且不含 CR。
4. `systemctl is-enabled realm-health-check.timer` → `enabled`；`is-active` → `active`。
5. `OnUnitActiveUSec` ≈ `4s`（默认 `HEALTH_CHECK_INTERVAL=4`；改过则按规则文件里的值）。
6. `ExecStart=` 指向 `/etc/realm/health/health_check.sh`（**路径里不能有 `\r`**）。
7. `config.json` 里该端点的 `balance` 形如 `"roundrobin: 1,0"` —— **注意 realm 不认识 `active-standby`，底层输出的是 `roundrobin`**（`lib/realm.sh` 的 `generate_endpoints_from_rules`）。比较时按逗号切分取数字序列，忽略空格。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| timer `is-enabled` 返回 `disabled` / `is-active` 返回 `inactive` | 健康检查服务没被拉起 → 查 `lib/rules.sh` 的 `ensure_health_check_service` 返回值；它失败时只打警告、**不回滚主备开关**，会出现「规则是主备但没人探测」的状态 → 这是第 1 轮报告 B1 |
| `health_check.sh` 不存在 | `start_health_check_service` 没跑到；先 `bash -x /etc/realm/xwFailover.sh start` 看断点 |
| `ExecStart` 路径带 `\r` | 落盘的 unit 是 CRLF → 同 A-1 第 3 步 |
| `balance` 还是 `roundrobin: 1,1` 或权重不对 | `port_weights` 与目标数没对齐；查规则文件里 WEIGHTS 的存储约定（第 1 条全量、其余单值） |

**交互路径复验**（可选，确认 UI 也能触发同一条链）：

```bash
pf   # 主菜单 → 6. 负载均衡管理 → 权重配置管理 → 选端口 8443 → 权重序列填 1,0 → 确认
```

**危险动作**：`apply_port_group_weight_config` 末尾会调 `service_restart` → **realm 重启，转发短暂中断**；并会写 `/etc/realm/rules/*`。业务机先备份。

---

## A-4　健康状态文件格式与文档一致

**验收目标**：状态文件结构与 `docs/health-check-and-failover.md` 声明的格式逐字段一致，**含 `TARGET` 的 `host:port` 口径**。

**前置**：A-3 已完成且健康检查至少跑过 1 轮。

> **锚点与口径来源（本节所有判据的依据）**
>
> - **被测产物锚定 `a7e23fc`**（`fix(health): 健康状态 TARGET 口径改 host:port`）—— 本节的字段定义、格式串、探测端双查逻辑均取自 `git show a7e23fc:lib/health.sh` 的 `health_check_script_body`，**不取工作区文件**。
> - **紧随其后的 `bfc99d3`（N1-R1）改了旧格式的兜底**：去掉了消费端「认得出归属时另存一份裸 host 宽键」与展示端「查不到时按裸 host 再查一次」。**裸 host 残留对同 host 多端口场景的影响因此以 `bfc99d3` 为准**（见下面「裸 host 残留的影响」一节的两版对照）。现场若装的是 `a7e23fc` 及更早，**结论相反** —— 验收时必须先确认装的是哪一版。
> - **复核时 HEAD 现状**：`14aef0c`。`a7e23fc..14aef0c` 之间 `lib/health.sh` 与 `lib/realm.sh` 的净变化**只有** N1-R1 那一次（去掉裸 host 兜底），**9 字段格式串与字段顺序未变**。

> **读文件前先看这三条**（都来自实现，不看会误判）：
>
> 1. **状态文件路径有三个候选**（`lib/health.sh` 的 `health_check_script_body` 按顺序探测）：`/etc/realm/health/health_status.conf` → `/etc/realm/health_status.conf` → `/var/lib/realm/health_status.conf`。下面的命令用 `$HEALTH_FILE`。
> 2. **头部注释是「首次创建时」写下的，不随升级刷新**（`if [ ! -f "$HEALTH_STATUS_FILE" ]; then ... fi`）。`a9102c1` 及更早版本写下的是 **7 字段**那一行，之后才是 9 字段。→ **从老版本升上来的机器，头部注释仍是老口径，但数据行已经是新口径**。此时以**数据行**为准，头部陈旧**登记不判 FAIL**（低优先级，不影响解析：读取端按位置取字段，多出的字段自动忽略）。
> 3. **文件一旦触发过内置的 >5MB 清理，头部注释会被截掉且不再补回**（清理用 `tail -n 2000` 保留尾部）。此时「前两行是注释」不成立，属已知形态，**登记不判 FAIL**。

**命令**

```bash
# 状态文件路径（产品按顺序探测这三个）
HEALTH_FILE=""
for p in /etc/realm/health/health_status.conf /etc/realm/health_status.conf /var/lib/realm/health_status.conf; do
  [ -f "$p" ] && { HEALTH_FILE="$p"; break; }
done
echo "状态文件: ${HEALTH_FILE:-<没找到>}"
[ -n "$HEALTH_FILE" ] || exit 1

echo "--- 头两行注释 ---"
head -2 "$HEALTH_FILE"

echo "--- 数据行字段数分布（应为 9）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '{print NF}' | sort | uniq -c

echo "--- STATUS 取值集合（应只有 healthy / failed）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '{print $3}' | sort | uniq -c

echo "--- TARGET 口径（应全部是 host:port，即第 2 字段含冒号）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$2 !~ /:/ {print "BAD-TARGET:", $0}' | head

echo "--- 时间戳字段（第 6 LAST_CHECK / 第 7 FAILURE_START_TIME，应全是纯数字）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$6 !~ /^[0-9]+$/ || $7 !~ /^[0-9]+$/ {print "BAD-TS:", $0}' | head

echo "--- 时延字段（第 8 LATENCY_MS 整数毫秒、第 9 LATENCY_HISTORY 逗号分隔数字，可为空）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$8 != "" && $8 !~ /^[0-9]+$/ {print "BAD-LAT:", $0}' | head
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$9 != "" && $9 !~ /^[0-9]+(,[0-9]+)*$/ {print "BAD-HIST:", $0}' | head

echo "--- 文档声明的格式 vs 文件头注释（应逐字符一致）---"
FMT='RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY'
doc_fmt=$(grep -o "$FMT" docs/health-check-and-failover.md 2>/dev/null | head -1)
file_fmt=$(head -2 "$HEALTH_FILE" | grep -o "$FMT" | head -1)
echo "doc : ${doc_fmt:-<没找到>}"
echo "file: ${file_fmt:-<没找到>}"
[ -n "$doc_fmt" ] && [ "$doc_fmt" = "$file_fmt" ] && echo "FMT-MATCH: OK" || echo "FMT-MATCH: MISMATCH"
```

> `docs/health-check-and-failover.md` 是**仓库内**路径 —— 这条命令要在**有仓库检出**的目录下跑（或把它换成被测文档的实际路径）。文档里 9 字段格式串出现 **2 次**（字段表 + 头部注释样例），`grep -o | head -1` 取到的是同一串。

**期望结果（可判定）**

1. 前两行是注释，第 2 行含 9 字段格式串 `RULE_ID|TARGET|STATUS|FAIL_COUNT|SUCCESS_COUNT|LAST_CHECK|FAILURE_START_TIME|LATENCY_MS|LATENCY_HISTORY`。（**老机器上头部可能是 7 字段那一行 → 见上面的读文件前提 2**。）
2. 数据行字段数**只有 9**（`awk` 输出只有一个计数，值为 9）。
3. `STATUS` **只有 `healthy` / `failed`** 两种取值。
4. `TARGET` 口径按**三档**判定（不是「一律 PASS / 一律 FAIL」）：
   - **绝大多数行是 `host:port`** → **期望，判 PASS**。`a7e23fc` 起写入端写的**就是** `host:port`（`target_endpoint="${target}:${REMOTE_PORT}"`）。
   - **少数行只有 host**，且其 `RULE_ID` **已不在规则目录里**（归属已失效的孤儿行）→ **有条件接受，但要登记**（见下面「裸 host 残留的影响」与 A-4.1）。这是**旧格式兼容路径**，不是设计，也不是缺陷。
   - **少数行只有 host**，且其 `RULE_ID` **仍在规则目录里**（归属可确定）→ 跑完 1 轮健康检查后**必须**已被迁成 `host:port`；仍裸 host ⇒ **判 FAIL**（迁移没生效）。
   - **裸 host 行占多数** → **判 FAIL**（装的是 `a7e23fc` 之前的旧产物，写端就没升级）。
   - 判定「归属还在不在」的命令见 **A-4.1**。
5. 第 6、7 字段**全部是纯数字**（`BAD-TS:` 无输出）；第 8 字段是整数毫秒或空（`BAD-LAT:` 无输出）；第 9 字段是逗号分隔的数字或空（`BAD-HIST:` 无输出）。**第 9 字段的两种合法形态**：`LATENCY_HISTORY` 为**空**（还没探测成功过、或没取到时间戳）或为**逗号分隔的数字列表**（如 `10,12,14`，最多 5 个样本）；**其余形态都是坏数据**。
6. 文档声明的格式串与文件头注释**逐字符一致**（`FMT-MATCH: OK`）—— **仅对全新安装成立**；升级机以数据行为准。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 字段数不是 9 | **先确认健康检查已跑过 1 轮**（老行由探测端在下一轮原地迁移，见 A-4.1）。仍为 7/6 字段的行，若其 `RULE_ID` **在规则目录里还存在**（归属可确定）⇒ **判 FAIL**（迁移没生效）；若该 `RULE_ID` 已不存在（孤儿行）⇒ **登记不判 FAIL**（产品按「当无记录」处理，下一轮重新探测生成精确键）。另外：**只有 7 个字段本身是老版本产物的正常形态**（`LATENCY_MS`/`LATENCY_HISTORY` 是后加的），此时应**升级**而不是改代码 |
| 出现第 3 种 STATUS | 判定逻辑里还有别的状态值 → 查 `lib/health.sh` 的状态机 |
| 第 6/7 字段不是数字 | 更老的格式（无 `failure_start_time`）未升级 → 文档 §6.4 有旧格式兼容说明，检查读取端是否做了兼容 |
| 第 8/9 字段不是数字 | 时延字段写坏了 → 查 `lib/health.sh` 的 `probe_with_latency` / `latency_avg_ms` |
| **TARGET 只有 host、没有端口** | **分三档，不要一律判 FAIL，也不要一律放过。** ① 少数行、且其 `RULE_ID` 已不在规则目录里 → **旧格式兼容路径，有条件接受 + 登记**（产品按「认不出归属 → 当无记录」处理，下一轮重新探测生成精确键）；② 少数行、且其 `RULE_ID` 仍在规则目录里 → 跑完 1 轮健康检查后**必须**迁成 `host:port`，仍裸 host ⇒ **判 FAIL**（迁移没生效）；③ 裸 host 行占多数 ⇒ **判 FAIL**（装的是 `a7e23fc` 之前的旧产物）。**判据依据**：文档 `docs/health-check-and-failover.md` 的 `TARGET` 字段表写的就是 `host:port`，`a7e23fc` 起写入端也是 `host:port` —— **裸 host 是旧格式，不是设计** |
| 头部注释与文档不一致 | **先判是全新安装还是升级机**（见读文件前提 2/3）。升级机 ⇒ **登记不判 FAIL**（低优先级，不影响解析）；全新安装仍不一致 ⇒ **判 FAIL**（写端的头部格式串与文档脱节） |
| 老文件升级后被当成「无记录 / 健康」 | 旧格式兼容失效 → 见 A-4.1，判据是「升级瞬间的老记录仍要被认出来」 |

**裸 host 残留对「同 host 多端口」场景的影响（为什么必须登记）**

裸 host 记录**不含端口**，所以它分不清同 host 的哪个端口。产品对它的处理随版本而变，验收时**必须先确认装的是哪一版**：

| 装的是 | 消费端（`lib/realm.sh` 的 `generate_endpoints_from_rules`）对旧格式行的处理 | 同 host 的另一个端口会不会被这条老记录带坏 |
|---|---|---|
| `a7e23fc`（有 N1，**没有** N1-R1） | 认得出归属 → 入精确键 `host:port`，**并且始终另存一份裸 host 宽键** | **会**。精确键查不到时退到宽键 → 读到这条老记录的状态 → 同 host 另一个端口被判成同样的状态 |
| `bfc99d3` 及以后（N1-R1） | 认得出归属 → **只**入精确键，**不存宽键**；认不出归属 → **当无记录** | **不会**。宽键已被去掉 |

`bfc99d3` 之前那个「宽键」的危害是**具体的**：同一主备组内两个目标同 host 不同端口（`10.0.0.1:111` / `10.0.0.1:222`）时，222 查不到精确键 → 退宽键 → 读到 111 的 `failed` → **两个目标都判 failed** → 走「全部目标都挂了」的兜底 → **保持原主不切备** —— 流量压在已故障的主机上，**该切不切的静默失效**。

所以**裸 host 残留 + 同 host 多端口 = 危险组合**，必须登记。清法见 A-4.1：跑完 1 轮健康检查即迁完；归属失效的孤儿行按「当无记录」处理，下一轮重新探测生成精确键。**现场验证见 A-Y。**

**危险动作**：**不要手工编辑** `health_status.conf`（每轮健康检查会原子重写，手改必丢）；排查时只读。A-4.1 要构造老文件时用**副本**，不要动生产文件。

### A-4.1　旧格式兼容登记（升级瞬间的老文件：**不必手工删**）

**要验的是什么**：现网老版本的 `health_status.conf` 里 `TARGET` **只有 host**。升级到当前版本后，这些老行**仍要被正确识别** —— 而不是被当成「没记录 → 目标健康」→ 故障转移静默失效。

**产品侧的三条口径**（与 `docs/health-check-and-failover.md` §6.4 一致）：

1. **探测端**（`lib/health.sh` 的 `health_check_script_body`）：先按 `RULE_ID|host:port` 找自己的记录，**找不到再按旧口径 `RULE_ID|host` 找**；找到就**沿用老记录的状态与计数**（`FAIL_COUNT` / `SUCCESS_COUNT` / `FAILURE_START_TIME` 不清零）；写回时**写成新格式并删掉同一 host 的旧行**。
2. **消费端**（`lib/realm.sh` 的 `generate_endpoints_from_rules`）：旧格式的行按该行 `RULE_ID` 对应规则的 `REMOTE_PORT` **补出端口**，入**精确键** `host:port`。
   - **认得出归属时只入精确键**，**不再另存一份裸 host 的宽键** —— 宽键会把「一个端口的故障」传播给同 host 的其他端口：同一主备组里两个目标同 host 不同端口时，两个目标会同时被判 failed → 走「全部目标都挂了」的兜底 → 保持原主不切备（**该切不切的静默失效**）。
   - **认不出归属**（规则已删、行号式的老记录）时**当无记录**：由健康检查下一轮重新探测、生成精确键。
3. **展示端**（`lib/health.sh` 的 `get_health_status_record`）：按 `TARGET` 字段**精确匹配**，查不到就是查不到，**不**按裸 host 兜底（否则会把同 host 另一个端口的记录显示成这条目标的）。

**验收动作（老文件是天然样本时）**

前置：本机是**从旧版本升级**上来的（升级前的老文件还在），或手上有一份同源的老文件副本。

```bash
HEALTH_FILE=/etc/realm/health/health_status.conf   # 按实际路径改

echo "--- 裸 host 老行样例（升级前的老文件天然就是这个形态）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$2 !~ /:/ {print}' | head

echo "--- 每条老行的 RULE_ID 是否还归属某条规则（owned=yes 归属可确定 / owned=no 已成孤儿）---"
for id in $(grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$2 !~ /:/ {print $1}' | sort -u); do
  owned=no
  for f in /etc/realm/rules/rule-*.conf; do
    [ -f "$f" ] || continue
    if grep -q "^RULE_ID=${id}$" "$f" 2>/dev/null; then owned=yes; break; fi
  done
  echo "RULE_ID=$id owned=$owned"
done
```

**期望结果（可判定）**

1. 升级瞬间，老行**仍在**文件里（升级不会自己删数据）。
2. 跑完**1 轮健康检查**后，归属可确定（`owned=yes`）的老行被**原地迁成 `host:port`**，且 `FAIL_COUNT` / `SUCCESS_COUNT` / `FAILURE_START_TIME` **沿用老值**（不是清零重来）。
3. 老行若曾是 `failed`，升级后**不能**变成 `healthy`（否则老故障被当成健康 → 故障转移静默失效）。
4. 归属已失效（`owned=no`）的老行**可以**留在文件里 —— 产品按「当无记录」处理，下一轮重新探测。

**因此：真机验收看到裸 host 时，不必手工删 `health_status.conf`** —— 产品自己会迁移（跑完 1 轮健康检查即迁完；归属失效的行由下一轮重新探测）。

**危险动作**：要**构造**老文件时，用**副本**（如 `/tmp/health_status.conf.bak`）在测试机上做，**不要**改生产文件；本节全程只读。

---

## A-X　旧格式状态文件 + 新代码 → 仍能正确切换

**验收目标**：老状态文件里那条 `failed` 在升级后**不被当成「无记录 → 目标健康」**（否则故障转移静默失效），同时**不会把同 host 的另一个端口一起判坏**。

**锚点**（复核时 2026-10-24，仓库 HEAD `14aef0c`）：
- **被测产物**：`git show a7e23fc:lib/health.sh`、`git show a7e23fc:lib/realm.sh`、`git show a7e23fc:lib/rules.sh`（N1 落地那笔）。
- **期望所依据的行为**：`bfc99d3`（N1-R1，**去掉裸 host 宽键兜底**之后）。`a7e23fc`（N1，**未含** N1-R1）的行为差异见 A-4 的「裸 host 残留的影响」对照表。
- **复核时 HEAD**：`14aef0c`；`a7e23fc..14aef0c` 之间 `lib/health.sh` 与 `lib/realm.sh` 的净变化**只有** N1-R1 那一次（去掉裸 host 兜底），**9 字段格式串与字段顺序未变**。
- 被测产物一律取 `git show <SHA>:<path>`，**不取工作区文件**。

**前置（三选一，优先级从高到低）**

1. **本机是从旧版本升级上来的**（最省事）：升级前的那个老文件**还在** `/etc/realm/health/health_status.conf` —— 升级**不会自己删数据**，它就是天然样本。
2. **手上有升级前留存的副本**：来源只能是 ① 升级前的整机/配置备份里的 `/etc/realm/health/` 目录；② 升级前手工 `tar` 的归档；③ 升级工具自己留的 `.bak`（**本产品不留** —— 健康状态文件不在安装/升级的备份清单里，**不能指望**）。**取不到就转第 3 条。**
3. **现场造样本**（见下表）—— **在沙箱/临时目录里造，不碰生产文件**。

**造样本的三种办法（按安全性排序）**

| 办法 | 怎么做 | 适用 | 注意 |
|---|---|---|---|
| **台架沙箱**（推荐） | `tests/run_tests.sh` 的沙箱把 `/etc/realm` 重定向到 `$SBX_ROOT` 下，**自带旧格式样本的用例**：`tests/cases/12_health_target_scope.sh` 的 `case_T52_health_target_scope`（同 host 不同端口互不覆盖 + 旧格式兼容 + 认不出归属时当无记录） | **本地或任意机器，不需要真机** | 台架覆盖的是**逻辑等价**，**不替代**现场 |
| **干净机/容器 + `HEALTH_DIR`** | 健康检查脚本对状态文件路径的取值顺序是：`HEALTH_STATUS_FILE` 环境变量 → 三个硬编码候选路径 → `${HEALTH_DIR}/health_status.conf`。**三个候选路径只要存在一个，环境变量就被覆盖** —— 所以只有**候选路径都不存在**的机器上，`HEALTH_DIR=/tmp/acc-x` 才生效 | **测试机 / 一次性容器** | 规则目录 `RULES_DIR` 在生成脚本里是**硬编码**的 `/etc/realm/rules`，**不可用环境变量改** → 规则也得在测试机上另备 |
| **复制到测试机** | 把 `lib/` 与规则目录复制到测试机，在测试机上造 | 有第二台机器时 | 本节全程**只读**；**不要**在生产机上造 |

> **⛔ 两条不要**
>
> 1. **不要手工编辑 `/etc/realm/health/health_status.conf`** —— 每轮健康检查会原子重写（先 `grep -v` 掉旧行、再 `mv` 新文件），手改必丢。
> 2. **不要指望 `HEALTH_STATUS_FILE=/tmp/x.conf` 能把健康检查重定向到临时文件** —— 生成脚本里的路径探测循环会**无条件重置**这个变量、再按硬编码候选路径找，**候选路径存在时你的环境变量不起作用**（在已有生产文件的机器上，它仍会写生产路径）。

**命令（全程只读，样本用第 1/2 条前置的自然样本）**

```bash
HEALTH_FILE=/etc/realm/health/health_status.conf
[ -f "$HEALTH_FILE" ] || HEALTH_FILE=/etc/realm/health_status.conf
[ -f "$HEALTH_FILE" ] || HEALTH_FILE=/var/lib/realm/health_status.conf
echo "状态文件: $HEALTH_FILE"

echo "--- 1) 老文件里裸 host 的行（升级瞬间的天然形态）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$2 !~ /:/ {print}'

echo "--- 2) 每条老行的 RULE_ID 是否还归属某条规则 ---"
echo "    owned=yes -> 归属可确定，产品应把它迁成 host:port"
echo "    owned=no  -> 归属已失效（规则已删），产品按「当无记录」处理"
for id in $(grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$2 !~ /:/ {print $1}' | sort -u); do
  owned=no
  for f in /etc/realm/rules/rule-*.conf; do
    [ -f "$f" ] || continue
    if grep -q "^RULE_ID=${id}$" "$f" 2>/dev/null; then owned=yes; break; fi
  done
  echo "RULE_ID=$id owned=$owned"
done

echo "--- 3) 老行里 failed 的那些（升级后不能被洗成 healthy）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$2 !~ /:/ && $3=="failed" {print "OLD-FAILED:", $0}'

echo "--- 4) 让探测端跑一轮（把老行原地迁成 host:port）---"
echo "    首选：等 timer 自然跑（OnUnitActiveUSec 默认 4s）—— sleep 8 即可"
echo "    备选：systemctl start realm-health-check.service（有副作用，见下方「危险动作」）"
sleep 8

echo "--- 5) 迁完后的全部数据行 ---"
grep -v '^#' "$HEALTH_FILE"

echo "--- 6) 跑完之后还剩哪些裸 host（应只剩下 owned=no 的孤儿行）---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$2 !~ /:/ {print}'

echo "--- 7) 关键：老故障有没有被洗白 ---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '$3=="failed" {print "STILL-FAILED:", $0}'

echo "--- 8) 同 host 的另一个端口有没有被这条老记录带坏 ---"
grep -v '^#' "$HEALTH_FILE" | awk -F'|' '{print $1, $2, $3}' | sort -u
```

**期望结果（可判定）**

1. 第 2 步里 `owned=yes` 的老行 = **归属可确定**的那些。
2. 第 4 步跑完后，**`owned=yes` 的老行已被原地迁成 `host:port`**（`TARGET` 含冒号），且 `FAIL_COUNT` / `SUCCESS_COUNT` / `FAILURE_START_TIME` **沿用老值**（不是清零重来）。
3. 第 3 步列出的每一条 `OLD-FAILED`，在第 7 步里都**必须**还能找到对应目标 —— 老故障**不能**被升级洗成 `healthy`（洗白了 = 故障转移静默失效）。
4. 第 8 步里，**同 host 的另一个端口不得因为这条老记录变成 `failed`** —— 它的状态必须来自它自己的探测。
5. 第 6 步里**允许**剩下 `owned=no` 的孤儿行（产品按「认不出归属 → 当无记录」处理，下一轮重新探测生成精确键）—— 这是**正确行为**，不是缺陷。
6. 迁完的老行**字段数应为 9**（见 A-4）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 老行跑完一轮还是裸 host（且 `owned=yes`） | 迁移没生效 → 查探测端 `lib/health.sh` 的 `health_check_script_body` 有没有做新旧双查（先 `grep` 精确键、再 `grep` 旧口径键）与写回时的旧行清理 |
| 老记录从 `failed` 变成 `healthy` | **最严重的一种**：老故障被洗白 → 查探测端取到旧记录后有没有把 `status` 一起继承下来（`IFS='|' read -r … status …`） |
| 同 host 的另一个端口被带成 `failed` | 消费端 `lib/realm.sh` 的 `generate_endpoints_from_rules` 还**存了一份裸 host 宽键** → 那是 `a7e23fc` 那一版（**未含 N1-R1**），**必须升级**；`bfc99d3` 起已去掉 |
| 一条老行都没迁、文件也没更新 | 健康检查根本没在跑 → `systemctl status realm-health-check.timer`；`journalctl -u realm-health-check.service -n 30` |
| 迁完后整行字段数不是 9 | 见 A-4 的字段数判据（老行迁完就该是 9 字段） |
| 老行一直不动、`owned` 也认不出 | 规则目录里的 `RULE_ID` 与老行对不上（规则被重排/重写过 ID）→ 查 `lib/rules.sh` 的 `sync_health_status_ids` |

**危险动作**：本节**全程只读**；唯一有副作用的是第 4 步的 `systemctl start realm-health-check.service` —— 它在探测到状态变化时会调 `pf --restart-service` → **realm 重启、转发短暂中断**，**要在维护窗口做**（优先用「等 timer 自然跑」代替）。**不要**手工改状态文件。

---

## A-Y　同 host 两个端口 → 状态互不覆盖

**验收目标**：**同一台 host** 上的**不同端口**是**不同目标**；一个坏了**不会**把另一个也带成坏。

**锚点**（复核时 2026-10-24，仓库 HEAD `14aef0c`）：被测产物取 `git show a7e23fc:lib/health.sh` 与 `git show a7e23fc:lib/realm.sh`；`a7e23fc..14aef0c` 之间这两个文件**只有** N1-R1（`bfc99d3`，去掉裸 host 宽键兜底）一处变化，**9 字段格式串与字段顺序未变** —— 见 A-4 的锚点说明。被测产物一律取 `git show <SHA>:<path>`，**不取工作区文件**。

**为什么必须分两种形态做**

「同 host 不同端口」在真实部署里有**两种**形态，触发的是**不同**的代码路径，**两种都要测**：

| 形态 | 拓扑 | 旧实现的症状 |
|---|---|---|
| **① 两个不同的转发组** | 两条规则，**不同 `LISTEN_PORT`**，目标**同一 host 不同端口**（`127.0.0.1:8443` 与 `127.0.0.1:9443`） | N1 的主症状：读侧只按 host 建索引 → 两个组的状态互相覆盖（A 组故障被 B 组的健康记录盖掉） |
| **② 同一个转发组内的主备两端点** | 两条规则，**同一个 `LISTEN_PORT`**（主备组），目标**同一 host 不同端口** | N1-R1 的症状：宽键兜底把一个端口的故障传播给另一个 → 两个目标都判 failed → 走「全部目标都挂了」的兜底 → **保持原主不切备**（流量压在已故障的主机上） |

**前置**

- realm 已装且能起；本机 `command -v nc` 有输出（否则**先过 A-7**）。
- **已备份** `/etc/realm/rules/` 与 `/etc/realm/config.json`（本项会写规则、可能重启 realm）。
- 只允许在 `127.0.0.0/8` 上做；**严禁动 22 端口**。
- **端口规划**（避免与造目标用的监听撞端口）：转发组监听 `18443` / `19443`，目标监听 `8443` / `9443`。

**命令**

```bash
# ---------- 准备：同一 host 的两个端口各起一个监听 ----------
python3 -m http.server 8443 --bind 127.0.0.1 >/tmp/acc-y-8443.log 2>&1 & echo $! >/tmp/acc-y-8443.pid
python3 -m http.server 9443 --bind 127.0.0.1 >/tmp/acc-y-9443.log 2>&1 & echo $! >/tmp/acc-y-9443.pid
sleep 1
```

**形态 ①：两个不同的转发组，目标同 host 不同端口**

```bash
sudo bash <<'EOF'
R=/etc/realm/rules
mkdir -p "$R"

cat > "$R/rule-9101.conf" <<'C'
RULE_ID=9101
RULE_ROLE=1
RULE_NAME=ay-g1
SECURITY_LEVEL=standard
LISTEN_PORT=18443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=8443
ENABLED=true
BALANCE_MODE="roundrobin"
FAILOVER_ENABLED="true"
WEIGHTS="1"
C

cat > "$R/rule-9102.conf" <<'C'
RULE_ID=9102
RULE_ROLE=1
RULE_NAME=ay-g2
SECURITY_LEVEL=standard
LISTEN_PORT=19443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9443
ENABLED=true
BALANCE_MODE="roundrobin"
FAILOVER_ENABLED="true"
WEIGHTS="1"
C
EOF

echo "--- 让健康检查跑一轮（探测端只处理 RULE_ROLE=1 且 ENABLED=true 且 FAILOVER_ENABLED=true 的规则）---"
sleep 8

echo "--- 状态文件：应有两行，TARGET 分别是 127.0.0.1:8443 与 127.0.0.1:9443 ---"
grep -v '^#' /etc/realm/health/health_status.conf

echo "--- 只坏掉 9443 那个（同一 host 的另一个端口必须仍是 healthy）---"
kill "$(cat /tmp/acc-y-9443.pid)"; rm -f /tmp/acc-y-9443.pid
sleep 20

echo "--- 关键：8443 那行必须仍是 healthy ---"
grep -v '^#' /etc/realm/health/health_status.conf | awk -F'|' '{print $1, $2, $3, $4}'

echo "--- 日志 ---"
journalctl -u realm-health-check.service -n 30 --no-pager | grep -E 'FAILURE|CONFIG|RECOVERY'
```

> **为什么手写 `FAILOVER_ENABLED="true"`**：探测端只探测**故障转移中转规则**（`RULE_ROLE=1` 且 `ENABLED=true` 且 `FAILOVER_ENABLED=true`），`FAILOVER_ENABLED="false"` 的规则**根本不会被探测**、状态文件里也不会有它。走产品自己的开关也行：`apply_port_group_weight_config <LISTEN_PORT> "1,0" 1`（**第三个参数 `1` 是跳过交互确认，无头环境必须传**，否则会卡在 `read -p` 上；权重含 0 会自动切 `active-standby` 并开 `FAILOVER_ENABLED`）。本节用最直接的白盒写法，**不引入权重口径的干扰**。

**形态 ②：同一个转发组内的主备两端点，目标同 host 不同端口**

```bash
sudo bash <<'EOF'
R=/etc/realm/rules
# 先撤掉形态 ① 的第二条规则（它的目标也是 127.0.0.1:9443，留着会让同一个 TARGET 出现两行、断言含糊）
rm -f "$R/rule-9102.conf"
# 同一 LISTEN_PORT=18443 的第二条规则（主备组的另一端点）
cat > "$R/rule-9103.conf" <<'C'
RULE_ID=9103
RULE_ROLE=1
RULE_NAME=ay-g2
SECURITY_LEVEL=standard
LISTEN_PORT=18443
LISTEN_IP=0.0.0.0
THROUGH_IP=::
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9443
ENABLED=true
BALANCE_MODE="roundrobin"
FAILOVER_ENABLED="true"
WEIGHTS="0"
C

source /usr/local/bin/lib/core.sh
source /usr/local/bin/lib/health.sh
source /usr/local/bin/lib/rules.sh
# 第三个参数 1 = 跳过交互确认（无头环境必须传）
apply_port_group_weight_config 18443 "1,0" 1
EOF

echo "--- 规则与主备开关（同端口组内：第 1 条存完整权重串，其余存自己那个目标的值）---"
grep -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS)=' /etc/realm/rules/rule-9101.conf /etc/realm/rules/rule-9103.conf

echo "--- 恢复 9443 的监听，并把主（8443）弄坏：主坏、备好 ---"
python3 -m http.server 9443 --bind 127.0.0.1 >/tmp/acc-y-9443.log 2>&1 & echo $! >/tmp/acc-y-9443.pid
sleep 8
kill "$(cat /tmp/acc-y-8443.pid)"; rm -f /tmp/acc-y-8443.pid
sleep 20

echo "--- 关键：主（127.0.0.1:8443）应 failed、备（127.0.0.1:9443）应 healthy ---"
grep -v '^#' /etc/realm/health/health_status.conf | awk -F'|' '{print $1, $2, $3, $4}'

echo "--- 权重：主坏了应切到备（0,1）---"
jq -r '.endpoints[].balance' /etc/realm/config.json

echo "--- 日志：只应有 8443 的 FAILURE，不能有 9443 的 FAILURE ---"
journalctl -u realm-health-check.service -n 40 --no-pager | grep -E 'FAILURE|CONFIG|RECOVERY'
```

**期望结果（可判定）**

1. 形态 ①：状态文件里**两行**，`TARGET` 分别是 `127.0.0.1:8443` 与 `127.0.0.1:9443`（**都含端口**），`RULE_ID` 分别是 9101 / 9102。
2. 形态 ①：杀掉 9443 的监听后，**`127.0.0.1:8443` 那行必须仍是 `healthy`**；只有 `127.0.0.1:9443` 那行变成 `failed` 且 `FAIL_COUNT≥2`。**这是本项的核心断言。**
3. 形态 ②：两条规则**同一个 `LISTEN_PORT=18443`**；`apply_port_group_weight_config` 之后 `rule-9101` 存完整权重串、`rule-9103` 存自己那个目标的值，`BALANCE_MODE="active-standby"`、`FAILOVER_ENABLED="true"`。
4. 形态 ②：**主（`127.0.0.1:8443`）那行是 `failed`，备（`127.0.0.1:9443`）那行必须是 `healthy`** —— 备**不能**因为主坏了而跟着坏。
5. 形态 ②：**绝不能出现两个目标都 `failed`**；一旦出现，说明又走了「全部目标都挂了」的兜底 → 权重**不会**翻、流量压在已故障的主机上（该切不切的静默失效）。日志里应**只有** `[FAILURE] 目标 127.0.0.1:8443 …`，**没有**针对 `127.0.0.1:9443` 的 FAILURE。
6. 形态 ②：权重应翻成 **`0,1`**（切到备）。比较时按逗号切分取数字序列、忽略空格（realm 不认识 `active-standby`，底层输出的是 `roundrobin`）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 一个坏了，另一个也跟着 `failed` | 读侧仍按 host 建索引 → 查消费端 `lib/realm.sh` 的 `generate_endpoints_from_rules` 是否按 `host:port` 建**精确键**；查写端 `lib/health.sh` 的 `health_check_script_body` 的 `target_key` 是否含端口（`target_endpoint="${target}:${REMOTE_PORT}"`） |
| 两个目标都 failed、然后「全挂兜底」 | 宽键污染 → 查消费端有没有**再存一份裸 host 宽键**（`a7e23fc` 那一版有，`bfc99d3` 起去掉） |
| 状态文件里没有 9443 那行 | 规则**没被健康检查覆盖** → 查 `RULE_ROLE=1` / `ENABLED=true` / `FAILOVER_ENABLED=true` 三个开关（探测端只处理故障转移中转规则） |
| 状态文件里 TARGET 还是裸 host | 装的是 `a7e23fc` 之前的旧产物 → 见 A-4 的 TARGET 三档判据 |
| 权重没落到主备形态 / `rule-9103` 的权重不对 | 落盘约定：组内**第一条**规则存完整权重串、其余规则存**自己那个目标**的值（不含逗号）；查 `lib/rules.sh` 的 `apply_port_group_weight_config` 的返回值与 `validate_weight_input` |
| 权重没翻（主坏了也不切） | ① 状态没进 failed → 看 `FAILURE_THRESHOLD` / `CONNECTION_TIMEOUT`；② 状态进了 failed 但 config 没重生成 → 看 `journalctl` 有没有 `[CONFIG]`，没有就是 `pf --restart-service` 没被调用 |
| 探测端把两个端口都判 failed | 探测本身失败（`nc` 缺失、`/dev/tcp` 回退失效）→ **先过 A-7** |

**危险动作**：本项会**写规则文件**并可能**重启 realm**（`apply_port_group_weight_config` 末尾调 `service_restart` → 转发短暂中断）。**验收前先备份** `/etc/realm/rules/` 与 `/etc/realm/config.json`；**验收后** `rm` 掉 `rule-9101.conf` / `rule-9102.conf` / `rule-9103.conf` 再 `pf --restart-service` 恢复。**只允许在 `127.0.0.0/8` 上做**；**严禁动 22 端口**。

---

## A-5　主节点断连 → 权重翻 `0,1`

**验收目标**：主目标不可达后，经过 `FAILURE_THRESHOLD` 轮，realm 实际配置的权重翻转为 `0,1`（备接管）。

**前置**：A-3 完成；两个监听已起（见下）。

> **★ 本节同时承载「负载均衡路径真机结论」（2026-10-24 21:20 迁入）**
>
> 用户裁定保留的三条路径是：**单端口中转**、**同端口多目标负载均衡（权重 5,5）**、**权重 10,0 主备**。
> 「权重 10,0 主备」走的是 **realm 规则 `TARGET_STATES`**，由 `realm-health-check.timer` 驱动 —— **与被删除的进程级主备池是两套不同机制**。
>
> **五步状态迁移链（真机实测结果，证据目录 `/root/xwpf-evidence-20261024-190720-lb/`）**：
>
> | 步 | 动作 | **观察结果** | 机制落点 |
> |---|---|---|---|
> | ① | 权重设成 **5,5** | **生效模式 = `roundrobin`，权重 `5,5`** | 权重序列无 0 ⇒ 保持负载均衡模式，不进主备 |
> | ② | 权重设成 **10,0** | **生效模式 = `active-standby`，且 `FAILOVER_ENABLED=true`（自动进主备）** | `lib/rules.sh` 的 `auto_enable_active_standby`：权重序列出现 0 ⇒ 规则 `BALANCE_MODE` 改写为 `active-standby` 并打开 `FAILOVER_ENABLED`（锚点 PR #4 = `a9102c1`） |
> | ③ | **杀主**（主目标监听进程） | **权重翻 `0,1`**，**角色变 `DBACKUP`** | 健康检查连续 `FAILURE_THRESHOLD`（默认 2）次失败 ⇒ 判 `failed` ⇒ 写回权重 `0,1`（备接管） |
> | ④ | **恢复主** | **权重翻 `1,0`**，**角色变 `DPRIMARY`** | 连续 `SUCCESS_THRESHOLD`（默认 2）次成功 **且** 已过 `RECOVERY_COOLDOWN`（默认 120）⇒ 严格主备切回 |
> | ⑤ | 权重改回 **5,5** | **回到 `roundrobin`** | 权重序列无 0 ⇒ 退出主备形态，回到负载均衡 |
>
> **⚠️ 证据完整性声明（必须先看）**：第 ③④ 步的**观察结果**来自 **Chief 的实机复核**（2026-10-24）；**审稿本轮无 VPS 凭据**（凭据环境变量在会话压缩后丢失、无 SSH 私钥与 agent、免密登录被拒）⇒ **未进入该证据目录逐文件取证**，**具体证据文件名待补**。
> ⇒ **拿不到来源的实测数字一律不写** —— 下面两条时间特性的**实测区间**同样标「待补」，取证命令见 **A-6.2**（在 VPS 上跑一条即可补齐）。
> ⇒ `DBACKUP` / `DPRIMARY` 这两个角色标识在**仓库里 0 处命中**（全仓检索无）⇒ 它们是**真机上的运行时观察词**，不是本仓库常量，引用时必须带真机证据。

**命令**

```bash
# 造两个目标（不同 IP，同一端口）
python3 -m http.server 8443 --bind 127.0.0.1 >/tmp/acc-a.log 2>&1 & echo $! >/tmp/acc-a.pid
python3 -m http.server 8443 --bind 127.0.0.2 >/tmp/acc-b.log 2>&1 & echo $! >/tmp/acc-b.pid
sleep 1

echo "--- 初始权重（应为 1,0）---"
jq -r '.endpoints[].balance' /etc/realm/config.json

echo "--- 模拟主节点断网：杀掉 127.0.0.1 的监听 ---"
kill "$(cat /tmp/acc-a.pid)"; rm -f /tmp/acc-a.pid

echo "--- 等待 FAILURE_THRESHOLD(2) x interval(4s) + 余量 ---"
sleep 20

echo "--- 状态文件 ---"
grep -v '^#' /etc/realm/health/health_status.conf

echo "--- 翻转后的权重（应为 0,1）---"
jq -r '.endpoints[].balance' /etc/realm/config.json

echo "--- 日志 ---"
journalctl -u realm-health-check.service -n 30 --no-pager | grep -E 'FAILURE|CONFIG|RECOVERY'
```

**期望结果（可判定）**

1. 初始 `balance` 的权重序列 = `1,0`。
2. 杀掉主监听后 **≥ 20 秒**内，`health_status.conf` 里 `127.0.0.1` 那行的 `STATUS=failed`、`FAIL_COUNT≥2`；`127.0.0.2` 那行 `STATUS=healthy`。
3. `config.json` 的权重序列变为 **`0,1`**（顺序对应端点顺序，不是「主机名顺序」）。
4. `journalctl` 里出现 `[FAILURE] 目标 127.0.0.1:8443 检测失败…` 与 `[CONFIG] 检测到节点状态变化…`。
5. **关键**：`127.0.0.2` 的那行**不能**也是 failed。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 两个目标都 failed | 全局探测失败（两个目标其实都不可达）；或健康检查根本没在跑。（「两条规则的 host 被判成同一个 key」是 N1 修复**之前**的旧成因，`TARGET` 口径改成 `host:port` 后不再成立，见 A-4） |
| 权重没翻 | ① 状态没进 failed → 看 `FAILURE_THRESHOLD` / `CONNECTION_TIMEOUT`；② 状态进了 failed 但 config 没重生成 → 看 `journalctl` 有没有 `[CONFIG]`，没有就是 `pf --restart-service` 没被调用（`lib/health.sh` 里调的是 `pf --restart-service`） |
| `[CONFIG]` 有但 config.json 没变 | `pf --restart-service` 失败 → 手工执行 `pf --restart-service` 看报错；realm 起来后权重仍不变 → 生成端 `lib/realm.sh` 的 `generate_endpoints_from_rules` 的健康映射 key 不匹配 |
| 翻转了但方向反了 | 权重索引与目标顺序错位 → 回看第 1 轮报告 S1（权重落盘用 rule_index 与目标索引可能错位） |

**危险动作**：`kill` 监听进程是低危。**如果改用 iptables 模拟断网**：只允许 `127.0.0.0/8`，**严禁动 22 端口**；拦完用 `iptables -L -n` 留证，验收后删除规则。

---

## A-6　主节点恢复 → 权重翻回 `1,0`

**验收目标**：主目标恢复后，经过 `SUCCESS_THRESHOLD` + **`RECOVERY_COOLDOWN`（默认 120 秒）**，权重翻回 `1,0`（严格主备切回）。

**前置**：A-5 已完成（当前处于 `0,1` 状态）。

**命令**

```bash
# 恢复主节点
python3 -m http.server 8443 --bind 127.0.0.1 >/tmp/acc-a.log 2>&1 & echo $! >/tmp/acc-a.pid
sleep 1

echo "--- 恢复后立刻（应当仍是 0,1，冷却期未到）---"
jq -r '.endpoints[].balance' /etc/realm/config.json

echo "--- 等待 SUCCESS_THRESHOLD(2) + RECOVERY_COOLDOWN(120s) + 余量 ---"
sleep 140

echo "--- 翻回了吗（应为 1,0）---"
jq -r '.endpoints[].balance' /etc/realm/config.json
grep -v '^#' /etc/realm/health/health_status.conf
journalctl -u realm-health-check.service -n 40 --no-pager | grep -E 'RECOVERY|CONFIG'
```

**期望结果（可判定）**

1. 恢复后**立刻**读取，**权重仍在备上**（承载主的那位 = 0、承载备的那位 = 1）——**冷却期没到就不许翻**（这是严格主备的关键行为）。
   > ⚠️ **不钉字面量**：不写死 `"0,1"` 这个串（策略名与权重取值会随形态变）⇒ 判据是**「主位为 0、备位为 1」这个关系**。
2. **≥ 140 秒**后，权重变为 **`1,0`**。
3. `health_status.conf` 中 `127.0.0.1` 行 `STATUS=healthy`。
4. `journalctl` 出现 `[RECOVERY] 目标 127.0.0.1:8443 已恢复健康`。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 冷却期没到就翻回 | 冷却期判定失效 → 查 `RECOVERY_COOLDOWN`（默认 120，`_ensure_rule_field_default` 写入）是否真的落到规则文件里 |
| 140 秒后仍未翻回 | ① 看 `SUCCESS_THRESHOLD`（默认 2）② 看 `failure_start_time` 是否被正确重置 ③ 看 `[RECOVERY]` 日志有没有 |
| 翻回成 `1,1` | 兜底逻辑或多主语义有问题（第 1 轮报告缺口 D） |

**危险动作**：无（低危）。**注意**：本项天然耗时 > 2.5 分钟，验收窗口要留够。

---

### A-6.1　两条时间特性（机理与口径）

> **本节迁入时间**：2026-10-24 21:20（从已废弃的 `reports/round3-failover-restart-storm-status.md` 迁出）。
> **纪律**：**拿不到来源的数字不写**。下面凡标「**待补**」的，是审稿**确实没取到**（无 VPS 凭据），**不是**「忘了写」。
> **代码口径锚点**：`7c95dca`（`lib/health.sh` 的健康检查体、`lib/failover.sh` 的默认值）；被测产物一律取自 `git show 7c95dca:<path>`。

#### ① 硬故障检测耗时（负载均衡路径）

**★ 实测结论（2026-10-24 真机 103，Chief 实测；审稿未独立复现）**

| 项 | 实测值 |
|---|---|
| **故障检测耗时** | **30 秒**（精确值：kill 主后端 epoch `1792850569` → 出现 `[FAILURE]` epoch `1792850599`） |
| 探测实际间隔 | **不固定**：实测日志间隔 **4 / 6 / 9 / 10 / 11 / 12 / 18 / 30 秒**（**标称是 4 秒**） |
| 对照（**已删除的旧路径**） | 被删的守护进程那套是 **8–10 秒切走** |
| 实测环境 | 真机 `103.42.31.186`；形态 = 两条规则同端口 `19443` + 权重 `10,0`；自己起的临时后端 `127.0.0.3` / `127.0.0.4` 端口 `19081`（**未碰用户的 `dprimary` / `dbackup`**） |

⇒ **⚠️ 迁到权重路径后，故障检测会明显变慢：8–10 秒 → 约 30 秒（≈ 慢 3–4 倍）。**
⇒ **这是产品事实，不是回归。** 被删的守护进程是**自己持 socket 探测**，探测间隔稳定；权重路径是 **systemd timer 拉起一次性脚本**，间隔受 timer 调度与脚本执行时间影响 ⇒ 实测间隔在 4~30 秒之间浮动。
⇒ **两条原因叠加**（都不是 bug，但都要写进验收预期）：
   1. **探测间隔不固定**（实测 4~30 秒）⇒ 判定要等「下一次探测恰好落在故障之后」；
   2. **探测超时预算从 3 秒抬到 10 秒**（`CONNECTION_TIMEOUT`）⇒ **失败判定会更慢** —— 要等预算耗尽才判失败。**这个代价必须让用户知道。**

> **⚠️⚠️ 前提绑定（这条最重要 —— 30 秒这个数已经过期了）**
> 上面这个 **30 秒**是在**探测超时预算仍为 3 秒**的口径下测出来的。
> ⚠️ **产品已把预算统一抬到 10 秒**（`05b5ebb`：规则模板 + 探测调用 + OCR 脚本三个落点全改，`lib/health.sh` 侧本来就是 10 ⇒ **全仓已无 3 秒落点**）—— **超时预算从 3 秒抬到 10 秒 ⇒ 失败判定必然更慢**（要等预算耗尽）⇒ **30 秒在新代码下不再成立**。
> ⇒ **★ 结论：30 秒是「旧预算口径下的过期实测值」** —— **真机必须重测**，重测后**把新的实测值连同当时的 `CONNECTION_TIMEOUT` 一起记**（现在应当恒为 10）。
> ⇒ **验收不得拿 30 秒当判据**（判据仍是「> 60 秒才排查」）；**回切 119 秒同理**（它也是那一次的实测值，不是常数）。

> **⚠️ 给用户的提醒（验收时必须口头确认）**：**主备切换不是瞬时的。** 客户端必须能容忍**几十秒**的不可用窗口。若业务要求秒级切换，**权重路径满足不了** —— 这是被删的守护进程路径与保留路径的**能力差**，不是配置问题。

**代码口径（理论下限，与实测的差距见上）**

由 **realm 侧健康检查**决定，三个参数相乘：

| 参数 | 默认值 | 出处 |
|---|---|---|
| 健康检查周期 `HEALTH_CHECK_INTERVAL` | **4 秒** | `lib/health.sh` 的 `get_port_failover_params`（`${HEALTH_CHECK_INTERVAL:-4}`） |
| 连续失败阈值 `FAILURE_THRESHOLD` | **2** | 同上（`${FAILURE_THRESHOLD:-2}`） |
| 单次探测超时 `CONNECTION_TIMEOUT` | **3** → 已改 **10** | 同上（`${CONNECTION_TIMEOUT:-10}`） |

⇒ **理论下限 ≈ 2 个周期 = 8 秒**（再加一次探测本身的耗时）。
⇒ **实测 30 秒 ≫ 理论 8 秒** ⇒ 差距来自「间隔不固定（4~30 秒）」+「超时预算」两项，**不是参数配错**。
⇒ **验收时不要拿 8 秒当判据** —— 8 秒是理论下限，真机实测是 **30 秒**；若实测 **> 60 秒**，才需要排查（探测卡死 / timer 没被调度 / 产物是旧的）。⚠️ 且 **30 秒是「超时预算 = 3 秒」口径下的实测值**，预算抬到 10 秒后**必然更慢**（见本节开头的「前提绑定」框）。

> **⚠️ 口径警告（重要，且已随旧功能删除而简化）**：本条**只指负载均衡路径**（`realm-health-check.timer` 驱动的权重翻转）。
> 历史上的「**直连池 8–10 秒切走**」是**另一个守护、另一套参数**（`cmd/xwpf-failover.py` 的 `interval_sec` / `fail_threshold` / `cooldown_sec`，作用对象是池内主备转发，不是规则权重）。
> ⇒ **该直连池功能已随「主备池整块删除」作废** ⇒ 现版本**只剩负载均衡路径一条口径**。
> ⇒ **但迁移决策时必须记住这个差值**：8–10 秒（已删）→ 30 秒（保留）。

#### ② 回切间隔（受冷却期约束）

回切条件在 `lib/health.sh` 的健康检查体里，**三个条件同时成立**才翻回：

```
① status == failed                        （之前确实判过故障）
② success_count >= SUCCESS_THRESHOLD(2)  （连续 2 次探测成功）
③ current_time - failure_start_time >= RECOVERY_COOLDOWN(120)
```

**⇒ 关键机理：③ 的基准是 `failure_start_time`（故障**起始**时刻），不是「恢复时刻」。**

由此推出的三条性质：

1. **回切受冷却期约束，不是「一恢复就立刻切回」** —— 刚判故障就恢复，必须等满 120 秒。
2. **故障持续得越久，恢复后到回切的等待越短** —— 若故障已持续超过 120 秒，恢复后 2 个周期（≈ 8 秒）即回切。
3. ⇒ **「故障发生 → 权重翻回」的总时长 ≈ `RECOVERY_COOLDOWN` + 2 个周期**；而**「主恢复 → 权重翻回」的等待 = 120 − 已流逝的故障时长**（下界为 2 个周期）。

**实测值：119 秒** —— 来源：**Chief 真机实测（2026-10-24 真机 103）**，精确值：主后端恢复可用 epoch `1792850599` → 出现 `[RECOVERY]` epoch `1792850718`；**审稿未独立复现**。
（口径：**从「主后端恢复可用」到「探测端打出 `[RECOVERY]` 判定 + 配置权重翻回主」**。）
⇒ **与机理一致**：③ 的基准是 `failure_start_time`，而本次故障持续时间（检测耗时 30 秒）**远小于 120 秒冷却** ⇒ 冷却期是**主导项** ⇒ 恢复后仍要等满 120 秒（再 + 2 次成功探测）⇒ 实测 119 秒。
⇒ **回切后的实测验证（Chief 同一轮）**：`balance` = `"roundrobin: 1, 0"`，**实连 3 次全部落到主** `127.0.0.3:19081` ⇒ 回切不只改了配置，**流量真的回来了**。
⚠️ **注意这个 119 秒不是常数**：故障若持续**超过** 120 秒才恢复，恢复后的等待会**显著变短**（下界 = 2 个探测周期）⇒ 验收**不要**把「必须是 119 秒」当判据。
⇒ 验收仍按下面这两条判（与探测间隔无关，是硬判据）：
   - **「回切发生在故障起始 + 120 秒之后」**；
   - **「恢复后立刻读，权重仍在备上（主位 = 0、备位 = 1）」**（A-6 第 1 条期望）。

> **⚠️ 回切间隔的预期值会受「检测耗时变慢」影响** —— 但**不是**简单的相加：
> 回切的三个条件里，③ 的基准是**故障起始时刻**（不是恢复时刻）⇒ 冷却期 120 秒是从**故障发生**那刻起算的。
> ⇒ **「故障持续得越久，恢复后到回切的等待越短」**这条性质**不变**。
> ⇒ 但由于**探测间隔不固定（4~30 秒）**，实测回切间隔会有**几十秒量级的浮动** ⇒ 验收时**不要**把「必须是 120 秒」当判据，而应判「**回切发生在故障起始 + 120 秒之后**，且**恢复后不是立刻切回**」。
> ⇒ **真正要卡的判据是「恢复后立刻读，权重仍在备上（主位 = 0、备位 = 1）」**（A-6 第 1 条期望）—— 这条与探测间隔无关，是硬判据。

> **验收等待值 ≠ 实测值**：`A-6` 里的 `sleep 140`（= 120 冷却 + 2 周期 + 余量）是**验收用的等待时长**，**不能**当作实测回切间隔写进任何结论。

---

### A-6.2　补齐两个实测数字的取证命令（在 VPS 上跑一条即可）

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
- **检测耗时** = `[FAILURE] 目标 … 检测失败` 的时间戳 → 权重变成 `0,1` 的那轮 `[CONFIG]` 时间戳的差。
- **回切间隔** = `[FAILURE]`（故障起始）→ `[RECOVERY] 目标 … 已恢复健康` 的差；**应当与 `RECOVERY_COOLDOWN=120` 吻合**（误差来自 2 个探测周期与探测耗时）。
- **拿不到 `timeline.log` 的时间戳就写「待补」** —— **不要用 `sleep 140` 这种验收等待值冒充实测值**。

---

## A-7　不装 netcat 时靠 `/dev/tcp` 仍能切换

**验收目标**：系统没有 `nc`（或 `nc` 不支持 `-z`）时，探测回退到 `bash /dev/tcp`，健康检查**继续正常工作**，不把全部目标误判为故障。

**前置**：A-3 完成（主备已在跑）；本机 `command -v nc` 有输出（否则本项直接 PASS 跳过）。

**命令**

```bash
# 0) 先证明 /dev/tcp 本身可用（前提）
bash -c 'exec 3<>/dev/tcp/127.0.0.2/8443' && echo "DEVTCP_OK" || echo "DEVTCP_FAIL"

# 1) 临时屏蔽 nc（必须同一命令块内改回）
sudo bash <<'EOF'
set -e
NC=$(command -v nc || true)
if [ -z "$NC" ]; then echo "NO_NC_INSTALLED"; exit 0; fi
mv "$NC" "${NC}.accbak"
restore() { mv "${NC}.accbak" "$NC" 2>/dev/null || true; }
trap restore EXIT

echo "--- 屏蔽 nc 后手工跑一轮健康检查 ---"
bash /etc/realm/health/health_check.sh; echo "HEALTH_EXIT=$?"

echo "--- 状态文件是否仍在更新 ---"
stat -c '%y %n' /etc/realm/health/health_status.conf
sleep 6
stat -c '%y %n' /etc/realm/health/health_status.conf
EOF

# 2) 确认 nc 已恢复
command -v nc && nc -h 2>&1 | head -2
```

**期望结果（可判定）**

1. `DEVTCP_OK`（前提成立）。
2. 屏蔽 nc 后 `bash /etc/realm/health/health_check.sh` **退出码 0**，无 `command not found` 类报错。
3. 两次 `stat` 的 mtime **不同** → 状态文件仍在被更新（探测仍在跑）。
4. `127.0.0.2` 那行 **仍是 `healthy`**（没有被误判 failed）。
5. 脚本结束后 `command -v nc` **恢复有输出**，且 `nc` 文件已回到原位。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 全部目标变 failed | 回退分支没生效 → 查 `lib/health.sh` 的 `check_connectivity`（nc 能力探测 → `/dev/tcp` 回退）。**能力探测靠 `nc -h \| grep -z` 匹配帮助文本**，各家 nc 的 usage 排版不同，可能整条 nc 分支被跳过 |
| `HEALTH_EXIT` 非 0 且报 `timeout: command not found` | `timeout` 缺失（coreutils）→ 极简镜像场景；此时**必然全判故障** |
| mtime 不变 | 健康检查没在跑 → 先看 timer 是否 active |
| nc 没恢复 | `trap restore EXIT` 生效即可；若中途 `kill -9` 导致 trap 不执行 → 手工 `mv ${NC}.accbak $NC` |

**危险动作**：**改 `/usr/bin/nc` 文件名属于系统级改动** —— 必须用 `trap` 保证改回；**不要在有并发任务/其它人用机的机器上做**；不要用 `apt-get remove netcat-openbsd`（会留下 dpkg 状态不一致）。备选方案：`unshare`/容器隔离（但本机无 Docker，只能在 VPS 上装）。

---

## A-8　journalctl 输出与 vacuum

**验收目标**：健康检查的日志格式可读、可检索；journal 按 7 天保留策略被清理。

**前置**：A-5/A-6 已跑过（有故障与恢复记录）。

**命令**

```bash
echo "--- 近期日志 ---"
journalctl -u realm-health-check.service -n 50 --no-pager

echo "--- 关键事件计数 ---"
journalctl -u realm-health-check.service --since "-30 min" --no-pager \
  | grep -cE '\[FAILURE\]|\[RECOVERY\]|\[CONFIG\]|\[INFO\] 健康检查完成'

echo "--- 日志量 ---"
journalctl -u realm-health-check.service --since "-1 day" --no-pager | wc -l

echo "--- vacuum 干跑（不改任何东西）---"
journalctl --vacuum-time=7d --dry-run | tail -5

echo "--- 当前保留策略 ---"
grep -E 'MaxRetentionSec|SystemMaxUse' /etc/systemd/journald.conf 2>/dev/null || echo "(journald.conf 未显式设置，走默认)"

echo "--- unit 的 journal 归属 ---"
systemctl show realm-health-check.service -p SyslogIdentifier -p StandardOutput -p StandardError
```

**期望结果（可判定）**

1. 日志里能看到 `[INFO] 健康检查完成`、`[FAILURE] …`、`[RECOVERY] …`、`[CONFIG] …` 四类标记。
2. `grep -c` 结果 **≥ 4**（说明四类都出现过）。
3. `journalctl --vacuum-time=7d --dry-run` 输出的条目数与实际保留策略一致（**dry-run 不删任何东西**）。
4. `SyslogIdentifier=realm-health`，`StandardOutput=journal`。
5. 1 天内的日志行数**不是持续暴涨**（健康检查默认 4 秒一轮，一天 ≈ 2 万行量级属正常；**远超这个量级说明有重复刷屏**）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| journal 完全没记录 | unit 没跑，或 `StandardOutput` 不是 journal |
| 一天行数远超 2 万 | 每轮打了过多日志，或 timer 间隔被设成了秒级 |
| `vacuum` 报 `Unknown option` | systemd 版本过旧（`--dry-run` 需 systemd ≥ 230）→ 见兼容性矩阵 |
| 一直不执行 vacuum | vacuum 只在**整点**（`current_minute == 00`）触发；非整点看到没清理是正常的 |

**危险动作**：`journalctl --vacuum-time=7d`（**不带 `--dry-run`**）会**真删日志**，不可恢复 → 验收期间一律加 `--dry-run`；确需清理时先 `journalctl --backup` 或先导出。

---

## A-9　停服务 + 卸载后的残留清理

**验收目标**：卸载后不留 systemd unit、不留常驻进程、不留 `/etc/realm` 残留配置（除用户明确保留的数据）。

**前置**：**必须是测试机**（本项会删配置）；已 `cp -a /etc/realm /etc/realm.bak.$(date +%s)`。

**命令**

```bash
# 0) 备份（不可跳过）
sudo cp -a /etc/realm /etc/realm.bak.$(date +%s)
sudo cp -a /etc/xwpf /etc/xwpf.bak.$(date +%s) 2>/dev/null || true

# 1) 卸载前快照（用于比对残留）
sudo ls -la /etc/systemd/system/ | grep -E 'realm|xwpf' | tee ~/realm-acceptance/A9-before-units.txt
sudo ls -la /etc/realm/ | tee ~/realm-acceptance/A9-before-realm.txt

# 2) 走官方卸载入口（pf 主菜单 → 8. 卸载服务；两阶段：Realm 服务与配置 / 脚本文件）
sudo pf
# 菜单里选「8. 卸载服务」，按提示走完两阶段

# 3) 残留检查
echo "--- systemd unit ---"
ls /etc/systemd/system/ | grep -E 'realm|xwpf' || echo "NO-UNIT-LEFT"
echo "--- 常驻进程 ---"
pgrep -af 'realm|xwpf-failover|health_check' || echo "NO-PROCESS-LEFT"
echo "--- /etc/realm ---"
ls -la /etc/realm 2>/dev/null || echo "NO-/etc/realm"
echo "--- /etc/xwpf ---"
ls -la /etc/xwpf 2>/dev/null || echo "NO-/etc/xwpf"
echo "--- 安装目录 ---"
ls -la /usr/local/bin/lib /usr/local/bin/cmd /usr/local/bin/pf /usr/local/bin/xwPF.sh 2>/dev/null || echo "NO-INSTALL-FILES"
echo "--- systemd 状态 ---"
systemctl list-unit-files | grep -E 'realm|xwpf' || echo "NO-UNIT-FILE-REGISTERED"
```

**期望结果（可判定）**

1. `ls /etc/systemd/system/ | grep -E 'realm|xwpf'` → **无输出**（打印 `NO-UNIT-LEFT`）。
2. `pgrep -af 'realm|xwpf-failover|health_check'` → **无输出**。
3. `/etc/realm`、`/etc/xwpf` → 不存在，或只剩**明确声明保留**的目录（用户备份、证书）。
4. `/usr/local/bin/{pf,xwPF.sh,lib/,cmd/}` → 脚本文件被清掉（`uninstall_script_files` 的职责）。
5. `systemctl list-unit-files | grep -E 'realm|xwpf'` → 无输出。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| unit 残留但 `systemctl list-unit-files` 没有 | 只是 `/etc/systemd/system/` 里的孤儿文件 → 卸载流程漏了 `rm -f` |
| 进程还在 | 只 `stop` 了 timer 没停 service，或守护进程没被 `disable` |
| `/etc/realm` 还在 | 两阶段卸载只做了阶段一（`uninstall_realm_stage_one`），阶段二（`uninstall_script_files`）没跑 |
| 卸载后 `pf` 还在 | 快捷命令软链没删 |

**危险动作**：**本项会删除全部转发配置与规则**。只在测试机做；执行前必须完成第 0 步备份；执行后**不要**立刻删备份，先确认业务无影响再清理。

---

## A-10　~~`xwpf-failover` 的 active/passive 热切换（进程级）~~　**⛔ 已废弃，不再验**

> **⛔ 本项已删除（2026-10-24 21:20）**：用户裁定「**主备池模式的都抛弃**」⇒ 进程级主备池（独立守护进程 `cmd/xwpf-failover.py`、公开监听口 + 主/备后端、`failover.json` 池机制）**整块功能废弃删除**。
> ⇒ 本项连同它守的「守护进程热切换 / 守护日志 / 守护退出码语义 / 崩溃循环限流 / drop-in / ETXTBSY（写正在执行的守护二进制）」**全部不再验收** —— 被守护的进程没了，守它的断言也没了意义。
> ⇒ **历史留档**：`reports/round3-crashloop-review.md`（根因链）与 `reports/round3-failover-restart-storm-status.md`（处置状态）—— 两份文首均已加状态声明。
> ⇒ ⚠️ **不要**把「进程级主备」与「权重主备」混为一谈：**权重 10,0 主备保留**（走 realm 规则 `TARGET_STATES`，由 `realm-health-check.timer` 驱动），它的验收项是 **A-3 / A-5 / A-6**。

---

## A-11　保留路径一：普通单端口中转

**验收目标**：一个监听口后挂**一个**目标，流量按该目标转发，**不进入**任何主备/负载均衡逻辑。

**前置**：干净的 VPS，已 `pf install` 完成 A-1。

**命令**

```bash
# 造一个后端
python3 -m http.server 8443 --bind 127.0.0.1 >/tmp/acc-single.log 2>&1 & echo $! >/tmp/acc-single.pid
sleep 1

echo "--- 规则（应只有一条，且无 WEIGHTS 键）---"
grep -H -E '^(LISTEN_PORT|REMOTE_HOST|REMOTE_PORT|BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS)=' /etc/realm/rules/rule-*.conf

echo "--- realm 实际生效的端点 ---"
jq -r '.endpoints[] | "\(.listen) -> \(.remote) balance=\(.balance)"' /etc/realm/config.json

echo "--- 健康探测不应被拉起（单端口不构成故障转移场景）---"
systemctl is-enabled realm-health-check.timer 2>&1
systemctl is-active  realm-health-check.timer 2>&1
```

**期望结果（可判定）**

1. 规则里**没有** `WEIGHTS` 行；`BALANCE_MODE` 不是 `active-standby`。
2. `config.json` 里该端点的 `balance` 是**单个**权重（不是逗号分隔的多目标串）。
3. `realm-health-check.timer` 为 `disabled` / `inactive`（**不适用**则写「N/A，不阻塞」—— 单端口不触发探测是正确行为；**关键是它不得因为单端口就误判 failed**）。
4. 转发可用：`curl -sS -o /dev/null -w '%{http_code}\n' --resolve "<监听域名>:<端口>" "http://<监听域名>:<端口>/"` 返回非 000（TLS 站点按实际协议验）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 单端口也被写进 `WEIGHTS` | 权重写入入口没区分「单目标」与「多目标」；查 `lib/rules.sh` 的权重配置入口对单目标的处理 |
| 单端口把后端判 `failed` | 探测端把不适用场景也纳入了；查 `lib/health.sh` 的健康检查体对「规则不是故障转移中转规则」的过滤（`RULE_ROLE=1` / `ENABLED=true` / `FAILOVER_ENABLED=true` 三个开关） |
| `config.json` 的 `balance` 是 `1,0` 之类多值 | 端点生成端把权重串当成了多目标；查 `lib/realm.sh` 的 `generate_endpoints_from_rules` |

**危险动作**：写规则文件会触发 realm 重启 → 转发短暂中断。**验收前先备份** `/etc/realm/rules/` 与 `/etc/realm/config.json`；**验收后**删掉测试规则再 `pf --restart-service` 恢复。

---

## A-12　保留路径二：同端口多目标负载均衡（权重 5,5）

**验收目标**：一个监听口后挂**多个**目标、权重**相等**（`5,5`）⇒ 走**负载均衡**（不是主备），流量在多个目标间分摊。

**前置**：两个后端监听已起（`127.0.0.1:8443` 与 `127.0.0.2:8443`）。

**命令**

```bash
python3 -m http.server 8443 --bind 127.0.0.1 >/tmp/acc-lb-a.log 2>&1 & echo $! >/tmp/acc-lb-a.pid
python3 -m http.server 8443 --bind 127.0.0.2 >/tmp/acc-lb-b.log 2>&1 & echo $! >/tmp/acc-lb-b.pid
sleep 1

echo "--- 下发权重 5,5（同端口多目标）---"
# 第三个参数 1 = 跳过交互确认（无头环境必须传）
source /usr/local/bin/lib/rules.sh
apply_port_group_weight_config 18443 "5,5" 1

echo "--- 规则 ---"
grep -H -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS)=' /etc/realm/rules/rule-*.conf

echo "--- 生效权重序列（应为 5,5）---"
jq -r '.endpoints[].balance' /etc/realm/config.json

echo "--- 探测端状态（两个目标都应 healthy）---"
grep -v '^#' /etc/realm/health/health_status.conf
```

**期望结果（可判定）**

1. `BALANCE_MODE` = **负载均衡模式**（realm 侧通常呈现为 `roundrobin`；规则文件里**不应**是 `active-standby`）。
2. `FAILOVER_ENABLED` 的取值符合该模式的产品口径（等权负载均衡不触发主备切换）。
3. 权重序列 = **`5,5`**。
4. 状态文件里**两个目标都是 `healthy`**。
5. **多次请求能落到不同后端**（真正的分摊，而不是全打一个）：连发 ≥ 10 次请求，两个后端的访问日志**都**有命中计数。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 权重写成了 `10,0` 之类 | 下发时传错；重跑 `apply_port_group_weight_config 18443 "5,5" 1` |
| 模式变成 `active-standby` | `auto_enable_active_standby` 的触发条件错了（**只有权重含 0 才该进主备**）→ 查 `lib/rules.sh` 的 `auto_enable_active_standby` |
| 两个后端只有一个收到请求 | realm 的分摊没生效（配置没重新生成，或 realm 未重启）→ 看 `journalctl` 有没有 `[CONFIG]`；没有就 `pf --restart-service` |
| 权重序列不是 `5,5` | 落盘约定：组内**第一条**规则存完整权重串、其余规则存自己那个目标的值 → 查 `lib/rules.sh` 的 `apply_port_group_weight_config` 与 `validate_weight_input` |

**危险动作**：同 A-11（写规则 + 重启 realm）。**只允许在 `127.0.0.0/8` 上做**；**严禁动 22 端口**。

---

## A-13　保留路径三：权重 10,0 主备（主备切换可靠性 —— **本清单的重心项**）

**验收目标**：同端口多目标、权重 **`10,0`** ⇒ 自动进**主备**形态；主故障 ⇒ 翻备；主恢复 ⇒ **受 120 秒冷却约束**后翻回。

> **为什么这是重心项**：用户裁掉进程级主备池之后，**权重主备是唯一的主备机制**。它没有独立守护进程 —— 命脉全压在**健康探测端**上：探测端不工作 ⇒ 主备**永不切换**，而界面/journal 一切正常 ⇒ **静默失效**（不是失败）。
> ⇒ **本项必须与 A-14（探测端确实在探测）连着看**：A-13 判「切得对」，A-14 判「探测端真的在跑」。

**前置**：A-12 完成（已能下发多目标权重）；A-11 完成（确认单端口不进主备）。

### A-13.0　★ 硬约束：规则形态不对 ⇒ 切换**完全不工作且完全静默**

**探测准入条件**（真机生成物 `health_check.sh` ≡ 仓库 `lib/health.sh` 的健康检查体）：

```
RULE_ROLE == "1"  &&  ENABLED == "true"  &&  FAILOVER_ENABLED == "true"
```

⚠️ **三个条件缺一不可**，任何一条不满足 ⇒ **该规则根本不会被探测** ⇒ 不判失败、不切换、**日志里连一句失败都没有**。

**真机实测的坑（Chief 实测，2026-10-24）**：真机原来那两条规则是 `RULE_ROLE="2"` + `FAILOVER_ENABLED="false"` ⇒ **从来没被探过** ⇒ 真机上「主备能切」**完全靠被删的守护进程自己那套探测**（不是权重路径在工作）。⇒ 守护一删，切换立刻失效，而**没有任何报错**。

⇒ **★ 硬性判据（缺这条整个验收无效）**：**承载对外端口的必须是中转规则（`RULE_ROLE=1`）且 `FAILOVER_ENABLED=true`**。

**命令**

```bash
echo "--- 承载对外端口的规则：必须是中转规则 + 开了故障转移 ---"
for f in /etc/realm/rules/rule-*.conf; do
  role=$(grep -m1 '^RULE_ROLE=' "$f" | cut -d= -f2)
  en=$(grep -m1 '^ENABLED=' "$f" | cut -d= -f2)
  fe=$(grep -m1 '^FAILOVER_ENABLED=' "$f" | cut -d= -f2)
  port=$(grep -m1 '^LISTEN_PORT=' "$f" | cut -d= -f2)
  rm_h=$(grep -m1 '^REMOTE_HOST=' "$f" | cut -d= -f2)
  printf '%-28s port=%-6s ROLE=%-2s ENABLED=%-5s FAILOVER=%-5s remote=%s\n' \
    "$(basename "$f")" "$port" "$role" "$en" "$fe" "$rm_h"
done
```

**期望结果（可判定）**

1. 承载对外端口的那条规则：**`RULE_ROLE=1`**、**`ENABLED=true`**、**`FAILOVER_ENABLED=true`** —— **三条全对**才算通过。
2. **反例必须判 FAIL**：`RULE_ROLE=2`（服务端 / 出口规则）、或 `ENABLED=false`、或 `FAILOVER_ENABLED=false` —— 任一命中 ⇒ **该规则不参与探测**。

**★ 正确形态（Chief 真机实测过的可用形态 —— 一条规则带两个目标即可，不必两条规则）**：

```
RULE_ROLE="1"
LISTEN_PORT="19443"
LISTEN_IP="127.0.0.1"
THROUGH_IP="127.0.0.1"
REMOTE_HOST="127.0.0.3,127.0.0.4"     ← 逗号分隔多目标
REMOTE_PORT="19081"
BALANCE_MODE="active-standby"
WEIGHTS="10,0"                          ← 完整权重序列
FAILOVER_ENABLED="true"
CONNECTION_TIMEOUT="10"
HEALTH_CHECK_INTERVAL="4"  FAILURE_THRESHOLD="2"  SUCCESS_THRESHOLD="2"  RECOVERY_COOLDOWN="120"
```

**生成出来的 realm 配置形态（Chief 真机实测到的）**：

```json
{ "listen": "127.0.0.1:19443", "remote": "127.0.0.3:19081",
  "extra_remotes": ["127.0.0.4:19081"], "balance": "roundrobin: 1, 0" }
```

主故障后自动翻成 `"balance": "roundrobin: 0, 1"`。

> ⚠️ **注意 `remote` 与 `extra_remotes` 的关系**：第一个目标在 `remote`，其余在 `extra_remotes` ⇒ **验收时别只 grep `remote` 就以为只有一个目标**。
> ⚠️ **`balance` 的实际值是 `"roundrobin: 1, 0"` 这种带前缀的串**（realm 不认识 `active-standby`，底层是 `roundrobin`）⇒ 比较时**按逗号切分取数字序列**。

### A-13.1　主备切换的「成功」判据 —— **五步链，每步都要断**（不能看脚本绿灯）

> **★ 为什么这条要单独强调**：在切换**完全失效**（规则形态不对、从没被探测）的情况下，以下三样**全是绿的**：
> ❌ 「脚本跑过」　❌「退出码 0」　❌「日志有成功字样」
> ⇒ **判据必须落在产出物上。**

**★ Chief 真机跑通的完整判据链（2026-10-24 真机 103；来源：Chief 实测，审稿未独立复现）**

```
① 停主后端
   ↓
② 探测连续失败达阈值 → 状态文件里该目标变 failed
   （FAIL_COUNT 达阈值 + FAILURE_START_TIME 被记上）
   ↓
③ 探测脚本调 pf --restart-service
   ↓
④ 重新生成的 config 里**权重翻转**：承载主的那位从 1 变 0、承载备的那位从 0 变 1
   （参考形态：`"roundrobin: 1, 0"` → `"roundrobin: 0, 1"`；⚠️ **判据是「主位↔备位」这个关系，不是那个字面量**）
   ↓
⑤ realm 重启后，实连该端口 → 流量落到备后端
```

⇒ **五步每一步都要有判据；只判「配置里的权重变了」是假绿** —— **配置翻了不等于流量切了**。

**命令**

```bash
echo "--- 判据 1: 目标出现在状态文件里，且 LAST_CHECK 是本轮时间戳 ---"
date +%s                                   # 记下当前时刻
grep -v '^#' /etc/realm/health/health_status.conf
# 判据：承载的两个目标（host:port）都在文件里，且 LAST_CHECK 是刚才那一刻附近的

echo "--- 判据 2: 主故障后状态变 failed（FAIL_COUNT 达阈值 + FAILURE_START_TIME 被记上）---"
kill "$(cat /tmp/acc-a.pid)"               # 杀主后端
sleep 60                                   # ★ 必须等 ≥ 60 秒（实测检测耗时 30 秒，但超时预算抬到 10 秒后会变慢 —— 见 A-6.1 的「前提绑定」框）
grep -v '^#' /etc/realm/health/health_status.conf
# 判据：主那行 STATUS=failed 且 FAIL_COUNT>=2，且 FAILURE_START_TIME 非 0；备那行必须仍是 healthy

echo "--- 判据 3: 探测脚本确实调了 pf --restart-service（写回链路）---"
journalctl -u realm-health-check.service --no-pager -o short-iso -n 50 \
  | grep -E '\[CONFIG\]|\[FAILURE\]|\[RECOVERY\]'
# 判据：出现 [CONFIG] 检测到节点状态变化 → 紧接着 [CONFIG] 配置更新完成
# ⚠️ 这一步缺失 ⇒ 状态变了但配置没重生成 ⇒ 权重不会翻（见失败排查表）

echo "--- 判据 4: 配置里的权重发生翻转（判据钉「主位↔备位」这个关系，不钉字面量）---"
jq -r '.endpoints[].balance' /etc/realm/config.json
# 判据：承载主的那位从 1 变 0、承载备的那位从 0 变 1
# 参考形态："roundrobin: 1, 0" → "roundrobin: 0,  1"（realm 实际带空格，按逗号切分取数字序列比较）
# ★ 顺手做 A-17 的形态核查 + realm 存活检查（panic ⇒ 全站断）

echo "--- 判据 5: ★ 实际连一次，确认流量落到了备后端（不只是配置变了）---"
# ⚠️⚠️ 正确测法：后端回一行标识，客户端读那一行，用标识判断落到哪个后端
#   （详见下面的「实连测法」小节）
curl -sS --max-time 10 --resolve "test.local:19443" "http://test.local:19443/" | head -1
# 判据：返回的那一行标识 = 备后端的标识；主后端日志不应再有新增命中
tail -5 /tmp/acc-b.log
```

**★ 实连测法（必须照这个做 —— Chief 第一轮就踩了这个坑）**

⚠️ **不能用「TCP 连得上」当通过**：realm 接受连接后**可能立刻断**，分不清「转发了」和「只握手」⇒ 会把**健康的**切换判成失败（Chief 第一轮判成「两边都没流量」，**实际是测法错了，产品功能本身是好的**）。

**正确测法：让后端回一行标识，客户端读那一行，用标识判断落到哪个后端。**

```bash
# 准备：两个后端各自回一行自己的标识（例：hostname + pid）
# 后端 A（主）用 nc 或 socat：  echo "BACKEND-A" | nc -l -p 19081
# 后端 B（备）用 nc 或 socat：  echo "BACKEND-B" | nc -l -p 19081
#
# 客户端：读回的那一行就是答案
echo "=== 切主前 ==="
curl -sS --max-time 10 --resolve "test.local:19443" "http://test.local:19443/" | head -1
# 期望：BACKEND-A

echo "=== 杀掉主、重跑完切换后 ==="
curl -sS --max-time 10 --resolve "test.local:19443" "http://test.local:19443/" | head -1
# 期望：BACKEND-B   ← 这一行才是「切换成功」的证据
```

⇒ **判据落到那一行标识上**，不落到「有没有连上」「curl 的退出码」上。

**期望结果（可判定，五步全过才算「切换成功」）**

1. **目标出现在状态文件里，且 `LAST_CHECK` 是本轮时间戳** ⇒ 证明**探测端确实在探这个目标**。
2. **主故障后状态变 `failed`**（`FAIL_COUNT >= 2` 且 `FAILURE_START_TIME` 非 0）⇒ 证明**探测确实拿到了失败结果**。
3. **日志里出现 `[CONFIG] 检测到节点状态变化` → `[CONFIG] 配置更新完成`** ⇒ 证明**写回链路通了**（探测脚本确实调了 `pf --restart-service`）。
4. **配置里的权重发生翻转**（`balance` 从 `1, 0` 变 `0, 1`）⇒ 证明**新配置确实写下去了**。
5. **实连读回的那一行标识 = 备后端的标识** ⇒ 证明**转发层真的切了**。⚠️ **只改配置不算数** —— 配置翻了但流量没走（规则没重新生成 / realm 没重启 / 目标解析错）都会让前四条绿、第 5 条红。

> **★ 预期现象（不是缺陷，验收不要误判 FAIL）**：权重翻转要**重启 realm 服务**才生效（探测脚本调 `pf --restart-service` → `lib/ui.sh` 的 `--restart-service` 分支 → `service_restart`）⇒ **切换瞬间有几秒转发中断**。
> ⇒ 这是**机制固有代价**，不是「切换把流量打死了」⇒ **验收时不得因为这几秒中断判 FAIL**。
> ⇒ **但必须写进验收记录**：中断窗口 ≈ 几秒（用 realm 的 stop/start 时间戳对上）—— 因为它决定**客户端要能容忍多长的不可用窗口**（与 A-6.1 的「主备切换不是瞬时的」是同一件事的两面）。
> ⇒ 收进 `docs/local-unverifiable-checklist.md` 的第 5 条（Chief 指定必须包含）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| **状态文件里根本没有这个目标** | ⇒ **探测准入不满足**：查 `RULE_ROLE=1` / `ENABLED=true` / `FAILOVER_ENABLED=true` 三条（A-13.0） |
| 状态在但 `LAST_CHECK` 不前进 | 探测端没跑 → 查 timer（`systemctl is-active realm-health-check.timer`）+ **A-14**（产物是不是旧的） |
| 状态一直是 `healthy`，主都挂了 | 探测打到了**错误的地址**（例如探的是回环口不是真实后端）→ 查 `REMOTE_HOST` / `REMOTE_PORT` 与 `TARGET` 口径（`host:port`） |
| 状态变 `failed` 但**没有 `[CONFIG]` 日志** | 写回链路没走（探测脚本没调 `pf --restart-service`）→ 查 `lib/health.sh` 的健康检查体的 `[CONFIG]` 段 |
| 权重翻了但实连还是主后端 | realm 配置没重新生成 / 没重启 → 查 `[CONFIG]` 之后的重启是否成功；查 `remote` / `extra_remotes` 是否含备目标 |
| **实连「连上了但读不到标识」** | ⚠️ **大概率是测法问题，不是产品问题** —— 改用「后端回一行标识」的测法（见上）。**先怀疑自己的测法，再怀疑产品** |
| **realm 整个挂了 / 所有端口都不通** | ⇒ 查 **A-17**（`balance` 形态非法 → realm panic → **全站断流**），不要只查这一个 endpoint |
| 两个目标都 `failed` | 走了「全挂兜底」⇒ **权重不翻、流量压在已故障的主机上** = 该切不切的静默失效 → 查 `RULE_ID` 归属（见 A-16） |

### A-13.2　主备切换可靠性的四条附加判据

| # | 判据 | 为什么是它 |
|---|---|---|
| **R1** | **切换耗时可复现**：从「杀掉主监听」到「`config.json` 里权重翻到备上（主位 = 0、备位 = 1）」的**实测间隔**记进验收记录 | 用户唯一能感知的指标。**实测 30 秒**（来源：**Chief 真机实测**，2026-10-24 真机 103；审稿未独立复现）⇒ 理论下限 8 秒。⚠️ 相比**已删除**的守护进程路径（8–10 秒）**慢 3–4 倍** ⇒ **这是产品事实，不是回归**。⚠️ **30 秒是「超时预算 = 3 秒」口径下的实测值**（预算抬到 10 秒后**必然更慢**）⇒ **不得当判据**；若 **> 60 秒** ⇒ 探测端有问题 |
| **R2** | **备机不跟着挂**：主挂时状态文件里备那行必须仍是 `healthy` | 两目标都 `failed` ⇒ 走全挂兜底 ⇒ **权重不翻、流量压已故障主机** = 静默失效 |
| **R3** | **恢复后不立刻翻回**（冷却期约束） | 「严格主备」与「恢复就均摊」的分界。⚠️ 判据是「**恢复后立刻读，权重仍在备上（主位 = 0、备位 = 1）**」，**不是**「必须是 120 秒」 |
| **R4** | **切换不需要人工干预，也不必重启 realm 守护** | 切换是「健康检查写回权重 → 重生成 `config.json` → 重启 realm」自动完成的；出现「要手工干预才对」⇒ 链路断了 |

> **⚠️ R1 的纪律**：实测值**必须写来源**（起止时间戳 + 复现命令）。**不要**把「理论下限 8 秒」或验收用的 `sleep 140` 当成实测值写进结论 —— 拿不到就写「待补」。

### A-13.3　主备的建立（权重下发与形态确认）

**命令**

```bash
echo "--- 下发权重 10,0（应自动进主备）---"
source /usr/local/bin/lib/rules.sh
apply_port_group_weight_config 19443 "10,0" 1

echo "--- 规则：应是主备形态 ---"
grep -H -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS|TARGET_STATES|RULE_ROLE)=' /etc/realm/rules/rule-*.conf

echo "--- 生效权重（应为 10,0）---"
jq -r '.endpoints[].balance' /etc/realm/config.json

echo "--- 探测端 timer 必须已拉起（没有探测就没有切换）---"
systemctl is-enabled realm-health-check.timer
systemctl is-active  realm-health-check.timer
```

**期望结果（可判定）**

1. `BALANCE_MODE` = **`active-standby`**；`FAILOVER_ENABLED` = **`true`**。
2. 权重序列 = **`10,0`**。
3. `realm-health-check.timer` = **`enabled` + `active`**（**这是主备路径的命脉** —— 探测端没起来就永远不会切换）。
4. 形态必须是 A-13.0 的正确形态（一条规则两个目标 + `RULE_ROLE=1`）。

**危险动作**：同 A-11。**本项会真的把流量切走** —— 确认在测试环境；**严禁动 22 端口**。

### A-13.4　★ 分诊：「切换失败」与「切换没发生」必须能区分开

> **为什么单列**：这两件事的现象**几乎一样**（都是「流量还在主后端」），但**根因、严重级、处置完全不同**：
> **切换失败** = 切换**发生了但没成功**（realm 崩了 / 配置非法 / 转发层坏了）⇒ **可能是阻断级**。
> **切换没发生** = 切换**压根没启动**（探测端没探到 / 形态不对）⇒ **静默失效**，日志里连一句失败都没有。
> ⇒ **判据必须能把这两者分开，否则会把阻断级事故当成「没触发」放过。**

**分诊命令**

```bash
echo "=== 分诊第一步：realm 还活着吗？（区分「切换失败」与「切换没发生」）==="
systemctl is-active realm && echo "realm active" || echo "★realm 未 active ⇒ 切换失败（不是没发生）"
journalctl -u realm --no-pager -o short-iso -n 50 | grep -iE 'panic|panicked|backtrace' \
  && echo "★realm 有 panic ⇒ 切换失败（见 A-17）" || echo "realm 日志无 panic"

echo "=== 分诊第二步：全站转发还通吗？（panic 是全站断，不是单 endpoint 断）==="
# 另开一个与主备无关的端口试一下
curl -sS --max-time 10 --resolve "test.local:<另一个端口>" "http://test.local:<另一个端口>/" | head -1

echo "=== 分诊第三步：状态文件里那个目标变 failed 了吗？（区分「没探到」与「探到了但没切」）==="
grep -v '^#' /etc/realm/health/health_status.conf
# ★ 目标仍是 healthy / 压根没有这行 ⇒ 切换【没发生】（探测端没探到 / 形态不对）

echo "=== 分诊第四步：探测端在跑吗？==="
systemctl is-active realm-health-check.timer
journalctl -u realm-health-check.service --no-pager -o short-iso -n 20
```

**判定表（可判定）**

| realm | 状态文件里目标 | 判定 | 根因方向 | 严重级 |
|---|---|---|---|---|
| **未 active** / 有 panic | 任意 | **切换失败** | `balance` 形态非法 → realm panic → **全站断流**（**A-17**） | 🔴 **阻断级** |
| active，但**其它端口也不通** | 任意 | **切换失败**（且已扩散） | 查 realm 全局状态（不止这一个 endpoint） | 🔴 **阻断级** |
| active，其它端口正常 | 目标**仍是 healthy** / **没有这行** | **切换没发生** | **探测准入不满足**（`RULE_ROLE=1` + `ENABLED=true` + `FAILOVER_ENABLED=true`）⇒ **A-13.0**；或 timer 没跑 | 🟠 静默失效 |
| active，其它端口正常 | 目标**已 `failed`** 但**权重没翻** | **切换发生但没成功** | 写回链路断（没调 `pf --restart-service` / `[CONFIG]` 没打出来） | 🟠 静默失效 |
| active，其它端口正常 | 目标**已 `failed`**、权重**翻了**、但实连还是主 | **切换发生且配置生效，但转发层没切** | realm 没重启 / 目标解析错 / `remote`/`extra_remotes` 不含备 | 🟠 |
| active，其它端口正常 | 实连读回的标识**是备后端** | ✅ **切换成功** | — | — |

> **⚠️ 纪律**：分诊**先看 realm 活不活**，再谈切换。**「日志里没有失败记录」不等于「切换失败」** —— 也可能是**切换压根没发生**（静默失效），这正是 A-13.0 那条坑。

---

## A-14　健康探测端确实在探测（保留路径的命脉）

**验收目标**：健康探测端**真的在跑**，且产物与真源一致、状态文件不残留已删规则的行。

> **为什么本项独立成条**：用户裁定保留的三条路径中，**只有权重主备依赖健康探测** —— 探测端不工作 ⇒ 主备永远不会切换 ⇒ **「静默失效」而非「失败」**。所以本项是保留路径的**命脉项**，不能并进 A-3 顺带看一眼。

**命令**

```bash
echo "--- 探测 timer / service ---"
systemctl is-enabled realm-health-check.timer
systemctl is-active  realm-health-check.timer
systemctl list-timers realm-health-check.timer --no-pager

echo "--- 生成物在位 ---"
ls -l /etc/realm/health/health_check.sh
ls -l /etc/realm/health/health_status.conf

echo "--- ★ 生成物内容必须与真源一致（唯一真源 = lib/health.sh 的 health_check_script_body）---"
# 生成物应包含从真源机械抽取的实现；不一致 ⇒ 生成物是旧的（静默失效）
grep -c 'check_connectivity' /etc/realm/health/health_check.sh

echo "--- ★ 状态文件的最后检查时间必须随轮次前进（不能是静止的旧值）---"
grep -v '^#' /etc/realm/health/health_status.conf
sleep 15
echo "--- 15 秒后再读一次，最后检查时间应更新 ---"
grep -v '^#' /etc/realm/health/health_status.conf
```

**期望结果（可判定）**

1. `realm-health-check.timer` = `enabled` + `active`；`list-timers` 能看到下次触发时间。
2. `/etc/realm/health/health_check.sh` 存在且**非空**。
3. **两次读取 `health_status.conf`，最后检查时间字段必须不同**（**第二次比第一次新**）⇒ 证明探测端**每轮都在跑**。若两次完全相同 ⇒ **探测端没跑**，无论日志里写了什么都判 FAIL。
4. 状态文件里**只有当前存在的规则的行** —— 已删除的规则**不得残留**（残留行会让 `lib/realm.sh` 的 `generate_endpoints_from_rules` 按 `host:port` 建索引时命中一条**已经不存在的目标**，把流量判成 failed）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 最后检查时间两次相同 | 探测端没跑 → `systemctl status realm-health-check.service` 看 journal；或 `health_check.sh` 没被生成 |
| 生成物内容与真源不一致 | 生成物是旧版本 ⇒ **静默失效**。写端唯一是 `lib/health.sh` 的 `health_check_script_body`（经 `start_health_check_service` 落盘）；**装 / 升级路径若不经过这个写点 ⇒ 生成物永远不更新** ⇒ 查 `update.sh` 与 install 两处是否都调到了写点 |
| 状态文件有已删规则的残留行 | 状态文件不是「每轮原子重建、只留当前规则行」→ 查写端是否在每轮清掉旧行 |
| 探测端把两个端口判成同一个 key | `TARGET` 口径问题（裸 host 宽键）→ 见 A-4 的三档判据 |

**危险动作**：无（只读观测）。

---

## A-15　老机器残留清理（升级到新版本后）

**验收目标**：**在装了旧版（主备池/守护进程时代）的机器上升级到新版本** ⇒ 旧的守护进程、unit、drop-in、`failover.json` 池配置**被卸载流程清理干净**，**不留占着端口的僵尸**。

> **为什么必须单列一条**：删除功能最容易出的事故不是「删不掉」，而是**「删了一半」** —— 老机器上 `xwpf-failover.service` 还在跑、还在占着监听端口，界面却已经显示「该功能已移除」⇒ 端口冲突 + 僵尸进程 + 用户以为产品坏了。

**前置**：一台**跑过旧版**的机器（真机 `103.42.31.186` 现跑两个池：旧池监听 `18443`、直连池监听 `18444`）；升级前先备份。

**命令**

```bash
echo "=== 升级前快照（留证）==="
systemctl list-unit-files | grep -E 'xwpf-failover' || echo NO-UNIT-FILE
systemctl status xwpf-failover --no-pager | head -5 || true
ss -lntp | grep -E 'xwpf-failover|:18443|:18444' || echo NO-LISTEN
ls -l /etc/systemd/system/xwpf-failover.service.d/ 2>/dev/null || echo NO-DROPIN-DIR
ls -l /etc/xwpf/ 2>/dev/null || echo NO-CONF-DIR

echo "=== 升级（走更新中心或 pf install）==="
# 升级后：

echo "=== 升级后核对：守护相关残留应全部为空 ==="
echo "--- 1) unit 文件 ---"
ls /etc/systemd/system/ | grep -E 'xwpf-failover' && echo "★FAIL: 残留 unit" || echo "OK: 无残留 unit"

echo "--- 2) drop-in 目录 ---"
ls -d /etc/systemd/system/xwpf-failover.service.d 2>/dev/null && echo "★FAIL: 残留 drop-in 目录" || echo "OK: 无残留 drop-in"

echo "--- 3) 进程 ---"
pgrep -af 'xwpf-failover' && echo "★FAIL: 守护进程还在跑" || echo "OK: 无守护进程"

echo "--- 4) 监听端口（18443 / 18444 不得还被旧守护占着）---"
ss -lntp | grep -E ':18443|:18444' && echo "★FAIL: 旧端口仍被占用" || echo "OK: 无旧监听"

echo "--- 5) 池配置：不得有活配置（留档 .disabled 是允许的，但要登记）---"
ls -1 /etc/xwpf/ 2>/dev/null | grep -v '\.disabled$' && echo "★FAIL: /etc/xwpf 下有未留档的活配置" || echo "OK: 无活配置"
ls -1 /etc/xwpf/*.disabled 2>/dev/null && echo "ℹ 留档文件（需在验收记录里登记）" || true

echo "--- 6) 卸载后复核（走 pf → 8. 卸载服务）---"
systemctl list-unit-files | grep -E 'xwpf-failover' && echo "★FAIL: 卸载后仍有 unit" || echo "OK: 卸载后无 unit"
```

**期望结果（可判定）**

1. **升级后**，以下**全部不存在**（Chief 给的判据，逐条可勾）：
   - `/usr/local/bin/xwpf-failover`（守护二进制）
   - `/etc/systemd/system/xwpf-failover.service`（守护 unit）
   - `/etc/systemd/system/xwpf-failover.service.d/`（守护 drop-in 目录，**整目录**）
   - `/etc/xwpf/failover.json`（池配置）—— ⚠️ **实现是「改名留档」**：`lib/ui.sh` 的 `_cleanup_legacy_failover_daemon` 把它 `mv` 成 `failover.json.disabled` ⇒ **原路径不存在** ⇒ 这条判据成立，但**`.disabled` 留档文件会留下**（属用户数据，不删）⇒ **必须在验收记录里登记留档文件名**
   - `/etc/xwpf/failover-state.json`（守护状态文件）—— 同上，`mv` 成 `failover-state.json.disabled`
   - `/usr/local/bin/.xwpf-failover-version`（版本指纹）
   - `/usr/local/bin/cmd/xwpf-failover.py` / `.service`（守护源文件副本）
2. **`ss -lntp` 里 18443 / 18444 不再有人监听**（守护进程已停，端口释放）。
3. **无残留守护进程**：`pgrep -af 'xwpf-failover'` 无输出。
4. **卸载后**同样全部为空，且 `systemctl list-unit-files | grep xwpf-failover` 无输出。
5. **不得影响保留路径**：升级/卸载过程中，`realm-health-check.timer`、`/etc/realm/health/`、权重主备的规则与 `config.json` **不受损**（若被清掉 ⇒ 保留路径被误伤，是**阻断级**问题）。
6. ⚠️ **真机 103 的特别提醒**：该机现在跑两个池（`18443` 旧池 / `18444` 直连池），**守护进程一旦不再监听，依赖这两个端口的转发就会断** ⇒ **必须先把流量迁到「同端口多目标 + 权重」路径**，再删守护。**顺序错了 = 真机断转发。**

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| unit 残留但 `list-unit-files` 没有 | 只是 `/etc/systemd/system/` 里的孤儿文件 → 卸载流程漏了 `rm -f` |
| 进程还在 | 只 `stop` 了 timer 没停 service，或守护进程没被 `disable` |
| 端口还被占 | 守护没停干净（见上），或 realm 侧规则仍指向该端口 |
| **保留路径的东西被一起清了** | 卸载/删除的**范围**过宽（把 `/etc/realm/health/` 或 health-check unit 当成守护的东西删了）→ 查卸载两阶段的路径清单 |
| `/etc/xwpf/` 目录还在 | **不是残留、不是失败** —— 实现的清理策略是**改名留档**（`failover.json` → `failover.json.disabled`）⇒ 目录里只剩**留档文件** ⇒ **判据是「里面不得有活配置」**，不是「目录必须不存在」。⚠️ 但**留档文件名要登记** |
| 老池在菜单里**列不出来也删不掉** | ⚠️ **这不是缺陷，是功能下线的必然结果** —— 池管理入口 `failover_proxy_menu`（建池/列池/删池）已随 `2beb7bd` **整块删除** ⇒ 「列出/删除老池」这个能力**已不存在**。⚠️ **原判据写错了**（曾写「老池必须仍能列出与删除」——那是审稿在功能下线前基于「兼容读取保留」的推断，**现已作废**）⇒ 现状的正确判据：**原路径 `failover.json` 不存在 + 留档文件在 + 文档告诉用户「留档不删、用户可自己回查」**（`docs/install-and-upgrade.md` 的老机器残留清理表已按此写，**与实现一致**） |

**危险动作**：**升级会改转发配置** ⇒ 先备份 `/etc/realm`、`/etc/xwpf`；**卸载会删全部规则与配置** ⇒ 确认是测试机或已备份。

## A-16　删除规则后，健康状态**不得残留、不得过户给别的规则**

**验收目标**：删掉一条规则 ⇒ 它的健康状态**从状态文件里消失**、**不被别的规则继承**、**不污染别的规则的显示与切换**。

> **为什么必须单列一条**：用户裁掉进程级主备池之后，**权重主备是唯一的主备机制**，而它的判据**全部落在状态文件里**。状态文件一旦出现**孤儿行**（指向已不存在的目标）或**重复行**（**同一条规则**对同一 target 两行），就会出现两种**静默**故障：
> ① 界面把一条**健康**规则显示成「故障」；
> ② 故障转移拿一个**不属于这条规则**的历史失败计数当判据 ⇒ 该切的不切 / 不该切的切。
> 两种都**不报错**，只是「不工作」—— 与 A-13.0 那条「形态不对 ⇒ 完全静默」是同一族病。
> ⚠️ **注**：「**两条不同规则**合法地指向同一个后端 ⇒ 状态文件里**就该有两行**」是**正常形态**，不是本条要治的病 ⇒ 判据钉的是「**同一条规则**对同一 target 不得两行」。

### A-16.0　机制：状态文件的三套写法（先看懂再判定）

**锚点**（复核时 2026-10-24，仓库 HEAD `9dc5b56`）：本节判据核自 `git show 9dc5b56:lib/health.sh` 与 `git show 9dc5b56:lib/rules.sh`。⚠️ `9dc5b56`（N4 落地）只改了 `lib/health.sh` / `lib/update.sh` / `xwPF.sh`，**`lib/rules.sh` 未被该提交触碰** ⇒ 本节关于 `sync_health_status_ids` 的描述对 `f59e389` 与 `9dc5b56` **同时成立**。⚠️ 但 **`lib/health.sh` 的状态文件写法在 `9dc5b56` 发生了代际变化**（「按需替换」→「整份原子重建」）⇒ 详见本节下方的**口径更正**框。**本节其余各节仍以 `a9102c1` 为基线。**

**写入方一：`lib/health.sh` 的健康检查体 —— 每轮整份原子重建**
- 顺序：快照旧文件 → **只为「本轮被监控的目标」**算新行 → 整份覆盖。
- 被监控的准入（与 A-13.0 同一条）：`RULE_ROLE=1 && ENABLED=true && FAILOVER_ENABLED=true`。
- ⇒ **只要探测端在工作**，状态文件里**不该有孤儿行**（没被监控的目标不会被写回）。
- ⇒ **但**：若规则形态不对（A-13.0 的坑），探测端**从来没跑过** ⇒ 状态文件是**历史遗留** ⇒ 孤儿行会一直躺在那里。

**写入方二：`lib/rules.sh` 的 `sync_health_status_ids` —— 规则增删时过户 / 清理**
- 只在 `reorder_rule_ids` 末尾调用（即**规则增删改**时，**不是**每轮探测时）。
- 逐行按 **target** 去当前规则文件里找归属：`RULE_ROLE=1` 按 `host:REMOTE_PORT` 精确匹配；`RULE_ROLE=2` 按 `FORWARD_TARGET`。
- 找到 ⇒ **把该行的 RULE_ID 改写成命中规则的 RULE_ID**；找不到 ⇒ **整行丢弃**（清无主行）。
- ⚠️ 保留了一条**老口径兜底**：`REMOTE_HOST` 子串匹配 ⇒ **理论上可能把 `127.0.0.1` 认领给 `127.0.0.1:18081`** ⇒ 存在**跨地址串号**通道（**待实测**，见判据 2）。

**读取方：`lib/health.sh` 的 `get_health_status_record` —— 按 target 取第一行就退出**
- ⇒ **同一个 target 若在文件里有两行**，取到哪一行**取决于文件行序** ⇒ 孤儿行排在前面就会污染显示。

**跨轮继承：`lib/health.sh` 的 `health_status_find_row` —— 🔄 匹配键已改成「(RULE_ID, 目标地址) 组合键」**
- **锚点：HEAD `43c135a`**（`fix(health): 状态继承键改回 (RULE_ID, 目标地址) 组合键`）。审稿**逐端独立核过**：
  - **函数定义**：`health_status_find_row` 现在是 **4 参**（`status_file` / `rule_id` / `endpoint` / `host`）⇒ 匹配处有 `if [ "$_rid" != "$rule_id" ]; then continue; fi` ⇒ **RULE_ID 那一半真的被比对了** ✅
  - **调用点**：`health_status_find_row "$_health_status_old" "$RULE_ID" "$target_endpoint" "$target"` ⇒ **传了 RULE_ID** ✅
  - **生成物里的抽取副本**：`health_emit_function health_status_find_row` 与调用点同在健康检查体内 ⇒ **一致** ✅
  - ⇒ **原来那个「`target_key` 是死变量」的缺陷已修复** ✅
- ⇒ **组合键口径下的继承语义（三条，钉清楚）**：
  | 场景 | 是否继承 | 理由 |
  |---|---|---|
  | 同 `RULE_ID` + **同**目标地址 | **继承** | 同一个后端的同一行状态，本来就该延续它的失败计数 / 故障起始时间 |
  | 同 `RULE_ID` + **不同**目标地址 | **不继承** | RULE_ID 被复用但后端不同 ⇒ 老状态与新目标无关 |
  | **不同** `RULE_ID` + 同目标地址 | **不继承** | 两条规则各自的状态归属独立 |

**⚠️ 但读端（`lib/realm.sh`）还没跟上 —— 组合键只修了一半**
- `lib/realm.sh` 的 `generate_endpoints_from_rules` 读状态文件时，建键是 `health_status["$_row_target"]`（**键里没有 RULE_ID**）⇒ **两条规则指向同一后端时，同一个 key 被后读的行覆盖** ⇒ 只剩一个 status。
- 而切换判断用的正是这个 map（active-standby 与剔除模式两处都查 `health_status[$_t]`）⇒ **一条规则的 failed 可能被算到共用同一后端的另一条规则头上** ⇒ **误继承 = 误切**（危险方向）。
- ⇒ **写端（组合键）/ 跨轮读端（组合键）/ 读端（地址键）三者仍不一致** ⇒ 记为 **A-18 待修项 ① 的残留部分**。
- ⇒ **验收侧处置**：见 **判据 5**（读端归属）—— **待产品修复后验证**。

> **★ Chief 真机实测（2026-10-24，来源：Chief 实测，审稿未独立复现）**
> ① 状态文件 **4 行里 3 行是孤儿**；
> ② 删掉一条规则后，它的行 `3|127.0.0.1:18081` 被改写成 `1|127.0.0.1:18081`（**目标地址相同**）；
> ③ `reorder_rule_ids` 会**重排 RULE_ID**：实测 `rule-5`（ID=5）→ 重排后变成 `rule-3`（ID=3），并**按目标地址把状态行过户给当前规则**。
>
> ⇒ ②③ 发生在**组合键修复之前**（`43c135a` 之前）⇒ **观测有效，但结论的适用范围受版本限制**。
> ⇒ ② 的「同地址被继承」在**组合键口径下已不再是缺陷路径**（跨轮读端现在要求 RULE_ID 也对上）⇒ **判据 3 已改向**（见下）。
> ⇒ **3 行孤儿**的根因是：真机那两条规则是 `RULE_ROLE=2` + `FAILOVER_ENABLED=false` ⇒ **探测端从来没跑过** ⇒ 状态文件是历史遗留 ⇒ **归因到 A-13.0，不另开缺陷单**。
> ⚠️ **但一旦形态改对、探测端跑起来，这些历史行会被整份重建**一次抹掉** —— 这一点本身就是验收时应当看到的变化（判据 1 会在改造后自动转绿）。

> **⚠️⚠️ 口径更正（重要 —— 「按需替换」与「整份原子重建」是两代实现，结论相反）**
>
> Chief 观测到的「**状态行是按需替换的：探测只清掉自己这个 target 的行 ⇒ 被删规则的行永远留着**」—— 审稿对着 git 历史核过，**这条描述精确对应 `9dc5b56^`（N4 之前）的实现**：
> ```
> 9dc5b56^:lib/health.sh  →  grep -v -e "^${target_key}|" -e "^${legacy_key}|" "$HEALTH_STATUS_FILE" > tmp
>                             echo "新行" >> tmp && mv tmp "$HEALTH_STATUS_FILE"
> ```
> ⇒ **只清掉自己 target 的行** ⇒ **被删规则的行永远留着** ⇒ **Chief 的观测与旧实现完全一致，没有测错。**
>
> **但 HEAD `9dc5b56` 起改成了「整份原子重建」**（N4 落地，提交信息里就写着「状态文件每轮原子重建」）：
> ```
> 9dc5b56:lib/health.sh   →  快照旧文件 → 只为「本轮被监控的目标」写新行 → 整份覆盖
> ```
> ⇒ **孤儿行会被一次抹掉**（只要探测端在跑）。
>
> ⇒ **⇒ 对验收的三条影响**：
> 1. **判据 1（孤儿行 = 0）在 `9dc5b56` 上应当转绿**；若仍红 ⇒ **不是状态文件机制的问题，是探测端没在工作**（回 A-13.0 / A-14）。
> 2. **判别的命令**（先确认真机上跑的是哪一代）：
>    ```bash
>    grep -c '_health_status_new' /usr/local/bin/health_check.sh   # 有 = 原子重建版（9dc5b56+）
>    stat -c '%y' /etc/realm/health/health_status.conf              # mtime 是否随每轮探测前进
>    ```
> 3. **Chief 那次实测的机器版本需要确认**（测的是 `9dc5b56` 之前还是之后）—— 观测本身有效，**结论的适用范围取决于版本**。

### A-16.1　★ 硬判据

**判据 1　无孤儿行（必测）**
状态文件里**每一行**的 target 都必须能对应到**当前存在**的某条规则的某个目标。
- 对不上的行 = **残留** ⇒ **FAIL**。
- 判定脚本见 A-16.2 的第 3 步（逐行比对 target ↔ 当前规则的 `REMOTE_HOST:REMOTE_PORT` 集合）。

**判据 2　不跨地址过户（必测）**
删掉规则 X（目标 `A`）后，指向**不同**目标 `B` 的规则**不得**继承 X 的 `status` / `fail_count` / `failure_start_time`。
- 代码现状：`health_status_find_row` 按 target 精确匹配 ⇒ **不同地址不会串** ⇒ 预期 **PASS**。
- ⚠️ **唯一要盯的例外**：`sync_health_status_ids` 的**老口径子串兜底** ⇒ **必须实测**，不能只读代码就判过。

**判据 3　同地址归属（🔄 已改向 —— 组合键已落地，判据跟着改）**
**产品口径 = 组合键 `(RULE_ID, 目标地址)`**（`43c135a` 已修跨轮读端）⇒ 删掉规则 X 后，**别的规则不得继承 X 的状态**，哪怕它们指向同一个后端。
- ⇒ **「同地址被继承」在修复后应判 FAIL**（修复前是现状，标「**待产品修复后验证**」）。
- ⇒ **⚠️ 反过来，「同一地址出现两行」本身不一定是缺陷**：**两条不同规则合法地指向同一个后端**时，状态文件**就该有两行**（每条规则一行，各带自己的 RULE_ID）⇒ **那种情况下不判 FAIL**。
- ⇒ **真正判 FAIL 的是「同一条规则（RULE_ID）对同一个目标出现两行」** —— 那才是重复 / 残留。

**判据 4　取样时序（判据 1~3 的前置）**
删规则的瞬间状态文件**可能**还没清（清理发生在下一次探测轮或规则重排时）⇒ **必须在「探测端跑过至少一轮之后」再取样**。
- 等待口径：`HEALTH_CHECK_INTERVAL` 标称 4 秒、实测波动 **4–30 秒** ⇒ **至少等 60 秒**再取样。
- 且取样前**必须确认 `journalctl -u realm-health-check.service` 有本轮输出** —— 没有本轮输出就取样 = 测了个寂寞。

**判据 5　读端归属（🔴 新增 —— 组合键只修了一半，待产品修复后验证）**
`lib/realm.sh` 的 `generate_endpoints_from_rules` 建键仍是 `health_status["$_row_target"]`（**不含 RULE_ID**）⇒ **两条规则共用同一后端时，同一个 key 被后读的行覆盖** ⇒ 切换判断（查 `health_status[$_t]`）可能拿到**另一条规则**的 failed ⇒ **误继承 = 误切**。
- **修复前**：不判 PASS/FAIL，**只登记现象**（标「待产品修复后验证」）。
- **修复后**（读端也按组合键）：**同后端不同规则的状态互不影响** ⇒ 判据 = 「**两条规则共用同一后端时，其中一条判 failed，另一条的切换判断不受影响**」。
- **取样方法**：造两条规则指向**同一个** `host:port`、但 `RULE_ID` 不同 ⇒ 停掉该后端 ⇒ **判据**：两条规则的状态行都变 `failed`（各带各的 RULE_ID），而**任何一条规则的切换判断都不应把另一条的状态算进来**。

**★ 前置依赖**：本项**依赖 A-13.0 形态正确 + A-14 探测端在跑**。若形态不对，本项「孤儿行」的结论**归因到 A-13.0**，不要另开缺陷单。

### A-16.2　取证命令

```bash
echo "=== 1) 状态文件原始内容（每行：RULE_ID|TARGET|...）==="
grep -v '^#' /etc/realm/health/health_status.conf | tee /tmp/hs_rows.txt
echo "状态行数: $(wc -l < /tmp/hs_rows.txt)"

echo "=== 2) 当前规则的真实目标集合（host:port）==="
: > /tmp/live_targets.txt
for f in /etc/realm/rules/rule-*.conf; do
  [ -f "$f" ] || continue
  role=$(grep -m1 '^RULE_ROLE=' "$f" | cut -d= -f2)
  en=$(grep -m1 '^ENABLED=' "$f" | cut -d= -f2)
  fe=$(grep -m1 '^FAILOVER_ENABLED=' "$f" | cut -d= -f2)
  [ "$role" = "1" ] && [ "$en" = "true" ] && [ "$fe" = "true" ] || continue
  rport=$(grep -m1 '^REMOTE_PORT=' "$f" | cut -d= -f2)
  IFS=',' read -ra hs <<< "$(grep -m1 '^REMOTE_HOST=' "$f" | cut -d= -f2)"
  for h in "${hs[@]}"; do
    h=$(echo "$h" | xargs); [ -n "$h" ] || continue
    echo "${h}:${rport}" >> /tmp/live_targets.txt
  done
done
sort -u /tmp/live_targets.txt > /tmp/live_targets.sorted
echo "被监控目标数: $(wc -l < /tmp/live_targets.sorted)"

echo "=== 3) 孤儿行（状态文件里有、当前规则里没有）—— 判据 1 ==="
orphan=0
while IFS='|' read -r rid target rest; do
  [ -z "${rid:-}" ] && continue
  if ! grep -Fxq "$target" /tmp/live_targets.sorted; then
    echo "★孤儿行: ${rid}|${target}|${rest}"
    orphan=$((orphan+1))
  fi
done < /tmp/hs_rows.txt
echo "孤儿行数: $orphan   （期望 0）"

echo "=== 4) 同一规则对同一目标出现多行（重复行）—— 判据 3 ==="
# ★ 判据钉「同一条规则（RULE_ID）+ 同一个 target」这个组合
#   注意：两条【不同】规则合法地指向同一后端时，状态文件【就该有两行】—— 那不是缺陷
cut -d'|' -f1,2 /tmp/hs_rows.txt | sort | uniq -d | tee /tmp/dup_keys.txt
echo "重复 (RULE_ID,TARGET) 组合数: $(wc -l < /tmp/dup_keys.txt)   （期望 0）"

echo "--- 附：同一 target 出现在几条不同规则下（合法，但要登记）---"
cut -d'|' -f2 /tmp/hs_rows.txt | sort | uniq -c | awk '$1>1' | tee /tmp/shared_targets.txt
echo "共用后端的目标数: $(wc -l < /tmp/shared_targets.txt)"
```

**删除动作 + 取样（判据 1~4 的完整动作序列）**

```bash
echo "=== 5) 删规则前留证 ==="
grep -v '^#' /etc/realm/health/health_status.conf > /tmp/hs_before.txt
cp -a /etc/realm/health/health_status.conf /tmp/hs_before.conf

echo "=== 6) 删除一条规则（走菜单：pf → 规则管理 → 删除）==="
# 记下被删规则的 RULE_ID 与它的目标地址，删除后立刻再看一眼
grep -v '^#' /etc/realm/health/health_status.conf

echo "=== 7) 等探测端跑过一轮（>= 60 秒），并确认本轮有输出 ==="
sleep 60
journalctl -u realm-health-check.service --no-pager -o short-iso -n 20
grep -v '^#' /etc/realm/health/health_status.conf

echo "=== 8) 前后对比：被删目标是否还在、别的目标的状态有没有被改写 —— 判据 2 ==="
diff /tmp/hs_before.conf <(grep -v '^#' /etc/realm/health/health_status.conf) || true
```

**期望结果（可判定）**

1. **判据 1**：第 3 步的 `孤儿行数` = **0**。
2. **判据 2**：第 8 步的 `diff` 里，**没有**「某条规则的 status / fail_count / failure_start_time 被写成另一条规则的值」这种改动；被删目标的行**消失**，且**别的 target 的行内容不变**。
3. **判据 3**：第 4 步的 `重复 (RULE_ID,TARGET) 组合数` = **0**。
   ⚠️ **不再用「状态文件行数 == 被监控目标数」当判据** —— **两条不同规则合法地指向同一后端时，行数会多于目标数**（每条规则各一行）⇒ 那是**合法形态**，不是缺陷。
4. **判据 4**：第 7 步的 `journalctl` 有**本轮**输出（不是上一轮的旧日志）⇒ 取样有效。
5. **判据 5（读端归属）**：**待产品修复后验证**（`lib/realm.sh` 的读端建键还没带 RULE_ID）⇒ 修复前**只登记现象**，不判 PASS/FAIL。
6. **同地址场景的正确口径（🔄 已改向）**：删掉的规则与留下的规则**指向同一地址**时 ⇒ **按组合键口径，两条规则的状态互相独立** ⇒ 「留下的那条继承了被删那条的 failed」= **缺陷方向** ⇒ **修复后判 FAIL**。
   ⚠️ **但「同一地址出现两行」本身不算缺陷** —— 那是**两条规则各自的一行**，合法。
7. **改造后应当看到的变化**：把规则形态改对（A-13.0）并让探测端跑起来后，**历史遗留的孤儿行会被整份重建一次抹掉** ⇒ 状态文件里**不再有指向已不存在目标的行**。若**仍然**有孤儿行 ⇒ **探测端没在工作**，回 A-14 查。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 删规则后该行**还在**，target 指向已删规则 | **多半不是本项缺陷** —— 探测端**没在工作**（形态不对，见 A-13.0）⇒ 状态文件从没被重建 ⇒ **先过 A-13.0 / A-14 再判本项** |
| **同一条规则 + 同一个 target** 出现两行 | ⇒ **重复行**，FAIL。`get_health_status_record` 按 target **取第一行就退出** ⇒ 显示结果取决于行序 ⇒ **必须清掉** |
| **两条不同规则** + 同一个 target 出现两行 | ⇒ **合法形态**（各带各的 RULE_ID）⇒ **不判 FAIL**；但要确认**读端归属**对（判据 5） |
| 被删规则的 failed 被**别的地址**的规则继承 | `sync_health_status_ids` 的**老口径子串兜底**（`REMOTE_HOST` 含 `target`）⇒ 当前**唯一**可能跨地址的通道 ⇒ 查 `lib/rules.sh` 的 `sync_health_status_ids` 里那段兜底 |
| 删规则后行**立刻**还在 | **不是缺陷** —— 清理发生在下一次探测轮 / 规则重排时 ⇒ 判据必须等探测端跑过一轮再取样（判据 4） |
| **同地址**的 failed 被**另一条规则**继承 | 🔴 **现在是缺陷方向**（组合键口径）⇒ 查 `lib/health.sh` 的 `health_status_find_row` 是否按 `(RULE_ID, 目标地址)` 比对（`43c135a` 已修跨轮读端 ⇒ 若仍出现 ⇒ **多半是读端 `lib/realm.sh` 的 `generate_endpoints_from_rules` 建键没带 RULE_ID** ⇒ 判据 5） |
| 删规则**没有**触发规则重排 | `delete_rule` 在 `skip_confirm=true`（批量删除内部调用）时**不自己调** `reorder_rule_ids` ⇒ 靠 `batch_delete_rules` 末尾那次重排兜底 ⇒ 若那条路径没走到，`sync_health_status_ids` **不会执行** ⇒ 无主行不会被清 |

**危险动作**：本项会**真的删一条规则** ⇒ 用**测试机**或先备份 `/etc/realm`；删的是**承载对外端口**的规则会**断转发** ⇒ 真机上务必在**验证流量已迁走**之后再做。

## A-17　★ 阻断级：`balance` 字段格式非法 → **realm 崩溃** → **全站转发断**

**验收目标**：任何一次配置生成或改动之后，**realm 必须仍然是 active**，且**每个 endpoint 的 `balance` / `remote` / `extra_remotes` 都是合法形态**。

> **★ 为什么这是全清单最高风险项**：realm 解析 `balance` 失败 ⇒ **realm 直接 panic** ⇒ **不是只断那一个 endpoint，是所有 endpoint 的转发全断**（全站断流）。
> ⇒ 而且 **panic 发生在 realm 启动/重载那一刻** ⇒ **一次手滑的配置改动就能把整台机器的转发打掉** —— 与「删了一半」「静默失效」是**完全不同级别**的事故：前者是**立刻可见的全站故障**，后者是「不报错但不工作」。

**★ 真机实测（2026-10-24 真机 103，realm 2.9.6；来源：Chief 实测，审稿未独立复现）**

| `config.json` 里的写法 | realm 的反应 |
|---|---|
| `"remote": "a"`（**string**）+ `"extra_remotes": ["b"]`（**数组**）+ `"balance": "roundrobin: 1, 0"` | ✅ 正常 |
| 同上，但 `"balance": "roundrobin: 0, 1"`（切换后形态） | ✅ 正常 |
| `"remote": ["a", "b"]`（**数组**形式） | ❌ **realm panic**（realm 2.9.6 的 `realm_lb-0.1.1` 的 `balancer.rs`） |
| `"balance": "roundrobin"`（**不带权重**） | ❌ **realm panic**（同一处） |

⚠️ **panic ⇒ 全站转发断**（不是单 endpoint 断）。⚠️ realm 侧定位写「realm 2.9.6 内 `realm_lb-0.1.1` 的 `balancer.rs`」—— **不写行号**（本清单纪律：禁「文件:行号」）。

> **⚠️ 覆盖缺口声明（**别把没测过的写成已验**）**
> 已实测的**只有上表这四种形态**。以下组合 **尚未实测**，**不得**写成「已验」：
> - **权重 0 与 `iphash` 策略的组合**（`"balance": "iphash: 0, 10"` 之类）—— **未测**。
> - `roundrobin` 之外的**其它策略**（`iphash` / `random` 等）与**权重 0** 的各种组合 —— **未测**。
> - `extra_remotes` 里有 **3 个以上**目标时的权重个数口径 —— **未测**（只测过 2 个目标）。
> ⇒ **遇到未测组合时**：**不要**判 PASS，**登记为「未覆盖」**并补测。

> **★ 断言纪律（本节照这条写）**：判据钉**不变式**，**不钉具体字面量、不钉结构、不钉份数**。
> - ✅ 「`balance` 里权重个数 == 目标数」= 不变式
> - ✅ 「`remote` 是 string」/「`extra_remotes` 是 array」= 不变式
> - ❌ 「`balance` 必须等于 `"roundrobin: 1, 0"`」= 钉字面量（策略名与权重取值会随形态变）⇒ **不作为判据**，只作**参考形态**。

**代码侧核查（审稿对着 HEAD `9dc5b56` 核过 `lib/realm.sh`）—— 当前生成器**不会**产出上面两种非法形态**

| 非法形态 | 生成器现状 | 出处（`lib/realm.sh`） |
|---|---|---|
| `remote` 是数组 | `remote` **恒为 string**：`"remote": "${main_target}"` | endpoint 生成段 |
| `balance` 不带权重 | **恒写作** `"$realm_balance_mode: $weight_config"` ⇒ **必带 `: 权重`**；且**只有 ≥2 目标**时才写 `balance` | endpoint 生成段（`active-standby` 会被映射成 `roundrobin`，权重已是 0/1 序列） |
| 权重个数 ≠ 目标数 | 三条路径都保证个数相等：① **主备路径按目标顺序重新生成 0/1 权重**（一目标一权重）② **剔除模式按保留下来的目标下标切权重**，权重数组不够时补 `1` ③ **无存储权重时按目标数生成等权 `1`** | 端口组处理段 |

⇒ **结论**：这两种 panic 形态**只能来自「手改 `config.json`」或「生成器回归」**，**不是**当前代码的既有行为。
⇒ **但当前没有运行时护栏** —— 一旦 `config.json` 被手改、或生成器被改坏，realm 会**直接 panic 且全站断流**，而**上层看不到任何「配置非法」的提示**。
⇒ Chief 已同步给阿测（加断言）与小编（加生成器保险）—— 本节就是这两件事的**验收侧**。

### A-17.1　★ 硬判据

**判据 1　形态合法（对**生成物**，逐 endpoint 判）**
- `remote` 必须是 **string**（不是数组）。
- `extra_remotes` 必须是 **array**（多目标时存在）。
- `balance` 若存在，必须形如 **`$strategy: $w1, $w2, ...`**（**必带 `: ` 与权重**）。
- **`balance` 的权重个数必须 == 目标数**（目标数 = `remote` 1 个 + `extra_remotes` 的元素个数）。
- 单目标（无 `extra_remotes`）时**不应有** `balance` 字段。

**判据 2　★ 红线：每次配置生成/改动后，必须确认 realm 还活着**
- **不能**把「配置生成成功」当通过 —— **生成成功 ≠ realm 收下了**。
- 必须同时满足：`systemctl is-active realm` 返回 `active` **且** realm 日志里**没有** panic 痕迹。

**判据 3　转发实测（不是只看配置）**
- 配置形态对、realm active，**仍不等于**流量通 ⇒ 必须**实连一次**并确认有响应。
- ⚠️ 实连的**正确测法见 A-13.1 的判据 5**（后端回一行标识、客户端读那一行）—— **「TCP 连得上」不能当通过**。

**判据 4　负向对照（验生成器保险真的有牙齿）**
- 注入一个**非法** `balance`（如去掉 `: 权重`）⇒ 必须被**拦住**（生成器拒绝写出 / 或写入前被校验拦下）。
- ⚠️ **只在测试机做**，且**先备份 `config.json`**。

### A-17.2　取证命令

```bash
echo "=== 1) 形态核查：逐 endpoint 打印并判定 ==="
jq -r '
  .endpoints[] |
  (.remote|type) as $rt |
  ((.extra_remotes // [])|length) as $xn |
  ((.extra_remotes // [])|type) as $xt |
  (.balance // "") as $b |
  (if $b == "" then 0 else (($b | split(": "))[1] // "" | split(", ") | length) end) as $wc |
  "listen=\(.listen)  remote=\($rt)  extra=\($xt)/\($xn)  balance=\(if $b == "" then "NONE" else $b end)  权重数=\($wc)  目标数=\(1+$xn)" +
  (if $rt != "string" then "   ★FAIL remote 必须是 string（数组形式 → realm panic）" else "" end) +
  (if $xt != "array"  then "   ★FAIL extra_remotes 必须是 array" else "" end) +
  (if $b != "" and ($b | test(": ") | not) then "   ★FAIL balance 必须形如 strategy: w1, w2（不带权重 → realm panic）" else "" end) +
  (if $b != "" and $wc != (1+$xn) then "   ★FAIL 权重个数 != 目标数（→ realm panic）" else "" end) +
  (if $b == "" and $xn > 0 then "   ★多目标却没有 balance 字段（负载均衡未生效）" else "" end)
' /etc/realm/config.json | tee /tmp/balance_shape.txt

grep -q '★' /tmp/balance_shape.txt && echo "★FAIL: 存在非法 balance 形态" || echo "OK: 全部 endpoint 形态合法"

echo "=== 2) ★红线：realm 必须还活着 ==="
systemctl is-active realm && echo "OK: realm active" || echo "★FAIL: realm 未 active（可能 panic）"
journalctl -u realm --no-pager -o short-iso -n 50 \
  | grep -iE 'panic|panicked|backtrace' && echo "★FAIL: realm 日志有 panic" || echo "OK: 日志无 panic"

echo "=== 3) 转发实测（形态对 + realm active 之后仍要做）==="
# ⚠️ 正确测法见 A-13.1 判据 5：后端回一行标识、客户端读那一行
curl -sS --max-time 10 --resolve "test.local:19443" "http://test.local:19443/" | head -1
```

**负向对照（★ 只在测试机做，先备份）**

```bash
echo "=== 4) 负向对照：注入非法 balance，护栏必须拦住 ==="
cp -a /etc/realm/config.json /tmp/config.json.bak

# 方式一（优先）：直接跑生成器，看它是否拒绝产出非法形态
#   —— 生成器保险若已落地，应在写出前就拦住
#
# 方式二（兜底）：手改配置，验证 realm 确实会崩
jq '.endpoints[0].balance = "roundrobin"' /etc/realm/config.json > /tmp/cfg.bad.json
cp /tmp/cfg.bad.json /etc/realm/config.json
systemctl restart realm
systemctl is-active realm || echo "（预期：realm 起不来 —— 证明这条护栏是必要的）"
journalctl -u realm --no-pager -o short-iso -n 20 | grep -iE 'panic|panicked' || true

echo "=== 5) 立即回滚并确认恢复 ==="
cp -a /tmp/config.json.bak /etc/realm/config.json
systemctl restart realm
systemctl is-active realm && echo "OK: 已回滚，realm active" || echo "★FAIL: 回滚后仍异常"
```

**期望结果（可判定，四条全过）**

1. **判据 1**：第 1 步输出里 **没有任何 `★FAIL`** ⇒ 每个 endpoint 的 `remote` 是 string、`extra_remotes` 是 array、`balance` 形如 `strategy: w1, w2`、**权重个数 == 目标数**。
2. **判据 2**：第 2 步 `systemctl is-active realm` = **`active`**，且日志**无 panic**。
3. **判据 3**：第 3 步实连**有响应**，且响应的标识行指明**后端是谁**（见 A-13.1 判据 5）。
4. **判据 4**：负向对照里，**生成器保险把非法形态拦住了**（或 realm 确实崩了 ⇒ 证明这道护栏是必要的）⇒ **回滚后 realm 恢复 `active`**。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| realm `active` 但转发全断 | realm 起来了但**配置非法没被拒** ⇒ 查生成器保险是否落地；查 `journalctl -u realm` 有无 balancer 报错（不一定有 panic 文本） |
| `remote` 变成数组 | 有人手改了 `config.json`，或生成器被改 ⇒ 查 `lib/realm.sh` 的 endpoint 生成段：`remote` 必须恒为 string |
| `balance` 不带权重 | 同上 ⇒ 查 `balance` 的写出处必须恒带 `: $weight_config` |
| 权重个数 ≠ 目标数 | 查端口组处理段的三条路径（主备重生成 0/1 / 剔除模式切权重 / 无权重时等权）是否都被走到 |
| panic 后 realm 起不来 | **立即回滚 `config.json`**（先 `cp -a` 备份）⇒ 恢复后再查是谁改的 |
| 单 endpoint 断但其它 endpoint 正常 | **不是**本项的 panic 形态（panic 是全站断）⇒ 查该 endpoint 的目标解析 / 权重 |

**危险动作**：**手改 `config.json` 会打掉全站转发** ⇒ 改之前 `cp -a` 备份，改完立刻 `systemctl is-active realm` + 实连一次。

## A-18　⚠️ 待产品修复后验证（**本轮新增 —— 不要现在判 FAIL**）

> **为什么单列一节**：Chief 在冻结点 `1190d4c` 上独立核出**产品侧 3 处还没落地 / 落地错方向**的项（已返工给小编）。
> ⇒ **凡是依赖这三项的判据，现在只登记现象，不产出 PASS/FAIL** —— 否则会把**「产品未修」**误判成**「验收不通过」**。

### A-18.1　三处待修项（审稿已独立复核，结论与 Chief 一致）

| # | 待修项 | **状态（2026-10-24 22:5x 复核）** | 影响哪些判据 |
|---|---|---|---|
| **1** | **状态继承键** —— 正确口径是 **(RULE_ID, 目标地址) 组合键** | 🟡 **跨轮读端已修 ✅**（`43c135a`）：`lib/health.sh` 的 `health_status_find_row` 现在是 **4 参**，匹配处有 `if [ "$_rid" != "$rule_id" ]; then continue; fi`，调用点传了 `$RULE_ID`，生成物里的抽取副本一致 ⇒ **原「`target_key` 是死变量」的缺陷已消除**。<br>🔴 **读端仍未修**：`lib/realm.sh` 的 `generate_endpoints_from_rules` 建键仍是 `health_status["${_row_target}:${_row_port}"]` / `health_status["$_row_target"]`（**不含 RULE_ID**）⇒ **两条规则共用同一后端时同一个 key 被后读覆盖** ⇒ 切换判断（查 `health_status[$_t]`）可能拿到**522b处**的 failed ⇒ **误继承 = 误切**（危险方向）。<br>⇒ **本项仍需修**（请小编把读端一并对齐） | **A-16 判据 3**（同地址但不同 RULE_ID ⇒ 不继承）、**A-16 判据 5**（读端归属，**新增**）、A-16 判据 2、A-14 |
| **2** | **探测产物重生成失败没有 fail fast** | ✅ **已修**（审稿复核 HEAD 现状）：**安装路径**（`xwPF.sh`）失败时● 打印醒目错误 + **可执行的修复步骤** + **写日志**（`health_regenerate_log_failure` → `/var/log/xwPF/health-regenerate.log`）+ **「安装中断」** + **`exit 1`**（非 0 退出）。<br>**升级路径**（`lib/update.sh`）⇒ **用 grep 判「能力是否存在」**：有 `health_check_script_regenerate` 则**必须成功**，没有（老版本/降级）则**跳过不算失败**（免得老机器升级被误判）；失败时也写日志 + 打印修复步骤。<br>⚠️ 原来那两处「失败不中断」的注释口径已随代码一并改掉 | **A-14**（产物是不是新的）；**A-13.1 判据 3**（`[CONFIG]` 日志）；**A-3** |
| **3** | **探测超时预算** —— 新建规则仍是 3 秒 | ✅ **已修**（`05b5ebb`：`fix(rules): 新建规则的探测超时预算统一到 10 秒（规则模板 + 探测调用 + OCR 脚本））。审稿复核：`lib/server.sh` 两处模板、`lib/rules.sh` 的探测调用、`xw_realm_OCR.sh` 均已是 **10**；`lib/health.sh` 的健康检查体与参数取值也是 **10** ⇒ **全仓再无 3 秒落点**（剩下的四处是老规则文件 3→10 的**迁移模式**，不是默认值，保留对**）；还顺手同步了 3 份 docs 的口径。<br>⚠️ **但这直接影响已实测值**：预算从 3 秒抬到 10 秒 ⇒ **失败判定必然更慢** ⇒ **「故障检测耗时 30 秒」是旧预算口径下的过期值 ⇒ 真机必须重测** | **A-6.1 ①**（实测值需重测）、**A-13.2 R1**（切换耗时） |

### A-18.2　验收处置口径（**照这条走，不要自行改口径**）

| 情形 | 处置 |
|---|---|
| 判据依赖上述**任一**待修项 | **只登记现象**（实测值 + 原文），**不判 PASS、也不判 FAIL**，标「**待产品修复后验证**」 |
| 现象本身**明显违背**不变式（例：同 target 出现两行、realm 不 active、`balance` 形态非法） | **照常判 FAIL** —— 这些与待修项无关 |
| 实测值带前提 | **必须连同前提一起记**（例：检测耗时 30 秒 **必须**注明当时的 `CONNECTION_TIMEOUT` 是 3 秒）⇒ **前提变了，实测值就不再是判据** |
| 待修项落地后 | 重新跑一遍对应判据，**再**产出 PASS/FAIL；**不要**沿用修复前的观察 |

> **⚠️ 纪律**：**「产品还没修」不等于「验收不通过」。** 判 FAIL 之前先问：**这一条依赖的是「已修好」还是「还在修」？**

### A-18.3　三条待修项落地后的复验清单

```bash
echo "=== ① 继承键：组合键落地了吗（RULE_ID + 目标地址 都要对上）==="
# 修好后：同地址不同规则之间不应互相继承；同规则同地址跨轮应继承
grep -n 'target_key\|health_status_find_row' /etc/realm/health/health_check.sh

echo "=== ② 产物重生成：失败会不会 fail fast ==="
# 装/升级时故意让生成失败（改权限），看退出码是不是非 0
systemctl is-active realm-health-check.timer
journalctl -u realm-health-check.service --no-pager -o short-iso -n 20 | grep -i '生成\|regenerat'

echo "=== ③ 超时预算：新建规则的 CONNECTION_TIMEOUT 是多少 ==="
grep -H '^CONNECTION_TIMEOUT=' /etc/realm/rules/rule-*.conf
# 判据：新建规则的 CONNECTION_TIMEOUT 应为 10（不是 3）
```

### A-18.4　★ 台架用例 ↔ 验收项对照表（审稿 ↔ 阿测 对号入座）

> **来源**：阿测 2026-10-24 报的台架编号占用。**台架是 `tests/**`（阿测的地盘），审稿只读不改**；这张表只做**映射**，让两边说的能对上。
> **编号占用**：T63–T67（N5 质量只观测）／ T68–T76（切换可靠性 9 组）／ T77–T84（权重 10 独占）／ T85–T88（N4 探测端）；**T55–T62 留空**（作废项不占号）；T01–T54 为历史登记。

| 验收项 | 台架用例 | 对应关系 |
|---|---|---|
| **A-13.0**（探测准入三条件） | **T68** | 准入三条件并进 T68 的判定 |
| **A-13.1**（五步判据链 / 断言产出物） | **T72** | 断言落在**状态文件 + 权重 balance** 上，不看脚本绿灯 |
| **A-13.1**（切换可靠性 9 组） | **T68–T76** | 进得了主备 / 切得走（达阈值才切）/ 切得回（冷却期没到必须切不回）/ 抖动不反复切 / 探测端真在探测（`LAST_CHECK` 必须前进）/ 不误切（慢但未断不得切）/ 不继承老状态 / 不留半拆半装 / 目标集合一致 |
| **A-14**（探测端确实在探测） | **T85–T88** | N4 探测端那组 |
| **A-16**（删规则后状态不残留 / 不过户） | **T86**（孤儿行 = 0）、**T87**（继承语义） | ⚠️ **T87 的方向已更正**（组合键口径）—— 见下方「用例方向三条要求」 |
| **A-17**（`balance` 形态合法 · realm 存活） | 待阿测补断言 | Chief 已同步阿测加断言 |

**★ 用例方向三条要求（2026-10-24 审稿 → 阿测，已发）**
1. **T87 要精确化**：必须是「**同 RULE_ID + 不同目标地址**」才不继承；**同 RULE_ID + 同目标地址 ⇒ 应当继承**（同一个后端）。
2. **「同地址被继承 = 刻意设计 = 不判 FAIL」作废** ⇒ 现在的口径是「**同地址但不同 RULE_ID ⇒ 不继承**」。
3. **「同一 target 出现两行」本身不是缺陷**（两条不同规则合法共用同一后端时本就该两行）⇒ 真正判 FAIL 的是「**同一条规则（RULE_ID）** 对同一 target 两行」⇒ 去重要按 **(RULE_ID, TARGET) 组合**，不是只按 target。

**★ 不补的台架（已确认）**：**崩溃循环防护**（守护进程 / `StartLimit` / `DROPIN_DIR` / `crash.loop`）—— 已随进程级主备池**整块删除** ⇒ 补了就是**测一个不存在的东西 = 给假信号** ⇒ **全仓 0 命中是符合现状，不是覆盖空洞**。

## 11. 最小化 Debian 兼容性矩阵

**为什么需要矩阵**：`lib/core.sh` 的 `REQUIRED_TOOLS` 只保证 `curl wget tar grep cut bc jq openssl python3`；`nc` **不在**清单内（健康检查已不依赖它，但**仍依赖 `timeout`**——属 coreutils，极简镜像也基本都有）。`jq` 缺失会让 `lib/core.sh` 的 `generate_network_config` / `lib/rules.sh` 的 `proxy_management_menu` 里的 config.json 合并退化。

| 变量 | 取值 | **必跑**项 | 该组合的重点观察 |
|---|---|---|---|
| **netcat-openbsd** | 装了（`apt-get install -y netcat-openbsd`） | A-1 A-3 A-5 A-6 A-8 **A-Y** **A-16** **A-17** | 探测走 nc 分支；确认 `nc -h 2>&1 \| grep -q -- '-z'` 在**本机 nc 版本上返回真**（能力探测靠匹配帮助文本）；**A-17** 查 `balance` 形态与 realm 存活 |
| | **不装**（或 busybox nc） | **A-7** + A-5 A-6 **A-Y** **A-16** **A-17** | 必须靠 `bash /dev/tcp` 回退；**任何目标都不能被误判 failed**（A-Y 正是「一个坏了不能把另一个也带坏」的加强版）；**A-16** 同样要跑（它要的是「探测端跑过一轮后状态文件收敛」，与 nc 分支无关）；**A-17** 与 nc 分支无关，但**每次改配置都要跑** |
| **jq** | 装了 | 全部 | 基准 |
| | **不装** | A-1 A-2 A-9 A-10 | ① 安装器应**自动补装**（在 REQUIRED_TOOLS 里）；② 故意不装时，`config.json` 的 network 段合并会退化 → 查 `lib/core.sh` 的 `generate_network_config` 里 `2>/dev/null \|\| echo "{}"` 兜底是否留下残缺配置 |
| **systemd 版本** | Debian 11（systemd 247） | A-3 A-8 A-9 **A-X** **A-16** **A-17** | `journalctl --vacuum-time=7d --dry-run` 需 systemd ≥ 230（247 满足）；timer `OnUnitActiveUSec` 行为（**A-X 与 A-16 都要靠 timer 跑完一轮**：A-X 看老行迁移、A-16 看状态文件收敛）；**A-17** 看 `systemctl is-active realm` 与 journal 的 panic 痕迹 |
| | Debian 12（systemd 252） | A-3 A-8 A-9 **A-X** **A-16** **A-17** | 基准；`systemctl show -p` 字段名有微调 |
| | Ubuntu 22.04（systemd 249） | A-3 A-8 A-9 **A-X** **A-16** **A-17** | `systemd-analyze verify` 对 unit 的校验更严 |
| **shell** | `sh`（dash）调用 | A-1 A-3 | 所有 `.sh` 入口必须带 `#!/bin/bash`；`sh xwPF.sh install` **应明确失败**而不是半跑 |
| | `bash`（Debian 默认 5.2） | 全部 | 基准 |

**矩阵最小建议组合**（资源有限时至少跑这 4 组）：

1. Debian 12 + netcat-openbsd + jq　→ 基准全绿
2. Debian 12 + **无 nc** + jq　→ A-5 A-6 A-7（**回退路径**）
3. Debian 11 + netcat-openbsd + jq　→ A-3 A-8 A-9（**旧 systemd**）
4. Debian 12 + netcat-openbsd + **无 jq**　→ A-1 A-9（**自动装依赖**）

**每组跑完必须记录**：`~/realm-acceptance/baseline.txt`（OS/systemd/依赖）+ 各项 PASS/FAIL + 失败现象原文。

---

## 12. 结果记录模板

| 项 | 目标 | 结果 | 现象 / 证据 | 备注 |
|---|---|---|---|---|
## A-Z　非交互环境（管道 / 后台 / cron）下 `pf` 必须快速退出且输出量有上限

**验收目标**：stdin **不是终端**时执行交互菜单，必须**自己**退出（不是靠 `timeout` 才结束），退出码 0，且**输出字节数有上限**。

**前置**：A-1 已完成。本项**只读** —— 不改配置、不重启服务、不碰规则文件。

**为什么单列这一项**：`read` 在 stdin 是 EOF 时**立刻返回非 0**（不阻塞）→ 读到的变量为空 → `case` 不匹配任何分支 → 回到 `while true` 顶部 → **无限重绘 + 忙循环 + 无界输出**。`/tmp` 在真机上是 tmpfs（吃的是内存），无界输出会把它灌满 → 内存 + swap 耗尽 → **sshd 握不上手，整机被压垮**。这是本项目的真实事故，不是理论风险。

**判据**（四条都要满足）：

| 判据 | 期望 |
|---|---|
| 退出方式 | **自己**退出 —— 退出码 **≠ 124**（124 = 被 `timeout` 杀掉 = 还在忙循环） |
| 退出码 | 0 |
| 输出字节数 | 有上限（上限取 **64 KB**；无界输出会到几百 KB 量级） |
| 输出内容 | 非空，且命中入口提示语（防空过：根本没跑起来也会表现为「输出很小」） |

**命令**

```bash
# ① 非 TTY：stdin 是 /dev/null
timeout 5 bash /usr/local/bin/xwPF.sh < /dev/null > /tmp/acc-z.out 2>&1
rc=$?
echo "rc=$rc bytes=$(wc -c < /tmp/acc-z.out)"

# ② 用法输出走的是另一条分支，仍然正常
timeout 5 bash /usr/local/bin/xwPF.sh --help < /dev/null > /tmp/acc-z-help.out 2>&1
echo "rc=$? bytes=$(wc -c < /tmp/acc-z-help.out)"

# ③ 首屏提示
head -3 /tmp/acc-z.out

# ④ 防空过：确认落盘产物没有 CRLF（CRLF 会让 bash 第一行就报错退出，
#    表现为「输出很小、也退出了」，其实是根本没跑起来）
for f in /usr/local/bin/xwPF.sh /usr/local/bin/lib/*.sh; do
  if grep -q $'\r' "$f"; then echo "FAIL-CRLF: $f"; else echo "OK: $f"; fi
done
```

**失败排查**

| 现象 | 原因 | 处置 |
|---|---|---|
| `rc=124`（被 `timeout` 杀掉） | 菜单入口的 TTY 护栏没生效，或读入没做 EOF 处理 → 忙循环 | 检查 `lib/core.sh` 的 `ui_require_tty` 与 `ui_read_into`；菜单里不得出现裸 `read` |
| 输出字节数很大（几十 KB 以上） | 同上，无界输出 | 同上 |
| 输出为空 / 只有一行报错 | 根本没跑起来（路径错，或落盘产物是 CRLF 导致 bash 解析失败） | 先 `bash -n`；再查 `grep -c $'\r'` |
| 管道里喂数字进不了菜单 | **这是有意的行为变更**（见下），不是缺陷 | 需要交互就在真终端里跑 |

**适用范围说明（重要）**：本项只约束 **stdin 不是终端**的场合。**真终端（TTY）下的交互不受影响** —— 菜单照常显示、照常能选数字、照常能进子菜单。

**与 A-2 的关系**：A-2 验 `pf --help` 的三种写法与退出码；A-Z 验的是**无参 `pf` 在非 TTY 下**的行为。两者走的是不同分支（`--help` 显式处理，非 TTY 时不落进菜单），不要用 A-2 的结论覆盖 A-Z。

---

| A-1 | 一键安装落盘 | ☐PASS ☐FAIL ☐BLOCKED | | 重点：落盘文件含 CR 数 = |
| A-2 | `pf --help` | ☐PASS ☐FAIL ☐BLOCKED | | 三种写法退出码 |
| A-3 | 权重 1,0 → 主备 + timer | ☐PASS ☐FAIL ☐BLOCKED | | timer enabled/active |
| A-4 | 状态文件格式 | ☐PASS ☐FAIL ☐BLOCKED | | 字段数 = / TARGET 口径 = / FMT-MATCH = |
| A-5 | 主断 → 权重 0,1 | ☐PASS ☐FAIL ☐BLOCKED | | 翻转耗时 |
| A-6 | 主恢复 → 权重 1,0 | ☐PASS ☐FAIL ☐BLOCKED | | 冷却期是否生效 |
| A-7 | 无 nc 靠 /dev/tcp | ☐PASS ☐FAIL ☐BLOCKED | | 误判 failed 的目标数 = |
| A-8 | journal + vacuum | ☐PASS ☐FAIL ☐BLOCKED | | 四类标记是否齐全 |
| A-9 | 卸载残留清理 | ☐PASS ☐FAIL ☐BLOCKED | | 残留 unit / 进程数 = |
| A-10 | ~~xwpf-failover 热切换~~ | **⛔ 已废弃删除，不再验** | | 功能已废弃（见该节状态说明） |
| A-11 | 保留路径一：单端口中转 | ☐PASS ☐FAIL ☐BLOCKED | | 无 WEIGHTS 行 = / balance 是单值 = |
| A-12 | 保留路径二：负载均衡 5,5 | ☐PASS ☐FAIL ☐BLOCKED | | 权重序列 = 5,5 / 两后端都收到请求 = |
| A-13 | 保留路径三：权重 10,0 主备（**重心**） | ☐PASS ☐FAIL ☐BLOCKED | | active-standby + FAILOVER_ENABLED=true / timer enabled+active / **R1 切换耗时（实测，写来源）** / R2 备未跟着挂 / R3 冷却期生效 / R4 无需人工干预 |
| A-14 | 健康探测端确实在探测 | ☐PASS ☐FAIL ☐BLOCKED | | **两次读取的最后检查时间必须不同** / 生成物与真源一致 / 无已删规则残留行 |
| A-15 | 老机器残留清理 | ☐PASS ☐FAIL ☐BLOCKED | | **7 个路径全部不存在** / 18443+18444 不再被监听 / 无残留进程 / **保留路径未被误伤** |
| A-16 | 删规则后状态不残留、不过户 | ☐PASS ☐FAIL ☐BLOCKED | | **孤儿行数 = 0** / 不跨地址继承 / **同一条规则对同一 target 不得两行** / 取样前探测端**已跑过一轮** ｜ **「同地址被继承」= 待产品修复后验证**（组合键 `43c135a` 已修跨轮读端）｜ **判据 5 读端归属 = 待产品修复后验证** |
| A-17 | ★ **`balance` 形态合法 · realm 存活** | ☐PASS ☐FAIL ☐BLOCKED | | `remote`=string / `extra_remotes`=array / `balance`=**`strategy: w1, w2`** / **权重数 == 目标数** / **`systemctl is-active realm` = active** / 日志**无 panic** / **实连有响应** ｜ **权重 0 × iphash 组合 = 未覆盖**（不判 PASS） |
| A-18 | ⚠️ **待产品修复后验证** | ☐PASS ☐FAIL ☐BLOCKED | | ① 继承键：**跨轮读端 ✅ / 读端 ❌**（`lib/realm.sh` 建键未带 RULE_ID）② 产物重生成 fail fast **✅ 已修** ③ 超时预算抬到 10 **✅ 已修**（`05b5ebb`）｜ **仍待修的只有 ① 的读端**；**③ 已修 ⇒ 30 秒那个实测值已过期，真机需重测** |
| A-X | 旧格式状态文件 → 仍能切换 | ☐PASS ☐FAIL ☐BLOCKED | | 老故障没被洗白 = / 迁完字段数 = |
| A-Y | 同 host 两端口 → 互不覆盖 | ☐PASS ☐FAIL ☐BLOCKED | | 坏一个另一个仍 healthy = / 两形态各记一次 |
| A-Z | 非 TTY 下 pf 快速退出 | ☐PASS ☐FAIL ☐BLOCKED | | rc≠124 / rc=0 / bytes≤64K / 输出命中入口提示语 |

**缺陷单请直接交 Chief 路由**（按第 1 轮约定：审稿只出报告与清单，不改 `lib/`、`tests/`、`docs/`、`xwFailover.sh`）。

---

## 附：归档期间的门禁实测基线（供对照）

以**唯一入口** `tests/run_tests.sh`、从**干净 clone + 指定 SHA checkout** 实测（不是工作区）：

| SHA | 退出码 | 结果 | 说明 |
|---|---|---|---|
| `2244886` | 1 | 22 条 / 通过 14 / 失败 8 | 失败：T02 T05 T06 T07 T16 T17 T20 T22 |
| `a9102c1` | **0** | **22 条 / 全过** | 8 条红已由 `4558e65` 修掉 |
| `9d49653` | 0 | 22 条 / 全过 | |

> **但门禁全绿 ≠ 缺陷已修**：截至 `a9102c1`，第 1 轮报告的 **B2（`source` 注入）/ B4（`TARGET_STATES` 未清）/ 探测函数三份拷贝**仍然成立，且**唯一性守卫（`check_connectivity() {` 出现次数 == 1）尚未落地** —— 见 `reports/round1-baseline-review.md` 附录 A-2、A-3。
