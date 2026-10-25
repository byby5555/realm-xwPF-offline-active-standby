# 真机 103 收尾执行单（执行用单子）

> **本单是 `reports/real-machine-acceptance.md`（真机验收清单，下称「清单」）的执行用摘要**：
> 只给**顺序、可粘贴命令、判据出处**，**不复制清单正文**；**判据与清单冲突时以清单为准**。
> 本单的命令段已由审稿逐条**对过清单正文与产品实现**（`lib/ui.sh` 的 `_cleanup_legacy_failover_daemon`），
> 对账结论在文末「§13 对账结论」——**与执行单原稿有 12 处差异，已在正文就地更正**。
>
> ⚠️ **本单已更正过一次（审稿自己判错）**：原 §11「展示端符号」一条**已撤回**（符号确实存在于产品里，
> 是审稿的 grep **输出被截断**造成的假阴性）⇒ **以 §11 现在的正文为准**；`reports/correction-quality-window-display.md`
> 那份更正文件里的**成因归因**也不准确 ⇒ **成因以 §11 为准**。

---

## §0 使用前提、已知阻塞与本单的边界

1. **★ 本轮真机复测尚未执行** —— Chief 侧凭据（root 口令 + 公钥 + 真实主/备上游地址）未提供 ⇒
   **本单是「待执行件」，不是实测记录**：里面没有一条结论是审稿在真机上跑出来的。
2. **端口按 103 真机**：旧池 `18443`、直连池 `18444`。
   （清单 A-13.3 的示例端口 `19443` 是 Chief 那轮用的临时端口，**本单一律改成 18443/18444**。）
3. **判据出处一律引清单小节名**（如「清单 A-15 第 5 条」），**不写行号** —— 清单行号会随修订漂移。
4. **★ 执行前先备份**（清单 A-15「危险动作」栏）：

   ```bash
   # 卸载/清理会改转发配置、甚至删全部规则 ⇒ 先备份这两处
   tar czf /root/xwpf-103-backup-$(date +%Y%m%d-%H%M%S).tgz /etc/realm /etc/xwpf 2>/dev/null
   ls -l /root/xwpf-103-backup-*.tgz
   ```

   ⚠️ 清单原文：「升级会改转发配置 ⇒ 先备份 `/etc/realm`、`/etc/xwpf`；卸载会删全部规则与配置 ⇒ 确认是测试机或已备份。」

---

## §1 取证快照（改任何东西之前）

> 判据出处：清单 A-15 的「升级前快照（留证）」；「已知现状」来自 Chief 侧观测（**审稿未独立复现**）。

```bash
echo "=== 现状快照（留证）==="
systemctl is-enabled xwpf-failover; systemctl is-active xwpf-failover
systemctl show xwpf-failover -p NRestarts -p ExecMainStartTimestamp
systemctl list-unit-files | grep -E 'xwpf-failover' || echo NO-UNIT-FILE
ss -lntp | grep -E ':(18443|18444)\b' || echo NO-LISTEN
ls -la /etc/xwpf/ 2>/dev/null || echo NO-CONF-DIR
ls -ld /etc/systemd/system/xwpf-failover.service.d/ 2>/dev/null || echo NO-DROPIN-DIR
sha256sum /etc/xwpf/failover.json /etc/xwpf/failover-state.json 2>/dev/null
ls -la /etc/systemd/system/xwpf-failover.service* /lib/systemd/system/xwpf-failover.service* 2>/dev/null
ls -la /usr/local/bin/xwpf-failover /usr/local/bin/.xwpf-failover-version 2>/dev/null
ls -la /usr/local/bin/cmd/ 2>/dev/null || echo NO-CMD-COPY-DIR
```

**已知现状（Chief 侧观测，执行时须复核）**：老守护仍 `enabled + active`，占着 `18443`/`18444`；
`/etc/xwpf/failover.json` 在；`NRestarts=0`（历史重启风暴已被 drop-in 限流掐断）⇒ **当前无重启循环**。

---

## §2 先迁流量，再卸守护（顺序不可反）

> 判据出处：清单 A-15 第 7 条 + A-13.0 + A-13.3。

**为什么不可反**：守护一停，`18443`/`18444` 立刻不再监听；而**「主备池管理」入口已随功能整块下线**
（`2beb7bd`），**没有建池入口**能把它重建回来 ⇒ **先卸后迁 = 转发当场断**。

### 2.1 下发权重并确认形态（清单 A-13.3）

```bash
echo "--- 下发权重 10,0（主位 10 / 备位 0）---"
source /usr/local/bin/lib/rules.sh
apply_port_group_weight_config 18443 "10,0" 1

echo "--- 规则形态必须是「一条规则两个目标 + ROLE=1 + 故障转移开」---"
grep -H -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS|TARGET_STATES|RULE_ROLE)=' /etc/realm/rules/rule-*.conf

echo "--- 生效权重应为 10,0 ---"
jq -r '.endpoints[].balance' /etc/realm/config.json

echo "--- 探测端 timer 必须已拉起（探测端没起来就永远不会切换）---"
systemctl is-enabled realm-health-check.timer
systemctl is-active  realm-health-check.timer
```

**形态判据（清单 A-13.0 / A-13.3，硬约束）**：`BALANCE_MODE=active-standby`、`FAILOVER_ENABLED=true`、
权重序列 = `10,0`、`realm-health-check.timer` = `enabled` + `active`、
规则形态 = 一条规则两个目标 + `RULE_ROLE=1`。
⚠️ **形态不对 ⇒ 切换完全不工作且完全静默**（清单 A-13.0：日志里连一句失败都没有）。

### 2.2 实测转发真的通（清单 A-13.1 判据 5 的「实连测法」）

⚠️ **「TCP 连得上」不算通过** —— realm 接受连接后可能立刻断，会把**健康的**转发判成失败
（Chief 第一轮就踩了这个坑，**测法错了、产品是好的**）。**正确测法 = 后端回一行标识、客户端读那一行。**

```bash
# 客户端读回的那一行标识 = 落到哪个后端
curl -sS --max-time 10 --resolve "test.local:18443" "http://test.local:18443/" | head -1
# 期望：主后端的标识
```

★ **别把这里和 §7 的切换后实连混为一谈**：本步验的是「**迁到权重路径后流量通**」，§7 验的是「**故障后流量落到备位**」。

---

## §3 停守护（清单 A-15 的清理动作 1）

```bash
systemctl stop xwpf-failover
systemctl disable xwpf-failover
```

★ **补一步（原执行单漏了）—— 兜底杀残留进程**：产品实现 `lib/ui.sh` 的 `_cleanup_legacy_failover_daemon`
在 `stop`+`disable` 之后**还有一段兜底**（不在 systemd 管辖下的残留进程仍会占着 `18443`/`18444`）：

```bash
# 照抄产品的 pgrep 排除法：排除自身、父进程、pid 1
_self=$$; _ppid=${PPID:-0}
for _pid in $(pgrep -f "xwpf-failover" 2>/dev/null); do
  [ "$_pid" = "$_self" ] && continue
  [ "$_pid" = "$_ppid" ] && continue
  [ "$_pid" = "1" ] && continue
  if [ -r "/proc/$_pid/cmdline" ]; then
    case "$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)" in
      *xwpf-failover*) ;;
      *) continue ;;
    esac
  fi
  kill "$_pid" 2>/dev/null && _killed=1
done
```

⚠️ **不要用 `pkill -f "xwpf-failover"`** —— 它按**整条命令行**匹配，会把调用它的 shell、用户的 `grep`/`tail`、
甚至 `bash -c` 那一层一起杀掉 ⇒ **自杀会让清理半途而废**（unit 还没删、退出码诡异），比不清理更糟
（产品实现里专门写了这条注释）。

---

## §4 删残留（清单 A-15 第 1 条的 7 个路径）

```bash
# 4.1 unit 文件（两处：产品实现的 unit 与 unit_alt 都删）
rm -f /etc/systemd/system/xwpf-failover.service
rm -f /lib/systemd/system/xwpf-failover.service

# 4.2 drop-in 目录（崩溃循环防护那几行在里面）—— 整个目录
rm -rf /etc/systemd/system/xwpf-failover.service.d/

# 4.3 守护二进制
rm -f /usr/local/bin/xwpf-failover

# 4.4 版本指纹
rm -f /usr/local/bin/.xwpf-failover-version

# 4.5 守护源文件副本（清单列的是这两个文件；★ 建议先看清目录内容再决定，见下）
ls -la /usr/local/bin/cmd/ 2>/dev/null
rm -f /usr/local/bin/cmd/xwpf-failover.py /usr/local/bin/cmd/xwpf-failover.service

# 4.6 让 systemd 忘掉被删掉的 unit
systemctl daemon-reload
```

★ **两处与原执行单/清单的差异（以产品实现为准）**：
- **两处 unit**：`/etc/systemd/system/` 与 `/lib/systemd/system/` **产品实现两处都删**
  （`lib/ui.sh` 的 `_cleanup_legacy_failover_daemon` 的 `unit` 与 `unit_alt` 两个变量）⇒
  清单 A-15 第 1 条**只列了 `/etc/systemd/system/` 一处**（**清单漏列一处，已登记**）。
- **源文件副本**：清单 A-15 第 1 条列的是 `/usr/local/bin/cmd/xwpf-failover.py` / `.service` **两个文件**，
  而**产品实现根本没有删 `cmd/` 这一步**（清理函数只处理 unit / drop-in / 二进制 / 版本指纹 / 池配置改名）⇒
  原执行单那句「整个 `/usr/local/bin/cmd/` 目录删掉」**比清单和产品都宽** ⇒
  **本单改为只删那两个文件**；若确要删整个目录，先 `ls -la` 确认里面没有别的东西。

---

## §5 池配置：改名留档 + 登记（清单 A-15 第 5 条）

```bash
# 5.1 改名留档（不删）：与产品实现同名同做法
[ -f /etc/xwpf/failover.json ]       && mv -f /etc/xwpf/failover.json       /etc/xwpf/failover.json.disabled
[ -f /etc/xwpf/failover-state.json ] && mv -f /etc/xwpf/failover-state.json /etc/xwpf/failover-state.json.disabled

# 5.2 登记（验收口径第 2 条，硬要求：文件名 + 大小 + 时间）
stat -c '%n %s %y' /etc/xwpf/*.disabled
```

★ **顺序硬约束**：这一步必须排在**任何会删 `/etc/xwpf` 的动作之前** ——
`docs/install-and-upgrade.md` 的「手工兜底（菜单不可用时）」小节里有
`rm -rf /etc/realm /etc/xwpf /usr/local/bin/lib /usr/local/bin/cmd`
⇒ **照做那一段会把留档连目录一起抹掉**（该缺陷已另行派给小编修；**修好之前，先改名留档再动别的**）。

⚠️ **手工路径不会自动留档**：改名留档这件事，产品是在 `xwPF.sh` 的 install 分支与 uninstall 分支、
以及菜单项 8「卸载服务」里调 `_cleanup_legacy_failover_daemon` 顺带做的
⇒ **若真机走的是手工兜底、没经过 install/uninstall ⇒ 这一步没人替你做 ⇒ 必须自己补做**。

---

## §6 验收三条（清单 A-15 第 5 条 · 与「删/不删」决策无关，只钉行为）

| # | 判据 | 怎么核 |
|---|---|---|
| 1 | **不得有活配置**：生效中的 `/etc/xwpf/failover.json` 不存在 | `ls /etc/xwpf/failover.json` ⇒ 不存在 |
| 2 | **留档允许但须登记**：`.disabled` 可存在，已登记（名 + 大小 + 时间） | §5.2 的 `stat` 输出进验收记录 |
| 3 | **`/etc/xwpf` 目录保留不删** | `ls -ld /etc/xwpf` ⇒ 目录仍在 |

**反例（判红）**：`/etc/xwpf` 目录被整个删掉、或 `failover.json` 仍以原名存在并生效。

---

## §7 A-15 复核（清单 A-15 期望结果 1–4、6）

```bash
echo "--- 1) 进程：不得有残留守护进程 ---"
pgrep -af 'xwpf-failover' && echo "★FAIL: 守护进程还在跑" || echo "OK: 无守护进程"

echo "--- 2) 端口：18443 / 18444 不得再被监听 ---"
ss -lntp | grep -E ':(18443|18444)\b' && echo "★FAIL: 旧端口仍被占用" || echo "OK: 无旧监听"

echo "--- 3) unit 文件：list-unit-files 里也不该有（★原执行单漏了这条）---"
systemctl list-unit-files | grep -E 'xwpf-failover' && echo "★FAIL: 仍有 unit" || echo "OK: 无 unit"

echo "--- 4) 保留路径未误伤（★原执行单只写了一句、没给核法；误伤=阻断级问题）---"
systemctl is-enabled realm-health-check.timer
systemctl is-active  realm-health-check.timer
ls -l /etc/realm/health/ 2>/dev/null || echo "★FAIL: 探测端目录被清"
grep -H -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS|TARGET_STATES|RULE_ROLE)=' /etc/realm/rules/rule-*.conf
jq -r '.endpoints[].balance' /etc/realm/config.json
```

**保留路径判据（清单 A-15 第 6 条）**：`realm-health-check.timer`、`/etc/realm/health/`、
权重主备的规则与 `config.json` **不受损** ⇒ 若被清掉 ⇒ **保留路径被误伤 = 阻断级问题**。

---

## §8 A-13 主备切换：五步链 + 四条附加判据（清单 A-13.1 / A-13.2）

### 8.1 五步链（每一步都要断，**不能看脚本绿灯**）

```
① 停主后端
   ↓
② 探测连续失败达阈值 → 状态文件里该目标变 failed
   （FAIL_COUNT 达阈值 + FAILURE_START_TIME 被记上）
   ↓
③ 探测脚本调 pf --restart-service（写回链路）
   ↓
④ 重新生成的 config 里权重翻转：承载主的从 1 变 0、承载备的从 0 变 1
   （★ 判据是「主位↔备位」这个关系，不是那个字面量）
   ↓
⑤ realm 重启后实连该端口 → 流量落到备后端
```

```bash
echo "--- 判据 1：目标在状态文件里，且 LAST_CHECK 是本轮时间戳 ---"
date +%s
grep -v '^#' /etc/realm/health/health_status.conf

echo "--- 判据 2：主故障后状态变 failed（FAIL_COUNT>=2 且 FAILURE_START_TIME 非 0；备那行必须仍 healthy）---"
kill "$(cat /tmp/acc-a.pid)"     # 杀主后端
sleep 60                         # ★ 必须等 ≥ 60 秒（清单原文要求；预算抬到 10 秒后检测会变慢）
grep -v '^#' /etc/realm/health/health_status.conf

echo "--- 判据 3：写回链路（★ 现在分成两行，必须看是哪一行）---"
journalctl -u realm-health-check.service --no-pager -o short-iso -n 50 \
  | grep -E '\[CONFIG\]|\[FAILURE\]|\[RECOVERY\]'
#   「[CONFIG] 配置更新完成」                          ⇒ 本步通过
#   「[CONFIG] 配置更新失败（重启返回码 N）—— 权重可能未生效」⇒ 本步 FAIL
#     （且这属于「切换发生了但没成功」，不是「切换没发生」）
#   只看到 [CONFIG] 四个字就判通过 = 假绿

echo "--- 判据 4：权重翻转（钉主位↔备位关系，不钉字面量）---"
jq -r '.endpoints[].balance' /etc/realm/config.json

echo "--- 判据 5：★ 实连读回的那一行标识 = 备后端标识（这才是「切换成功」的证据）---"
curl -sS --max-time 10 --resolve "test.local:18443" "http://test.local:18443/" | head -1
```

### 8.2 四条附加判据（清单 A-13.2 · **原执行单未收**）

| # | 判据 | 要点 |
|---|---|---|
| **R1** | **切换耗时可复现** | 从「杀掉主监听」到「权重翻到备上（主位 0、备位 1）」的**实测间隔**记进验收记录，**必须写来源**（起止时间戳 + 复现命令）。⚠️ **不要**把理论下限 8 秒或验收用的 `sleep 140` 当实测值写进结论 ⇒ 拿不到就写「待补」 |
| **R2** | **备机不跟着挂** | 主挂时状态文件里备那行必须仍是 `healthy`；两目标都 `failed` ⇒ 走全挂兜底 ⇒ **权重不翻、流量压在已故障主机** = 静默失效 |
| **R3** | **恢复后不立刻翻回** | 判据 = **「恢复后立刻读，权重仍在备上（主位 0、备位 1）」**，**不是**「必须是 120 秒」 |
| **R4** | **切换不需要人工干预** | 切换是「健康检查写回权重 → 重生成 `config.json` → 重启 realm」自动完成的；出现「要手工干预才对」⇒ 链路断了 |

### 8.3 分诊：必须能分开「切换失败」与「切换没发生」（清单 A-13.4）

- **切换失败** = 切换**发生了但没成功**（realm 崩了 / 配置非法 / 转发层坏了）⇒ **可能是阻断级**。
- **切换没发生** = 切换**压根没启动**（探测端没探到 / 形态不对）⇒ **静默失效**，日志里连一句失败都没有。
- ⇒ 判据必须能把两者分开，**否则会把阻断级事故当成「没触发」放过**。

### 8.4 ★ 预期现象，**不得因此判 FAIL**（清单 A-13.1 末段）

权重翻转要**重启 realm 服务**才生效（探测脚本调 `pf --restart-service`）⇒
**切换瞬间有几秒转发中断** —— 这是**机制固有代价**，不是「切换把流量打死了」。
⇒ **验收不得因为这几秒中断判 FAIL**；
⇒ **但必须写进验收记录**：中断窗口 ≈ 几秒（用 realm 的 stop/start 时间戳对上）——
因为它决定**客户端要能容忍多长的不可用窗口**。

---

## §9 A-6.1 两条时间特性：**必须重测**（旧值已过期）

> 判据出处：清单 A-6.1。

- **故障检测耗时**：「30 秒」是**探测超时预算仍为 3 秒**口径下的实测值；
  产品已把预算统一抬到 **10 秒**（规则模板 + 探测调用 + OCR 脚本三个落点全改）⇒
  **30 秒在新代码下不再成立**；「**回切 119 秒**」同理（它也是那一次的实测值，**不是常数**）。
- ⇒ **验收不得拿 30 秒当判据**；「**检测延迟 12~27 秒**」「**回切 46 秒**」是另外两轮实测，同样**只作参考**。

**★ 硬判据（重测时按这两条判，不是按旧实测值判）**：

1. **检测耗时**：**> 60 秒才排查**（探测卡死 / timer 没被调度 / 产物是旧的）；
   8 秒只是理论下限，**不拿它当判据**。
2. **回切**：**回切发生在「故障起始 + 120 秒之后」** + **「恢复后立刻读，权重仍在备上」**。

**★ 重测时必须连带记下当时的 `CONNECTION_TIMEOUT`**（现在应当恒为 10）——
**拿不到来源的数字不写**。

⚠️ **别重犯一次已犯过的实验设计错误**：清单里记着一次「只等了 55 秒就判『没切回』」——
**那是冷却期没等满，属实验设计错误，不是产品缺陷** ⇒
**恢复后必须等过 `RECOVERY_COOLDOWN`（默认 120 秒）再判「没翻回」**。

⚠️ **给用户的话术（验收时必须口头确认）**：**主备切换不是瞬时的** —— 客户端必须能容忍**几十秒**的不可用窗口；
若业务要求秒级切换，**权重路径满足不了**（这是已删守护路径与保留路径的**能力差**，不是配置问题）。

---

## §10 A-14 健康探测端确实在探测（清单 A-14）

```bash
echo "--- timer / service ---"
systemctl is-enabled realm-health-check.timer
systemctl is-active  realm-health-check.timer
systemctl list-timers realm-health-check.timer --no-pager

echo "--- 生成物在位 ---"
ls -l /etc/realm/health/health_check.sh
ls -l /etc/realm/health/health_status.conf

echo "--- 生成物内容必须与真源一致（唯一真源 = lib/health.sh 的 health_check_script_body）---"
grep -c 'check_connectivity' /etc/realm/health/health_check.sh

echo "--- ★ 最后检查时间必须随轮次前进（两次读必须不同）---"
grep -v '^#' /etc/realm/health/health_status.conf
sleep 15
grep -v '^#' /etc/realm/health/health_status.conf
```

**四条期望（清单 A-14）**：

1. `realm-health-check.timer` = `enabled` + `active`；`list-timers` 能看到下次触发时间。
2. `/etc/realm/health/health_check.sh` 存在且**非空**。
3. **两次读取 `health_status.conf`，最后检查时间字段必须不同（第二次更新）**
   ⇒ 证明探测端**每轮都在跑**；两次完全相同 ⇒ **探测端没跑**，无论日志里写了什么都判 FAIL。
4. 状态文件里**只有当前存在的规则的行** —— **已删除的规则不得残留**
   （残留行会让读端按 `host:port` 建索引时命中一条已经不存在的目标，把流量判成 failed）。
   ★ **这一条原执行单没收**。

---

## §11 展示端遗留：**二轮再议**（清单第 19 次修订 ④ / A-16 口径）

🔄🔄 **审稿自己上条「更正」撤回 —— 原稿这一段是对的，是审稿判错了**
（上游 `f01ec4a` 已先一步指出「展示端符号产品里也不存在」不成立）：

- **符号存在**：`lib/health.sh` 里有 `quality_window_display`（定义 + 导出），`lib/rules.sh` 里有调用点 ⇒
  **原稿标的物正确** —— 它就是**质量窗口展示串的单点**（代码注释明写「**展示口径只有这一处** ⇒ 菜单与别处不会两处漂」）。
- **窗口列结构也对**：`TARGET|RULE_ID|SAMPLE_SEQ|LAT_SEQ|WINDOW|FAIL_LAT_SEQ` 就是**质量窗口采样文件的行格式**
  （`lib/health.sh` 的该文件格式注释逐字这么写）；`read_quality_window` 从中取**第 3 / 4 / 6 列**
  （`SAMPLE_SEQ` / `LAT_SEQ` / `FAIL_LAT_SEQ`），`quality_window_stats` 据此算失败率与时延分布，
  `quality_window_display` 再把结果拼成展示串（形如 `[窗口: 失败率 30% (6/20) · 成功时延均值 12ms · 失败时延 均 2500ms 最大 3000ms]`）。
- ⇒ **审稿撤回「原稿此处抽错」这条判定**；第 10 步的标的物**回到原稿的 `quality_window_display`**。
- ★ **审稿这条错判的成因（可复现；注意：不是「没搜 lib/」）**：审稿当时跑的是
  `git grep -n 'quality_window' -- lib/ cmd/ xwPF.sh`，**但输出被 `Select-Object -First 8` 截断** ⇒
  排在后面的 `lib/health.sh`（定义与导出）与 `lib/rules.sh`（调用点）那几条命中**被切掉了** ⇒
  审稿把「**我的输出被截断**」当成了「**产品里没有这个符号**」⇒ **假阴性**。
  ⇒ **纪律（跨项目）**：**「grep 命中 0 ⇒ 不存在」这个推断，必须先自证输出没被截断**
  （去掉 `head` / `First` 之类限制，或直接打印命中总数）；**「查了没查到」与「没查全」要分开**。
  ⚠️ 附带更正：`reports/correction-quality-window-display.md` 把成因写成「只搜了 `reports/`、没搜 `lib/`」
  —— **与实测不符**（审稿搜的正是 `lib/`）⇒ **以本条为准**。

**清单认定的展示端遗留 —— 是「两处」，不是一处**（二轮再议，本轮不动）：

1. **展示串单点** —— `lib/health.sh` 的 `quality_window_display`（原稿标的物；窗口列 6 段口径见上）。
2. **读端取状态** —— `lib/health.sh` 的 `get_health_status_record` **只拿到目标地址**（调用处 `lib/rules.sh`
   的菜单展示**没有规则上下文**；函数实现是 `awk … $2 == t { print; exit }` ⇒ **取到第一行就退出**）
   ⇒ 同后端被两条规则共用时，菜单显示的是**文件里第一行**那条的状态 ⇒ 可能显示成另一条规则的状态。
   - **不参与切换判定**（切换由 `lib/realm.sh` 读端决定，已修）⇒ 严重级**中低**（显示误导，不是误切）。
   - 修法要改**函数签名 + 调用处** ⇒ 属接口变更 ⇒ 排上线后第二轮。

---

## §12 已知阻塞与不需要拍板的事

1. **需要 Chief 侧凭据**才能执行本单：root 口令 + 公钥 + 真实主/备上游地址。
   ⇒ **在凭据到手前，本单的任何一步都不得在真机上执行**（§0 起的顺序是硬约束）。
2. **不需要拍板**：`failover.json` 删 or 留档 ——
   `docs/install-and-upgrade.md` 的「老机器残留清理（主备池守护）」小节已定「**留档不删（改名保留）**」，
   验收口径是**决策无关形态**（只钉「没有活配置」这一条不变式），
   产品实现 `lib/ui.sh` 的 `_cleanup_legacy_failover_daemon` 也是改名留档 ⇒ **一致**。
3. **🔄 docs 侧那处缺陷** —— **已修**（上游 `680339f`：手工兜底改成「改名留档 + 保留目录」，与本文验收口径对齐）。
   ★ **本条是更正**：审稿落库时它还是「缺陷仍在」，现已被 `680339f` 修掉 ⇒ 现在的口径是：
   - `docs/install-and-upgrade.md` 的「手工兜底（菜单不可用时）」小节**自己会做改名留档**
     （`if [ -d /etc/xwpf ]; then … mv -f … .disabled`）并**明确保留 `/etc/xwpf` 目录**
     ⇒ **照 docs 那一段做，第 4 步的改名留档由它代劳**。
   - ⇒ **只有「不照 docs 那一段做」时**，本单第 4 步的改名留档才要自己补做，
     且**必须排在任何删 `/etc/xwpf` 的动作之前**（理由见 §5 的顺序硬约束）。
   - ⇒ 顺带作废审稿自己上一句「**三处一致 + 一处矛盾**」：**四处的口径现已一致**
     （文档留档表 / 产品实现 / 验收口径 / 手工兜底小节）。

---

## §13 对账结论（审稿 · 与执行单原稿的差异清单）

> 判据一律以**清单**为准；与产品实现冲突时以**产品实现**为准（清单是判据文档，代码是现状）。

| # | 执行单原稿 | 清单 / 产品实现实况 | 本单处置 |
|---|---|---|---|
| 1 | 删整个 `/usr/local/bin/cmd/` 目录 | 清单 A-15 只列**两个源文件副本**；**产品实现根本没有删 `cmd/` 这一步** | **收窄**为只删那两个文件；先 `ls -la` 再决定 |
| 2 | 只 `stop` + `disable` | 产品实现**还有兜底杀残留进程**（pgrep 排除自身/父进程/1），且**明确不用 `pkill -f`**（会自杀） | **补**兜底杀进程一步（§3） |
| 3 | 删两处 unit | 清单 A-15 的 7 路径**只列了 `/etc/systemd/system/` 一处**；产品实现**两处都删** | 以产品为准（两处都删）⇒ **清单漏列一处，已登记** |
| 4 | `[ -f /etc/xwpx/failover-state.json ]` | **路径笔误**（`xwpx` → `xwpf`） | 已更正（§5） |
| 5 | 五步链只列了五步 | 清单 A-13.1 的五步**一致**；但缺判据 2 的 **`sleep 60`**、判据 3 的**「配置更新完成 / 配置更新失败」两行必须分开判**、判据 4 的**「钉主位↔备位关系不钉字面量」** | 已补（§8.1） |
| 6 | 只写五步链 | 清单 A-13.2 的 **R1–R4 四条附加判据**未收 | 已补（§8.2） |
| 7 | 「重测两条时间特性」 | 清单 A-6.1 给的是**硬判据**（> 60 秒才排查；故障起始 + 120 秒之后 + 恢复后立刻读权重仍在备上），且记着一次**实验设计错误**（只等 55 秒就判「没切回」） | 已补判据 + 补「等过冷却期再判」（§9） |
| 8 | 探测端两条 | 清单 A-14 共 **4 条**期望：多「timer enabled+active + list-timers」「生成物存在且非空」「**状态文件不得有已删规则的残留行**」 | 已补（§10） |
| 9 | 复核只给 `pgrep` + `ss` | 清单 A-15 另有：**卸载后 `list-unit-files` 无输出**、**保留路径未误伤**（timer / `/etc/realm/health/` / 规则 / `config.json`，误伤=阻断级） | 已补核法（§7） |
| 10 | 无备份步骤 | 清单 A-15「危险动作」栏：**先备份 `/etc/realm`、`/etc/xwpf`** | 已补为 §0 第 4 步 |
| 11 | 展示端遗留写 `quality_window_display` + 窗口列结构 | **原稿两处断言都对**（符号在 `lib/health.sh` 有定义、`lib/rules.sh` 有调用点；6 段窗口列就是采样文件的行格式）⇒ **审稿上条「产品里也不存在」是输出截断造成的假阴性，已撤回** | **回到原稿**（§11）；清单认定的展示端遗留是**两处**（展示串单点 + 读端取状态），**别混** |
| 12 | 用 `文件:行号` 引用（`lib/ui.sh` / `docs/install-and-upgrade.md` 各三处） | 清单的引用纪律：**写「文件的符号 / 小节名」，禁「文件:行号」**（行号随修订漂移） | 已全部改成符号 / 小节名 |

**结论**：执行单原稿的**主干（顺序、判据来源、留档与登记口径、分诊口径）与清单一致**；
差异集中在**① 产品实现里有、原稿没写的两处（兜底杀进程、unit 两处）② 清单里漏收的原稿也没收的判据
（`sleep 60`、`[CONFIG]` 两行分开判、R1–R4、A-14 第 4 条、保留路径核法、备份）③ 一处实打实的抽错
（`/etc/xwpx` 笔误）④ 一处范围过宽（删整个 `cmd/` 目录）** ⇒
**本单已按上表就地更正，落库版可执行。**
⚠️ **审稿自己上条把「展示端符号」也列进 ③，那是审稿的假阴性，已撤回**（见第 11 行与 §11）。

---

> **本单是执行用件，不是实测记录** —— 里面没有一条结论来自真机复测；
> 真机复测的实测值、退出码、来源必须按清单的引用纪律另行记录并带来源。
