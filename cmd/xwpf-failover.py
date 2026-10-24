#!/usr/bin/env python3
"""
xwpf-failover: true active/passive TCP failover proxy for xwPF.

This is NOT load balancing - this is REAL primary/backup:
  - while primary is healthy → all new connections → primary
  - when primary fails (probe fail >= threshold) → switch to backup
  - when primary recovers (success_threshold met + cooldown elapsed) → switch back

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

Stdlib-only (asyncio). Logs go to stdout (journald-friendly when run as systemd service).
"""

# 守护进程版本号：lib/failover.sh 用它判断已安装版本是否落后（不一致则自动重装）。
# 修改本文件的功能时记得同步递增。
__version__ = "1.1.0"

import argparse
import asyncio
import errno
import json
import logging
import signal
import sys
import time


class ListenAddressInUse(RuntimeError):
    """监听地址不可用 —— 端口已被占用（EADDRINUSE）等 bind 失败。

    单独一个类型，是为了让「端口被占用」在日志里一眼可辨，
    而不是淹没在 task 异常的 repr 里。
    """


class Pool:
    def __init__(self, cfg):
        self.name = cfg["name"]
        self.listen_addr = cfg["listen"]
        self.primary = cfg["primary"]
        self.backups = list(cfg.get("backups") or [])

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
        self.last_switch = 0.0
        self.lock = asyncio.Lock()

    def targets(self):
        return [self.primary] + list(self.backups)

    @property
    def active(self):
        return self.targets()[self.active_idx]

    async def _probe(self, addr):
        """Open a TCP connection - returns True if reachable."""
        try:
            host, port_s = addr.rsplit(":", 1)
            port = int(port_s)
        except Exception:
            return False
        try:
            fut = asyncio.open_connection(host, port)
            r, w = await asyncio.wait_for(fut, timeout=self.timeout)
            w.close()
            try:
                await w.wait_closed()
            except Exception:
                pass
            return True
        except Exception:
            return False

    async def probe_loop(self):
        while True:
            await asyncio.sleep(self.interval)
            for i, t in enumerate(self.targets()):
                ok = await self._probe(t)
                async with self.lock:
                    if ok:
                        self.succ_streak[i] = min(self.succ_n + 5,
                                                  self.succ_streak[i] + 1)
                        self.fail_streak[i] = 0
                    else:
                        self.fail_streak[i] = min(self.fail_n + 5,
                                                   self.fail_streak[i] + 1)
                        self.succ_streak[i] = 0

            async with self.lock:
                primary_down = self.fail_streak[0] >= self.fail_n
                cur = self.active_idx
                now = time.monotonic()
                if primary_down and cur == 0:
                    # Switch to first healthy backup
                    for i in range(1, len(self.targets())):
                        if self.fail_streak[i] < self.fail_n:
                            self.active_idx = i
                            self.last_switch = now
                            logging.warning(
                                "[%s] PRIMARY DOWN → BACKUP %d (%s)",
                                self.name, i - 1, self.targets()[i],
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
                        self.last_switch = now
                        logging.warning(
                            "[%s] PRIMARY RECOVERED → switch back from backup %d",
                            self.name, old - 1,
                        )
                logging.debug(
                    "[%s] active=%d fail=%s succ=%s",
                    self.name, self.active_idx,
                    self.fail_streak, self.succ_streak,
                )

    async def _handle_one(self, reader, writer):
        # Decide which backend under lock
        async with self.lock:
            target = self.active
        peername = writer.get_extra_info("peername")
        try:
            host, port_s = target.rsplit(":", 1)
            port = int(port_s)
            backend_r, backend_w = await asyncio.wait_for(
                asyncio.open_connection(host, port),
                timeout=self.timeout,
            )
        except Exception as e:
            logging.warning("[%s] dial %s from %s: %s", self.name, target, peername, e)
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
        tasks.append(asyncio.create_task(p.probe_loop()))

    # Wait for either: a serve/probe task crashed (need to bail out), or
    # SIGTERM/SIGINT arrived (clean shutdown). asyncio.wait() returns when the
    # first future completes — previously we waited only on `tasks` so the
    # `stop` future was orphaned and SIGTERM left us hanging until systemd
    # SIGKILL'd us at the 90s timeout.
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
