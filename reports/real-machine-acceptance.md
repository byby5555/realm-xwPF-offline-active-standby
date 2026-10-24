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

1. 恢复后**立刻**读取，权重仍是 `0,1`（**冷却期没到就不许翻**——这是严格主备的关键行为）。
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

由 **realm 侧健康检查**决定，三个参数相乘：

| 参数 | 默认值 | 出处 |
|---|---|---|
| 健康检查周期 `HEALTH_CHECK_INTERVAL` | **4 秒** | `lib/failover.sh` 的默认值；生效值走 `lib/health.sh` 的 `get_effective_health_check_interval` |
| 连续失败阈值 `FAILURE_THRESHOLD` | **2** | `lib/health.sh` 的健康检查体 |
| 单次探测超时 `CONNECTION_TIMEOUT` | **3** | 同上 |

⇒ **理论下限 ≈ 2 个周期 = 8 秒**（再加一次探测本身的耗时）。
⇒ **实测区间：待补**（本轮无 VPS 凭据）—— 取证方式见 A-6.2。

> **⚠️ 口径警告（重要，且已随旧功能删除而简化）**：本条**只指负载均衡路径**（`realm-health-check.timer` 驱动的权重翻转）。
> 历史上还有一个「**直连池 8–10 秒切走**」的口径 —— 那是**另一个守护、另一套参数**（`cmd/xwpf-failover.py` 的 `interval_sec` / `fail_threshold` / `cooldown_sec`，作用对象是池内主备转发，不是规则权重）。
> ⇒ **该直连池功能已随「主备池整块删除」作废** ⇒ 现版本**只剩负载均衡路径一条口径**，不再需要分清两个「8 秒」。
> ⇒ **仍需记住的分清原则**（防未来再混）：引用检测耗时必须写清「**哪条路径**」—— 权重翻转的耗时 ≠ 守护进程切池内主备的耗时。

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

**实测值 X 秒：待补** —— 取证方式见 A-6.2。

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

## A-13　保留路径三：权重 10,0 主备（杀主翻备 / 恢复翻回 / 回切冷却）

**验收目标**：同端口多目标、权重 **`10,0`** ⇒ 自动进**主备**形态；主故障 ⇒ 翻备；主恢复 ⇒ **受 120 秒冷却约束**后翻回。

**前置**：A-12 完成（已能下发多目标权重）。

**命令**

```bash
echo "--- 下发权重 10,0（应自动进主备）---"
source /usr/local/bin/lib/rules.sh
apply_port_group_weight_config 18443 "10,0" 1

echo "--- 规则：应是主备形态 ---"
grep -H -E '^(BALANCE_MODE|FAILOVER_ENABLED|WEIGHTS|TARGET_STATES)=' /etc/realm/rules/rule-*.conf

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
4. **杀主 → 翻备**、**恢复主 → 翻回**：见 **A-5**（杀主翻 `0,1`）与 **A-6**（恢复翻回 `1,0`）。
5. **回切冷却期生效**：见 **A-6** 的第 1 条期望（恢复后**立刻**读权重**仍是 `0,1`**）+ **A-6.1** 的机理（③ 的基准是 `failure_start_time`，`RECOVERY_COOLDOWN` 默认 120）。

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| 权重含 0 但没进主备 | `auto_enable_active_standby` 没触发 → 查 `lib/rules.sh` 的 `auto_enable_active_standby`（锚点 `a9102c1`） |
| 进了主备但 timer 没拉起 | 探测端没起来 ⇒ **永远不会切换**（静默失效）→ 查 `lib/rules.sh` 的 `ensure_health_check_service` 与 `start_health_check_service` |
| timer 起来了但 `health_status.conf` 里没有这组规则的行 | 探测端没覆盖这组规则 → 查 `RULE_ROLE=1` / `ENABLED=true` / `FAILOVER_ENABLED=true` 三个开关 |
| 主挂了权重不翻 | 状态没进 `failed` → 查 `FAILURE_THRESHOLD` / `CONNECTION_TIMEOUT`；进了但 config 没重生成 → 看 `journalctl` 有没有 `[CONFIG]` |
| 恢复后立刻就翻回（没有冷却） | 冷却期判定失效 → 查规则文件里 `RECOVERY_COOLDOWN`（默认 120）是否真的落盘 |

**危险动作**：同 A-11。**本项会真的把流量切走** —— 确认在测试环境；**严禁动 22 端口**。

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

echo "--- 5) 池配置目录 ---"
ls -d /etc/xwpf 2>/dev/null && echo "★FAIL: 残留 /etc/xwpf" || echo "OK: 无 /etc/xwpf"

echo "--- 6) 卸载后复核（走 pf → 8. 卸载服务）---"
systemctl list-unit-files | grep -E 'xwpf-failover' && echo "★FAIL: 卸载后仍有 unit" || echo "OK: 卸载后无 unit"
```

**期望结果（可判定）**

1. **升级后**：unit 文件、drop-in 目录、守护进程、`/etc/xwpf` 目录**全部不存在**；`18443` / `18444` **不再被旧守护占用**。
2. **卸载后**：同样全部为空，且 `/etc/systemd/system/` 里 `xwpf-failover` **零命中**。
3. **不得影响保留路径**：升级/卸载过程中，`realm-health-check.timer`、`/etc/realm/health/`、权重主备的规则与 `config.json` **不受损**（若被清掉 ⇒ 保留路径被误伤，是**阻断级**问题）。
4. ⚠️ **真机 103 的特别提醒**：该机现在跑两个池（`18443` 旧池 / `18444` 直连池），**守护进程一旦不再监听，依赖这两个端口的转发就会断** ⇒ **必须先把流量迁到「同端口多目标 + 权重」路径**，再删守护。**顺序错了 = 真机断转发。**

**失败判据与排查方向**

| 现象 | 排查方向 |
|---|---|
| unit 残留但 `list-unit-files` 没有 | 只是 `/etc/systemd/system/` 里的孤儿文件 → 卸载流程漏了 `rm -f` |
| 进程还在 | 只 `stop` 了 timer 没停 service，或守护进程没被 `disable` |
| 端口还被占 | 守护没停干净（见上），或 realm 侧规则仍指向该端口 |
| **保留路径的东西被一起清了** | 卸载/删除的**范围**过宽（把 `/etc/realm/health/` 或 health-check unit 当成守护的东西删了）→ 查卸载两阶段的路径清单 |
| 老池在菜单里**列不出来也删不掉** | 兼容读取被一并删了 —— **老机器上已有的池必须仍能列出与删除**（产品只删「新建」路，兼容读取保留）⇒ 查读池/删池入口是否还在 |

**危险动作**：**升级会改转发配置** ⇒ 先备份 `/etc/realm`、`/etc/xwpf`；**卸载会删全部规则与配置** ⇒ 确认是测试机或已备份。

## 11. 最小化 Debian 兼容性矩阵

**为什么需要矩阵**：`lib/core.sh` 的 `REQUIRED_TOOLS` 只保证 `curl wget tar grep cut bc jq openssl python3`；`nc` **不在**清单内（健康检查已不依赖它，但**仍依赖 `timeout`**——属 coreutils，极简镜像也基本都有）。`jq` 缺失会让 `lib/core.sh` 的 `generate_network_config` / `lib/rules.sh` 的 `proxy_management_menu` 里的 config.json 合并退化。

| 变量 | 取值 | **必跑**项 | 该组合的重点观察 |
|---|---|---|---|
| **netcat-openbsd** | 装了（`apt-get install -y netcat-openbsd`） | A-1 A-3 A-5 A-6 A-8 **A-Y** | 探测走 nc 分支；确认 `nc -h 2>&1 \| grep -q -- '-z'` 在**本机 nc 版本上返回真**（能力探测靠匹配帮助文本） |
| | **不装**（或 busybox nc） | **A-7** + A-5 A-6 **A-Y** | 必须靠 `bash /dev/tcp` 回退；**任何目标都不能被误判 failed**（A-Y 正是「一个坏了不能把另一个也带坏」的加强版） |
| **jq** | 装了 | 全部 | 基准 |
| | **不装** | A-1 A-2 A-9 A-10 | ① 安装器应**自动补装**（在 REQUIRED_TOOLS 里）；② 故意不装时，`config.json` 的 network 段合并会退化 → 查 `lib/core.sh` 的 `generate_network_config` 里 `2>/dev/null \|\| echo "{}"` 兜底是否留下残缺配置 |
| **systemd 版本** | Debian 11（systemd 247） | A-3 A-8 A-9 **A-X** | `journalctl --vacuum-time=7d --dry-run` 需 systemd ≥ 230（247 满足）；timer `OnUnitActiveUSec` 行为（A-X 要靠 timer 跑完一轮完成老行迁移） |
| | Debian 12（systemd 252） | A-3 A-8 A-9 **A-X** | 基准；`systemctl show -p` 字段名有微调 |
| | Ubuntu 22.04（systemd 249） | A-3 A-8 A-9 **A-X** | `systemd-analyze verify` 对 unit 的校验更严 |
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
| A-13 | 保留路径三：权重 10,0 主备 | ☐PASS ☐FAIL ☐BLOCKED | | active-standby + FAILOVER_ENABLED=true / timer enabled+active |
| A-14 | 健康探测端确实在探测 | ☐PASS ☐FAIL ☐BLOCKED | | **两次读取的最后检查时间必须不同** / 生成物与真源一致 / 无已删规则残留行 |
| A-15 | 老机器残留清理 | ☐PASS ☐FAIL ☐BLOCKED | | 残留 unit / drop-in / 进程 / 占用端口数 = / 保留路径未被误伤 = |
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
