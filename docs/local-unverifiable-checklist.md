# 本机不可验项清单（开发机 → 真机）

> 适用范围：`realm-xwPF-offline-active-standby` 的开发机（Windows + Git Bash + Python 3.11）。
> 真机：Linux VPS（生产环境是 Linux，行为与开发机在若干点上是**不一样**的）。
>
> 这份清单的用法：**每条都写清楚「本机为什么验不了」「真机怎么验」「验收判据是什么」**，
> 不写「本机无法验证」这种含糊话 —— 含糊的条目会在真机验收时被跳过，或者被临时改口径。

---

## 1. 端口占用的真机判定

| 本机不可验项 | 为什么本机不可验 | 真机验法 + 验收判据 |
|---|---|---|
| listen 端口**真被别的进程占住**时，`failover_check_port_listening` 返回「被占用」 | **Windows 的 `SO_REUSEADDR` 语义与 Linux 相反**：Windows 上带 `SO_REUSEADDR` 的第二个 socket 可以直接绑到已有活跃监听的端口上（实测：监听 45999 后，另一个带 `SO_REUSEADDR` 的 socket 绑定成功），所以试绑**永远成功** → 本机测出来的永远是「端口空闲」。Linux 上 `SO_REUSEADDR` 只允许复用 TIME_WAIT，不会覆盖活跃监听 → 才会报 `EADDRINUSE`。 | 真机上：① `ss -lntp \| grep ':<端口>'` 确认端口被占；② 建一个主备池，监听端口填该端口 → **判据**：提示「端口 <端口> 已被占用 (listen address already in use)」，**拒绝写入** `failover.json`，且返回码非 0；③ 释放端口后重试 → **判据**：正常建池成功。 |

## 2. 协议族不可用的真实 errno（IPv6-only 主机）

| 本机不可验项 | 为什么本机不可验 | 真机验法 + 验收判据 |
|---|---|---|
| 「该协议族不可用」在真实内核上的 errno 形态（`socket()` 失败 vs `bind()` 报 `EADDRNOTAVAIL`） | 本机 IPv4/IP6 都能用，**造不出**「IPv4 不可用」的主机。本轮是用注入假 `socket` 模块的方式验证判定逻辑（`EADDRNOTAVAIL` → 跳过该族 → 试下一个族），**不等于**真机上的真实行为。 | ① 在一台只配了 IPv6 的主机上（或 `ip addr` 里没有 IPv4 地址的容器）建池，监听端口填一个空闲端口 → **判据**：**不再**提示「端口已被占用」；提示为「无法确认端口是否空闲」或直接建池成功（取决于另一个协议族能否试绑）。② 对照：同一台机上 `python3 -c "import socket;s=socket.socket(socket.AF_INET);s.bind(('0.0.0.0',12345))"` 的真实报错 → 记下 errno，用于确认判定分支覆盖到了。 |

## 3. ETXTBSY：覆盖正在执行的二进制

| 本机不可验项 | 为什么本机不可验 | 真机验法 + 验收判据 |
|---|---|---|
| 覆盖**正在运行的** `/usr/local/bin/xwpf-failover` 时内核报 `ETXTBSY` | 这是 **Linux 内核**语义（正在执行的 inode 不可写）。Windows 上同样场景是「被挡住的只有 cp，`mv` 换目录项能替换运行中的 exe」—— 结论不可互证。 | 真机上：对**正在运行的** `/usr/local/bin/xwpf-failover` 做覆盖写 → **判据**：报 `Text file busy`（ETXTBSY）。⚠️ 覆盖仓库里的 `cmd/xwpf-failover.py` 源文件**不构成验证** —— 那不是被执行的 inode。 |

## 4. systemd 限流后 unit 的真实状态

| 本机不可验项 | 为什么本机不可验 | 真机验法 + 验收判据 |
|---|---|---|
| 崩溃循环被限流打停后 unit 停在 `failed`、`systemctl start` 拉不起来、`reset-failed` 才能恢复 | 本机没有 systemd。 | 真机上：让守护因端口被占反复崩溃（`StartLimitBurst=3` / `StartLimitIntervalSec=60`）→ **判据**：① `systemctl show xwpf-failover -p Result -p NRestarts` → `Result=exit-code`、`NRestarts≥3`；② `systemctl start` 之后 unit 仍是 `failed`；③ `systemctl reset-failed xwpf-failover && systemctl start xwpf-failover` → 起来；④ **产品侧**：执行一次 `pf install`（或建一次池）之后 → **判据**：`systemctl show -p Result` 不再是 `exit-code`（自动清计数生效），且**未处理**的故障场景下计数不会被误清。 |

## 5. 守护进程以 systemd 身份写状态文件

| 本机不可验项 | 为什么本机不可验 | 真机验法 + 验收判据 |
|---|---|---|
| `xwpf-failover.service` 的加固配置（`ProtectSystem=strict` + `ReadWritePaths=/etc/xwpf` + `ReadOnlyPaths=/etc/xwpf`）下，守护进程**能不能**写 `/etc/xwpf/failover-state.json` | 本机没有 systemd，也没有 unit 沙箱；本机的进程是普通用户起的。 | 真机上：起守护 → **判据**：① `/etc/xwpf/failover-state.json` 存在且内容是合法 JSON；② `journalctl -u xwpf-failover` 里**没有**「状态文件写入失败」告警；③ 菜单里能看到「运行状态」而不是「暂无状态文件」。 |

## 6. 状态文件跨进程重启不丢

| 本机不可验项 | 为什么本机不可验 | 真机验法 + 验收判据 |
|---|---|---|
| 「上次切换时间」跨守护进程重启仍然保留、冷却期不被重启清零 | 本机自测只做到「进程内落盘 + 读回」，**没有**在真机上验证 systemd 重启后的行为，也没有验证 systemd 拉起时工作目录/权限是否影响读回。 | 真机上：制造一次切换（杀掉主后端）→ 记下 `last_switch_at` → `systemctl restart xwpf-failover` → **判据**：① 重启后状态文件里的 `last_switch_at` 与重启前**一致**（不是空、不是重启时刻）；② 重启后到冷却期结束之前不会立刻切回主。 |

## 7. realm 回环池按双地址切换（真机端到端）

| 本机不可验项 | 为什么本机不可验 | 真机验法 + 验收判据 |
|---|---|---|
| 「转发打回环口、探测打真实后端」在真实 realm 链路上的切换 | 本机没有 realm，也没有真实后端；本机自测用的是两个普通 TCP 监听端口，**证明的是口径与状态机**，不是与 realm 的联动。 | 真机上（realm 回环池）：① `cat /etc/xwpf/failover.json` → 判据：`primary` 形如 `127.0.0.1:<回环口>\|<真实后端>`；② 杀掉真实后端 → **判据**：日志出现 `PRIMARY DOWN → BACKUP`，且连接被转到了备线；③ 状态页显示「当前主 = 备1」「探测目标 = 真实后端」「连续失败数 ≥ 阈值」。 |

## 8. `err_kind` 在 Linux 上的区分

| 本机不可验项 | 为什么本机不可验 | 真机验法 + 验收判据 |
|---|---|---|
| `refused`（服务没监听）与 `timeout`（包丢了）在**生产环境**的区分 | 本机 Windows 上，连接 127.0.0.1 上无人监听的端口，**拒连要 ~2 秒才回来**（实测 2031 ms），所以超时设成 1s 时会**先**判成 timeout；只有超时 ≥ 3s 才能拿到 `refused`。本机还发现 `192.0.2.1` 这类地址在本机网络环境下**被透明接管**（连接立即成功），不能用来造 timeout。 | 真机（Linux）上：① 探一个无人监听的本机端口 → **判据**：`err_kind=refused`（Linux 上拒连是即时的，不受 Windows 那个 2 秒影响）；② 探一个黑洞地址（如 `10.255.255.1`）并把超时设成 2s → **判据**：`err_kind=timeout`。 |

---

## 附：本轮**本机已验**的项（对照，避免重复劳动）

| 已验项 | 本机怎么验的 | 结论 |
|--------|--------------|------|
| 双地址解析口径（转发口 / 探测口 / 老格式同址） | 真起守护进程 + 两个本地监听端口对调 | 转发打第 1 段、探测打第 2 段；老格式不炸 |
| 探测失败 → 切备线 → 转发改打备线转发口 | 同上 | 切换链路通 |
| `err_kind` 三分类 | 直接调守护进程里的 `_probe` | `refused` / `timeout` / 成功 三者可分（Windows 的 2 秒延迟见 §8） |
| 状态文件字段与落盘 | 真起进程读状态文件 | 字段齐（当前主 / 转发目标 / 探测目标 / 连续失败数 / 上次切换时间） |
| 建池写入双地址 + 规则 ID 映射 | 走产品的建池写配置路径读回 JSON | `primary` 为双地址；`backups` 双地址；`backup_rule_ids` 正确 |
| 端口探测三态判定逻辑 | 从产品文件里原样抠出判定代码，注入假 `socket` 模块 | IPv6-only → FREE（不再误报占用）；两族都不可用 → UNKNOWN；真占用 → BUSY |
| 状态展示 | 菜单函数直接跑 | 当前主 / 转发目标 / 探测目标 / 连续失败数 / 上次切换时间 / 旧格式标记 全部可见 |
