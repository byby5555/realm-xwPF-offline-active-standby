# Active/Passive Failover (xwpf-failover)

This is **real primary/backup**, not load balancing:

- While primary is reachable → all new connections go to primary
- After N consecutive probe failures → switch to backup
- After primary recovers (and cooldown elapsed) → switch back

The proxy is a small Python 3 daemon (Python stdlib only, no third-party
deps) listening on a public port and forwarding each accepted connection
either to the primary or backup realm listener. A separate probe loop
TCP-connects to each backend every `interval_sec` seconds and tracks
failure / success streaks.

## Layout

### Direct mode (default)

```
   :443 (public)
        │
   ┌────▼────────────┐
   │ xwpf-failover  │       systemd: xwpf-failover.service
   │ /etc/xwpf/     │       binary:    /usr/local/bin/xwpf-failover
   │  failover.json │       config:    /etc/xwpf/failover.json
   └───┬────────┬───┘
       │        │   direct: the daemon opens the connection itself
    primary     backup
   1.2.3.4:443  5.6.7.8:443
```

The daemon forwards raw TCP to the **real backend addresses** — no realm
rule is involved, one hop instead of two.

### Realm loopback mode (legacy)

```
   :443 (public)
        │
   ┌────▼────────────┐
   │ xwpf-failover  │
   └───┬────────┬───┘
   :10443     :10444
      │         │
   rule-A     rule-B (separate realm endpoints on loopback)
   remote=    remote=
    1.2.3.4    5.6.7.8
        :443        :443
```

⚠️ **Known limitation of the legacy mode**: the probe target is the
**loopback port**, not the real backend. If the backend dies but `realm` is
still up, the probe still succeeds → **the failover never switches**
(measured on a real host: after killing the primary backend it stayed on
PRIMARY for 40 s; the same host in direct mode switched over in 8 s).
Use **direct mode** when the switch must follow the backend's health.

The menu under `pf` → 转发配置管理 → 6. 负载均衡管理 → 4. 主动/被动主备
asks which mode to use, writes `failover.json` accordingly, then restarts
`xwpf-failover` (direct mode does not need a `realm` restart).

## Configuration schema

`/etc/xwpf/failover.json`:

```json
[
  {
    "name": "tcp-443",
    "listen":  "0.0.0.0:443",
    "primary": "127.0.0.1:10443",
    "backups": ["127.0.0.1:10444"],
    "probe": {
      "interval_sec":      4,
      "timeout_sec":       3,
      "fail_threshold":    2,
      "success_threshold": 2,
      "cooldown_sec":      120
    }
  }
]
```

| Key | Default | Meaning |
|-----|---------|---------|
| `interval_sec`      | 4   | seconds between probes per backend |
| `timeout_sec`       | 3   | probe connect timeout |
| `fail_threshold`    | 2   | consecutive failures before marking primary as down |
| `success_threshold` | 2   | consecutive successes required before switching back |
| `cooldown_sec`      | 120 | minimum time between any switch (prevents flapping) |

## Failure semantics

The daemon **does NOT terminate existing connections** on a switch — only
new connections are routed to the active backend. Old connections on the
failed backend either continue or fail naturally.

This matches typical Linux/Unix `ip rule` semantics and avoids the
half-open-connection problem with active-active load balancers.

## Running

```sh
# install
cp cmd/xwpf-failover.py        /usr/local/bin/xwpf-failover
chmod +x /usr/local/bin/xwpf-failover
mkdir -p /etc/xwpf
cp cmd/xwpf-failover.service   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now xwpf-failover

# verify
journalctl -fu xwpf-failover     # look for "listening on" + state transitions
systemctl status xwpf-failover
```

## Crash loop: causes, systemd rate limiting, port conflicts

### Symptom

`journalctl -fu xwpf-failover` scrolls forever, the process is re-launched
every few seconds, and the unit ends up in a restart storm.

### Root cause chain

1. The `listen` port of a pool is already taken — most often a `realm`
   listener on the same port, or a leftover process from an earlier run.
2. `cmd/xwpf-failover.py`'s `Pool.serve` cannot bind → `OSError(EADDRINUSE)`.
3. The `serve` task raises, so `_main` returns.
4. **Before the fix** `_main` returned normally, so `asyncio.run` returned
   normally and the **process exit code was 0** — systemd read that as a
   *clean* exit.
5. `Restart=always` + `RestartSec` → systemd started the daemon again a few
   seconds later → restart loop → journald write storm.

### Exit-code semantics

| Situation | Exit code | systemd reaction (`Restart=always`) |
|-----------|-----------|--------------------------------------|
| SIGTERM / SIGINT received | `0` | not restarted (systemd suppresses the restart on an explicit stop) |
| a `serve` / `probe` task raised (e.g. port in use) | non-zero | restarted, at most `StartLimitBurst` times per `StartLimitIntervalSec` |
| config file missing / unreadable / empty pool list | `1` | restarted, same rate limit |

`cmd/xwpf-failover.py`'s `main` passes on the code returned by `_main`:
`0` for a signal-driven stop, non-zero for any task failure. The two
`sys.exit(1)` calls for an unreadable / empty config are unchanged.

The exception type, its message and the offending task all reach stderr
(journald), e.g.:

```
ERROR task <Task pending name='Task-3' ...> raised ListenAddressInUse: listen address already in use: 0.0.0.0:443 (pool 'tcp-443', errno 98 EADDRINUSE) - port 443 is already bound; change the listen port, or stop the service holding it
```

### systemd rate limiting (the actual defence)

`cmd/xwpf-failover.service` carries:

```ini
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=3
StartLimitAction=none

[Service]
Restart=always
RestartSec=5s
```

- `StartLimitIntervalSec=60` + `StartLimitBurst=3` — at most **3 starts per
  60 seconds**. Past that, systemd stops the unit instead of looping
  forever, so a misconfigured daemon can no longer take the whole machine
  down.
- `StartLimitAction=none` — written out explicitly: the default can be
  overridden system-wide (`DefaultStartLimitAction=`), and inheriting
  `reboot` / `poweroff` would be catastrophic.
- `Restart=always` — **deliberately not `on-failure`**. With the exit-code
  semantics above, a clean exit only happens on an explicit stop, so
  `on-failure` would behave the same today. But `always` is the safer
  default for a failover daemon: if the exit-code semantics ever regress,
  `always` still restarts the daemon (a loud failure) whereas
  `on-failure` would let it disappear silently and the traffic would stop
  without anyone noticing. `always` also restarts the daemon when it is
  killed by a signal systemd did not initiate (e.g. an operator's manual
  `kill`), which `on-failure` would not.
- `RestartSec=5s` — the pause between two restarts.

### Port already in use: what to do

The daemon refuses to start on a busy port and says so in plain language
(`listen address already in use`). Two ways out:

```sh
# 1) find out who holds the port
ss -lntp | grep ':443'

# 2a) stop the service holding it
systemctl stop realm          # whatever owns that port

# 2b) or move the pool to a free listen port
#     pf → 负载均衡管理 → 主动/被动主备 → recreate the pool with another listen port
```

`lib/failover.sh`'s `failover_pool_create` and `failover_pool_create_direct`
check the listen port **before** `failover.json` is written: if the port is
busy the pool is **not** created, the reason is printed, and the command
returns non-zero. That check is the single place where port occupancy is
decided; the daemon only reacts to the bind failure it actually hits at
runtime.

Two details worth knowing:

- The probe binds `0.0.0.0` and `::` in turn and **skips an address family
  the kernel does not support** (e.g. a machine with IPv6 disabled) instead
  of reporting the port as busy. "Cannot tell" and "port is occupied" are
  two different verdicts and are printed as two different messages.
- The check happens *before* anything is written, so a rejected pool leaves
  no half-written `failover.json` and no orphaned realm rule.

### Install does not start the daemon

`pf install` installs `xwpf-failover` but **does not start it**. The daemon
needs `/etc/xwpf/failover.json`, and that file is only written by the
"create a pool" flow — starting the daemon right after an install meant the
daemon exited `1` on a missing config and `Restart=always` turned that into
a restart loop. The menu text already said "create a pool first, then start
the daemon"; the install path now matches it. Start the daemon from
`pf → 主备池管理 → 启停守护` once a pool exists.

The same guard covers the other way in: `lib/failover.sh`'s
`failover_service_enable` refuses to enable the service when
`/etc/xwpf/failover.json` is missing or holds no pool, and says what to do
instead. Without that guard, clicking "start the daemon" before creating a
pool produced exactly the restart loop described above.

```sh
# 守护是否具备启动条件（0 = 可以启动）
pf → 主备池管理 → 启停守护
# 没有池时会看到:
#   没有可用的主备池配置 (/etc/xwpf/failover.json) —— 守护启动后会立刻退出
#   处置: 先用「建立主备池」建至少一个池，再启动守护
```

### After systemd gives up: `systemctl reset-failed`

When the rate limit kicks in, systemd stops the unit and leaves the
service in the `failed` state. A plain `systemctl start` will not bring it
back — clear the rate-limit counter first:

```sh
systemctl reset-failed xwpf-failover
systemctl start xwpf-failover
journalctl -fu xwpf-failover
```

Fix the root cause (free the port, or change the listen port) **before**
doing this — otherwise the daemon hits the rate limit again.

### Local overrides: use a drop-in, do not edit the unit in place

`/etc/systemd/system/xwpf-failover.service` is reinstalled from
`cmd/xwpf-failover.service` by `pf install` (and by the update centre), so
**direct edits to that file are silently overwritten** on the next install
or upgrade.

For a machine-local override, use a drop-in — it lives in its own
directory and survives reinstalls:

```sh
systemctl edit xwpf-failover
# → /etc/systemd/system/xwpf-failover.service.d/override.conf
systemctl daemon-reload
systemctl restart xwpf-failover
```

`pf install` writes one drop-in of its own:

```
/etc/systemd/system/xwpf-failover.service.d/10-crash-loop-guard.conf
```

It carries the same rate-limit and restart values as the main unit and is
**rewritten at the same path on every install / upgrade**. That is
deliberate: a hand-made drop-in overrides the main unit, so a machine that
already had one at *that* path would otherwise end up with two different
sets of values. A drop-in under any *other* name is left alone — overriding
the shipped values is the operator's call.

For example, to relax the restart rate limit on a busy box:

```ini
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=10
```

The shipped values are `StartLimitIntervalSec=60` and `StartLimitBurst=3`
(see `cmd/xwpf-failover.service`); they are deliberately tight so that a
misconfigured daemon cannot take the machine down.

Note that a drop-in wins over the main unit, so an older hand-made drop-in
(e.g. `10-crash-loop-guard.conf`) can override the shipped values — check
`systemctl show xwpf-failover` for the values actually in effect.

## Why not just round-robin?

Realm upstream (`zhboner/realm`) only implements `off` / `roundrobin` /
`iphash`. None of these is true primary/backup; roundrobin distributes
even when primary is up, and iphash gives the same IP to the same backend
but still doesn't auto-failover on backend death.

This daemon sits in front of realm and does what realm itself cannot.

## Why Python 3 (not Go / not bash)?

Python 3 is a default part of Debian 12. Single-file, stdlib-only, ~250
LOC. `asyncio` handles thousands of concurrent TCP connections.
