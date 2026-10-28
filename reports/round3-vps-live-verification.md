# 第 3 轮补充：VPS 实机验证补记（`103.42.31.186`）

**性质**：本文件是 `reports/round3-crashloop-review.md` 的**实机验证补记**。第 3 轮报告里所有标「待现场」的结论，在本轮全部用**真实 systemd** 实测收敛；同时在本轮挖出 **2 个新缺陷**。

**被测对象仍是冻结点 `f730c8b`**（见 §1.2 的指纹比对：本机 `/usr/local/bin/xwpf-failover` 与冻结点 `cmd/xwpf-failover.py` 的 sha256 **逐字节相同**，已装的 unit 与冻结点 `cmd/xwpf-failover.service` 全文逐字相同）。

**本轮对真实仓库的写操作**：**零**。所有探针 unit 都在独立命名空间（`xwpf-probe-*`）里，实验结束即删除；对 VPS 的改动只有 §5 的止血动作，且逐条列明、可一条命令回滚。

---

## 1. 测试环境

### 1.1 机器

| 项 | 值 |
|---|---|
| 主机名 | `ser06500088545` |
| 系统 | Debian GNU/Linux 13 (trixie) |
| 内核 | `7.2.11-x64v3-xanmod1`（XanMod） |
| **systemd** | **257 (257.13-1~deb13u1)**，`/sbin/init` 是 PID 1 |
| Python | 3.13.5（`/usr/bin/python3`） |
| bash | 5.2.37 |
| 规格 | 2 核 / 957 MB RAM / 1 GB swapfile / 20 GB 磁盘 |
| **locale** | `LANG=C.UTF-8`，可用 UTF-8 locale 仅 `C.utf8` |
| 工具链 | `python3 bash curl jq nc ss git` 齐全；**无** `netstat` / `lsof` |

### 1.2 ★ 冻结点指纹比对（证明测的就是 `f730c8b`）

```
本机已装 /usr/local/bin/xwpf-failover  sha256 = 15be865d63f57a70392dc086f8a113c5b67f2a664b5b3ae821d55584feef5677
冻结点 f730c8b:cmd/xwpf-failover.py   sha256 = 15be865d63f57a70392dc086f8a113c5b67f2a664b5b3ae821d55584feef5677
```
**完全一致**。本机 `/usr/local/bin/.xwpf-failover-version` = `1.0.0`。
本机 `/etc/systemd/system/xwpf-failover.service` 全文与冻结点 `cmd/xwpf-failover.service` **逐字相同**。

→ 第 3 轮报告的源码级分析**对这台机器逐字成立**。

### 1.3 ★ C 问的核心变量：默认启动限流的实际取值

```
/etc/systemd/system.conf:
  #DefaultRestartSec=100ms
  #DefaultStartLimitIntervalSec=10s      ← 注释状态 = 未被覆盖
  #DefaultStartLimitBurst=5
/usr/lib/systemd/system.conf.d/: 10-coredump-debian.conf   ← 只有 coredump，不碰限流
```
unit 生效值：
```
StartLimitIntervalUSec=10s
StartLimitBurst=5
StartLimitAction=none
```
→ **Debian 13 未改默认值 → 限流就是 10 秒 5 次**，与第 3 轮报告的假设完全一致。

---

## 2. 现场实况：崩溃循环**当时正在跑**

```
$ systemctl show xwpf-failover
ActiveState=activating        SubState=auto-restart
Result=exit-code              ExecMainCode=1   ExecMainStatus=1
Restart=always                RestartUSec=2s
NRestarts=10362
```
journal 时间线：
```
02:11:45  Scheduled restart job, restart counter is at 1.
...
08:24:00  Scheduled restart job, restart counter is at 10363.
```
→ **6 小时 12 分、10362 次重启、间隔约 2 秒**，且全程
```
$ journalctl -u xwpf-failover | grep -c 'Start request repeated too quickly'
0
```
→ **限流一次都没触发。**

**触发原因（与本机实况不同！）**：本机是**配置缺失**，不是端口冲突：
```
$ ls -la /etc/xwpf/          → 空目录，只有 . 和 ..
$ cat /etc/xwpf/failover.json → No such file or directory
journal: ERROR failed to read config /etc/xwpf/failover.json: [Errno 2] No such file or directory
```
→ 走的是第 3 轮报告 §D.1 的 **D8（配置文件不存在 → 退出码 1）**，而不是 D1（EADDRINUSE → 退出码 0）。**这正好补上了 D 问清单里 D8 的实机确认。**

---

## 3. B 问：退出码语义 —— 实机确认

在真机（Linux / systemd 257 / Python 3.13.5）直接跑冻结点那份守护进程：

| 场景 | 冻结点位置 | **实机退出码** | 第 3 轮报告 §D.1 的断言 | 一致？ |
|---|---|---|---|---|
| listen 端口已被占用（EADDRINUSE） | `cmd/xwpf-failover.py` 的 `Pool.serve` | **0** | D1 = 0 | ✅ |
| listen 地址没有冒号 | 同上 | **0** | D2 = 0 | ✅ |
| 配置缺 `primary` 键 | `cmd/xwpf-failover.py` 的 `Pool.__init__` | **1** | D11 = 1 | ✅ |
| 配置文件不存在 | `cmd/xwpf-failover.py` 的 `_main` | **1** | D8 = 1 | ✅ |

实机日志原文（EADDRINUSE）：
```
ERROR task <Task finished name='Task-2' coro=<Pool.serve() ...>> exception=OSError(98,
"error while attempting to bind on address ('127.0.0.1', 19999): [errno 98] address already in use")> raised: ...
```

→ **B 问的核心断言「task 内部抛出的普通异常 → 退出码严格为 0」在真机成立**，第 3 轮报告 §B.1 的不变式**不需要修改**。同时「第 3 轮报告 §B.3 的修复方案形态」也被实机坐实（见 §4.2）。

---

## 4. C 问 / E 问 / F 问：实机确认

### 4.1 C 问：默认限流**掐不断**循环 —— **实机确认，且有两条独立证据**

**证据一（生产 unit）**：§2 的 10362 次重启，限流触发 0 次。

**证据二（受控实验）**：独立探针 unit，`Restart=always` + `RestartSec=2s`，配置指向一个被占端口（**走的是退出码 0 的路径**）：

```
NRestarts=9 / 20 秒
ExecMainStatus=0                      ← 退出码 0
Start request repeated too quickly 计数 = 0
restart job 时间戳: 08:26:49 / :51 / :54 / … / 08:29:49 / :52
```

**为什么掐不断（第 3 轮报告 §C.4 的推演被实测印证）**：
实际重启间隔 = 进程存活（~0.15 s）+ `RestartSec=2s` + 调度开销 ≈ **2.15 s**。
限流是**固定窗口**（`src/basic/ratelimit.c` 的 `ratelimit_below`），窗口内第 6 次尝试才被拒；而
`5 × 2.15 = 10.75 s > 10 s` → **第 6 次尝试落在窗口之外 → 窗口整窗重置 → `num` 峰值只到 5 → 永不越界**。

→ **第 3 轮报告 §C 的全部结论成立**：
- 「默认限流不会掐断循环」✅
- 「用户的『无限重启循环』结论成立」✅
- 「余量只有约 0.1 s，极脆弱」✅（把 `RestartSec` 调到 1.9 s 或删掉走默认 100 ms 就会翻转）

### 4.2 ★ E 问方向②：`Restart=on-failure` + 退出码 0 → **静默失效实锤**

同一份配置（EADDRINUSE，退出码 0），只把 `Restart=` 改成 `on-failure`：

```
Result=success
NRestarts=0                          ← 一次都没重启
ExecMainCode=0   ExecMainStatus=0
ActiveState=inactive   SubState=dead
journal:
  Started xwpf-probe-onfail.service ...
  xwpf-probe-onfail[30831]: ERROR task ... exception=OSError(98, ... address already in use) raised: ...
  xwpf-probe-onfail.service: Deactivated successfully.        ← 不是 "Failed"
```

→ **第 3 轮报告 §B.3 的预言被实机坐实**：
> 守护进程以 0 退出 → `on-failure` **不重启** → unit 直接 `inactive/dead` → **无限循环消失了，但故障转移彻底静默失效**，而且 journal 里写的是 `Deactivated successfully.` —— **连「失败」两个字都没有**。

→ **所以「先改退出码、再改 `Restart=`」的顺序不能反**，这条从「推论」升级为**实机结论**。

### 4.3 E 问方向③：显式 `StartLimitIntervalSec=60` + `StartLimitBurst=3`

```
NRestarts=3
ActiveState=failed   SubState=failed
journal:
  08:27:35  Scheduled restart job, restart counter is at 1.
  08:27:37  Scheduled restart job, restart counter is at 2.
  08:27:39  Scheduled restart job, restart counter is at 3.
  08:27:39  Start request repeated too quickly.
```
→ **实机确认**：第 4 次启动尝试被拒，unit 进 `failed` 并**停在那里**（`StartLimitAction=none`，没有别的 unit 会拉起它）→ **与第 3 轮报告 §E.3 的判断一致**（报告估的触发时刻约 6.3 s，实机约 4~6 s，因为进程存活比假设的短）。

### 4.4 F 问止血第 1 步：`systemctl stop` 确实断掉循环

```
停之前：NRestarts=10504
停之后：ActiveState=inactive  SubState=dead  Result=success  NRestarts=0
```
→ **实机确认**：`systemctl stop` 之后 `Restart=always` 不会把它拉回来。

---

## 5. ★ 本轮挖出的 2 个新缺陷

### N1（高）★ `lib/ui.sh` 的 `show_menu` 在 stdin EOF 下**无限重绘菜单 + 忙循环**

冻结点 `lib/ui.sh` 的 `show_menu` 的结构是：
```
show_menu() {
    while true; do
        clear
        ... 打印菜单 ...
        read -p "请输入选择 [0-9]: " choice
        case $choice in
            1) ... ;; 2) ... ;; ... 0) exit 0 ;;
        esac
    done
}
```
`read` 在 **stdin 到达 EOF** 时**立即返回非 0**（不阻塞），`choice` 为空 → `case` **不匹配任何分支** → 回到 `while true` 顶部 → **无限重绘**。而且循环里**没有 `sleep`** → **纯忙循环**（不降速）。

**实机证据（当前冻结点版本，缺陷仍在）**：
```
$ timeout 5 bash /usr/local/bin/xwPF.sh < /dev/null > out 2>&1
exit=124                       ← 被 timeout 砍掉，进程本身不会退出
5 秒内输出 = 473,398 字节      ← 约 94 KB/s 的无界输出
首行: TERM environment variable not set.     ← `clear` 在无 TERM 时报错
$ timeout 5 bash /usr/local/bin/xwPF.sh --help < /dev/null > out 2>&1
exit=0，输出 471 字节            ← --help 分支是好的
```

**触发场景**：任何在**无人值守 / 后台 / cron / systemd / 管道**里调用 `pf`（无参数）的场合。`pf --help` 之所以没事，只是因为 `lib/ui.sh` 的 `main` 显式处理了 `--help` → `show_usage; exit 0`；**「`--help` 不被识别 → 落进菜单」的历史版本会直接踩中这个洞**（见 §6）。

**建议修法（两处都要）**：
1. `show_menu` 的 `read` 之后立刻判 EOF：
   ```
   if ! read -p "请输入选择 [0-9]: " choice; then
       echo ""
       exit 0
   fi
   ```
   （`read` 返回非 0 就是 EOF/错误 → 干净退出）
2. 菜单循环里加 `sleep 0.2` 兜底，避免任何未来的「不匹配分支」退化成忙循环。

**建议补的台架用例（现在零覆盖）**：钉「stdin 为 EOF 时，`pf` 必须在有限时间内退出，且输出量有上限」——用 `timeout` + 输出字节数双断言，**不要**只断言退出码。

### N2（高）★ `/tmp` 是 tmpfs，**单个文件就能吃掉一半内存**

```
$ mount | grep tmpfs
tmpfs on /dev/shm type tmpfs (rw,nosuid,nodev,noexec,relatime,size=479M,...)   ← /tmp 与 /dev/shm 同一个 479M tmpfs
$ df -h /tmp
tmpfs  479M  479M  0  100%  /tmp
```
事故现场：
```
/tmp/help.out   662,831,104 字节   ← 一个文件占满 tmpfs
$ free -m
Mem: 957 total, 565 used, 189 free, 409 buff/cache
Swap: 1023 total, 475.7 used       ← 被逼出 475 MB swap
```
→ **一个日志文件就把整机内存 + swap 吃掉一半**。这是「sshd 握不上手」最直接的物理原因：内存被 tmpfs 占用 → sshd fork 失败/握手变慢。

**建议**：
1. 仓库脚本里**不要往 `/tmp` 写无界输出**；确需写盘就用 `mktemp` + 显式上限（`head -c` / `timeout`）。
2. 真机部署时给 `/tmp` 单独限额（Debian 13 的 `/usr/lib/tmpfiles.d/` 里给 `/tmp` 配 `size=`），或确认 systemd-tmpfiles 的设置。
3. `xwPF.sh` 的 `install` 路径产生的临时目录（`lib/update.sh` 的 `mktemp -d`）在异常退出时会残留，**部署脚本应带 `trap` 清理**。

---

## 6. ★ 压垮这台机器的**真正**元凶（不是重启循环）

第 3 轮报告 §A.5 判定「单靠 `xwpf-failover` 的重启循环不足以造成 journald 写盘风暴或压垮 sshd」——**本轮实机数据完全支持这个判定**：

| 量 | 第 3 轮报告 §A.5 的估算 | **实机实测** |
|---|---|---|
| 该 unit 的 journal 行速率 | 约 1.9 行/秒 | **2.33 行/秒**（1400 行 / 10 分钟） |
| CPU 占用 | 约 2~3% | top 前 5 名里**没有** python 进程 |
| 内存 | 无累积 | 无累积 |

**真凶是一个遗留的真机 e2e 脚本**：
```
$ ps -p 26755,26756,26825 -o pid,ppid,stat,%cpu,time,args
26755     1 Ss    0.0 00:00:00 bash -c bash /tmp/e2e_vps.sh 2>&1
26756 26755 S     0.0 00:00:00 bash /tmp/e2e_vps.sh
26825 26756 S    11.8 00:40:50 /bin/bash /usr/local/bin/pf --help
         fd 1 -> /tmp/help.out    fd 2 -> /tmp/help.out    fd 255 -> /usr/local/bin/xwPF.sh (deleted)
```
- `/tmp/e2e_vps.sh` 是 **2026-10-24 02:42** 留下的真机端到端测试脚本（从 `feat/auto-standby-on-zero-weight` 分支安装），**从 02:43 一直挂到现在**。
- 它卡在自己的**第 2 步** `pf --help` 上 —— 而那个分支装上去的 `xwPF.sh`（已 `deleted`，03:44 被重装覆盖）**不认 `--help`** → 落进交互菜单 → 命中 N1 的 EOF 忙循环 → **每轮把 471 字节的帮助/菜单文本追加进 `/tmp/help.out`**。
- 结果：5.7 小时灌出 **662 MB**，撑爆 tmpfs → 内存 + swap 被吃 → 机器吃力。

→ **教训（两条，都要进规范）**：
1. **真机 e2e 脚本必须带超时与自清理**（`timeout` + `trap` 删临时目录），且**不能留在机器上长期跑**。本轮 `/tmp` 里还躺着 `e2e_vps.sh` / `e2e_vps2/3/4.sh` / `prep_vps.sh` / `listener.py` / `dog.sh` / `pfdeploy*` 等一堆同类遗留。
2. **「VPS 被压垮」的归因不能只看 systemctl 的循环数** —— 要看 `top` / `free` / `du` 里**谁在吃资源**。本例里 systemd 的 `NRestarts=10362` 很扎眼，但它**不是**资源消耗大户。

---

## 7. 本轮对 VPS 做的改动（全部可回滚）

| # | 动作 | 目的 | 回滚方式 |
|---|---|---|---|
| 1 | `kill` 进程链 26825 / 26756 / 26755 | 停掉 5.7 小时的 `pf --help` 忙循环 | 无需回滚（那是要停的东西） |
| 2 | `rm -f /tmp/help.out`（662 MB） | 释放 tmpfs | 无法回滚（是垃圾输出） |
| 3 | `systemctl stop xwpf-failover` | 停掉 10504 次重启循环 | `systemctl start xwpf-failover` |
| 4 | `systemctl disable xwpf-failover` | 防止重启后再次复活循环 | `systemctl enable xwpf-failover`（已验证 `UnitFileState=disabled`，恢复命令见 §4.4） |
| 5 | 删除探针 unit `xwpf-probe-always` / `xwpf-probe-onfail` / `xwpf-probe-limit` + `daemon-reload` | 清理实验残留 | 无需回滚 |
| 6 | `rm -rf /root/probe` | 清理实验配置 | 无需回滚 |

**未做的事（有意不动）**：
- **没有创建 `/etc/xwpf/failover.json`** —— 缺配置是本机循环的根因，但**主备池应该长什么样是产品决策**（本机 `realm` 的规则是 `0.0.0.0:8443 → [127.0.0.1:18081|127.0.0.2:18081]`，没有给主备代理留位置）。应由用户/小编决定后再装。
- **没有动 `realm.service`、`realm-health-check.timer`、docker、fail2ban** 等既有服务。
- **没有清理 `/tmp` 里其余的 e2e 遗留**（总共只有 2.3 MB，无害；且分不清哪些属于别的项目）。

**止血效果**：

| 指标 | 止血前 | 止血后 |
|---|---|---|
| `/tmp` tmpfs | 479 M / **100%** | 2.3 M / **1%** |
| swap 占用 | **475.7 MB** | **65.1 MB** |
| MemAvailable | 396 MB | **551 MB** |
| load average (1m) | 1.22 | **0.63** |
| `xwpf-failover` | 重启循环 10504 次 | `inactive/dead`，`disabled` |
| `pf --help` 忙循环 | 11.8% CPU，662 MB/5.7h | 已终止 |

---

## 8. ★ 本轮我自己的一次失误（必须记下来）

**第一轮远程实验的 E1 / E1b / E1c / E3 四个用例全部无效**，当时打印出来的退出码是 1、1、1、9 次重启，看着像「EADDRINUSE 也是退出码 1」——**与第 3 轮报告矛盾**。

真因：脚本里用 `cat > /tmp/xwpf-probe/*.json` 写配置，而**当时 `/tmp` 的 tmpfs 已经被 `help.out` 撑满** → 4 份配置**一份都没写出来** → python 读不到配置 → 全部走「配置文件不存在 → `sys.exit(1)`」路径。stderr 里其实有 4 条 `cat: write error: No space left on device`，**我第一眼没读它**。

**教训（跨项目）**：
> **在远端机器上做实验，输出与配置文件的写入目标，必须先确认「可写且有空间」；否则「实验没跑起来」会被误读成「实验的结果」。**
> 判据：实验结束后**回读产物、确认它就是你要喂进去的那个东西**（本次的正确做法：把配置改放 `/root/probe`（真实磁盘）、并在跑之前 `ls -l` 确认四份 JSON 都在）。
> 这与「负向对照跑起来了吗」是同一类错误，只是发生在远端。

（重做后的正确结果见 §3、§4.2。）

---

## 9. 仍未闭环的项

1. **本机 `xwpf-failover` 到底该不该跑、跑什么配置** —— 需要产品侧决定主备池的形态（§7「未做的事」）。
2. **`VPS-87`（原 VPS）仍不可达** —— 本轮的实机结论**很可能同样适用**（同 systemd、同 `RestartSec=2s`），但**没有实机证据**，不能替代现场取证。建议在那台机器上先跑 `systemctl show xwpf-failover -p NRestarts -p ExecMainStatus` 与 `journalctl -u xwpf-failover | grep -c 'Start request repeated too quickly'` 这两条。
3. **N1（菜单 EOF 忙循环）在仓库里零覆盖** —— 需要补台架用例（§5 给了断言形态）。
4. **N2（/tmp tmpfs 无界输出）在仓库里零覆盖** —— 建议加「脚本产物必须有大小上限」的检查。
5. **第 3 轮报告 §E.4 后半（单 pool 隔离 + 退避重试）本轮未触及** —— 仍只做了风险评估。
6. **`lib/ui.sh` 的 `show_menu` 在 `TERM` 未设时 `clear` 报错** —— 小问题，但会让无人值守场景的输出更难读，顺手一起修。

---

## 10. 补记（2026-10-24 20:45 +08:00）—— §9 第 3 条已闭环

> 本节是**追加**的补记，不改上文原文。§9「仍未闭环的项」第 3 条是当时的状态，**现已在台架侧闭环**。

### 10.1 §9 第 3 条「N1（菜单 EOF 忙循环）在仓库里零覆盖」→ **已闭环**

台架用例 **T53** 已入库：

| 项 | 值 |
|---|---|
| 提交 | `6056cbc`（`test(台架): 第 9 轮 —— T53 交互菜单在 stdin EOF 时必须干净退出`，台架 v2.10.0） |
| 用例文件 | `tests/cases/13_menu_eof_safety.sh` |
| 登记 | `tests/run_tests.sh` 的用例表里以 `T53:case_T53_menu_eof_no_busy_loop` 注册 |
| 台架规模 | 复核时 HEAD 的 `tests/run_tests.sh` 登记 **53 条**用例 |
| 认证 | 干净克隆（锚点 `2a01a33`，`BASE_SHA=HEAD`）跑 T53 → **PASS / 退出码 0** |

**T53 钉了两层**（这一点与审稿侧的经验一致 —— 入口层断言对 helper 层完全无感知，两层必须各有一条腿）：

1. **helper 契约层**：菜单读入统一走 helper，读到 EOF 时 helper 必须**终止调用方**。
   - 判据**不用退出码**（helper 坏掉时脚本继续往下跑、照样 rc=0 → 恒绿），改用**哨兵**：在调用之后再打印一行 `AFTER-CALLBACK-SENTINEL`，**哨兵不出现** = helper 终止了调用方。
   - 覆盖 **4 处**实现：主脚本用的那份 + 3 个独立脚本各自内置的那份。
2. **入口端到端层**：菜单入口在 `stdin=/dev/null` 下 ① 有限时间退出（自己退出，不能被 timeout 杀掉）② 输出字节数有上限（`_T53_BYTE_LIMIT=65536`）③ 退出码 0；另加「防空过护栏」与「输出命中入口标志」。
3. **负向对照**：用**真实修复前实现**（`_T53_PRE_FIX_SHA=d0366b3`）现场复现忙循环，断言「坏情况确实发生」。

**修复前的实测口径与本文件 §5 的实测不同源、不可混用**：T53 在台架沙箱（菜单桩）上测得「修复前 5 秒灌 171,903 字节 / 修复后 170 字节」；本文件 §5 是在 **VPS 真机上跑完整 `xwPF.sh`** 测得「5 秒 473,398 字节」。两者测的是同一类病（EOF → 忙循环 → 无界输出），但**被测对象与运行环境都不同**，引用时不要把两个数字当成互相印证或互相矛盾。

### 10.2 §9 第 4 条「N2（`/tmp` tmpfs 无界输出）零覆盖」→ **仍未覆盖**

台架侧至今没有「脚本产物必须有大小上限」这类断言。**注意这里的 N2 与 `reports/round3-failover-restart-storm-status.md` 里的 N2 不是同一个东西** —— 后者的 N2 指「崩溃循环三处根因」（与 `Restart` 口径 / 退出码语义 / install 启守护有关），见该报告第二节。

### 10.3 ⚠️ 编号撞车提醒（本仓库已出现的两套 N 编号）

审稿侧现有**两套**编号，指代不同缺陷，引用时必须带报告名：

| 编号 | 含义 | 出处 |
|---|---|---|
| **N1** | 交互菜单在 stdin EOF 下无限重绘 + 忙循环 | 本文件 §5；`round3-failover-restart-storm-status.md` 第四节（同一缺陷） |
| **N2** | `/tmp` tmpfs 无界输出 | 本文件 §5（**本文件的 N2 指这个**） |
| **N2** | 崩溃循环三处根因（`Restart` 口径 / 退出码语义 / install 启守护） | `round3-failover-restart-storm-status.md` 第二节（**该文件的 N2 指这个**） |

**建议**：下一轮审稿起，缺陷编号统一加前缀（如 `V-N1` / `V-N2` 表示 VPS 轮、`F-N1` / `F-N2` 表示 failover 轮），避免跨报告引用时指错。
