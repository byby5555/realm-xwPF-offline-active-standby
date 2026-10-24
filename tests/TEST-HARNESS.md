# 测试台架说明（realm-xwPF-offline-active-standby）

> 本目录由「阿测」维护。`tests/README.md`、`tests/test_active_standby.sh`、
> `tests/test_connectivity.sh`、`tests/test_e2e.sh`、`tests/test_set_u.sh` 属于其他会话的产物，未改动。

## 一句话

`bash tests/run_tests.sh` —— 在**沙箱**里跑 22 条回归用例，只读仓库、绝不碰 `/etc`、`/usr`、`/var`。
全过退出码 0，有失败非 0。

## 跑法

```bash
bash tests/run_tests.sh                  # 全部用例
bash tests/run_tests.sh --only T10,T14   # 只跑指定用例
bash tests/run_tests.sh --repeat 3       # 连跑 3 轮，校验结果一致
bash tests/run_tests.sh --list           # 列出用例编号
bash tests/run_tests.sh --clean          # 跑完删掉沙箱
```

## 目录结构

| 文件 | 作用 |
|------|------|
| `run_tests.sh` | 主入口：用例登记表、沙箱构建、跑批、汇总表、退出码 |
| `lib/harness.sh` | 用例账本与断言助手（`h_check_eq` / `h_check_contains` / `h_check_rc` / `h_check_file` …） |
| `lib/sandbox.sh` | 沙箱构建：LF 副本、路径重定向、root 模拟、离线镜像、基线 manifest、越界扫描 |
| `cases/01_static_contract.sh` | 静态契约类（T01–T09）：下载地址、文档一致性、行尾、声明的唯一真源 |
| `cases/02_weight_active_standby.sh` | 权重校验与主备规则状态（T10–T15） |
| `cases/03_failover_runtime.sh` | 故障转移运行时（T16–T22）：timer、systemd unit、连通性回退、权重翻转、离线安装、--help |
| `shims/*` | 外部依赖打桩：`systemctl` `nc` `curl` `wget` `realm` `journalctl` `flock` `bc` `id` `apt-get` |

## 台架做了什么（以及为什么）

### 1. LF 副本

仓库 `core.autocrlf=true`，Windows 工作区是 CRLF。直接 `source` 工作区副本在 Linux 语义下会出错，
所以被测产物一律是 `tr -d '\r'` 之后的 LF 副本（`$SBX_SRC`），执行副本在其基础上再做路径重定向（`$SBX_RUN`）。

### 2. 路径重定向（防越界）

副本里所有系统绝对路径都被改写到沙箱目录，映射表见 `lib/sandbox.sh` 的 `SBX_PATH_MAP`：
`/etc/realm` `/etc/systemd/system` `/etc/xwpf` `/usr/local/bin` `/var/lock` `/tmp` …
跑完会做一次**越界残留扫描**，把副本里剩下的真实系统绝对路径列出来（当前只剩 `/opt/realm/$filename` 一处只读查找）。

### 3. root 模拟

Git Bash 的 `EUID` 是 Windows uid（197610），`check_root` 会直接 `exit 1`。
沙箱副本把 `[[ $EUID -ne 0 ]]` 改成 `false`，等价于「以 root 运行」。

### 4. 外部依赖打桩

假 bin 目录放在 `PATH` 最前。`nc` 单独放一份在 `$SBX_BIN_NC`，**默认不进 PATH** ——
这样「机器上没装 nc」是默认状态，需要时用例显式加进来做对照口径。

`curl` / `wget` 桩从**离线镜像**取文件：镜像只放 `git ls-files` 跟踪的内容，
所以「本地有、但没提交」的文件在镜像里是 404 —— 这正是要暴露的问题。
桩会把每次请求的 URL 记进日志，用例据此断言「下载地址是否指向本 fork」。

### 5. 基线 manifest

仓库在多人并发改动，所以每次跑批都会在沙箱里写一份 `manifest.txt`：
被测提交的 HEAD、`git status` 快照、**每个被测文件的 sha256**。
三份 manifest 对不上，就说明被测对象变了，结论不可比 —— 这条在实测中真的抓到过一次
（`lib/health.sh` 在一轮跑批过程中被改写，T22 因此出现「第 1 轮红、后 2 轮绿」）。

## 已知环境限制

| 限制 | 影响 | 处理 |
|------|------|------|
| MSYS 的 `grep` 对含 CR 的模式不可靠 | 行尾断言不能靠 `grep -c $'\r$'` | 改用 `od` 数字节（`sbx_count_cr` / `sbx_count_crlf`） |
| MSYS 读文件是文本模式 | CRLF 脚本在本机能正常跑，Linux 上会挂 | 该失败模式列为「待真机验证」 |
| 本机 `python3` 是 WindowsApps 占位符 | 监听端口起不来 | 改用真实 `python`（3.11.15） |
| 没有 `jq` / `nc` / `systemctl` / `flock` | 依赖这些的路径需打桩 | 已打桩；依赖 `jq` 的整段配置生成未覆盖 |
| 没有 WSL / Docker / shellcheck | 不能做真机级验证 | 全部列入「待真机验证」清单 |

## 退出码

`0` = 全部通过；非 `0` = 有失败（`1`）。每条用例的 stdout / 断言记录 / 元信息都在
`$SBX_ROOT/cases/<编号>.{stdout,log,notes,fails,meta}`，跑完会打印沙箱路径。
