#!/bin/bash
# 【已并入唯一入口】本脚本现在只是 tests/run_tests.sh 的薄封装。
#
# 原来的独立实现（47 项断言）已全部并入 run_tests.sh，
# 对应用例：T43 版本号归一化 / T44 校验不过拒绝安装 / T45 回滚健壮性 /
#           T46 自动回滚 / T47 脚本包更新 + 并发锁
# 保留这个文件只是为了不打断「谁还在跑这个脚本」的习惯。
#
# ★ 为什么必须薄封装而不是留两份实现：
#   两份实现 = 两个真源 = 改了一处忘了另一处 → 门禁测的和产品跑的可以是两套逻辑。
#   第 1 轮就出过「第 1 轮红、后 2 轮绿」的假抖动，根因就是读了工作区而不是冻结点。
#
# 唯一入口：bash tests/run_tests.sh
# 冻结点：  BASE_SHA=<sha> bash tests/run_tests.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[提示] test_update.sh 已并入唯一入口，转发到 run_tests.sh --only T43,T44,T45,T46,T47" >&2
exec bash "$SCRIPT_DIR/run_tests.sh" --only T43,T44,T45,T46,T47 "$@"
