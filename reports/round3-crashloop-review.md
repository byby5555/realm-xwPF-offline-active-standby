# 第 3 轮只读复核：`xwpf-failover` 崩溃循环根因链

**冻结点**：`f730c8b`（`f730c8bb5809f74a60be71928b3d9a4aaf763000`，2026-10-24 13:38:05 +0800，`修正 active-standby 文档里过时的「两处同步」说法`）
**复核对象**：`cmd/xwpf-failover.service`、`cmd/xwpf-failover.py`（以及 `lib/failover.sh`、`lib/realm.sh`、`lib/health.sh`、`lib/ui.sh` 中会拉起/影响该 unit 的路径）
**报告作者立场**：独立复核，**不默认提问者的结论成立**。凡提问者的判断被推翻，在下文用「**更正**」显式标出，并给出推翻它的证据。
**仓库 HEAD 说明**：写本报告时仓库 HEAD 已前移到 `805dc5e`。本报告的一切结论**只对 `f730c8b` 成立**，不追 HEAD、不重测。

---

## 0. 取证方法与证据等级

被测产物**只**从 `git show f730c8b:<path>` 导出，未使用工作区文件作为被测对象。全文引用一律写「文件 的 符号」，不写行号。

| 标记 | 含义 | 本轮实际做了什么 |
|---|---|---|
| 【实测】 | 在本机对冻结点产物实际执行得到的结果 | 用冻结点 `cmd/xwpf-failover.py` 的副本跑了 15 个退出码用例，逐个记录退出码 |
| 【文档级】 | systemd 官方 man page 原文 | 取自 freedesktop.org 的 `systemd.service(5)` / `systemd.unit(5)` / `systemd-system.conf(5)`（systemd 255） |
| 【源码级】 | systemd v255 源码逐行读出 | 取自 `github.com/systemd/systemd`（tag v255）的 `src/basic/ratelimit.c`、`src/core/service.c`、`src/core/unit.c` |
| 【仿真】 | 把 systemd 源码函数逐字移植后在本地复算 | 把 `ratelimit_below()` 逐字移植为 Python，跑 200 次 attempt 的时间线 |
| 【待现场】 | 必须在那台 VPS 上执行才能确认 | `VPS-87` 当前 SSH banner 超时、ping 50% 丢包，本轮**无法登录**，相关项只给命令不给结论 |

本机环境：Windows + PowerShell 5.1，**无 systemd / 无 WSL / 无 Docker / 无 realm**。因此 systemd 侧结论全部是「文档级 + 源码级 + 仿真级」，**没有一条是 systemd 实机实测**；这一点在每处相关结论里都标明了。

---

## 0.1 结论速览

| 问 | 结论 | 关键依据 |
|---|---|---|
| **A.1** `Restart=always` + `RestartSec=2s`，`[Unit]` 无 StartLimit | **成立** | 【文档级/实测】冻结点 unit 原文 |
| **A.2** `Pool.serve` 在端口被占用时抛 `OSError(EADDRINUSE)` | **成立** | 【实测】退出码 0，日志含 `exception=OSError(... 10048 ...)` |
| **A.3** task 抛错 → `asyncio.wait` 返回 → `_main` 正常返回 | **成立**（但提问者省略了关键中间步骤） | 【实测】该步骤里异常被 `t.result()` 取出并被 `except Exception` 吃掉 |
| **A.4** 退出码 = 0 | **前半成立、后半被更正** | 【实测】task 内部异常 → **严格 0**；但「只有配置读失败的两处是 `sys.exit(1)`」**不成立**，另有 5 类非 0 路径 |
| **A.5** 无限重启循环 | **成立** | 【仿真】默认限流在 `RestartSec=2s` 下**不触发**，见 C 问 |
| **A.5** journald 写盘风暴 → 负载飙升 → sshd 握不上手 | **不成立（定量）** | 【实测+估算】约 1.9 行/秒、约 0.55 MB/小时、CPU 约 2~3% |
| **B. 退出码判断是否严格成立** | **「task 内部异常 → 退出码 0」严格成立**；「未捕获异常 → 1」也成立但范围窄；「只有两处 `sys.exit(1)`」不成立 | 【实测】15 个用例 + 【源码级】 |
| **C. systemd 默认启动限流会不会掐断循环** | **不会掐断**（在 `RestartSec=2s` 的实配下）→ 提问者的「无限循环」结论**成立**，但**不能**指望限流兜底 | 【文档级】+【源码级】+【仿真】 |
| **D. 全部快速退出路径** | 见 §D 的 **D1–D21** 完整清单，逐条标注退出码 | 【实测】15 例 + 【源码级】 |
| **E. 五个修复方向的新问题** | 见 §E；**方向② 单独改会造成静默失效**，必须与方向①成对 | 【实测】修复写法实测 + 【仿真】 |
| **F. 最小止血顺序** | 见 §F（6 步 + 3 个别做错的动作） | 【文档级】+ 现场命令 |

---

## A. 提问者给出的 5 条根因链：逐条判定

### A.1 —— **成立**

`cmd/xwpf-failover.service` 的 `[Service]` 段原文（冻结点）：

```
[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /usr/local/bin/xwpf-failover -c /etc/xwpf/failover.json
Restart=always
RestartSec=2s
```

`cmd/xwpf-failover.service` 的 `[Unit]` 段原文：

```
[Unit]
Description=xwpf-failover — active/passive TCP failover proxy (xwPF)
Documentation=https://github.com/byby5555/realm-xwPF-offline-active-standby
After=network.target realm.service
Wants=realm.service
```

`[Unit]` 段**确实没有** `StartLimitIntervalSec=` / `StartLimitBurst=` / `StartLimitAction=`。

**补充（提问者未提）**：冻结点全树只有 **一个** `.service` 文件（`cmd/xwpf-failover.service`）。`realm.service` 与 `realm-health-check.service` / `realm-health-check.timer` 都是**安装时由脚本生成**的，不在仓库里。因此「仓库里还有别的 unit 会反复拉起这个 unit」这个假设**不成立**（但见 §D.6 与 §F.2：现场仍需确认 `realm.service` 自己没有在循环）。

`[Service]` 段另有两点提问者未提、但对止血有影响：

- **没有 `User=`** → 守护以 root 运行（`cmd/xwpf-failover.service` 的 `[Service]` 段）。`ProtectSystem=strict` + `ReadWritePaths=/etc/xwpf` 只挡写，不挡 bind 特权端口。
- `WorkingDirectory=/etc/xwpf` → 目录不存在时 systemd 在启动阶段就失败（见 §D.2 D21）。

### A.2 —— **成立**

`cmd/xwpf-failover.py` 的 `Pool.serve` 原文：

```python
    async def serve(self):
        host, port_s = self.listen_addr.rsplit(":", 1)
        port = int(port_s)
        server = await asyncio.start_server(self._handle_one, host, port)
```

【实测】占用一个端口后用冻结点脚本启动，日志：

```
ERROR task <Task finished name='Task-2' coro=<Pool.serve() ...>> exception=OSError(10048,
"error while attempting to bind on address ('127.0.0.1', 63052): ...")> raised: ...
```

### A.3 —— **成立，但提问者省略了正是它导致「退出码 0」的那一步**

`cmd/xwpf-failover.py` 的 `_main` 原文：

```python
    waitable = {stop} | set(tasks)
    try:
        done, pending = await asyncio.wait(
            waitable, return_when=asyncio.FIRST_COMPLETED
        )
        if stop in done:
            logging.info("stop signal received, shutting down...")
        else:
            # Some task ended unexpectedly - inspect which
            for t in done:
                if t is stop:
                    continue
                try:
                    t.result()
                except Exception as exc:
                    logging.error("task %r raised: %s", t, exc)
    finally:
        for t in tasks:
            if not t.done():
                t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
```

省略掉的步骤是：`asyncio.wait` 返回后进入 `else` 分支 → `t.result()` **把 task 的异常取出来** → `except Exception` **捕获并只记一行日志** → 异常**没有**继续往外抛 → `finally` 取消其余 task → `_main` 正常返回。

**这一步是整条链的枢纽**：不是「`_main` 忘了处理异常」，而是「`_main` 主动把异常吞了并降级成一行日志」。所以异常既不会让进程以非 0 退出，也不会让 `_main` 抛错。

补充一处提问者也未提的**行为性事实**：`asyncio.wait(..., return_when=FIRST_COMPLETED)` 是 **all-or-nothing** 语义 —— 任意一个 pool 的 `serve` 失败，整个守护就整体退出，其余本来健康的 pool 也被 `finally` 里的 `t.cancel()` 一起取消。这决定了「改退出码」这件事本身并不改变故障传播范围（见 §E.1）。

### A.4 —— **前半成立；后半被更正**

**前半（task 内部异常 → 退出码 0）：严格成立。** 【实测】15 个用例的完整退出码表见 §D.1。

**后半（「只有配置读失败的两处是 `sys.exit(1)`」）：不成立。** 冻结点里非 0 退出的路径至少有 5 类，见 §D.1 的 D8–D16。提问者的表述漏掉了：

- `cmd/xwpf-failover.py` 的 `Pool.__init__` 对 `cfg["name"]` / `cfg["listen"]` / `cfg["primary"]` 的**下标取值** → 缺键时 `KeyError` → 未捕获 → traceback → **退出码 1**（不是 `sys.exit(1)`，但退出码同样是 1）。
- `cmd/xwpf-failover.py` 的 `Pool.__init__` 对 `int(p.get("interval_sec", 4))` 等的**类型转换** → 值非数字时 `ValueError` → **退出码 1**。
- `cmd/xwpf-failover.py` 的 `_main` 里 `argparse.ArgumentParser().parse_args()` → 参数非法 → `SystemExit(2)` → **退出码 2**。
- `cmd/xwpf-failover.py` 的 `_main` 里 `t.result()` 抛出的若是 **`BaseException` 而非 `Exception`**（`SystemExit` / `asyncio.CancelledError`；Python 3.8 起 `CancelledError` 继承 `BaseException`）→ `except Exception` **不捕获** → 逃出 `asyncio.run()` → **退出码 1**。
- `cmd/xwpf-failover.py` 的 `_main` 里 `loop.add_signal_handler(...)` 只捕获 `NotImplementedError`，**`RuntimeError` 未捕获** → 逃出 → **退出码 1**（低概率，但在受限环境/非主线程下真实存在）。

**更正后的准确表述**：
> 「task 内部抛出的**普通**异常（`Exception` 子类）→ 退出码 **严格为 0**；task 内部抛出**非** `Exception` 的 `BaseException` → 退出码 1；配置**读取**失败与配置**结构**不合法 → 退出码 1；CLI 参数非法 → 退出码 2。」

### A.5 —— **前半成立；后半不成立（定量）**

**前半（无限重启循环）：成立。** 依据见 C 问。

**后半（journald 写盘风暴 → 负载飙升 → sshd 握不上手）：定量上不成立。**

【实测】守护在 EADDRINUSE 场景下**每个进程只写 1 行** ERROR 日志（异常被 `except Exception` 吃掉，没有 traceback）；systemd 侧每轮约 3 行（`Main process exited` / `Failed with result` / `Scheduled restart job`）。

【仿真】实际重启间隔 = 进程存活时长 + `RestartSec=2s` + systemd 调度开销。Python 解释器启动到 bind 失败约 0.05~0.1 s，故实际间隔约 **2.1 s** → **约 0.47 次/秒**。

| 量 | 估算 | 判断 |
|---|---|---|
| journal 行数 | 0.47 轮/秒 × 3~5 行 ≈ **1.9 行/秒** ≈ 6,900 行/小时 | 对 journald 可忽略 |
| journal 体积 | 按 80 B/行 ≈ **0.55 MB/小时** ≈ 13 MB/天 | 与「写盘风暴」差 3~4 个数量级 |
| CPU | 每次 Python 启动约 40~60 ms CPU × 0.47/s ≈ **2~3%** | 不足以拖垮 |
| 内存 | 进程退出即释放 | **无累积** |
| 连接表 / 文件描述符 | 每次都是全新进程 | **无累积** |

**结论**：单靠 `xwpf-failover` 一个 unit 的这个循环，**不足以**造成 journald 写盘风暴或把 sshd 压垮。要让「负载飙升」成立，必须存在**提问者这条链之外的放大机制**，候选与判别方法见 §D.7 与附录 D。

**但请注意**：这条链的第 5 环虽不成立，**第 1~4 环成立**，所以「这个守护在无限重启」这件事本身是真的 —— 只是它**大概不是**把机器压垮的原因。真正的压垮原因需要 §F.2 的现场取证才能定位。

---

## B. 第 4 条的退出码判断是否严格成立

**这一问是本报告最关键的一问，因为它直接决定修复方案的形态。**

### B.1 「task 内部异常 → 退出码 0」：**严格成立**

机制（【源码级】，冻结点 `cmd/xwpf-failover.py` 的 `_main` 与 `main`）：

1. `Pool.serve` 内的异常让该 task 变成「done with exception」。
2. `_main` 的 `asyncio.wait(..., FIRST_COMPLETED)` 返回；`else` 分支遍历 `done`，对每个 task 调 `t.result()`。
3. `t.result()` **重新抛出**该异常，但紧随其后的 `except Exception as exc:` **把它捕获**，只做 `logging.error(...)`。
4. 异常**没有**逃出 `_main` → `asyncio.run(_main())` 正常返回。
5. `main()` 里只有 `except KeyboardInterrupt: pass`，**没有 `sys.exit()`** → 函数正常返回 → **解释器退出码 0**。

【实测】9 个「task 内部异常」用例的退出码**全部为 0**（完整表见 §D.1 的 D1–D7、D17）。

**这条不变式可以这样表述（不钉结构）**：
> **守护进程在「task 内部抛出普通异常」时，必须以退出码 0 结束。**

### B.2 「未捕获异常 → 退出码 1」：成立，但范围比提问者想的窄

【实测】以下路径实测退出码 **1**：

| 场景 | 冻结点位置 | 实测退出码 |
|---|---|---|
| pool 缺 `name` 键 | `cmd/xwpf-failover.py` 的 `Pool.__init__` | 1（`KeyError: 'name'`） |
| pool 缺 `listen` 键 | `cmd/xwpf-failover.py` 的 `Pool.__init__` | 1（`KeyError: 'listen'`） |
| pool 缺 `primary` 键 | `cmd/xwpf-failover.py` 的 `Pool.__init__` | 1（`KeyError: 'primary'`） |
| pool 不是 dict | `cmd/xwpf-failover.py` 的 `Pool.__init__` | 1（`TypeError: string indices must be integers`） |
| probe 阈值非数字 | `cmd/xwpf-failover.py` 的 `Pool.__init__` | 1（`ValueError: invalid literal for int()`） |
| `backups` 不是可迭代对象 | `cmd/xwpf-failover.py` 的 `Pool.__init__` | 1（`TypeError: 'int' object is not iterable`） |

**边界要说清楚**：这些 `KeyError` / `ValueError` / `TypeError` 发生在 `Pool.__init__`，而 `Pool.__init__` 是由 `_main` 的 `pools = [Pool(c) for c in pools_cfg]` 调的 —— **在 `try:` 块之外、也在 task 之外**。所以它们**不是**「task 内部异常」，而是**「未捕获异常」**，直接逃出 `asyncio.run()`，由解释器打印 traceback 并以 1 退出。

**两者的区别，用一句话钉住**：
> **异常发生在 task 内部 → 被 `_main` 的 `except Exception` 吃掉 → 退出码 0；异常发生在 `_main` 的 task 之外 → 未捕获 → traceback → 退出码 1。**

### B.3 修复方案形态的直接后果（**这一段会改变改动方案**）

因为「崩溃 → 退出码 0」：

- **只改** `Restart=always` → `Restart=on-failure`（而不先修退出码）→ 守护进程以 0 退出 → **systemd 认为它成功退出了，不重启** → **守护彻底消失、故障转移静默失效、机器不再有循环**。
  → 这是把「吵但不致命」换成「安静但致命」。**必须避免**。
- **正确顺序**：先让异常路径返回**非 0**（方向①），**再**把 `Restart=` 改成 `on-failure`（方向②）。**顺序不能反。**

【实测】方向①的两种写法都实测可用（见 §E.1）。

### B.4 一个必须纠正的常见误解（非本次提问内容，但现场极易踩）

**「进程崩了」≠「非 0 退出」。** 冻结点的 `cmd/xwpf-failover.py` 有一条**显式的、刻意的**「把崩溃降级成日志」的设计：`except Exception as exc: logging.error(...)`。这不是疏忽，是写法选择。现场看到 journal 里有 `ERROR task ... raised: ...` 而 `systemctl show` 里 `ExecMainStatus=0` 时，**不要怀疑自己看错了** —— 那是这份代码的既定行为。

---

## C. systemd 默认启动限流会不会掐断循环

**正面回答：不会掐断。在 `RestartSec=2s` 的实配下，循环可以无限持续。**

### C.1 默认值（【文档级】）

`systemd-system.conf(5)` 的 `DefaultStartLimitIntervalSec=` / `DefaultStartLimitBurst=` 原文：

> Configure the default unit start rate limiting, as configured per-service by `StartLimitIntervalSec=` and `StartLimitBurst=`. …
> `DefaultStartLimitIntervalSec=` defaults to **10s**. `DefaultStartLimitBurst=` defaults to **5**.

冻结点的 `cmd/xwpf-failover.service` 的 `[Unit]` 段没有覆盖这两项 → **走 manager 默认值：10 秒窗口 / 5 次**。

### C.2 限流确实作用于 `Restart=` 触发的自动重启（【文档级】）

`systemd.service(5)` 的 `Restart=` 原文：

> Note that service restart is subject to unit start rate limiting configured with `StartLimitIntervalSec=` and `StartLimitBurst=`, see systemd.unit(5) for details.

`systemd.unit(5)` 的 `StartLimitIntervalSec=` / `StartLimitBurst=` 原文：

> These configuration options are particularly useful in conjunction with the service setting `Restart=` …; however, they apply to all kinds of starts (including manual), not just those triggered by the `Restart=` logic.
> Note that units which are configured for `Restart=`, and which reach the start limit are not attempted to be restarted anymore; however, they may still be restarted manually or from a timer or socket at a later point, after the interval has passed. From that point on, the restart logic is activated again. `systemctl reset-failed` will cause the restart rate counter for a service to be flushed …
> Rate-limiting is enforced after any unit condition checks are executed, and hence unit activations with failing conditions do not count towards the rate limit.

→ **限流确实覆盖自动重启**。这一环提问者担心错了方向（提问者担心的是「限流会不会生效」，答案是**会生效**，问题在于**阈值**）。

### C.3 源码级：限流是怎么判的（【源码级】）

`src/core/service.c` 的 `service_can_start`：

```c
static int service_can_start(Unit *u) {
        ...
        /* Make sure we don't enter a busy loop of some kind. */
        r = unit_test_start_limit(u);
        if (r < 0) {
                service_enter_dead(s, SERVICE_FAILURE_START_LIMIT_HIT, false);
                return r;
        }
        return 1;
}
```

`src/core/unit.c` 的 `unit_test_start_limit`：

```c
int unit_test_start_limit(Unit *u) {
        ...
        if (ratelimit_below(&u->start_ratelimit)) {
                u->start_limit_hit = false;
                return 0;
        }
        log_unit_warning(u, "Start request repeated too quickly.");
        u->start_limit_hit = true;
        ...
        return -ECANCELED;
}
```

`src/basic/ratelimit.c` 的 `ratelimit_below`（**固定窗口**，不是滑动窗口）：

```c
bool ratelimit_below(RateLimit *r) {
        usec_t ts;
        assert(r);
        if (!ratelimit_configured(r))
                return true;
        ts = now(CLOCK_MONOTONIC);
        if (r->begin <= 0 ||
            usec_sub_unsigned(ts, r->begin) > r->interval) {
                r->begin = ts;  /* Start a new time window */
                r->num = 1;     /* Reset counter */
                return true;
        }
        if (_unlikely_(r->num == UINT_MAX))
                return false;
        r->num++;
        return r->num <= r->burst;
}
```

> **必须纠正的常见误解**：这是**固定窗口**，不是滑动窗口。窗口在 `now - begin > interval` 时**整窗重置**（`num = 1`），不是逐次滑动。提问者在 C 问里举的「启动间隔 > 2 秒导致滑动窗口内始终不超过 5 次」—— **结论对，但机制描述错**。按固定窗口算，判据更简单也更硬（见 C.4）。

### C.4 定量推演：为什么 `RestartSec=2s` 掐不断（【仿真】）

设：
- `g` = 实际相邻两次启动尝试之间的间隔 = 进程存活时长 + `RestartSec(2s)` + systemd 调度开销
- 限流窗口 `interval = 10s`，`burst = 5`

窗口内第 6 次尝试才会被拒（`num` 从 1 递增，`num <= burst` 才放行）。第 6 次尝试落在窗口内的条件是 `5g ≤ 10`，即 **g ≤ 2s**。

而 **`g` 必然 > 2s**（`RestartSec=2s` 之外还有进程存活时长与调度开销）。所以**永远不会出现第 6 次尝试落在同一窗口内的情况** → `num` 的峰值只到 5 → **永不触发拒绝**。

【仿真】把 `ratelimit_below()` 逐字移植为 Python（起点用真实 uptime 86400 s，进程存活 0.1 s，`RestartSec=2s`）：

```
0.0s:ALLOW(num=1), 2.1s:ALLOW(num=2), 4.2s:ALLOW(num=3), 6.3s:ALLOW(num=4),
8.4s:ALLOW(num=5), 10.5s:ALLOW(num=1)   ← 窗口在 10.5s 处整窗重置
12.6s:ALLOW(num=2), 14.7s:ALLOW(num=3), ...
→ 前 200 次尝试全部放行（窗口内 num 峰值 5，从未越界）
```

### C.5 什么条件下会掐断（对照表，【仿真】）

`interval=10s`、`burst=5` 下：

| `RestartSec` | 进程存活 0s | 0.05s | 0.2s | 1.0s |
|---|---|---|---|---|
| 0.10s | 掐断 | 掐断 | 掐断 | 掐断 |
| 0.50s | 掐断 | 掐断 | 掐断 | 掐断 |
| 1.00s | 掐断 | 掐断 | 掐断 | 掐断 |
| 1.50s | 掐断 | 掐断 | 掐断 | 不限 |
| 1.90s | 掐断 | 掐断 | 不限 | 不限 |
| **2.00s（实配）** | 掐断 | **不限** | **不限** | **不限** |
| 2.50s | 不限 | 不限 | 不限 | 不限 |

**实配的 `RestartSec=2s` 落在「不限」一侧**，但**余量只有约 0.05~0.1 s**。这是一个**极其脆弱的平衡**：只要有人把 `RestartSec` 调到 1.9s，或者把 `RestartSec` 删掉（systemd 默认 `DefaultRestartSec=100ms`，【文档级】`systemd-system.conf(5)`），循环就会被限流掐断 —— 而那恰恰是提问者希望的行为。

另外两种会让限流**更不可能**生效的情况：
- 本机 `DefaultStartLimitIntervalSec=0`（限流被禁用，`systemd.unit(5)` 明写 "may be set to 0 to disable any kind of rate limiting"）→ 无限循环。
- 本机 `DefaultStartLimitBurst` 被调小（例如 3）→ 更早掐断。

**所以必须上机核对这两个值**（§F.2 给了命令）。

### C.6 结论

1. **提问者的「无限重启循环」结论在默认配置下成立**，不必修改。
2. **但不能把 systemd 限流当成安全网**：默认配置下它就是「差 0.1 秒不触发」。把它当兜底 = 把可用性押在一个 0.1 秒的余量上。
3. **如果真的要限流，必须显式写死**（方向③），并接受 §E.3 描述的可用性代价。
4. 限流一旦触发，unit 会进入 `failed`（`src/core/service.c` 的 `service_can_start` → `service_enter_dead(s, SERVICE_FAILURE_START_LIMIT_HIT, false)`），日志里会出现 `Start request repeated too quickly.`（`src/core/unit.c` 的 `unit_test_start_limit`）。**这条日志是现场判定的金标准**：现场如果有它 → 限流已触发 → 循环**不是**无限循环；如果没有 → 无限循环成立。

### C.7 一个必须纠正的常识误解

**TIME_WAIT 不会导致 `EADDRINUSE`。** asyncio 在 POSIX 上默认给监听 socket 设 `SO_REUSEADDR`（Windows 上默认不设，正是这个差异导致本报告的实测用例在 Windows 上同样能复现 EADDRINUSE）。因此：

- 真正的 `EADDRINUSE` 原因是**另一个进程正在 LISTEN 同一个 addr:port**。
- 现场要查的是「**谁在 listen**」，不是「有没有 TIME_WAIT 残留」。
- 同理，`lib/failover.sh` 的 `failover_check_port_listening` 因为也设了 `SO_REUSEADDR`，**不会**把 TIME_WAIT 误判成占用 —— 这一点用户的担心（§E.5）不成立，但方向反了（见 §E.5）。

---

## D. 全部「启动后很快退出 / 失效」的路径清单

### D.1 进程级路径（守护自己结束）

**【实测】**下表全部由冻结点 `cmd/xwpf-failover.py` 的副本实跑得到，退出码为实测值而非推演。

| # | 触发条件 | 冻结点位置 | 退出码 | 备注 |
|---|---|---|---|---|
| D1 | listen 端口已被别的进程 LISTEN（EADDRINUSE） | `Pool.serve` | **0** | ★现场最可能的故障 |
| D2 | listen 地址没有冒号（`rsplit` 解包失败） | `Pool.serve` | **0** | `ValueError: not enough values to unpack` |
| D3 | listen 端口非数字 | `Pool.serve` | **0** | `ValueError: invalid literal for int()` |
| D4 | listen 端口越界（> 65535） | `Pool.serve` | **0** | `OverflowError`（不是 `OSError`，但仍是 `Exception`） |
| D5 | listen host 不可解析（gaierror） | `Pool.serve` | **0** | `socket.gaierror` |
| D6 | listen 端口需特权但进程非 root（PermissionError） | `Pool.serve` | **0** | unit 无 `User=` → 正常情况是 root |
| D7 | 任一 serve / probe task 抛普通异常 | `_main` 的 `asyncio.wait` → `t.result()` → `except Exception` | **0** | 与 D1 同一条通路 |
| D8 | 配置文件不存在 / 不可读 | `_main` 的配置读取块 → `sys.exit(1)` | **1** | |
| D9 | 配置文件 JSON 语法错误 | 同上 | **1** | |
| D10 | 配置不是非空 list | `_main` 的非空 list 校验 → `sys.exit(1)` | **1** | |
| D11 | pool 缺 `name` / `listen` / `primary` 键 | `Pool.__init__` | **1** | `KeyError`，traceback |
| D12 | pool 不是 dict | `Pool.__init__` | **1** | `TypeError` |
| D13 | probe 阈值非数字（`interval_sec` / `timeout_sec` / `fail_threshold` / `success_threshold` / `cooldown_sec`） | `Pool.__init__` | **1** | `ValueError` |
| D14 | `backups` 不是可迭代对象 | `Pool.__init__` | **1** | `TypeError: 'int' object is not iterable` |
| D15 | 命令行参数非法 | `_main` 的 `argparse` | **2** | `SystemExit(2)` |
| D16 | task 抛出 `BaseException`（`SystemExit` / `CancelledError`） | `_main` 的 `t.result()`（`except Exception` 不捕获 `BaseException`） | **1** | 逃出 `asyncio.run()` |
| D17 | 收到 SIGTERM / SIGINT | `_main` 的 `stop` future → 正常收尾 | **0** | 【源码级】；Windows 上 `add_signal_handler` 抛 `NotImplementedError`（被捕获）故无法实测该路径，但不影响退出码结论 |
| D18 | 被 OOM killer 杀（SIGKILL） | 内核 | **137** | `Restart=always` 会重启 → 可形成 137 循环 |
| D19 | 被 SIGKILL | 内核 | **137** | |
| D20 | `add_signal_handler` 抛 `RuntimeError`（loop 已关闭 / 非主线程等） | `_main` 的信号注册块（只捕获 `NotImplementedError`） | **1** | 未捕获 → traceback |
| D21 | SIGTERM 但信号处理器未装上（受限环境）→ 默认处置 | 内核 | **143** | |

### D.2 systemd 级路径（进程根本没起来）

这些**不是**「进程退出」，因此**不产生** `ExecMainStatus`；systemd 报的是 `Result=` 与 `status=`。

| # | 触发条件 | 冻结点位置 | 后果 |
|---|---|---|---|
| D22 | `ExecStart` 的可执行文件不存在 / 不可执行（`/usr/local/bin/xwpf-failover` 未安装或不可执行） | `cmd/xwpf-failover.service` 的 `[Service]` 的 `ExecStart` | `status=203/EXEC`。【源码级】`src/core/service.c` 的 `service_shall_restart` 对 `SERVICE_RESTART_ALWAYS` 只排除 `SERVICE_SKIP_CONDITION` → **仍会进入自动重启链** → 同样是每 2 秒一次的循环，只是日志里没有 Python traceback，只有 systemd 的 `Failed to locate executable` |
| D23 | `WorkingDirectory=/etc/xwpf` 不存在 | `cmd/xwpf-failover.service` 的 `[Service]` 的 `WorkingDirectory` | `status=200/CHDIR`，同类 |
| D24 | `ProtectSystem=strict` 挡住了必需路径 | 同上 | 同类 |

### D.3 不崩、但「静默失效」的路径（**这些比崩溃更危险，因为没有任何告警**）

| # | 触发条件 | 冻结点位置 | 表现 |
|---|---|---|---|
| D25 | `primary` 为空字符串 | `Pool.__init__` | 守护正常 bind、正常存活；所有转发目标为空 → 转发全失败，但**没有任何错误日志**。【实测】进程持续运行不退出 |
| D26 | `listen` 端口写成 `0` | `Pool.serve` | 绑到**随机临时端口** → 外部连不上 → 静默失效 |
| D27 | `backups` 为空数组（只有 primary） | `Pool.__init__` | 合法但不构成主备；primary 挂掉后 `probe_loop` 的 `else` 分支只会打 `PRIMARY DOWN, no healthy backup; staying on primary` → 流量继续压到故障主机 |
| D28 | `failover.json` 是合法 JSON 但 `pools_cfg` 为空 list | `_main` | 走 `sys.exit(1)`（D10），非静默 |

### D.4 归纳：退出码的**不变式**表述

> **冻结点的 `cmd/xwpf-failover.py`：凡「task 内部抛出的普通异常」，进程必须以退出码 0 结束；凡「配置读取失败 / 配置结构不合法」，进程必须以退出码 1 结束；凡「CLI 参数非法」，进程必须以退出码 2 结束。**

这三条不变式应当成为台架的护栏断言（而不是断言「某文件里有某几行」）。

### D.5 一个尚未被任何一方覆盖的路径

`cmd/xwpf-failover.py` 的 `Pool.probe_loop` 与 `Pool._probe` 把所有探测异常吞掉（`_probe` 的 `except Exception: return False`）。因此：

- **探测端永远不会导致进程退出** → 探测端故障表现为「一直判定 primary down」→ 频繁切主备 → 连接被反复掐断。
- 这是一条**独立的故障链**：`probe_loop` 每 `interval_sec`（默认 4 s）探测一次全部 target，若探测逻辑本身有 bug 或超时参数不当，**不会**触发任何异常路径，只会产生持续的切换抖动。现场若看到「连接每隔几秒断一次」，应优先怀疑这里，而不是重启循环。

### D.6 谁在拉起这个 unit（**排除性结论**）

【实测/源码级】在冻结点全树检索：

| 拉起路径 | 冻结点位置 | 频率 | 是否会形成循环 |
|---|---|---|---|
| systemd 的 `Restart=always` | `cmd/xwpf-failover.service` 的 `[Service]` | 每次退出后 2 s | **会**（本题的循环） |
| `lib/health.sh` 的健康检查 → `pf --restart-service` | `lib/health.sh` 的健康检查脚本体尾部 → `lib/ui.sh` 的 `main` 的 `--restart-service` 分支 → `lib/realm.sh` 的 `service_restart` → `lib/realm.sh` 的 `svc_restart` | 健康检查定时器，间隔取各规则的 `HEALTH_CHECK_INTERVAL` 最小值（默认 4 s） | **不会** —— `service_restart` 只 `systemctl restart realm`，**不碰 `xwpf-failover`** |
| `realm-health-check.service` | `lib/health.sh` 的 `start_health_check_service` 生成的 unit：`Type=oneshot`，**无 `Restart=`** | 定时器 | **不会** |
| `realm.service` | `lib/realm.sh` 的 `generate_service_file` 生成：`Restart=on-failure`，`RestartSec=3s` | 自身失败后 3 s | **不会**被默认限流掐断（3 s + 存活 > 2 s > 窗口阈值）→ **但它自己若陷入失败循环，同样是无限循环**，且它的失败模式（exit 1）比 `xwpf-failover` 更"正常"，现场容易忽略 |
| `lib/ui.sh` 的交互菜单 | `lib/ui.sh` 的 `failover_service_restart` | 人工触发 | **不会** |
| `xwPF.sh` / `lib/ui.sh` 的安装流程 | `xwPF.sh` 的 `failover_install_check && failover_service_enable`、`lib/ui.sh` 的同一对调用 | 人工触发 | **不会** |

→ **结论：冻结点仓库内，唯一会反复拉起 `xwpf-failover` 的自动化机制就是 systemd 自己的 `Restart=always`。** 提问者「健康检查把它拉起来」的假设**不成立**。

### D.7 「负载飙升」的真凶候选（若第 5 环确实发生过）

既然 `xwpf-failover` 单机的量级不足以压垮机器（§A.5），现场必须排除下面几个**放大器**：

1. **`realm.service` 也在循环**（`Restart=on-failure` + `RestartSec=3s`）→ realm 每次退出要重新读配置、重建全部连接 → 单次开销比 python 大得多。
2. **健康检查定时器每 4 s 一次 `systemctl restart realm`** → realm 被反复重启 → 全部现存连接被掐断 → 客户端疯狂重连 → 连接表耗尽。
3. **日志量级被 `logging.basicConfig(level=INFO)` 放大**：`cmd/xwpf-failover.py` 的 `_main` 里 `logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)`；unit 的 `ExecStart` **没有** `-v` → INFO 级 → `Pool.probe_loop` 的 `logging.debug(...)` 不输出。**但**如果有人手工用 `-v` 跑，每 4 s 每 pool 会打一行 debug → 量级仍不大。
4. **客户端重连风暴**：守护每 2.1 s 重启一次 → 所有经代理的 TCP 连接被强制断开 → 客户端（尤其是没做退避的）立刻重连 → 新连接又撞上同一个 EADDRINUSE → 放大。
5. **journald 自身在写盘瓶颈下被拖死**（低内存 VPS 上 journal 占用几百 MB 后进入 sync 模式）—— 这才是「写盘风暴 → 负载飙升」的真正可能形态，但它的触发源必须先由 1~4 之一提供。

现场判别方法见附录 D。

---

## E. 五个修复方向：各自会引入什么新问题

### E.1 方向①「守护进程内部异常退出码非 0」

**【实测】两种写法都成立**（用冻结点副本打补丁后实跑）：

| 写法 | 实测退出码 | 说明 |
|---|---|---|
| 在 `cmd/xwpf-failover.py` 的 `_main` 的 `except Exception as exc:` 分支里 `raise SystemExit(1)` | **1** | 干净，无 traceback |
| 在 `cmd/xwpf-failover.py` 的 `Pool.serve` 内 bind 失败时 `sys.exit(1)` | **1** | `SystemExit` 经 `t.result()` 逃出 `except Exception`（`SystemExit` 是 `BaseException`）→ 退出码 1 |

**新问题**：

1. **「一律非 0」会把「可恢复」和「致命」混为一谈。** 现状是 all-or-nothing：任意一个 pool 挂 → 整个守护退出 → systemd 重启 → 所有 pool 一起重来。如果只改退出码而不改这个语义，那么一个**次要** pool 的端口冲突会导致**全部**转发中断并进入重启循环 —— 与今天相比只是把「安静地挂」换成「吵闹地挂」。
   → 建议：**先分层**。把「单个 pool 绑定失败」降级为「该 pool 标记为 disabled + 显式 ERROR 日志 + 守护继续服务其余 pool」，把「配置不可用」保留为致命非 0。这会改变 `_main` 的 `FIRST_COMPLETED` 语义，**必须配套台架**（现在没有覆盖「单 pool 失败时其余 pool 是否仍可用」的用例）。
2. **`raise SystemExit(1)` 在 `_main` 里会跳过 `finally` 里的 task 清理吗？** 不会 —— `raise` 在 `try` 块内，`finally` 仍会执行。但要注意：`raise SystemExit(1)` 若放在 `for t in done:` 循环里，**只处理第一个出错的 task** 就整体退出了；此时 `finally` 会取消其余 task → 行为与今天一致。
3. **退出码语义会外溢到运维**：`systemctl show` 的 `ExecMainStatus` 变成 1 → 监控告警规则若按「status=0 = 正常」写，会开始大量告警。这是**预期的**，但要提前跟运维对齐。
4. **不要用 `sys.exit()` 在 task 内部** —— 虽然实测退出码确实是 1（§E.1 表），但它依赖 `SystemExit` 恰好是 `BaseException` 这一实现细节，且在 `_main` 的 `except Exception` 之外逃逸时**不会**打印 traceback，排障时缺少现场。推荐在 `_main` 层面统一 `raise SystemExit(1)`。

### E.2 方向②「unit 改 `Restart=on-failure`」

**与「退出码非 0」是否自洽？—— 自洽，但有先后依赖。**

`systemd.service(5)` 的 `Restart=` 原文（【文档级】）：

> If set to `on-failure`, the service will be restarted when the process exits with a non-zero exit code, is terminated by a signal (including on core dump, but excluding the aforementioned four signals), when an operation (such as service reload) times out, and when the configured watchdog timeout is triggered.

`src/core/service.c` 的 `service_shall_restart`（【源码级】）：

```c
        case SERVICE_RESTART_ALWAYS:
                return s->result != SERVICE_SKIP_CONDITION;
        case SERVICE_RESTART_ON_FAILURE:
                return !IN_SET(s->result, SERVICE_SUCCESS, SERVICE_SKIP_CONDITION);
```

→ `on-failure` 覆盖非 0 退出、信号（除 SIGHUP/SIGINT/SIGTERM/SIGPIPE）、超时、看门狗；**不覆盖**干净退出。

**新问题**：

1. **单独改方向② = 静默失效**（§B.3）：现状下守护以 0 退出 → `on-failure` 不重启 → **守护彻底消失，故障转移静默失效**。**方向②必须在方向①之后。**
2. **`on-failure` 仍会在 OOM（SIGKILL）时重启** → 内存泄漏型故障会变成新的无限循环。→ 需要方向③兜底，或用 `RestartPreventExitStatus=` 把特定退出码排除掉。
3. **`on-failure` 不重启「exec 失败」以外的启动阶段失败**：D22/D23/D24（`203/EXEC` / `200/CHDIR`）在 `Restart=always` 下会进重启链；改成 `on-failure` 后它们算 failure（`SERVICE_FAILURE_RESOURCES`），**仍会**重启 —— 行为不变，但这意味着「二进制缺失」依然会循环。
4. **`systemctl stop` 在任何 `Restart=` 下都不会触发重启**（【文档级】`systemd.service(5)`：*"the service will not be restarted"* if *"the service is stopped with `systemctl stop`"*）→ **这是 F 问止血动作安全的前提**，改 `Restart=` 不影响止血步骤。
5. **`on-failure` 下「干净退出」意味着什么？** `cmd/xwpf-failover.py` 的 `main` 正常返回就是 0 → 不重启。**这正是我们要的**（正常收尾不该被拉起）。但必须确保「致命故障」一定走非 0，否则方向①的覆盖面不全 → 这正是方向①要「穷举退出路径」的原因（§D.1 的 D1–D7 都得归到非 0）。

### E.3 方向③「加 `StartLimitIntervalSec=60` + `StartLimitBurst=3`」

**【仿真】能掐断，但代价是「守护永久停掉」。**

```
60s/3: 0.0s:ALLOW(num=1), 2.1s:ALLOW(num=2), 4.2s:ALLOW(num=3), 6.3s:REJECT(num=4)
       → 第 4 次启动尝试（约 6.3 s 后）被拒
60s/5: 0.0s..8.4s:ALLOW(num=1..5), 10.5s:REJECT(num=6)
       → 第 6 次启动尝试（约 10.5 s 后）被拒
```

**可用性代价（提问者专门问的，答案是：确实存在）**：

- 一旦触发，`src/core/service.c` 的 `service_can_start` 走 `service_enter_dead(s, SERVICE_FAILURE_START_LIMIT_HIT, false)` → unit 进入 **`failed`** 状态。
- `systemd.unit(5)` 明确写：*"units which are configured for `Restart=`, and which reach the start limit are not attempted to be restarted anymore; however, they may still be restarted manually or from a timer or socket at a later point, after the interval has passed."*
- `xwpf-failover.service` **没有**任何 timer / socket 依赖它（`[Unit]` 段只有 `After=network.target realm.service` / `Wants=realm.service`）→ **60 秒过去后也不会自动复活**。
- → **守护会一直停在那里，直到人工 `systemctl reset-failed` + `systemctl start`。** 这与今天「崩溃但一直在重试」相比，可用性是**下降**的：故障转移从前台代理变成彻底不代理。

**其他新问题**：

1. **限流计数是「每次启动尝试」都算的**，包括人工 `systemctl start`。`systemd.unit(5)` 明写限流 *"apply to all kinds of starts (including manual)"* → **运维手工 `start` 也会消耗额度**，连续试几次就再也起不来了 → 排障时极易被限流锁死。缓解：排障前先 `systemctl reset-failed`。
2. **限流不区分「失败原因」**：一次人为的 `systemctl restart` 也会计数。
3. **必须配套一个外部可见的「守护已停」信号**，否则「限流停机」和「守护正常」在监控上无法区分。可选：`systemctl is-active` 轮询告警、或在 unit 上加 `WatchdogSec` + 守护侧 `sd_notify` 心跳（注意：这会需要改 `Type=notify`，改动面更大）。
4. **别忘了 `StartLimitAction=`**：默认是 `none`（只是拒绝启动）。若设成 `reboot`/`poweroff` 就更危险；**建议显式写 `StartLimitAction=none`** 以免被继承到意外值。
5. **与方向②的组合**：`on-failure` + `60s/3` → 干净退出（0）不重启、非 0 退出重启且 6 秒后被限流打死 → **等价于「守护崩溃 6 秒后彻底停机」**。这个组合必须配合方向①的「单 pool 失败不拖垮整体」才合理。

### E.4 方向④「`start_server` 失败时给明确错误」

**新问题**：

1. **只加日志不改退出码 = 零效果**。今天的日志已经写了（`ERROR task ... raised: ...`），问题不在信息量，在**退出码**。→ 方向④必须与方向①绑定。
2. **「明确错误」的措辞要能区分三类**：(a) 端口被占用（可等一会儿重试）、(b) 权限不足（重试无用，配置错）、(c) 地址非法（配置错，重试无用）。现在这三类都被压成同一行 `OSError`。
3. **如果改成「退避重试」**（比如 bind 失败后 sleep 5 s 再试），会引入两个新问题：
   - **两层重试叠加**：进程内退避 + systemd 的 `RestartSec` → 行为变得难以推理，现场看到的时间线不再是 2.1 s 一轮。
   - **退避让进程「活着但不服务」**：如果退避是无限的，systemd 永远不会重启它，端口冲突会变成一个「进程在、端口不通」的静默故障。→ **必须有重试上限，超过上限就走非 0 退出。**
4. **退避与 `FIRST_COMPLETED` 语义冲突**：现在任意 task 结束就整体退出。要做「单 pool 重试」，`_main` 的等待逻辑必须重写（`FIRST_COMPLETED` → 监视各 pool 状态），这是本轮改动里**代码量最大、回归风险最高**的一块。→ 建议**分两步**：先做「明确错误 + 统一非 0 退出」（小改动），再做「单 pool 隔离 + 退避」（大改动）。

### E.5 方向⑤「写 `failover.json` 前做端口占用校验」

**现有基础**：`lib/failover.sh` 的 `failover_check_port_listening` 已经做了 TCP bind 探测（`0.0.0.0:port` 与 `::port`，带 `SO_REUSEADDR`），`lib/failover.sh` 的 `failover_alloc_port` 也会避开 rules 目录里的 `LISTEN_PORT` 与 `failover.json` 里已有的 `127.0.0.1:<port>`。

**新问题 / 误伤评估（提问者专门问的）**：

1. **TIME_WAIT 不会被误伤，也不会被误判。** `lib/failover.sh` 的 `failover_check_port_listening` 的探测 socket 设了 `SO_REUSEADDR`，与守护进程在 POSIX 上的实际 bind 语义**一致** → 探测结果与实际 bind 结果一致 → 不会把 TIME_WAIT 当占用。**提问者的这个担心不成立。**
2. **但真正会导致 EADDRINUSE 的场景，探测未必拦得住**：
   - **TOCTOU**：探测通过 → 到守护真正 bind 之间有间隙 → 期间别人抢占了端口 → 仍 EADDRINUSE。**前置校验不能替代运行时处理。**
   - **配置内部自相矛盾**：两个 pool 的 `listen` 写成同一个端口 → 校验查的是「有没有别人在听」，查不出「自己和自己冲突」→ 第二个 pool 必然 bind 失败。
   - **校验探针与实际 bind 的地址不同**：探测探 `0.0.0.0:port` 和 `::port`；守护若绑在具体 IP（如 `10.0.0.5:443`），两者语义不同。
   - **`failover_alloc_port` 避开的端口集合里**，`lib/failover.sh` 的 `failover_used_ports_from_failover_json` 只抽取 `127.0.0.1:<port>` 形态的地址 → **代理自己的 public `listen`（如 `0.0.0.0:443`）不在被避让集合里** → 代理的 public listen 端口与 realm 规则的 public listen 端口撞车时，**配置期完全拦不住**。这恰恰是最可能的现场故障形态。
3. **误伤的另一个真实场景**：校验在**配置写入时**执行，而守护是**开机自启**（`[Install]` 的 `WantedBy=multi-user.target`）。开机瞬间，realm 可能还没起来、或上一个实例还没退干净 → 校验结论与实际不符。→ 校验的结论只能当作**提示**，不能当作**判据**。

**结论**：方向⑤的定位应是「**把故障提前到配置期，并给出可读的错误**」，**不能**当成「保证不会 EADDRINUSE」。真正的兜底必须是方向①（运行时失败要非 0 退出 + 可观测）。

### E.6 建议的改动顺序与组合

| 顺序 | 改动 | 为什么必须在这个位置 |
|---|---|---|
| 1 | 方向①：异常路径 → **明确非 0 退出**（穷举 §D.1 的 D1–D7） | 后面所有改动都依赖「崩溃 = 非 0」这个前提 |
| 2 | 方向④（前半）：`Pool.serve` 失败时给出**分类明确**的错误信息 | 退出码改对之后，日志决定现场能否定位 |
| 3 | 方向②：`Restart=always` → `on-failure` | **必须在 1 之后**，否则静默失效 |
| 4 | 方向③：显式 `StartLimitIntervalSec=` / `StartLimitBurst=` + `StartLimitAction=none` | 给方向②加上「崩溃风暴」的硬上限 |
| 5 | 方向⑤：配置期端口占用校验（**作为提示，不作为判据**） | 提前发现，但接受 TOCTOU |
| 6 | 方向④（后半）：单 pool 失败隔离 + 退避重试（**独立 PR**） | 改动面最大、需要配套台架，**不要**和前五项混在一起 |
| 7 | **增加「守护长期不健康」的外部可见信号** | 方向③一旦触发就是静默停机，没有信号就等于故障转移彻底失效且无人知晓 |

**总原则**：**退出码语义、unit 重启策略、限流阈值三者必须一起改，且顺序不能颠倒。** 单独改任何一项都会把「吵但不致命」换成「安静但致命」或「安静地循环」。

---

## F. 最小止血顺序（线上机器已宕）

**前提**：VPS `VPS-87` 当前 SSH banner 超时、ping 50% 丢包 → **本轮无法登录**，以下命令必须由用户在**云厂商的 VNC / 串口 / 网页控制台**执行。

**总原则**：**先让机器恢复可用（断循环），再取证（现场不等人），最后修因（从容做）。** 取证材料不会因为晚一步而消失 —— journal 会保留，配置还在磁盘上。

### F.1 止血六步

| 步 | 命令 | 预期效果 | 风险 |
|---|---|---|---|
| **1. 断循环** | `systemctl stop xwpf-failover` | 守护收到 SIGTERM → `_main` 的 `stop` future 置位 → 干净收尾 → 退出码 0。**`Restart=` 对 `systemctl stop` 不生效**（【文档级】`systemd.service(5)`）→ **不会**被拉回来。机器 CPU/IO 立刻回落 | ⚠️ **所有经主备代理的现存 TCP 连接会被断开**，转发全部中断 → 必须在维护窗口做；若当前业务已不可用则无额外代价 |
| **1'. 兜底**（仅当 1 无响应） | `systemctl mask xwpf-failover` | 让 unit 不存在 → 任何路径都无法再拉起 | ⚠️ **不要用 `chmod -x /usr/local/bin/xwpf-failover`** —— 那会变成 `203/EXEC`，在 `Restart=always` 下**依然每 2 秒循环一次**（见 §D.2 D22），只是日志不同。`mask` 才会真正停掉 |
| **2. 取证**（循环已断，此刻最安全） | `systemctl show xwpf-failover -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus -p NRestarts -p Restart -p RestartUSec`<br>`systemctl show --property=DefaultStartLimitIntervalSec --property=DefaultStartLimitBurst`<br>`journalctl -u xwpf-failover --since "-2h" --no-pager \| tail -200` | 确认：① 循环的是不是这个 unit（`NRestarts`）② 退出码是不是 0（`ExecMainStatus`）③ 限流有没有触发（`journalctl` 里搜 `Start request repeated too quickly`）④ 本机限流默认值 | 只读，无风险 |
| **3. 找端口占用方** | `ss -lntp \| grep -E ':(443\|10443\|11442)\b'`<br>（无 `ss` 时：`netstat -lntp` 或 `lsof -nP -iTCP -sTCP:LISTEN`）<br>`cat /etc/xwpf/failover.json` | 定位是谁占着代理的 `listen` 端口 → 这就是真正的根因候选 | 只读。若 `ss`/`netstat`/`lsof` 都没有（精简镜像），改用 `cat /proc/net/tcp` 手工解端口 |
| **4. 一并排除 `realm.service`** | `systemctl show realm -p NRestarts -p ExecMainStatus -p Result`<br>`journalctl -u realm --since "-2h" --no-pager \| tail -100` | `realm.service` 是 `Restart=on-failure` + `RestartSec=3s`（`lib/realm.sh` 的 `generate_service_file`）→ **它同样不会被默认限流掐断** → 它也可能在自己循环，且单次开销更大 | 只读。**若 realm 也在循环，机器压垮的真凶很可能在这里**，此时第 1 步应加 `systemctl stop realm` |
| **5. 清失败态** | `systemctl reset-failed xwpf-failover` | 清掉 `failed` 状态与**启动限流计数**（【文档级】`systemd.unit(5)`：*"systemctl reset-failed will cause the restart rate counter for a service to be flushed"*） | 只改 systemd 状态，**不解决根因**。不修因直接 `start` → 若限流已生效，6 秒后又会 dead（§E.3） |
| **6. 修因后再起** | 改 `/etc/xwpf/failover.json` 里冲突的 `listen` 端口（避开占用方），或停掉占用方 →<br>`systemctl start xwpf-failover` →<br>`systemctl status xwpf-failover --no-pager -l` + `journalctl -fu xwpf-failover` | 确认出现 `listening on ...` 且**不再**出现 `Scheduled restart job` | 改配置前先备份 `cp /etc/xwpf/failover.json /etc/xwpf/failover.json.bak`。端口改动可能需要同步改 realm 侧规则 —— **改前先确认规则里的 `LISTEN_PORT`** |

### F.2 三个最容易做错的动作

1. **不要用 `kill`（尤其 `kill -9`）来停这个守护。** `Restart=always` 覆盖「非正常信号终止」（【文档级】`systemd.service(5)`：`always` = *"regardless of whether it exited cleanly or not, got terminated abnormally by a signal"*）→ **杀掉了它照样会被拉起来**。正确做法只有 `systemctl stop`（它会置 `forbid_restart`，`src/core/service.c` 的 `service_shall_restart` 里 *"Don't restart after manual stops"*）。同理 `chmod -x` 也拦不住（见 §F.1 第 1' 步）。
2. **不要先 `systemctl restart`**。`restart` 也是 systemd 操作 → 同样不触发自动重启，但它会**立刻再起一次** → 若根因还在 → 又多一次失败启动 → 白白消耗限流额度。
3. **不要在没有 `reset-failed` 的情况下反复 `start`**。限流对**人工 start 也计数**（【文档级】`systemd.unit(5)`）→ 连续试几次后连人工都起不来 → 排障被限流锁死。**每次尝试前先 `systemctl reset-failed xwpf-failover`。**

### F.3 止血的「最低成功判据」

- `systemctl is-active xwpf-failover` → `active`
- `journalctl -u xwpf-failover --since "-5min" | grep -c 'Scheduled restart job'` → **0**
- `journalctl -u xwpf-failover --since "-5min" | grep -c 'listening on'` → ≥1
- `ss -lntp | grep -E ':<代理 listen 端口>'` → 有且只有一个进程在 LISTEN
- 机器负载回落：`uptime` 的 load average 明显下降，`vmstat 1 5` 的 `r` 列接近 CPU 核数

---

## 附录 A：退出码实测原始数据

方法：从 `git show f730c8b:cmd/xwpf-failover.py` 导出到临时目录，**不修改仓库**；构造各类 `failover.json` 后实跑并记录退出码。

| 用例 | 构造 | 退出码 | 关键输出 |
|---|---|---|---|
| A | listen 指向已占用端口 | **0** | `ERROR task ... exception=OSError(... 10048 ...) raised:` |
| B | listen 无冒号 | **0** | `exception=ValueError('not enough values to unpack (expected 2, got 1)')` |
| C | listen 端口非数字 | **0** | `exception=ValueError("invalid literal for int() with base 10: 'abc'")` |
| D | pool 缺 `primary` | **1** | `KeyError: 'primary'`（traceback） |
| E | probe `interval_sec` 非数字 | **1** | `ValueError: invalid literal for int() with base 10: 'abc'` |
| F | 配置是 dict 不是 list | **1** | `ERROR config must be a non-empty list of pools` |
| G | 配置文件不存在 | **1** | `ERROR failed to read config ...: [Errno 2] No such file or directory` |
| H | 非法 CLI 参数 | **2** | `error: unrecognized arguments: --no-such-flag` |
| I | JSON 语法错误 | **1** | `ERROR failed to read config ...: Expecting property name ...` |
| J | listen host 非法 | **0** | `exception=gaierror(11001, 'getaddrinfo failed')` |
| K | pool 缺 `name` | **1** | `KeyError: 'name'` |
| L | pool 缺 `listen` | **1** | `KeyError: 'listen'` |
| M | pool 不是 dict | **1** | `TypeError: string indices must be integers, not 'str'` |
| N | `backups` 是 int | **1** | `TypeError: 'int' object is not iterable` |
| O | listen 端口 99999 | **0** | `exception=OverflowError('bind(): port must be 0-65535.')` |
| P | `primary` 为空串 + listen 端口 0 | **不退出**（持续运行） | 静默失效，不崩溃 |

**修复写法实测**：

| 变体 | 改法 | 退出码 |
|---|---|---|
| V1 | `cmd/xwpf-failover.py` 的 `_main` 的 `except Exception as exc:` 分支加 `raise SystemExit(1)` | **1** |
| V2 | `cmd/xwpf-failover.py` 的 `Pool.serve` 内 bind 失败时 `sys.exit(1)` | **1** |
| 基线 | f730c8b 原样 | **0** |

**平台说明**：本机为 Windows。Windows 上 asyncio 的 `start_server` 默认**不**设 `SO_REUSEADDR`（POSIX 上默认设），因此 EADDRINUSE 的触发条件更严（反而更容易复现）；`OSError` 家族在两个平台上的捕获行为一致。**SIGTERM 路径（D17）在 Windows 上无法实测**（`loop.add_signal_handler` 抛 `NotImplementedError`，被代码捕获 → 信号处理器装不上），该条的退出码结论来自源码分析。

---

## 附录 B：限流仿真（`ratelimit_below()` 的逐字移植）

`src/basic/ratelimit.c` 的 `ratelimit_below` 的等价 Python：

```python
def below(self, ts):
    if self.interval <= 0 or self.burst <= 0:
        return True
    if self.begin <= 0 or (ts - self.begin) > self.interval:
        self.begin, self.num = ts, 1      # 整窗重置
        return True
    self.num += 1
    return self.num <= self.burst
```

关键参数：`interval=10s`、`burst=5`、`base=86400s`（真实 uptime）、进程存活 0.1 s、`RestartSec=2s`。

| 场景 | 结果 |
|---|---|
| 默认 10s/5 | 前 200 次尝试全部放行；轨迹 `0.0s:ALLOW(num=1) … 8.4s:ALLOW(num=5) → 10.5s:ALLOW(num=1)`（窗口在 10.5 s 处整窗重置）；窗口内 `num` 峰值 5 → **永不越界** |
| `RestartSec=1.0s` | 第 7 次尝试（t=6.6 s）被拒 → 循环被掐断 |
| `RestartSec=0.5s` | 第 7 次尝试（t=3.6 s）被拒 |
| 限流禁用（`interval=0`） | 全部放行 → 无限循环 |
| `interval=10s, burst=3` | 第 4 次尝试被拒 |
| `interval=30s, burst=5` | 第 6 次尝试被拒 |
| **提案 `60s/3`** | 第 4 次尝试（t=6.3 s）被拒 → unit 进 `failed` 并**保持停机**（无 timer 会再拉起它） |
| **提案 `60s/5`** | 第 6 次尝试（t=10.5 s）被拒 → 同上 |

---

## 附录 C：官方文档与源码出处

| 出处 | 用途 |
|---|---|
| `systemd.service(5)` 的 `Restart=` | `always`/`on-failure` 的触发条件；「service restart is subject to unit start rate limiting」；「stopped with `systemctl stop` 不重启」 |
| `systemd.service(5)` 的 `Type=` | `Type=simple` 下 `systemctl start` 即使二进制调不起来也报成功 |
| `systemd.service(5)` 的 `RestartPreventExitStatus=` / `RestartForceExitStatus=` | 方向②的补充手段 |
| `systemd.unit(5)` 的 `StartLimitIntervalSec=` / `StartLimitBurst=` | 限流语义、适用面（含人工 start）、触发后不再自动重启、`reset-failed` 会清计数、限流在条件检查之后 |
| `systemd-system.conf(5)` 的 `DefaultStartLimitIntervalSec=` / `DefaultStartLimitBurst=` | 默认 10s / 5 |
| `systemd-system.conf(5)` 的 `DefaultRestartSec=` | 默认 100 ms（用于 §C.5 的敏感性讨论） |
| `src/basic/ratelimit.c` 的 `ratelimit_below` | 固定窗口判定的精确语义 |
| `src/core/unit.c` 的 `unit_test_start_limit` | `Start request repeated too quickly.` 的出处；`start_limit_hit` 置位 |
| `src/core/service.c` 的 `service_can_start` | 限流判定点在启动路径上；`SERVICE_FAILURE_START_LIMIT_HIT` |
| `src/core/service.c` 的 `service_shall_restart` | `always` / `on-failure` 的源码级判定；`manual stop` 不重启 |
| `src/core/service.c` 的 `service_enter_dead` | `allow_restart` 参数的语义 |
| systemd v255 源码树 | `github.com/systemd/systemd`（tag v255） |

---

## 附录 D：需在 VPS 上执行的取证清单（本轮无法完成）

**前置**：VPS 当前 SSH banner 超时、ping 50% 丢包 → 必须走**云厂商控制台**（VNC / 串口 / 网页终端）。登进去后先做 §F.1 的第 1 步断循环，再做取证。

| # | 取证项 | 命令 | 用来判定 |
|---|---|---|---|
| D-1 | 是不是这个 unit 在循环 | `systemctl show xwpf-failover -p NRestarts -p ExecMainStatus -p Result -p ActiveState` | `NRestarts` 持续增长 = 循环成立 |
| D-2 | 退出码是不是 0 | `systemctl show xwpf-failover -p ExecMainCode -p ExecMainStatus` | 0 → 印证 §A.4；非 0 → 现场故障与假设不同，要重查 |
| D-3 | 限流是否触发 | `journalctl -u xwpf-failover --no-pager \| grep -c 'Start request repeated too quickly'` | >0 → 循环**不是**无限的（§C.6 金标准） |
| D-4 | 本机限流默认值 | `systemctl show --property=DefaultStartLimitIntervalSec --property=DefaultStartLimitBurst`<br>`cat /etc/systemd/system.conf 2>/dev/null; ls /etc/systemd/system.conf.d/ 2>/dev/null` | 若 `interval=0` → 限流被禁用（§C.5） |
| D-5 | 循环的实际周期 | `journalctl -u xwpf-failover --no-pager \| grep 'Scheduled restart job' \| tail -20` | 相邻两条的时间差应 ≈ 2.1 s（印证 §C.4 的 `g`） |
| D-6 | **谁占了端口** | `ss -lntp \| grep -E ':<listen 端口>'`<br>退化：`netstat -lntp` / `lsof -nP -iTCP -sTCP:LISTEN` / `cat /proc/net/tcp` | 根因候选（**不是** TIME_WAIT，§C.7） |
| D-7 | 代理实际配置 | `cat /etc/xwpf/failover.json` | 看 `listen` 与 `primary`/`backups`；确认有没有两个 pool 用同一个 `listen`（§E.5） |
| D-8 | realm 是否也在循环 | `systemctl show realm -p NRestarts -p ExecMainStatus -p Result` | 若也在循环 → 机器压垮的真凶在这里（§D.7 候选 1） |
| D-9 | 健康检查定时器 | `systemctl list-timers realm-health-check.timer --no-pager`<br>`systemctl show realm-health-check.timer -p OnUnitActiveSec` | 确认它只重启 realm（§D.6） |
| D-10 | 机器整体负载来源 | `uptime`；`vmstat 1 5`；`journalctl --disk-usage`；`top -bn1 \| head -20` | 找 §D.7 里的真凶 |
| D-11 | journal 体积 | `journalctl --disk-usage`；`du -sh /var/log/journal` | 印证/推翻 §A.5 的量级估算 |
| D-12 | 是否有其他 unit 在循环 | `systemctl list-units --type=service --state=failed`；`journalctl --since "-1h" \| grep -c 'Scheduled restart job' \| ...` | 全局排查 |

---

## 附录 E：本报告没有覆盖 / 不能确定的事

1. **VPS 上到底发生了什么** —— 本轮**无法登录**，所有现场结论均为「待现场」。本报告证明的是「**如果** `xwpf-failover` 因端口冲突陷入重启循环，**那么**会怎样」，而不是「**它确实**这样了」。
2. **systemd 侧没有实机验证** —— 本机无 systemd/WSL/Docker。C 问的结论由【文档级】+【源码级】+【仿真】三条腿支撑，**没有** systemd 实机实测。仿真用的是 systemd v255 源码；若 VPS 是 Debian 11（systemd 247）或更早，`ratelimit_below()` 的实现细节可能略有差异，但 `DefaultStartLimitIntervalSec`/`DefaultStartLimitBurst` 的默认值与「固定窗口 + `num <= burst`」的语义自 systemd v209 起未变。
3. **「负载飙升 → sshd 握不上手」的具体成因** —— 本轮只能判定「`xwpf-failover` 单机循环的量级不足以造成」，**不能**判定真凶。真凶需 §D.7 / 附录 D 的现场数据。
4. **§E.4 后半（单 pool 隔离 + 退避重试）的具体实现** —— 本报告只给了风险评估与改动量判断，没有给设计（超出「评估新问题」的范围）。
5. **台架对本轮结论的覆盖度** —— 本轮**未**检查 `tests/` 是否已有覆盖 §D.1 退出码不变式的用例。若要落地方向①，**必须先补这条护栏**（否则改了退出码，台架不会报警）。
