#!/bin/bash
# realm-xwPF-offline-active-standby · 测试台架主入口（唯一入口）
#
# 用法：
#   bash tests/run_tests.sh                       # 跑全部用例
#   bash tests/run_tests.sh --only T01,T02        # 只跑指定用例
#   bash tests/run_tests.sh --repeat 3            # 连跑 3 轮，校验结果一致
#   bash tests/run_tests.sh --list                # 列出用例
#   bash tests/run_tests.sh --clean               # 跑完删掉沙箱
#   BASE_SHA=a9102c1 bash tests/run_tests.sh      # 指定冻结点（推荐）
#   bash tests/run_tests.sh --base-sha a9102c1    # 同上
#
# ★ 冻结点机制（第 2 轮起）
#   被测产物一律来自 `git show $BASE_SHA:<path>`，**不读工作区文件**。
#   仓库多人并行改动，工作区随时在变 —— 读工作区就会出现「第 1 轮红、后 2 轮绿」的假抖动。
#   BASE_SHA 默认取当前 HEAD；正式跑批请显式指定，报告里必须写上这个 SHA。
#   SHA 一变，旧结论全部作废，必须重跑。
#
# 退出码：
#   0 = 全部通过
#   1 = 存在用例失败
#   2 = 冻结点 BASE_SHA 不存在（参数/用法错误），**或** 台架预检清单为空（台架配置错误）
#   3 = 跑批前预检未通过：负向对照依赖的**历史对象**在本地对象库里找不到
#       （克隆方式没把历史拉全，**不是**产品回归；修复命令见输出）
#   4 = --only 点名了未登记的用例 ID（一个用例都不会跑 ⇒ 原来会静默「全过」＝假绿）
#   5 = 有已知缺陷未修：用例显式声明 h_case_expect_fail 且确实判红
#       （不计入「失败」，但**仍然是非 0** ⇒ 按纪律不可合并、不可 push；
#         缺陷修好后该条会转绿、届时必须撤掉标注，否则台架会判红提醒）
#
# 汇总行格式：汇总: 总计 N 条，通过 N，失败 N，预期红 N
#   「预期红」= 本批声明为「已知缺陷预期红」的条数；恒为 0 时不影响「总计/通过/失败」三个数。
#
# 台架约定见 tests/TEST-HARNESS.md。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 台架版本：台架自身的改动会让旧报告的结论打折，改了台架就 bump
# v2.8.1：第 8 轮（续）—— T45 日志文字纠正（**台架说错了话**）
#         · 路径 bug 未修时，「恢复失败」被误归因为系统锁 → 台架写下「连 mv 也绕不过」
#         · 修好路径后实测：Windows 上 **mv（改目录项）能替换运行中的 exe**，被挡住的只有 cp
#           → 这正好证明「必须走 mv 覆盖」，文字照实改，结论只加强不放松
# v2.8.0：第 8 轮（续）—— 负向对照质量加固（Chief 的元规则）
#         · T43/T44/T47：每条负向对照加「破坏手法生效」的**正向确认**（断言注入点命中数）
#           —— 注入点没命中 → 症状不会出现 → 断言必红 → 会被误当成产品缺陷
#         · T45/T46：函数覆盖型负向对照加「覆盖确实生效」的确认
#         · T45：新增**本机可跑的等价断言**（inode 变化 = 走「替换」而不是原地 cp 覆写）
#           —— ETXTBSY 是 Linux 内核行为，非 Linux 上那条等于没测（skip ≠ 放过）
#         · 配套：每条负向对照都要在「修复前的冻结点」上验一次是红的
# v2.7.0：第 8 轮 —— T34 加固（小编 R3-D01 交付后暴露出的两个盲区）
#         · T34 行号引用从「兜底（文件缺失 / 行号越界才红）」收紧成**硬断言：必须为 0**
#           —— 旧口径下「行号漂了但仍在文件范围内」是绿的，那正是 D-01 那类静默漂移
#         · T34 解析器扩展到**英文所有格写法**（`lib/core.sh`'s `REQUIRED_TOOLS`）
#           —— 旧正则只认中文「的」式 → README_EN.md 的引用完全不被检查
#         · 配套加「英文写法命中数 ≥ 1」护栏 → 防止「正则扩了但没匹配上」的静默退化
#         · T34 补**判定器自检**（合成探针树）：两条新断言各有一个反例，
#           断言的是「坏情况确实被检出」—— 怎么写都绿的断言等于没有断言
# v2.6.0：第 7 轮收尾（续）—— 跟随产品 N1-R1（去掉裸 host 宽键兜底）
#         · T51 展示端断言改成「旧格式记录查不到就当无记录、不跨端口污染」
#           —— 旧口径「按裸 host 兜底命中」会把同 host 另一个端口的记录显示成这条目标的
#         · T52 认不出归属时改成「当无记录」→ 那条老记录不让任何目标被判故障
#         · T52 补上 N1 真正触发的形态：同一端口组内、同 host 不同端口
#           （旧格式与新格式的产出必须逐项一致 —— 兼容不是「不报错」，是「结果相同」）
# v2.5.0：第 7 轮收尾 —— 跟随产品口径变更（健康状态 TARGET 改 host:port）
#         · T51 状态记录定位改成**格式无关**（host / host:port 都能定位）
#           —— 记录定位写死旧格式 → 产品改口径就整组用例替产品背锅
#         · T51 补「同 host 不同端口必须查不到」的负向对照
#         · 健康状态 fixture（_write_health）改写**当前格式**（host:port）
#           —— 旧格式 fixture 会让用例退化成「旧格式兼容兜底分支」，精确索引主路径无人覆盖
#         · 新增 T52：同 host 不同端口互不覆盖（写侧 + 读侧）+ 旧格式兼容 + 3 条负向对照
# v2.4.0：第 7 轮 —— 补覆盖盲区
#         · T32 条件 4 改成**形态无关**（形态 A 内嵌 / 形态 B source 真源都判过）
#         · T32 条件 5 正则收紧（只匹配肯定误导句式 + 整行否定词豁免 + 扫描范围下限护栏）
#         · 新增 T43~T47（更新中心）、T48（OCR 导入）、T49（jq 配置生成）、
#           T50（规则落盘格式）、T51（时延，原 test_latency.sh 并入）
#         · tests/test_update.sh、tests/test_latency.sh 改薄封装（消除第二入口）
#         · jq 桩扩能力：数组下标路径、-e 退出码语义、JSON 对象字面量；
#           并把 `..` 这类「会被静默误解」的语法显式判为不支持
# v2.9.0：P1 —— T32 条件 5 的判定不再依赖宿主 locale
#         · 判据正则：中文标点字符类 [^，。；、] → `.`；窗口按**字节**放大 {0,40}→{0,120}、{0,6}→{0,30}
#           （原因：`.` 在 UTF-8 下是 1 字符、C 下是 1 字节，只换正则不钉 locale 会让窗口宽度随环境差 3 倍）
#         · 扫描 grep 与豁免 grep 钉 `LC_ALL=C` → 字节语义，判定与环境解耦
#         · 新增负向对照 7（三层）：(a) 正则层两种 locale 都必须抓到真违规行
#           (b) **扫描层**同一探针在两种 ambient locale 下判定必须相同（去掉钉子就判红）
#           (c) 扫描层真违规行在两种 ambient locale 下都必须抓到
#         · 负向对照 7 必须做在扫描层：正则层是**故意**两种 locale 各跑一遍的，
#           拿它比判定会判红自己
# v2.17.0：第 22 轮 —— 老机器主备池守护残留清理的护栏用例（T117/T118）
#         · 新增 T117/T118（cases/26_legacy_failover_guard_t117.sh）：
#           守「安装 / 升级路径：守护还在服务就跳过；卸载路径：强制清理」这条契约。
#           背景：真机 103.42.31.186 的老守护**正在对外服务**（0.0.0.0:18443 /
#           0.0.0.0:18444 两个公开口）⇒ 无条件清理 = 打黑在用的公开转发口
#         · T117 七场景：活池跳过（unit / drop-in / 二进制 / 池配置一个都不动，
#           且不去 stop 守护）/ 无池配置清干净 / 空数组清干净 / env 强制清干净 /
#           force 参数清干净 / 池目录不删 + 调用点静态契约
#           （安装路径不带 force、两条卸载路径带 force）
#         · T118 负向对照：**注入式退化**（判据是本次新引入的 helper，修复前没有
#           等价形态）—— 判据退化后活池必须从「跳过」变成「清掉」⇒ 证明 T117 的
#           「跳过」断言确实来自判据，不是恒绿
# v2.18.0：第 23 轮 —— 主备目标枚举口径统一（探测端 ↔ 路由端）#         · 新增 T119~T121（cases/27_standby_target_parity_t119.sh）：
#           守「同一组目标，探测端与路由端必须枚举出**同一份**」这条不变式。
#           两端口径不一致 ⇒ 状态行匹配不上配置里的目标 ⇒ 主备切换**静默失效**
#           （不报错、不出日志、界面也看不出来）
#         · 真实触发场景：老的「进程级主备池」支持「同 host 不同端口」的备机
#           （primary :28081 / backup :28082），规则级主备只能靠 TARGET_STATES 表达；
#           而修复前路由端认 TARGET_STATES、探测端只认 REMOTE_HOST × REMOTE_PORT
#           ⇒ 这类备机**永远切不过去**
#         · T120 负向对照：注入式退化（把共用真源换成旧口径）⇒ 状态文件里那个备机
#           确实消失 ⇒ 证明 T119 的断言来自口径、不是恒绿
#         · T121：进主备时不得抹掉显式写的「每目标自带端口」备机；
#           剔除模式残留（条目数比完整目标数少）仍然清空（M2 旧行为保留）
#         · T122：共用真源（core.sh）不可用时，探测端生成物必须报错 + 拒绝安装，
#           且不许把原来能跑的那份覆盖掉（自检挪到 mv 之前）
# v2.20.0：第 25 轮 —— 快探测流（**只观测**：每秒一轮，刷新菜单里的时延/丢包显示）
#         · 产品侧：lib/health.sh 新增快探测（fast_probe.sh 生成器 + 独立 unit/timer
#           + 独立观测文件 + 失败分型 + 窗口/丢包计算 + 菜单侧读数）
#         · 硬红线：快探测**不参与切换** —— 不写判定流的状态文件、不触发配置重生成；
#           生成物里出现这两类字样 ⇒ **拒绝安装**（反向护栏，可测的硬不变式）
#         · 1 秒一轮：timer 必须显式 AccuracySec=1s（systemd 默认 1 分钟 ⇒ 会被对齐
#           到分钟边界，「1 秒一轮」实际变成每分钟一轮）
#         · 失败分型抽成纯函数 fast_probe_classify（退出码 + stderr 文本 → 类型）：
#           真机形态由网络栈决定 ⇒ 断言必须测**规则本身**，不能绑宿主
#         · 菜单侧：时延优先取快探测（1 秒刷新），没有快探测数据时回落状态文件；
#           [健康]/[故障] 仍只取判定流；丢包 = SYN 被丢（SYN 被丢弃）的采样占比
#         · 台架：新增 T123~T127（cases/28_fast_probe_t123.sh）
# v2.19.0：第 24 轮 —— 探测端生成物的「共用真源」护栏
#         · 产品侧：health.sh 新增 health_shared_core_lib（core.sh 定位：同级目录 → LIB_DIR
#           → 标准安装路径）；抽取不到时报错，**不装**残缺的探测端
#         · health_check_script_regenerate：自检挪到 mv 之前（失败时保留原来能跑的那份），
#           自检清单加上 rule_target_endpoints（缺它 ⇒ 探测端枚举不到目标 ⇒ 主备静默不切）
#         · lib/realm.sh：单独 source 时自动带上同级 core.sh（照 lib/rules.sh 的既有做法）
#         · 台架：_prepare_failover_runtime 补齐 lib/core.sh（沙箱安装布局 = 真实安装布局）
#         · 台架安全：新增 tests/shims/pgrep 桩 —— 产品的残留清理段会
#           「pgrep 找进程 → kill」，不打桩时**真机上正在跑的同名守护会被杀掉**
#           （实测：生产 VPS 跑批时老守护被杀，systemd 拉回，NRestarts 0→1）
# v2.16.0：第 21 轮 —— 迁移端认领「候选门槛 + 身份优先」用例 + ui_read_default 默认值改判语义
#         · 新增 T115/T116（cases/25_sync_claim_gate_identity_t115.sh）：
#           覆盖 Chief 裁定的认领第三款：候选规则必须 ROLE=1 + ENABLED=true +
#           FAILOVER_ENABLED=true（没开故障转移的规则不许认领状态行）；
#           认领顺序 = 先按组合键 (old_rule_id, 目标) 认领，再退到**还没认领过
#           这个目标**的候选。★T94~T96 测不出这两点：六场景里每条规则都满足
#           门槛 ⇒ 门槛失效也全绿；场景 6 只数行数不数行归谁 ⇒ 身份优先也测不出
#         · T116 负向对照用**真实旧实现**（sync-pre = 75379aa：只有 ROLE=1 一道
#           门槛、无身份优先、无「已认领」判定）⇒ A/B/C/D/F 五场景结论必须相反
#         · cases/22 **零改动**：只读复用它的 helper（规则夹具自带在 cases/25）
#         · T54 判定器 7b：ui_read_default 调用点的默认值由「非空即违规」（结构
#           断言）改成「**肯定语义**才违规」（语义不变式）⇒ 将来合法传 ""/n 不
#           会误红；并补负向对照 7b（注入 "y" 必须被抓到 ⇒ 断言不是恒绿）
# v2.15.0：第 19 轮 —— 读端塌缩回归用例（T114）+ 已知缺陷「预期红」标注机制
#         · 新增 T114（cases/24_readend_collapse_t114.sh）：两条规则共用同一后端
#           host:port 时，读端必须按 (RULE_ID, 目标) 组合键各读各的 status
#           ——真挂的要切（该切不切）、健康的不能被拖着切（不该切却切）
#           · 判据落在产出物上（输出里那个 endpoint 的权重序列第一个权重），
#             钉「主位 ↔ 备位」关系不钉字面量；多组对照只让一个变量在变
#           · 负向对照（readend-pre = 63b6ec9，读端建键不含 RULE_ID 的那一版）
#             用**同一套场景、同一套判定器**必须判红 ⇒ 坏情况确实发生、牙齿成立
#           · ★ pre-tree 必须走沙箱同一条路径重定向（sbx_redirect）：老树写死的是
#             生产路径，不重定向会读真实系统目录（Linux 上就是生产目录）而且
#             读不到 fixture ⇒ 读端静默返回空 ⇒ 对照静默失效
#         · 新增 h_case_expect_fail：用例可声明「本条在当前冻结点预期为 FAIL」
#           —— 声明且确实判红 ⇒ 记 EXPECT_FAIL（不计入失败，退出码 5）；
#              声明却判绿 ⇒ 判 FAIL（缺陷修好了要撤标注 / 用例被改废了 ⇒ 恒绿）
#           —— 两边都报出来，不默默放过（它当场抓到过一次「标注方向反了」）
#         · 退出码语义补齐：4（--only 点名未登记）与 5（已知缺陷预期红在位）
#         · 汇总行新增末列「预期红 N」
# v2.14.0：第 12 轮（续）—— N4 健康探测端四组用例 + 登记表按编号分组
#         · 新增 T85~T88（cases/20_n4_health_probe_regen_state.sh）：
#           T85 生成物必须重新生成（装/升级路径跑完 health_check.sh 的内容或 mtime 必须变）
#           T86 状态文件每轮原子重建（只留当前规则的行；删掉的规则不留孤儿行）
#           T87 跨轮继承按**目标地址**（host:port）而不是按 RULE_ID
#              ★ RULE_ID 连续性是这条的前提：旧格式状态行归属靠 RULE_ID，
#                RULE_ID 不连续会重排 → 归属认不出 → **假绿**（原因写进用例注释）
#           T88 负向对照：同一套判定器跑**修复前的真实旧实现** → 必须判红（判定器有牙齿）
#         · 登记表按编号分组重排（T63-T67 / T68-T76 / T77-T84 / T85-T88），
#           顺序只影响可读性，不影响执行顺序（执行顺序按登记顺序）
# v2.13.0：第 12 轮 —— 主备切换可靠性收敛 + 台架自检三项
#         · ① **--only 点名不存在的用例 → 退出码 4**（并打印未登记 ID 清单）
#           背景：Chief 实测 `--only T99`（不存在的用例）EXIT=0 + 「总计 0 条」
#           → **假绿**（点名了不存在的用例，退出码却是 0）。
#           口径：0=通过 / 1=用例失败 / 2=台架自身或参数错误 / 3=历史对象缺失 /
#                 4=--only 点名了未登记的用例 ID。
#         · ② **登记表自检**（两个方向）：登记了但没实现 → 退出码 2；
#           已定义但未登记 → 醒目告警（「用例文件在 ≠ 用例被跑过」= 零覆盖的假绿）。
#           --list 时差集信息走 **stderr**，stdout 保持纯登记 ID 列表（供 T40 数条数）。
#         · ③ **T40 增断言**：候选范围最后一笔引用的「总计 N 条」必须等于
#           该冻结点 --list 的实际条数（只对最后一笔生效，不回溯历史）。
#         · ④ **探测超时预算 3s → 10s**（健康探测端）：探针预算 + 规则 fixture 的
#           CONNECTION_TIMEOUT 同步放宽，时延判据上界 <3000 → <=30000ms；
#           死端口那档**不动**（它测的是「连不上要快速失败」，与负载无关）。
#         · ⑤ **T20 必装清单改为「从产品自己声明里抽」**：产品正在删独立守护进程，
#           写死的清单会把「产品已删」误判成「安装缺文件」→ 假红。
#         · ⑥ 新增三组用例：T63-T67 质量指标只观测不动作 / T68-T76 主备切换可靠性
#           / T77-T84 权重「10 独占」校验。
#         · ⑦ 跑批自带 **mkdir 原子锁 + DONE 标记**：锁只告警不阻断（共享仓库多会话
#           并行，硬拒绝会搞挂别人的批次）；DONE 标记区分「跑完」与「被中断」。
#
# v2.11.0：第 10 轮 —— T54 交互读入 EOF 收口的不变式
#         · 静态四层（判据跑在冻结态 $SBX_SRC 上，不读工作区）：
#           ① UI helper 的**份数**（恰为 4：lib/core.sh + 3 个独立脚本）与**逐字一致性**
#              （sha256 相同）—— 独立脚本是独立安装单元、拿不到 lib/，
#              「一份实现」只能是「四份逐字一致的拷贝」→ 漂移必须判红
#           ② 不存在「无 EOF 处理的用户输入读入」（裸 read / 裸 read -p）
#           ③ 每个含输入读入的 while 循环都有 sleep 0.2 兜底
#           ④ 不存在裸 clear（必须走 ui_clear）
#         · 运行时层：ui_read_default 的契约 —— 读到 EOF → 取默认值 + **不终止调用方**
#           （与 ui_read_into 的「EOF 一律退出」刻意不同：安装流程里 EOF 是常态）
#         · 负向对照 (a)：静态四层用**真实修复前实现**（修复前冻结点的产品文件树）
#           跑同一套判定器 → 必须抓到违规（坏情况确实发生）
#         · 负向对照 (b)：运行时层是注入式退化（ui_read_default 新引入，修复前无等价形态）
# v2.12.2：第 9 轮（续）—— 修「预检退出码被一律映射成 3」
#         · 上一版写成 `if ! history_preflight; then exit 3; fi` → 预检的**两种**失败
#           （历史对象缺失 = 3 / 台架清单为空 = 2）都被报成 3，
#           而空清单那条的输出里明明写着「退出码 2」→ **输出说了假话**。
#         · 修法：退出码**原样透传**（`history_preflight || _pf_rc=$?` → `exit "$_pf_rc"`）。
# v2.12.1：第 9 轮（续）—— 给历史对象预检补**防空过护栏**
#         · 上一版有个静默放行的洞：若 sbx_required_history_shas 不可用
#           （没 source 到 / 清单写坏），while 读不到任何行 → n_total=0
#           → n_missing=0 → 直接 return 0 → **预检一个对象都没查却报「通过」**
#           → 历史对象缺失会被静默吞掉（= 假绿）。
#         · 修法：清单为空 → 响亮失败，退出码 2（台架配置错误，不是产品问题）。
# v2.12.0：第 9 轮（续）—— 审稿复核的两条发现 + 历史对象预检
#         · T32 锚点护栏（审稿 发现 1）：文件数下限护栏只防「全砍」，不防「砍一部分」
#           （实测：砍掉 docs/* → 候选数 28→22 仍 ≥ 下限 → 那 6 份文档里的误导句式
#           彻底无人检查而门禁是绿的）→ 改成「**锚点文件必须在范围内且被扫到**」
#           （锚点 = 历史上真出过这个毛病的文件），并配负向对照 8：
#           砍掉 docs/* 后锚点命中数必须掉下来 → 证明这条护栏有牙齿。
#         · T32 子句级豁免（审稿 发现 2）：否定词「整行豁免」是漏判通道 ——
#           「…两处必须同步，没有别的办法。」这类「肯定误导 + 句尾否定词」抓不到；
#           而且旧负向对照 6(b) 把这种漏判写成了「正确行为」（期望值本身写错）。
#           修法：豁免缩到**子句**——按核心短语「两处…同步」定位，同一子句内、
#           否定词起点不晚于命中起点且词尾紧邻或覆盖它 → 豁免；否则计入违规。
#           ★ 子句切分按**字节**（中文标点固定 3 字节）并钉 LC_ALL=C，
#             不引入中文标点字符类（那正是 P1 的病根）。
#           ★ 负向对照 6 拆成 (a)/(b-1)/(b-2)：(b-2) 期望「计入」= 新口径的牙齿。
#         · T53「份数」不变式（Chief 提的 4 份实现怎么钉）：全仓 ui_read_into() {
#           的定义份数 ≤ 4（lib/core.sh + 3 个独立脚本），**不许出现第 5 份副本**；
#           配合成树自检（第 5 份必须被数到）防这条上限断言恒真。
#         · T53 负向对照阈值修正：原用「正向上限 65536」当「坏情况下限」，
#           而并发争用下旧实现只吐 63,155 B（余量 3%）→ --repeat 3 第 3 轮 flaky。
#           改成「最差实测下限 16KB + 相对放大 ≥ 50 倍」（不受机器快慢影响）。
#         · 跑批前预检（Chief 派单 P2）：负向对照依赖的历史对象在不在本地对象库
#           —— 缺任一个 → **独立退出码 3** + 写清后果与修复命令（`git fetch --tags origin`），
#           绝不混进「用例失败」（那会被误读成产品回归）。
#           清单是**单一真源**（tests/cases/00_common.sh 的 sbx_required_history_shas），
#           用例与预检共用；可选自愈开关 XWPF_FETCH_TAGS=1（默认不联网）。
# v2.11.0：第 9 轮（续）—— T32 补回「第 3 轮放宽过的合法形态」分支（P2）
#         · 起因：T32 的份数判据在后续重构里被钉成「== 1」→ 第 3 轮明确放宽过的
#           「2 份 = 真源 + 生成脚本内的手工内联副本」（a9102c1 / b361ca8 的形态）
#           这个**合法**形态会被误判红 —— 手工扫描口径认它（reports/round2-review.md），
#           T32 却抓不住 → 按「并列分支」补回来。
#         · 不变式本身不变：全仓份数 ∈ [1,2]（不许有第 3 份）+ 副本集中在 lib/health.sh
#           + 生成物里恰好 1 份且与真源逐字一致。
#         · 2 份形态的附加条件：两份必须在**同一文件**、其中一份位于生成器
#           （health_check_script_body）的 heredoc 内、且两份**逐字一致**（无漂移）。
#         · ★ 补回的分支必须当场证明它会判对 → 5 组合成探针树自检
#           （单一真源 / 真源+内联副本 / 漂移 / 副本分散 / 第 3 份）。
#           否则「2 份」这条分支在当前产品（1 份）下**一次都没被跑过** → 判定器写错也全绿。
# v2.10.0：第 9 轮 —— T53 交互菜单 EOF 忙循环护栏
#         · 第一层 · helper 契约：读到 EOF 时 helper 必须**终止调用方**（4 处实现：
#           lib/core.sh + 3 个独立脚本各内置一份）—— 判据用**哨兵**（调用后打印的
#           AFTER-CALLBACK-SENTINEL 不出现），**不能断退出码**：helper 坏掉时脚本
#           会继续往下跑、照样 rc=0 → 恒绿。这层不能省：入口的 ui_require_tty 护栏
#           会先 exit，走不到 helper —— 只测入口的话，把 helper 回退/删掉都抓不到。
#         · 第二层 · 入口端到端：菜单入口在 stdin 非终端（EOF）下必须**自己**退出：
#           不得忙循环、不得无界输出（真机事故：旧实现 5.7 小时灌满 479MB tmpfs →
#           内存+swap 耗尽 → sshd 握不上手）。三腿断言：① 超时前自己退出（≠124）
#           ② 输出字节数有上限 ③ 退出码 0
#         · 防空过护栏：输出必须命中入口标志（入口提示语**或**菜单标题 —— 两种机制都算，
#           只钉行为不钉实现）且输出非空，否则「根本没进菜单 → 立刻退出」会让三条恒绿
#         · 负向对照：helper 层用注入式退化（helper 是新引入的，修复前没有等价形态，
#           如实标注）；入口层用**真实修复前实现**（d0366b3 的 lib/）复现忙循环，
#           断言的是「坏情况确实发生」（124 + 输出膨胀），不是「坏情况没发生」
HARNESS_VERSION="v2.20.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t32-copy-form-2 + t32-anchor-guard + t32-clause-exempt + t53-helper-count + t53-neg-floor + history-preflight + preflight-empty-guard + preflight-exit-passthrough + t54-ui-eof-closure-invariants + t54-judge-selfcheck + t53-rel-threshold + only-unregistered-exit4 + registry-selfcheck + t40-case-count-contract + probe-budget-10s + install-list-from-product + t63-t67-quality-observation + t68-t76-switch-reliability + t77-t84-weight10-exclusive + t85-t88-n4-probe-regen + run-lock-done-marker + t114-readend-collapse + expect-fail-exit5 + t54-affirm-default-7b + t115-t116-claim-gate-identity + t117-t118-legacy-failover-guard + t119-t121-standby-target-parity + t122-shared-core-guard + pgrep-shim + t123-t127-fast-probe)"

# shellcheck source=lib/harness.sh
. "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=lib/sandbox.sh
. "$SCRIPT_DIR/lib/sandbox.sh"

ONLY=""
ONLY_SET=0
REPEAT=1
CLEAN=0
LIST=0
BASE_SHA="${BASE_SHA:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            ONLY="${2:-}"
            ONLY_SET=1
            shift 2
            ;;
        --repeat)
            REPEAT="${2:-1}"
            shift 2
            ;;
        --base-sha)
            BASE_SHA="${2:-}"
            shift 2
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --list)
            LIST=1
            shift
            ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 2
            ;;
    esac
done

# 冻结点解析与校验：SHA 不存在就直接停，不要退化成"读工作区"
if [ -z "$BASE_SHA" ]; then
    BASE_SHA="$(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null)"
fi
if ! (cd "$REPO_ROOT" && git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null); then
    echo "错误: 冻结点不存在: $BASE_SHA" >&2
    echo "      用 git log --oneline -10 查可用 SHA，或用 --base-sha 指定" >&2
    exit 2
fi
BASE_SHA="$(cd "$REPO_ROOT" && git rev-parse "$BASE_SHA" 2>/dev/null)"

# ── 跑批锁（mkdir 原子锁）+ DONE 标记 ──────────────────────────
#   背景（硬约束）：后台跑批会被并发起多实例 → 互相抢机器、抢沙箱。
#   · 锁用 **mkdir**（原子操作：建不出来 = 已有同仓跑批在跑）。
#   · **不阻断**：共享仓库里经常有多个会话同时跑批，硬拒绝会把别人的批次搞挂
#     → 只大声告警并继续，同时把持有者 PID/起始时间写进锁目录，事后可查。
#   · **DONE 标记**：跑批**正常结束**才写 <沙箱>/DONE（含退出码/台架版本/冻结点）；
#     中途被杀 → 没有 DONE → 读日志的人一眼能分清「跑完了」和「被中断」，
#     别拿半截日志当结论（本轮真踩过：被取消的跑批留下了孤儿进程和半截日志）。
XWPF_LOCK_DIR="${TMPDIR:-/tmp}/xwpf-runlock-$(printf '%s' "$REPO_ROOT" | md5sum 2>/dev/null | cut -c1-10)"
XWPF_LOCK_OWNED=0
if mkdir "$XWPF_LOCK_DIR" 2>/dev/null; then
    XWPF_LOCK_OWNED=1
    printf 'pid=%s\nstart=%s\nrepo=%s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" "$REPO_ROOT" \
        > "$XWPF_LOCK_DIR/owner" 2>/dev/null || true
else
    echo "⚠ 检测到同一仓库已有跑批在运行（锁: $XWPF_LOCK_DIR）"
    echo "   持有者: $(tr '\n' ' ' < "$XWPF_LOCK_DIR/owner" 2>/dev/null)"
    echo "   不阻断（共享仓库多会话并行），但并发会互相拖慢 ——"
    echo "   引用结论前请确认没有别的批次正在改同一棵树。"
fi

_xwpf_finish() {
    local rc=$?
    if [ "${XWPF_LOCK_OWNED:-0}" = "1" ] && [ -d "$XWPF_LOCK_DIR" ]; then
        rm -rf "$XWPF_LOCK_DIR" 2>/dev/null || true
    fi
    if [ -n "${SBX_ROOT:-}" ] && [ -d "$SBX_ROOT" ]; then
        printf 'exit=%s\nfinished=%s\nharness=%s\nbase_sha=%s\n' \
            "$rc" "$(date '+%Y-%m-%d %H:%M:%S')" "${HARNESS_VERSION:-}" "${BASE_SHA:-}" \
            > "$SBX_ROOT/DONE" 2>/dev/null || true
    fi
}
trap _xwpf_finish EXIT


# 用例登记表：编号:函数名
CASES=(
    "T01:case_T01_download_urls"
    "T02:case_T02_old_repo_name"
    "T03:case_T03_eol"
    "T04:case_T04_xwpf_help_static"
    "T05:case_T05_failover_help_vs_docs"
    "T06:case_T06_devtcp_fallback"
    "T07:case_T07_docs_claim_missing_test"
    "T08:case_T08_docs_claim_missing_source"
    "T09:case_T09_tracked_pyc"
    "T10:case_T10_weight_valid"
    "T11:case_T11_weight_all_zero"
    "T12:case_T12_weight_count_mismatch"
    "T13:case_T13_weight_range"
    "T14:case_T14_active_standby_rule_state"
    "T15:case_T15_weights_contain_zero"
    "T16:case_T16_health_timer_start"
    "T17:case_T17_health_unit_consistency"
    "T18:case_T18_no_nc_fallback"
    "T19:case_T19_active_standby_flip"
    "T20:case_T20_bootstrap_offline"
    "T21:case_T21_xwpf_help_runtime"
    "T22:case_T22_crlf_install_artifact"
    # —— 第 2 轮：从原 4 套独立脚本并入的用例 ——
    "T23:case_T23_auto_standby_multi_rule"
    "T24:case_T24_priority_primary_selection"
    "T25:case_T25_back_to_roundrobin"
    "T26:case_T26_probe_source_behavior"
    "T27:case_T27_probe_generated_copy_behavior"
    "T28:case_T28_two_probe_copies_identical"
    "T29:case_T29_active_standby_six_states"
    "T30:case_T30_exclude_mode_five_states"
    "T31:case_T31_set_u_robustness"
    "T32:case_T32_single_probe_implementation"
    "T33:case_T33_missing_optional_field_set_u"
    # —— 第 3 轮：文档源码引用一致性 ——
    "T34:case_T34_docs_source_refs"
    # —— 第 4 轮：M1/M2/M5/M7/M8 的行为回归 ——
    "T35:case_T35_rule_parse_no_exec"
    "T36:case_T36_enter_standby_clears_target_states"
    "T37:case_T37_health_start_failure_rollback"
    "T38:case_T38_prev_balance_mode_restore"
    "T39:case_T39_active_standby_confirm"
    # —— 第 5 轮：提交信息契约（声称全过必须引用唯一入口实测口径）——
    "T40:case_T40_commit_message_contract"
    # —— 第 6 轮：主备语义（只有一个主）与权重落盘索引 ——
    "T41:case_T41_weight_writeback_index"
    "T42:case_T42_priority_single_primary"
    # —— 第 7 轮：补覆盖盲区（更新中心 / OCR / jq / 规则落盘 / 时延）——
    "T43:case_T43_version_normalize_and_uptodate"
    "T44:case_T44_refuse_on_failed_verification"
    "T45:case_T45_restore_backup_robust"
    "T46:case_T46_auto_rollback_on_start_failure"
    "T47:case_T47_scripts_update_and_lock"
    # —— 第 7 轮：补覆盖盲区（OCR 导入 / jq 配置生成 / 规则落盘 / 时延）——
    "T48:case_T48_ocr_import_chain"
    "T49:case_T49_jq_config_generation"
    "T50:case_T50_rule_crud_persistence"
    "T51:case_T51_latency_merged"
    # —— 第 7 轮收尾：健康状态 TARGET 口径（host:port）——
    "T52:case_T52_health_target_scope"
    # —— 第 9 轮：交互菜单 EOF 忙循环护栏 ——
    "T53:case_T53_menu_eof_no_busy_loop"
    # —— 第 10 轮：交互读入 EOF 收口的不变式 ——
    "T54:case_T54_ui_eof_closure_invariants"
    # —— 第 12 轮新增用例 ——
    # 质量指标只观测不动作（T63~T67 · cases/17_n5_quality_observation.sh）
    "T63:case_T63_latency_metric_observation_only"
    "T64:case_T64_fail_count_window_observation_only"
    "T65:case_T65_quality_threshold_injection_no_switch"
    "T66:case_T66_quality_detector_selfcheck"
    "T67:case_T67_observation_no_side_effect"
    # 质量窗口「真的可配」（T108 · cases/17_n5_quality_observation.sh）
    #   ★ Chief 拍板补的断言：键写在白名单/模板/文档里 ≠ 值真被读到
    #     （N5 第一版去 grep 一个从未被赋值的变量 ⇒ 永远回落默认 ⇒ 缺陷静默过去）。
    "T108:case_T108_quality_window_configurable"
    # 质量窗口「一轮探测只记一次采样」（T109 · cases/17_n5_quality_observation.sh）
    #   ★ Chief 审 N5 落树时发现的缺陷：采样块里又探测了一遍 ⇒ 探测次数翻倍，
    #     且采样口径可能与本轮 status 判定来自不同的探测结果（指标与切换决策对不上）。
    "T109:case_T109_quality_one_sample_per_cycle"
    # 探测端时间源单位契约 + 失败样本时延分布（T110~T113 · cases/23_probe_time_and_fail_latency.sh）
    #   ★ T110：now_us 两条分支单位不一致（纳秒 vs 微秒）⇒ 老 bash 机器上时延被放大 1000 倍。
    #   ★ T111/T112/T113：失败样本的时延没进窗口 ⇒ 用户拍板的「失败率 + 失败时延分布」口径只落了一半。
    "T110:case_T110_now_us_unit_consistent"
    "T111:case_T111_fail_latency_recorded_in_window"
    "T112:case_T112_fail_latency_rolls_with_window"
    "T113:case_T113_fail_latency_in_stats_and_display"
    # 主备切换可靠性九组（T68~T76 · cases/18_failover_switch_reliability.sh）
    "T68:case_T68_enter_active_standby"
    "T69:case_T69_switch_away_on_failure"
    "T70:case_T70_switch_back_on_recovery"
    "T71:case_T71_no_flapping"
    "T72:case_T72_probe_actually_runs"
    "T73:case_T73_no_false_switch_slow_target"
    "T74:case_T74_no_inherited_state"
    "T75:case_T75_rollback_when_probe_fails"
    "T76:case_T76_same_target_set"
    # 权重 10 独占校验（T77~T84 · cases/19_weight_ten_exclusive.sh）
    "T77:case_T77_weight10_exclusive_active_standby"
    "T78:case_T78_weight10_exclusive_load_balance"
    "T79:case_T79_weight10_must_be_rejected"
    "T80:case_T80_weight10_reject_leaves_no_half_write"
    "T81:case_T81_weight10_both_entries_rejected"
    "T82:case_T82_weight10_reject_message_speaks_human"
    "T83:case_T83_weight10_judge_selfcheck"
    "T84:case_T84_weight10_negative_control_old_impl"
    # N4 健康探测端：生成物重生成 / 状态文件原子重建 / 按地址继承 / 负向对照
    # （T85~T88 · cases/20_n4_health_probe_regen_state.sh）
    "T85:case_T85_probe_artifact_regenerated_on_install_and_update"
    "T86:case_T86_health_status_rebuilt_atomically_each_round"
    "T87:case_T87_health_status_inheritance_by_target_address"
    "T88:case_T88_negative_control_old_impl"
    # 静态 3（Chief r16 派单）：所有 while/until 循环里的输入读入必须 EOF 收口 + sleep 兜底
    #   豁免仅限 herestring / 文件重定向 / xwpf:noninteractive-io 标记（fail-closed）
    #   （T89~T92 · cases/21_static3_noninteractive_io.sh）
    "T89:case_T89_static3_noninteractive_io_invariant"
    "T90:case_T90_static3_covers_static2"
    "T91:case_T91_static3_probe_unmarked_read_is_caught"
    "T92:case_T92_static3_probe_marked_read_is_not_reported"
    "T93:case_T93_static3_probe_matrix_vs_chief_contract"
    # 迁移端认领一对一（Chief r17 派单 · 缺陷已由 84fe096 修掉）
    #   负向对照锚点 sync-pre = 75379aa（= 84fe096^，修复前的真实实现）
    #   （T94~T96 · cases/22_sync_claim_one_to_one.sh）
    "T94:case_T94_sync_claim_one_to_one_six_scenarios"
    "T95:case_T95_sync_negative_control_old_impl"
    "T96:case_T96_sync_old_vs_current_must_differ"
    "T114:case_T114_readend_collapse_same_target_two_rows"
    # 迁移端认领：候选门槛 + 身份优先（Chief 裁定第三条）
    #   ① 先按组合键 old_rule_id+目标地址认领 ② 再退到未认领过的候选
    #   ③ 候选必须 ROLE=1 + ENABLED=true + FAILOVER_ENABLED=true
    #   负向对照锚点 sync-pre = 75379aa（老实现：只有 ROLE=1 一道门槛、无身份优先、无已认领判定）
    #   （T115~T116 · cases/25_sync_claim_gate_identity_t115.sh）
    "T115:case_T115_sync_claim_identity_priority_and_candidate_gate"
    "T116:case_T116_sync_gate_and_identity_negative_control_old_impl"
    # 老机器主备池守护残留清理的护栏（第 22 轮 · cases/26_legacy_failover_guard_t117.sh）
    #   安装 / 升级路径：守护还在服务（池配置存在且含 "listen"）⇒ 跳过清理
    #   卸载路径（xwPF.sh uninstall + 菜单 8）：强制清理
    #   崩溃循环残留（没有池配置却在跑）⇒ 照常清干净
    "T117:case_T117_legacy_failover_guard_serve_vs_residue"
    "T118:case_T118_legacy_failover_guard_negative_control"
    # 主备目标枚举口径：探测端与路由端必须同一份（T119~T121 · cases/27_standby_target_parity_t119.sh）
    #   两端口径不一致 ⇒ 状态行匹配不上配置里的目标 ⇒ 主备切换**静默失效**
    "T119:case_T119_standby_probe_route_target_parity"
    "T120:case_T120_standby_probe_route_parity_negative_control"
    "T121:case_T121_standby_auto_enable_keeps_explicit_target_states"
    # 共用真源不可用时，探测端生成物不许被换成残缺版（T122 · cases/27_standby_target_parity_t119.sh）
    #   探测脚本缺 rule_target_endpoints ⇒ 探测端枚举不到任何目标 ⇒ 主备永远不切（静默失效）
    "T122:case_T122_shared_core_missing_must_not_install_broken_probe"
    # 快探测流（**只观测**：每秒一轮，刷新菜单里的时延/丢包显示）（T123~T127 · cases/28_fast_probe_t123.sh）
    #   快探测一旦参与切换，就等于改了切换时机（口径：切换仍按负载均衡脚本的默认时间）
    "T123:case_T123_fast_probe_guard_and_timer"
    "T124:case_T124_fast_probe_runs_without_touching_judgement"
    "T125:case_T125_fast_probe_classify_and_window"
    "T126:case_T126_menu_latency_prefers_fast_probe"
    "T127:case_T127_fast_probe_failure_does_not_roll_back_standby"
)


for f in "$SCRIPT_DIR"/cases/*.sh; do
    # shellcheck source=/dev/null
    . "$f"
done

# ── 登记表自检（两个方向都要查）────────────────────────────────
#   ① 登记了但**没实现**（case 函数不存在）→ 台架配置错误 → 退出码 2
#      （否则跑到那条用例才炸成「command not found」，看起来像产品缺陷）
#   ② **实现了但没登记** → 「用例文件在 ≠ 用例被跑过」= **零覆盖的假绿**
#      （实测过：漏登记时 `--only T53` 返回「总计 0 条，通过 0，失败 0」，看着像绿）
#   `--list` 时差集信息写 **stderr**，stdout 保持纯登记 ID 列表（供 T40 数条数）。
REG_UNIMPL=0
REG_UNREG=0
REG_DUP=0

defined_case_fns() {
    # ★ 编号位数放宽到 **2 位及以上**（不写死上限）：T100 起（T108/T109 …）也是合法用例号 ——
    #   写死两位数 ⇒ 三位数的用例函数**查不出来** ⇒ 「实现了但没登记」这条护栏
    #   对三位数编号**静默失效** ⇒ 漏登记时没人拦（= 零覆盖的假绿）。
    #   ★ 上限也不能写死：写死「2~3 位」⇒ 将来出现四位数编号时**原样复发**
    #     （静默失效、不报错）⇒ 只写「至少 2 位」。
    declare -F | awk '{print $3}' | grep -E '^case_T[0-9]{2,}_' | sort
}

registration_check() {
    local c fn def_fn found seen
    REG_UNIMPL=0; REG_UNREG=0; REG_DUP=0
    seen=" "
    for c in "${CASES[@]}"; do
        fn="${c##*:}"
        if ! declare -F "$fn" >/dev/null 2>&1; then
            echo "  ✗ 登记了但没实现: ${c%%:*} -> $fn" >&2
            REG_UNIMPL=$((REG_UNIMPL+1))
        fi
        case "$seen" in
            *" ${c%%:*} "*)
                echo "  ✗ 编号重复登记: ${c%%:*}" >&2
                REG_DUP=$((REG_DUP+1))
                ;;
        esac
        seen="$seen${c%%:*} "
    done
    for def_fn in $(defined_case_fns); do
        found=0
        for c in "${CASES[@]}"; do
            if [ "${c##*:}" = "$def_fn" ]; then found=1; break; fi
        done
        if [ "$found" = "0" ]; then
            echo "  ✗ 已定义但未登记（该用例不会被跑 = 零覆盖的假绿）: $def_fn" >&2
            REG_UNREG=$((REG_UNREG+1))
        fi
    done
}

registration_check

if [ "$LIST" = "1" ]; then
    # stdout = 纯登记 ID 列表（T40 数条数就数这个）；差集信息走 stderr
    for c in "${CASES[@]}"; do
        echo "${c%%:*}"
    done
    {
        echo "（登记表：登记 ${#CASES[@]} 条；已定义但未登记 ${REG_UNREG} 条；登记但未实现 ${REG_UNIMPL} 条）"
        if [ "$REG_UNREG" -gt 0 ]; then
            echo "  ★ 上面的「已定义但未登记」意味着这些用例**根本不会被跑**（零覆盖的假绿）"
            echo "    → 请把它们加进 tests/run_tests.sh 的 CASES 登记表。"
        fi
    } >&2
    if [ "$REG_UNIMPL" -gt 0 ]; then
        echo "汇总: 登记表与实现不一致（${REG_UNIMPL} 条登记了但没实现）—— 退出码 2" >&2
        exit 2
    fi
    exit 0
fi

# ── --only 点名校验：点名的 ID 必须已登记，否则非 0 退出 ──────────
#   背景（Chief 10/24 派单）：`--only T99`（不存在的用例）实测 EXIT=0 + 「总计 0 条」
#   → **假绿**：点名了不存在的用例，跑批却报「全过」。
#   口径：点名的 ID 里只要有**未登记**的 → 打印未登记清单 → **退出码 4**
#         （独立于 0=通过 / 1=用例失败 / 2=台架自身或参数错误 / 3=历史对象缺失）。
if [ "$ONLY_SET" = "1" ]; then
    _miss=""
    _n_miss=0
    _n_req=0
    _old_ifs="$IFS"
    IFS=','
    for _id in $ONLY; do
        [ -z "$_id" ] && continue
        _n_req=$((_n_req+1))
        _hit=0
        for c in "${CASES[@]}"; do
            if [ "${c%%:*}" = "$_id" ]; then _hit=1; break; fi
        done
        if [ "$_hit" = "0" ]; then
            _miss="${_miss}    · ${_id}"$'\n'
            _n_miss=$((_n_miss+1))
        fi
    done
    IFS="$_old_ifs"
    if [ "$_n_req" -eq 0 ]; then
        echo "错误: --only 没有点名任何用例 ID" >&2
        echo "汇总: --only 点名为空 —— 未跑任何用例，退出码 4" >&2
        exit 4
    fi
    if [ "$_n_miss" -gt 0 ]; then
        echo "=============================================================="
        echo " ✗ --only 点名了**未登记**的用例 ID"
        echo "=============================================================="
        printf '%s' "$_miss"
        echo "  （点名 ${_n_req} 个，其中 ${_n_miss} 个未登记）"
        echo
        echo "后果：未登记的 ID 会被**静默跳过** → 跑批只跑剩下那几条并报「全过」"
        echo "      （= 假绿：点名了不存在的用例，退出码却是 0）。"
        echo
        echo "已登记的用例 ID（--list 可看全量）："
        for c in "${CASES[@]}"; do echo "    ${c%%:*}"; done
        echo
        echo "汇总: --only 点名了 ${_n_miss} 个未登记的用例 ID —— 未跑任何用例，退出码 4"
        exit 4
    fi
fi

if [ "$REG_UNIMPL" -gt 0 ]; then
    echo "汇总: 登记表与实现不一致（${REG_UNIMPL} 条登记了但没实现）—— 未跑任何用例，退出码 2" >&2
    exit 2
fi

# ── 跑批前预检：负向对照依赖的历史对象在不在本地对象库里 ──────────
#   背景（第 9 轮 · Chief 派单 P2）：负向对照用 `git show <SHA>:<path>` 取
#   「修复前的真实旧实现」。堆叠 PR 全部 squash 合并后，main 的历史里
#   **不再包含**这些旧 SHA；而 `git clone --single-branch` **不拉 tag**
#   → 对象缺失 → 负向对照取不到 → **证明力归零**，门禁还会以「用例失败」的
#   形式红 → **会被误读成产品回归**。
#   所以缺任一个 → 用**独立退出码 3** 报（0=通过 / 1=用例失败 / 2=BASE_SHA 不存在 /
#   3=历史对象缺失），并在输出里写清：缺哪个、后果、可执行的修复命令。
#   ★ 清单来自 tests/cases/00_common.sh 的 sbx_required_history_shas
#     —— 与用例取旧实现用的是**同一份真源**，不会两处漂移。
#   ★ 默认**不联网**（台架要能在离线机器上跑）；要自愈必须显式 XWPF_FETCH_TAGS=1。
history_preflight() {
    local k sha desc missing="" n_missing=0 n_total=0
    while read -r k sha desc; do
        case "$k" in ''|'#'*) continue ;; esac
        [ -n "${sha:-}" ] || continue
        n_total=$((n_total + 1))
        if ! (cd "$REPO_ROOT" && git cat-file -e "$sha^{commit}" 2>/dev/null); then
            missing="${missing}    · ${k}  ${sha}  ${desc:-（无说明）}"$'\n'
            n_missing=$((n_missing + 1))
        fi
    done < <(sbx_required_history_shas)

    # ── 防空过护栏：清单本身必须非空 ───────────────────────
    #   若 sbx_required_history_shas 不可用（没 source 到 / 清单写坏了），
    #   上面的 while 读不到任何行 → n_total=0 → n_missing=0 → 直接 return 0
    #   → **预检静默放行**（假绿）：历史对象一个都没查，却报「通过」。
    #   所以清单为空 = **台架自身配置错误**，必须响亮地失败，不能当成通过。
    if [ "$n_total" -eq 0 ]; then
        echo "=============================================================="
        echo " ✗ 台架预检自身异常：历史对象清单为空（sbx_required_history_shas 没产出任何条目）"
        echo "=============================================================="
        echo "后果：预检**一个历史对象都没查**就放行 → 历史对象缺失会被静默吞掉"
        echo "      （= 假绿）。这是**台架配置错误**，不是产品问题。"
        echo "检查：tests/cases/00_common.sh 的 sbx_required_history_shas 是否可执行、"
        echo "      run_tests.sh 是否在预检之前 source 了 tests/cases/*.sh。"
        echo
        echo "汇总: 预检清单为空 —— 未跑任何用例，退出码 2（台架配置错误）"
        return 2
    fi

    [ "$n_missing" -eq 0 ] && return 0

    echo "=============================================================="
    echo " ✗ 跑批前预检未通过：负向对照依赖的历史对象在本地对象库里找不到"
    echo "=============================================================="
    printf '%s' "$missing"
    echo "  （共 $n_total 个历史对象，缺 $n_missing 个）"
    echo
    echo "后果：这些负向对照取不到「修复前的真实旧实现」→ 证明力归零；"
    echo "      不预检直接跑的话，它们会以「用例失败」的形式红 —— 会被误读成产品回归。"
    echo "      （这不是产品缺陷，是克隆方式没把历史拉全。）"
    echo
    echo "修复（取对象，不改历史）："
    echo "  git fetch --tags origin"
    echo "  # 或者重新完整克隆（**不要**用 --single-branch：它不拉 tag，旧 SHA 仍取不到）:"
    echo "  git clone https://github.com/byby5555/realm-xwPF-offline-active-standby.git"
    echo
    echo "自愈开关（默认不联网；显式打开才会 fetch --tags）："
    echo "  XWPF_FETCH_TAGS=1 bash tests/run_tests.sh --base-sha <sha>"
    echo
    echo "汇总: 预检未通过（历史对象缺失 $n_missing 个）—— 未跑任何用例，退出码 3"
    return 3
}

# 可选自愈：显式开关才联网（默认离线）
if [ "${XWPF_FETCH_TAGS:-0}" = "1" ]; then
    echo "· XWPF_FETCH_TAGS=1 → 正在 git fetch --tags origin（自愈）"
    (cd "$REPO_ROOT" && git fetch --tags origin 2>&1 | tail -3) || true
fi

# 退出码要**原样透传**，不能一律映射成 3：
#   预检有两种失败 ——「历史对象缺失」(3) 与「台架清单为空」(2)。
#   之前写成 `if ! history_preflight; then exit 3; fi` → 空清单也被报成 3，
#   而输出里写着「退出码 2」→ **输出说了假话**（这正是 T40 那类问题）。
_pf_rc=0
history_preflight || _pf_rc=$?
if [ "$_pf_rc" -ne 0 ]; then
    exit "$_pf_rc"
fi

selected_cases() {
    local c
    for c in "${CASES[@]}"; do
        local id="${c%%:*}"
        if [ -z "$ONLY" ]; then
            echo "$c"
        else
            case ",$ONLY," in
                *",$id,"*) echo "$c" ;;
            esac
        fi
    done
}

banner() {
    local dirty
    dirty=$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | tr '\n' ';')
    echo "=============================================================="
    echo " realm-xwPF-offline-active-standby · 测试台架（唯一入口）"
    echo "=============================================================="
    echo "仓库        : $REPO_ROOT"
    echo "★ 冻结点    : $BASE_SHA"
    echo "  冻结点标题: $(cd "$REPO_ROOT" && git log -1 --format='%ad %s' "$BASE_SHA" 2>/dev/null)"
    echo "  当前 HEAD : $(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null)（仅供对照，不作为被测产物）"
    echo "  台架版本  : $HARNESS_VERSION"
    echo "  产物来源  : git show \$BASE_SHA:<path>（不读工作区）"
    echo "工作区改动  : ${dirty:-（干净）}"
    echo "bash        : $BASH_VERSION"
    echo "沙箱根目录  : $SBX_ROOT"
    echo "冻结态原始  : $SBX_RAW（git show 原始字节）"
    echo "LF 副本     : $SBX_SRC"
    echo "执行副本    : $SBX_RUN（= LF 副本 + 路径重定向 + root 模拟）"
    echo "假 bin      : $SBX_BIN （nc 单独放 $SBX_BIN_NC，默认不进 PATH）"
    echo "离线镜像    : $SBX_MIRROR"
    echo "桩清单      : $(cd "$REPO_ROOT/tests/shims" && ls | tr '\n' ' ')"
    echo "路径重定向  :"
    local entry
    for entry in "${SBX_PATH_MAP[@]}"; do
        echo "               ${entry%%|*}  →  \${SBX}/$(printf '%s' "${entry##*|}" | tr '.' '.')"
    done
    echo "越界残留    : $(sbx_escape_scan | wc -l | tr -d ' ') 处真实系统绝对路径（只读白名单除外）"
    sbx_escape_scan | head -8 | while IFS= read -r l; do echo "               $l"; done
    echo "=============================================================="
}

# 跑一条用例，返回 0/1，并写入结果数组
run_one() {
    local id="$1" fn="$2"
    local out rc nfail actual

    RUNNER_CASE_ID="$id"
    out=$( ( set +e; "$fn" ) 2>&1 )
    rc=$?
    printf '%s\n' "$out" > "$SBX_ROOT/cases/$id.stdout"

    nfail=0
    actual=""
    if [ -s "$SBX_ROOT/cases/$id.fails" ]; then
        nfail=$(grep -c . "$SBX_ROOT/cases/$id.fails")
        actual=$(head -1 "$SBX_ROOT/cases/$id.fails")
    elif [ -s "$SBX_ROOT/cases/$id.notes" ]; then
        actual=$(tail -1 "$SBX_ROOT/cases/$id.notes")
    else
        actual="用例没有产生任何断言记录（疑似提前退出）"
        nfail=1
    fi

    if [ "$rc" != "0" ] && [ "$nfail" = "0" ]; then
        actual="用例函数返回码 $rc；尾部输出: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
        nfail=1
    fi

    RESULT_IDS+=("$id")
    RESULT_TITLES+=("$(awk -F'\t' '{print $2}' "$SBX_ROOT/cases/$id.meta" 2>/dev/null)")
    RESULT_PREREQS+=("$(awk -F'\t' '{print $3}' "$SBX_ROOT/cases/$id.meta" 2>/dev/null)")
    RESULT_CMDS+=("$(awk -F'\t' '{print $4}' "$SBX_ROOT/cases/$id.meta" 2>/dev/null)")
    RESULT_EXPECTS+=("$(awk -F'\t' '{print $5}' "$SBX_ROOT/cases/$id.meta" 2>/dev/null)")
    RESULT_ACTUALS+=("$actual")

    # ★ 已知缺陷 / 预期红（审稿第 18 次修订 ⑤）
    #   用例可在 h_case_begin 之后调 h_case_expect_fail "<理由>"，声明
    #   「本条在当前冻结点预期为 FAIL（产品缺陷还没修）」。
    #   · 声明了且**确实判红** ⇒ 记 EXPECT_FAIL：不算「台架失败」，
    #     但汇总行与退出码都要单独体现 —— 否则整批红会被误读成「台架坏了」，
    #     或者缺陷被悄悄放过（假绿）。
    #   · 声明了却**判绿** ⇒ 记 FAIL：要么缺陷修好了（该撤标注），
    #     要么用例被改废了（恒绿）—— 两种都必须报出来，绝不默默放过。
    local expect_fail_reason=""
    if [ -s "$SBX_ROOT/cases/$id.expect_fail" ]; then
        expect_fail_reason=$(head -1 "$SBX_ROOT/cases/$id.expect_fail")
    fi
    if [ "$nfail" = "0" ]; then
        if [ -n "$expect_fail_reason" ]; then
            RESULT_ACTUALS[${#RESULT_ACTUALS[@]}-1]="本条声明为「已知缺陷预期红」但这次**判绿**了 ⇒ 缺陷可能已修好（请撤掉 h_case_expect_fail），或用例被改废了（恒绿）—— 两者都要人工确认"
            RESULT_VERDICTS+=("FAIL")
        else
            RESULT_VERDICTS+=("PASS")
        fi
    elif [ -n "$expect_fail_reason" ]; then
        RESULT_VERDICTS+=("EXPECT_FAIL")
    else
        RESULT_VERDICTS+=("FAIL")
    fi
    return 0
}

RESULT_IDS=()
RESULT_TITLES=()
RESULT_PREREQS=()
RESULT_CMDS=()
RESULT_EXPECTS=()
RESULT_ACTUALS=()
RESULT_VERDICTS=()

run_round() {
    local c id fn
    RESULT_IDS=(); RESULT_TITLES=(); RESULT_PREREQS=(); RESULT_CMDS=()
    RESULT_EXPECTS=(); RESULT_ACTUALS=(); RESULT_VERDICTS=()
    for c in $(selected_cases); do
        id="${c%%:*}"
        fn="${c##*:}"
        run_one "$id" "$fn"
    done
}

vector() {
    local i out=""
    for i in "${!RESULT_IDS[@]}"; do
        out="$out${RESULT_IDS[$i]}=${RESULT_VERDICTS[$i]};"
    done
    printf '%s' "$out"
}

print_table() {
    local i
    echo
    echo "===================== 用例结果 ====================="
    printf '%-6s %-22s %-40s %-46s %-46s %-58s %s\n' "编号" "用例" "前置" "命令" "期望" "实际" "结论"
    printf '%s\n' "------------------------------------------------------------------------------------------------------------------------"
    for i in "${!RESULT_IDS[@]}"; do
        printf '%-6s %-22s %-40s %-46s %-46s %-58s %s\n' \
            "${RESULT_IDS[$i]}" \
            "$(h_trunc "${RESULT_TITLES[$i]}" 20)" \
            "$(h_trunc "${RESULT_PREREQS[$i]}" 38)" \
            "$(h_trunc "${RESULT_CMDS[$i]}" 44)" \
            "$(h_trunc "${RESULT_EXPECTS[$i]}" 44)" \
            "$(h_trunc "${RESULT_ACTUALS[$i]}" 56)" \
            "${RESULT_VERDICTS[$i]}"
    done
    echo "===================================================="
}

main() {
    sbx_init "$REPO_ROOT"
    banner

    local round vectors="" v
    for ((round = 1; round <= REPEAT; round++)); do
        echo
        echo ">>> 第 $round/$REPEAT 轮开始"
        run_round
        v="$(vector)"
        vectors="$vectors$v"$'\n'
        print_table
    done

    # 稳定性：多轮结果必须一致
    local stable="是"
    if [ "$REPEAT" -gt 1 ]; then
        local first="" other
        first=$(printf '%s' "$vectors" | grep -v '^$' | head -1)
        while IFS= read -r other; do
            [ -z "$other" ] && continue
            [ "$other" = "$first" ] || stable="否"
        done <<< "$vectors"
        echo "各轮结果向量: $(printf '%s' "$vectors" | tr '\n' ' ')"
    fi

    local pass=0 fail=0 expectfail=0 i
    for i in "${!RESULT_VERDICTS[@]}"; do
        case "${RESULT_VERDICTS[$i]}" in
            PASS)        pass=$((pass + 1)) ;;
            FAIL)        fail=$((fail + 1)) ;;
            EXPECT_FAIL) expectfail=$((expectfail + 1)) ;;
            *)           fail=$((fail + 1)) ;;
        esac
    done

    echo
    echo "汇总: 总计 $((pass + fail + expectfail)) 条，通过 $pass，失败 $fail，预期红 $expectfail"
    if [ "$expectfail" -gt 0 ]; then
        echo "★ 「预期红 $expectfail」= **已知缺陷未修**（用例显式声明 h_case_expect_fail）"
        echo "  · 不计入「失败」—— 它是产品缺陷在位，不是台架坏了"
        echo "  · 缺陷修好后该条目会**转绿**，届时必须撤掉 h_case_expect_fail（否则台架会判红提醒）"
        for i in "${!RESULT_VERDICTS[@]}"; do
            if [ "${RESULT_VERDICTS[$i]}" = "EXPECT_FAIL" ]; then
                echo "    · ${RESULT_IDS[$i]}：$(head -1 "$SBX_ROOT/cases/${RESULT_IDS[$i]}.expect_fail" 2>/dev/null)"
            fi
        done
    fi
    echo "多轮一致性（$REPEAT 轮）: $stable"
    echo "★ 冻结点 BASE_SHA : $BASE_SHA"
    echo "★ 台架版本        : $HARNESS_VERSION"
    echo "★ 产物指纹        : $SBX_ROOT/manifest.txt"
    echo "沙箱证据目录: $SBX_ROOT/cases"
    echo "（每个用例的 stdout / notes / fails / meta 都在 $SBX_ROOT/cases/$ID.* 里）"

    # 提交信息自查（第 2 轮是「打印告警」，第 5 轮升级为硬断言 → 见用例 T40）
    # 背景：第 1 轮出现过「另三套脚本全绿、正式入口 run_tests.sh 16/22 红」，
    # 提交信息却写成「全过」。第 2 轮把它做成打印告警 —— 但告警拦不住任何人，
    # 所以第 5 轮把同一套判定搬进用例 T40：**违规就是用例失败、门禁退出码非 0**。
    # 规则、豁免白名单与自检见 tests/cases/07_commit_message_contract.sh。
    local last_subject
    last_subject=$(cd "$REPO_ROOT" && git log -1 --format='%s' 2>/dev/null)
    echo
    echo "── 提交信息自查 ─────────────────────────────────────────"
    echo "· 本台架是**唯一入口**：bash tests/run_tests.sh"
    echo "· 提交信息若声称「全过/通过/测试通过」，必须引用本入口的输出"
    echo "  （BASE_SHA + 汇总行 / 用例总数 / 退出码），不要引用其它脚本的 PASS 计数。"
    echo "· 这条不再是告警：**用例 T40 会判红**（详见上面表格里的 T40 行）。"
    echo "· 上一条提交信息: ${last_subject:-（无）}"

    if [ "$CLEAN" = "1" ]; then
        rm -rf "$SBX_ROOT"
        echo "沙箱已清理"
    fi

    # ── 退出码口径 ─────────────────────────────────────────────
    #   0 = 全过
    #   1 = 有真失败（用例失败或台架失败）
    #   2 = 台架自身或参数错（另外 3=历史对象缺失 / 4=--only 点名未登记）
    #   5 = **有已知缺陷未修**（预期红在位）—— 与「真失败」分开，
    #       免得整批红被误读成「台架坏了」，也免得缺陷被悄悄放过。
    if [ "$fail" -ne 0 ]; then
        return 1
    fi
    if [ "$expectfail" -ne 0 ]; then
        return 5
    fi
    return 0
}

main "$@"
exit $?
