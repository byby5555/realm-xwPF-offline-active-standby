#!/bin/bash
# 【已并入唯一入口】本脚本现在只是 tests/run_tests.sh 的薄封装。
#
# 原来的独立实现已全部并入 run_tests.sh（用例编号见 --only 列表），
# 保留这个文件只是为了不打断「谁还在跑这个脚本」的习惯。
#
# 唯一入口：bash tests/run_tests.sh
# 冻结点：  BASE_SHA=<sha> bash tests/run_tests.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[提示] test_active_standby.sh 已并入唯一入口，转发到 run_tests.sh --only T10,T11,T12,T13,T14,T15,T23,T24,T25" >&2
exec bash "$SCRIPT_DIR/run_tests.sh" --only T10,T11,T12,T13,T14,T15,T23,T24,T25 "$@"
