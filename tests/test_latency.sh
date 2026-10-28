#!/bin/bash
# 【已并入唯一入口】本脚本现在只是 tests/run_tests.sh 的薄封装。
#
# 原来的独立实现（A~F 六组：时间打点 / 带耗时的探测 / 时延辅助函数 /
# 生成的 health_check.sh 真跑 / 菜单静态核对 / 菜单在 set -u 下渲染）
# 已全部并入 run_tests.sh，对应用例：T51。
# 保留这个文件只是为了不打断「谁还在跑这个脚本」的习惯。
#
# ★ 为什么必须薄封装而不是留两份实现：
#   两份实现 = 两个真源 = 改了一处忘了另一处 → 门禁测的和产品跑的可以是两套逻辑。
#
# 唯一入口：bash tests/run_tests.sh
# 冻结点：  BASE_SHA=<sha> bash tests/run_tests.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[提示] test_latency.sh 已并入唯一入口，转发到 run_tests.sh --only T51" >&2
exec bash "$SCRIPT_DIR/run_tests.sh" --only T51 "$@"
