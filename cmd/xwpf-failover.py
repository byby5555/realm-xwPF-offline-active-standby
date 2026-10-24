#!/usr/bin/env python3
"""
xwpf-failover: true active/passive TCP failover proxy for xwPF.

This is NOT load balancing - this is REAL primary/backup:
  - while primary is healthy -> all new connections -> primary
  - when primary fails (probe fail >= threshold) -> switch to backup
  - when primary recovers (success_threshold met + cooldown elapsed) -> switch back

Configuration: /etc/xwpf/failover.json (or via -c flag)

Schema (list of pools):
[
  {
    "name": "tcp-443",
    "listen": "0.0.0.0:443",                  # public, the failover-proxy listens here
    "primary": "127.0.0.1:10443",             # primary backend (realm listener)
    "backups": ["127.0.0.1:10444"],          # backup backends
    "probe": {
      "interval_sec":      4,
      "timeout_sec":       3,
      "fail_threshold":    2,                # consecutive fails to mark down
      "success_threshold": 2,                # consecutive successes to recover
      "cooldown_sec":      120              # minimum time between switches
    }
  }
]

★ 目标地址格式（N3）：<转发口>|<探测口>
  - 段数 >= 2：转发口 = 第 1 段，探测口 = 第 2 段，第 3 段起丢弃
  - 无 "|"    ：转发口 = 探测口 = 原串（老配置行为不变，不炸）
  - realm 回环模式下约定为「回环|真实后端」：转发走回环（保留 TLS / per-rule 日志），
    探测打真实后端（真实后端挂了才切 —— 只探回环的话 realm 活着就永远不切）。
  - 解析只有一处：split_target()。转发与探测都从同一份解析视图取，
    不允许在两个调用点各写一次 rsplit（口径漂移的形态是「探测打真实口、
    转发打回环口」的静默失效）。

★ 状态文件（可观测性）：默认 /etc/xwpf/failover-state.json（-s 可改）
  写端只有这里一处，读端是 lib/ui.sh 的 ui_show_failover_state —— 两边字段同名。

Stdlib-only (asyncio). Logs go to stdout (journald-friendly when run as systemd service).
"""

# 守护进程版本号：lib/failover.sh 用它判断已安装版本是否落后（不一致则自动重装）。
# 修改本文件的功能时记得同步递增。
__version__ = "1.2.0"

import argparse
import asyncio
import errno
import json
import logging
import os
import signal
import socket
import sys
import time

# 状态文件默认落点（与配置同目录：/etc/xwpf）
DEFAULT_STATE_FILE = "/etc/xwpf/failover-state.json"

# 状态文件里「上次切换时间」的可读格式
_SWITCH_TIME_FMT = "%Y-%m-%d %H:%M:%S"


class ListenAddressInUse(RuntimeError):
    """监听地址不可用 —— 端口已被占用（EADDRINUSE）等 bind 失败。

    单独一个类型，是为了让「端口被占用」在日志里一眼可辨，
    而不是淹没在 task 异常的 repr 里。
    """


def split_target(addr):
    """
    split_target() —— 主备目标地址解析的**唯一真源**。

    返回 (forward, probe, legacy)：
      forward 转发口（_handle_one 拨号用这个）
      probe   探测口（_probe 连这个）
      legacy  True = 原串没有 "|" → 转发与探测同址（老配置行为）

    口径（与产品侧建池口径一一对应）：
      段数 >= 2：转发口 = 第 1 段，探测口 = 第 2 段，第 3 段起丢弃
      无 "|"  ：转发口 = 探测口 = 原串（老配置不炸）
    """
    raw = addr if isinstance(addr, str) else ""
    parts = raw.split("|")
    if len(parts) >= 2:
        fwd = parts[0].strip()
        prb = parts[1].strip()
        if not prb:
            # 退化写法 "<host:port>|" → 探测退回转发口，
            # 不制造一个永远连不上的探测目标（否则该目标恒判 down）。
            prb = fwd
        return fwd, prb, False
    one = parts[0].strip() if parts else ""
    return one, one, True


class StateStore:
    """
    StateStore() —— 状态持久化的写端唯一真源。

    · 写：切换发生时立刻落盘；探测循环里按间隔落盘（原子写：tmp + os.replace）
    · 读：进程启动时把上次的「上次切换时间」读回来 → 冷却期跨进程重启不丢
    · 写失败只告警不抛 —— 状态文件写不了不能拖垮转发链路
    读端在 lib/ui.sh 的 ui_show_failover_state，两边字段同名。
    """

    def __init__(self, path, pools=None):
        self.path = path
        self.pools = list(pools or [])
        self._last_write = 0.0
        self._warned = False

    def snapshot_all(self):
        """所有池的快照（一次写全 —— 少写一个池 = 那个池的状态永远不更新）"""
        return {p.name: p.snapshot() for p in self.pools}

    def load(self):
        """读回上次的池状态（读不到就当没有 —— 首次启动是正常路径）"""
        try:
            with open(self.path) as f:
                data = json.load(f)
        except Exception:
            return {}
        if not isinstance(data, dict):
            return {}
        pools = data.get("pools")
        return pools if isinstance(pools, dict) else {}

    def save(self, force=False):
        now = time.time()
        if not force and (now - self._last_write) < 5:
            return
        payload = {"version": 1, "updated_at": now, "pools": self.snapshot_all()}
        tmp = self.path + ".tmp"
        try:
            parent = os.path.dirname(self.path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(tmp, "w") as f:
                json.dump(payload, f, indent=2, ensure_ascii=False)
            os.replace(tmp, self.path)
            self._last_write = now
            self._warned = False
        except Exception as exc:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            if not self._warned:
                self._warned = True
                logging.warning(
                    "状态文件写入失败 (%s): %s —— 状态展示会缺失, 转发不受影响",
                    self.path, exc,
                )


class Pool:
    def __init__(self, cfg):
        self.name = cfg["name"]
        self.listen_addr = cfg["listen"]
        self.primary = cfg["primary"]
        self.backups = list(cfg.get("backups") or [])
        # direct 模式 = 守护直连真实后端（不经过 realm 回环）
        self.direct = bool(cfg.get("direct"))

        p = cfg.get("probe") or {}
        self.interval = int(p.get("interval_sec", 4))
        self.timeout = int(p.get("timeout_sec", 3))
        self.fail_n = int(p.get("fail_threshold", 2))
        self.succ_n = int(p.get("success_threshold", 2))
        self.cooldown = int(p.get("cooldown_sec", 120))

        # State guarded by `lock`
        self.active_idx = 0   # 0 = primary, 1..N = backups
        self.fail_streak = [0] * (1 + len(self.backups))
        self.succ_streak = [0] * (1 + len(self.backups))
        # 每个目标最近一次探测结果（状态展示用）
        self.last_probe = [None] * (1 + len(self.backups))
        self.last_switch = 0.0        # 单调时钟（冷却期判定用）
        self.last_switch_epoch = 0.0  # 墙钟（状态展示 + 跨进程恢复用）
        self.last_switch_at = ""
        self.lock = asyncio.Lock()

    def targets(self):
        """原始目标串（primary + backups），顺序即索引顺序"""
        return [self.primary] + list(self.backups)

    def views(self):
        """解析视图列表 —— 每项 (forward, probe, legacy)

        ★ 解析只在这里发生一次（split_target 是唯一真源）：
          转发与探测都从这份视图取，两个调用点各写一次解析必然漂移。
        """
        return [split_target(a) for a in self.targets()]

    def target_view(self, idx):
        """第 idx 个目标的解析视图 (forward, probe, legacy)"""
        views = self.views()
        if 0 <= idx < len(views):
            return views[idx]
        return ("", "", True)

    def forward_targets(self):
        """转发口列表（拨号用）"""
        return [v[0] for v in self.views()]

    def probe_targets(self):
        """探测口列表（探测用）"""
        return [v[1] for v in self.views()]

    @property
    def active(self):
        """当前生效目标的**转发口**"""
        return self.forward_targets()[self.active_idx]

    async def _probe(self, addr):
        """_probe() —— 探测一个目标，返回 (ok, elapsed_ms, err_kind)

        err_kind 语义（质量检查的原料）：
          ""        成功
          refused   连接被拒 —— 服务没在监听，**线路是好的**
          timeout   超时 —— 包丢了，**链路有问题**
          dns       域名解析失败
          error     其它错误（含地址格式非法）
        """
        t0 = time.monotonic()

        def _elapsed():
            return round((time.monotonic() - t0) * 1000.0, 1)

        try:
            host, port_s = addr.rsplit(":", 1)
            port = int(port_s)
        except Exception:
            return False, _elapsed(), "error"
        try:
            fut = asyncio.open_connection(host, port)
            r, w = await asyncio.wait_for(fut, timeout=self.timeout)
            w.close()
            try:
                await w.wait_closed()
            except Exception:
                pass
            return True, _elapsed(), ""
        except asyncio.TimeoutError:
            # ★ 顺序要紧：TimeoutError 在 3.11 起是 OSError 的子类，
            #   ConnectionRefusedError / gaierror 也是 —— 必须先接具体的。
            return False, _elapsed(), "timeout"
        except ConnectionRefusedError:
            return False, _elapsed(), "refused"
        except socket.gaierror:
            return False, _elapsed(), "dns"
        except OSError:
            return False, _elapsed(), "error"
        except Exception:
            return False, _elapsed(), "error"

    def _mark_switch(self, now_mono):
        self.last_switch = now_mono
        self.last_switch_epoch = time.time()
        self.last_switch_at = time.strftime(_SWITCH_TIME_FMT, time.localtime(self.last_switch_epoch))

    def restore_switch(self, epoch):
        """从状态文件恢复「上次切换时间」—— 冷却期跨进程重启不丢"""
        try:
            epoch = float(epoch)
        except (TypeError, ValueError):
            return
        if epoch <= 0:
            return
        age = time.time() - epoch
        if age < 0:
            age = 0.0
        # 用单调时钟把「距今多久」折算回去：冷却期从切换那一刻算起，
        # 重启不该把冷却期清零（否则反复重启 = 反复绕过冷却）。
        self.last_switch = time.monotonic() - age
        self.last_switch_epoch = epoch
        self.last_switch_at = time.strftime(_SWITCH_TIME_FMT, time.localtime(epoch))

    def snapshot(self):
        """状态快照（写进状态文件）—— 字段与 lib/ui.sh 的读端同名"""
        idx = self.active_idx
        raw = self.targets()
        fwd, prb, legacy = self.target_view(idx)
        return {
            "active_index": idx,
            "active_role": "primary" if idx == 0 else "backup%d" % idx,
            "active_raw": raw[idx] if 0 <= idx < len(raw) else "",
            "active_forward": fwd,
            "active_probe": prb,
            "active_legacy": bool(legacy),
            "direct": self.direct,
            "fail_streak": list(self.fail_streak),
            "succ_streak": list(self.succ_streak),
            "last_switch_epoch": self.last_switch_epoch,
            "last_switch_at": self.last_switch_at,
            "last_probe": list(self.last_probe),
        }

    def log_targets(self):
        """启动时把每个目标的转发口/探测口讲清楚（老格式要标出来）"""
        raws = self.targets()
        for i, (fwd, prb, legacy) in enumerate(self.views()):
            role = "primary" if i == 0 else "backup%d" % i
            if legacy:
                logging.warning(
                    "[%s] %s 旧格式目标 %s: 无 '|' → 转发与探测同址 (探测打的就是它)",
                    self.name, role, raws[i],
                )
                if not self.direct:
                    logging.warning(
                        "[%s] %s 旧格式 + realm 回环模式: 探测打回环口 → 真实后端故障不会触发切换 (重建该池可拿到双地址)",
                        self.name, role,
                    )
            else:
                logging.info(
                    "[%s] %s 转发口=%s 探测口=%s",
                    self.name, role, fwd, prb,
                )

    async def probe_loop(self, store=None):
        while True:
            await asyncio.sleep(self.interval)
            probes = self.probe_targets()
            for i, t in enumerate(probes):
                ok, elapsed, kind = await self._probe(t)
                async with self.lock:
                    self.last_probe[i] = {
                        "target": t,
                        "ok": ok,
                        "err_kind": kind,
                        "elapsed_ms": elapsed,
                        "at": time.time(),
                    }
                    if ok:
                        self.succ_streak[i] = min(self.succ_n + 5,
                                                  self.succ_streak[i] + 1)
                        self.fail_streak[i] = 0
                    else:
                        self.fail_streak[i] = min(self.fail_n + 5,
                                                   self.fail_streak[i] + 1)
                        self.succ_streak[i] = 0

            switched = False
            async with self.lock:
                primary_down = self.fail_streak[0] >= self.fail_n
                cur = self.active_idx
                now = time.monotonic()
                if primary_down and cur == 0:
                    # Switch to first healthy backup
                    for i in range(1, len(self.targets())):
                        if self.fail_streak[i] < self.fail_n:
                            self.active_idx = i
                            self._mark_switch(now)
                            switched = True
                            fwd, prb, _legacy = self.target_view(i)
                            logging.warning(
                                "[%s] PRIMARY DOWN → BACKUP %d (转发=%s 探测=%s)",
                                self.name, i - 1, fwd, prb,
                            )
                            break
                    else:
                        # All backups also down - stay on primary (it'll error out)
                        logging.error("[%s] PRIMARY DOWN, no healthy backup; staying on primary", self.name)
                elif (not primary_down) and cur != 0:
                    if (self.succ_streak[0] >= self.succ_n and
                            now - self.last_switch > self.cooldown):
                        old = self.active_idx
                        self.active_idx = 0
                        self._mark_switch(now)
                        switched = True
                        fwd, prb, _legacy = self.target_view(0)
                        logging.warning(
                            "[%s] PRIMARY RECOVERED → switch back from backup %d (转发=%s 探测=%s)",
                            self.name, old - 1, fwd, prb,
                        )
                logging.debug(
                    "[%s] active=%d fail=%s succ=%s",
                    self.name, self.active_idx,
                    self.fail_streak, self.succ_streak,
                )

            if store is not None:
                # 切换立刻落盘；平时按间隔落盘（状态展示要能看到连续失败数）
                store.save(force=switched)

    async def _handle_one(self, reader, writer):
        # 决定用哪个后端（转发口 —— 不是探测口）
        async with self.lock:
            idx = self.active_idx
        forward, _probe_addr, _legacy = self.target_view(idx)
        peername = writer.get_extra_info("peername")
        try:
            host, port_s = forward.rsplit(":", 1)
            port = int(port_s)
            backend_r, backend_w = await asyncio.wait_for(
                asyncio.open_connection(host, port),
                timeout=self.timeout,
            )
        except Exception as e:
            logging.warning("[%s] dial %s from %s: %s", self.name, forward, peername, e)
            writer.close()
            return

        # bidirectional byte-copy
        async def pipe(src, dst, name):
            try:
                while True:
                    data = await src.read(8192)
                    if not data:
                        break
                    dst.write(data)
                    await dst.drain()
            except Exception:
                pass
            finally:
                try:
                    dst.close()
                except Exception:
                    pass

        try:
            await asyncio.gather(
                pipe(reader, backend_w, "c2b"),
                pipe(backend_r, writer, "b2c"),
            )
        finally:
            for w in (writer, backend_w):
                try:
                    w.close()
                except Exception:
                    pass

    async def serve(self):
        host, port_s = self.listen_addr.rsplit(":", 1)
        port = int(port_s)
        try:
            server = await asyncio.start_server(self._handle_one, host, port)
        except OSError as exc:
            # ★ 端口被占用 = 守护进程「起不来」的头号原因（事故根因）。
            #   只把 task 的 repr 抛给用户看不懂，这里翻译成人话：
            #   listen 地址 + 端口 + errno + 处置建议。
            #   异常继续往外抛 → _main 记非 0 退出码 → systemd 按
            #   Restart=always + StartLimit 限流处理（不会无限重启）。
            if exc.errno == errno.EADDRINUSE:
                raise ListenAddressInUse(
                    "listen address already in use: %s (pool '%s', errno %s EADDRINUSE) "
                    "- port %s is already bound; change the listen port, or stop "
                    "the service holding it"
                    % (self.listen_addr, self.name, exc.errno, port)
                ) from exc
            raise
        sa = server.sockets[0].getsockname()
        logging.info(
            "[%s] listening on %s:%s → primary=%s backups=%s",
            self.name, sa[0], sa[1], self.primary, self.backups,
        )
        try:
            async with server:
                await server.serve_forever()
        except asyncio.CancelledError:
            server.close()
            await server.wait_closed()
            raise


async def _main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--config", default="/etc/xwpf/failover.json")
    ap.add_argument("-s", "--state", default=DEFAULT_STATE_FILE,
                    help="state file path (default: %s)" % DEFAULT_STATE_FILE)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    try:
        with open(args.config) as f:
            pools_cfg = json.load(f)
    except Exception as e:
        logging.error("failed to read config %s: %s", args.config, e)
        sys.exit(1)

    if not isinstance(pools_cfg, list) or not pools_cfg:
        logging.error("config must be a non-empty list of pools")
        sys.exit(1)

    pools = [Pool(c) for c in pools_cfg]

    # 状态文件：读回上次的上次切换时间（冷却期跨进程重启不丢）
    store = StateStore(args.state, pools)
    prev = store.load()
    for p in pools:
        old = prev.get(p.name)
        if isinstance(old, dict) and old.get("last_switch_epoch"):
            p.restore_switch(old["last_switch_epoch"])
            logging.info(
                "[%s] 恢复上次切换时间: %s (%s)",
                p.name, old.get("last_switch_at") or "-",
                "冷却期继续计时" if p.last_switch else "-",
            )
        p.log_targets()

    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, lambda: stop.set_result(None))
        except NotImplementedError:
            pass  # Windows / restricted env

    tasks = []
    for p in pools:
        tasks.append(asyncio.create_task(p.serve()))
        tasks.append(asyncio.create_task(p.probe_loop(store)))

    # 等待停止信号或 task 异常退出
    waitable = {stop} | set(tasks)
    # ★ 退出码语义（事故修复的核心）：
    #   0 = 收到 SIGTERM/SIGINT，干净退出
    #   非 0 = 有 serve/probe task 抛异常（守护进程起不来 / 崩了）
    # 之前这里无论如何都返回 None → asyncio.run 正常返回 → 进程退出码 0 →
    # systemd 以为一切正常 → 配上 Restart=always 就是无限重启循环。
    exit_code = 0
    try:
        done, pending = await asyncio.wait(
            waitable, return_when=asyncio.FIRST_COMPLETED
        )
        if stop in done:
            logging.info("stop signal received, shutting down...")
        # 无论是否同时收到停止信号，都要检查 task 的异常：
        # 停止信号到达的同时某个 task 已经炸了 → 仍然算异常退出（非 0）。
        for t in done:
            if t is stop:
                continue
            try:
                t.result()
            except asyncio.CancelledError:
                logging.warning("task %r was cancelled", t)
            except Exception as exc:
                exit_code = 1
                logging.error(
                    "task %r raised %s: %s",
                    t, type(exc).__name__, exc,
                    exc_info=True,
                )
    finally:
        # 退出前把状态落盘（当前主 / 探测目标 / 转发目标 / 连续失败数 / 上次切换时间）
        try:
            store.save(force=True)
        except Exception:
            pass
        for t in tasks:
            if not t.done():
                t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    return exit_code


def main():
    try:
        code = asyncio.run(_main())
    except KeyboardInterrupt:
        # Ctrl+C 等价于干净停止 → 退出码 0
        code = 0
    # ★ 把退出码真正交给进程（之前 asyncio.run 正常返回 = 退出码 0，
    #   内部异常被系统当成「正常结束」）。
    sys.exit(code)


if __name__ == "__main__":
    main()
