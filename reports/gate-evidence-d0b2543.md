# 门禁留证：合并树 `d0b2543` 的全量双口径

> 本文件由「大厨」在跑批结束后自动抄写，字段全部取自跑批产物原文，**未手工编辑**。
> 抄写时间：2026-10-25 11:10:29

## 一、冻结点与被测树

| 项 | 值 |
|---|---|
| 冻结点（被测树） | `d0b2543` |
| 被测树 checkout | 干净 clone + `git checkout --detach d0b2543`（工作区 0 改动） |
| 台架版本 | `"v2.15.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t32-copy-form-2 + t32-anchor-guard + t32-clause-exempt + t53-helper-count + t53-neg-floor + history-preflight` |
| 登记条数 | 95 |
| case 文件数 | 23 |
| `tests/` 内容指纹 | `139ae23740fe57e5576cfdedf8cd49eef44353fd531dd4eba97d9c901e7fd935` |
| `lib/` 内容指纹 | `c0b712dd69c3e772d71884f4fc5347e4eb0a158ebca2e2f2081d31a8b81baa2b` |
| `cmd/` 内容指纹 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `docs/` 内容指纹 | `c3c9a82c1e09bf7e10a29f7d03c1793bc7bc8534af93ddaec6fdca723b5d2558` |

> 指纹算法：`git ls-tree -r <冻结点> -- <目录>` 的 `(mode, type, sha1, path)` 行集合取 SHA-256；
> **不随 rebase / 换基线而变** ⇒ 可跨分支平移。

## 二、两口径实况

| 口径 | 退出码 | 汇总行 | `.meta` | 非空 `.fails` | manifest SHA-256 | 沙箱 |
|---|---|---|---|---|---|---|
| ambient | **0** | `汇总: 总计 95 条，通过 95，失败 0，预期红 0` | 95 | **0** | `d7a702ba74e1e3db` | `/tmp/xwpf-sbx.LAbXZK` |
| C.UTF-8 | **0** | `汇总: 总计 95 条，通过 95，失败 0，预期红 0` | 95 | **0** | `c609b09182023868` | `/tmp/xwpf-sbx.K29LId` |

### ambient

- 起止：10:36:11 LC_ALL=ambient → 10:52:57
- 退出码：**0**
- 汇总行：`汇总: 总计 95 条，通过 95，失败 0，预期红 0`
- 沙箱：`/tmp/xwpf-sbx.LAbXZK`
- `DONE` 原文：

```
exit=0
finished=2026-10-25 10:52:57
harness=v2.15.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t32-copy-form-2 + t32-anchor-guard + t32-clause-exempt + t53-helper-count + t53-neg-floor + history-preflight + preflight-empty-guard + preflight-exit-passthrough + t54-ui-eof-closure-invariants + t54-judge-selfcheck + t53-rel-threshold + only-unregistered-exit4 + registry-selfcheck + t40-case-count-contract + probe-budget-10s + install-list-from-product + t63-t67-quality-observation + t68-t76-switch-reliability + t77-t84-weight10-exclusive + t85-t88-n4-probe-regen + run-lock-done-marker + t114-readend-collapse + expect-fail-exit5)
base_sha=d0b2543575739bdce07d9400415954b944e6d5e5
```
- `.meta` 数：95；`.fails` 文件数：95；**非空 `.fails`：0** 
- 预期红标注文件（`*.expect_fail`）：无
- manifest：`C:\Users\liwend\AppData\Local\Temp\xwpf-sbx.LAbXZK\manifest.txt`
- manifest 归属行：`repo        : /c/Users/liwend/AppData/Local/Temp/xwpf-gate-clone-d0b`
- manifest SHA-256（跑批脚本记录）：`d7a702ba74e1e3dbd26bf2e0342c72149fef9281cc06053eb99a2d3031f75c99`
- manifest SHA-256（本地复算）：`d7a702ba74e1e3dbd26bf2e0342c72149fef9281cc06053eb99a2d3031f75c99`
- 沙箱（Windows 路径）：`C:\Users\liwend\AppData\Local\Temp\xwpf-sbx.LAbXZK`

### C.UTF-8

- 起止：10:52:57 LC_ALL=C.UTF-8 → 11:10:10
- 退出码：**0**
- 汇总行：`汇总: 总计 95 条，通过 95，失败 0，预期红 0`
- 沙箱：`/tmp/xwpf-sbx.K29LId`
- `DONE` 原文：

```
exit=0
finished=2026-10-25 11:10:10
harness=v2.15.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t32-copy-form-2 + t32-anchor-guard + t32-clause-exempt + t53-helper-count + t53-neg-floor + history-preflight + preflight-empty-guard + preflight-exit-passthrough + t54-ui-eof-closure-invariants + t54-judge-selfcheck + t53-rel-threshold + only-unregistered-exit4 + registry-selfcheck + t40-case-count-contract + probe-budget-10s + install-list-from-product + t63-t67-quality-observation + t68-t76-switch-reliability + t77-t84-weight10-exclusive + t85-t88-n4-probe-regen + run-lock-done-marker + t114-readend-collapse + expect-fail-exit5)
base_sha=d0b2543575739bdce07d9400415954b944e6d5e5
```
- `.meta` 数：95；`.fails` 文件数：95；**非空 `.fails`：0** 
- 预期红标注文件（`*.expect_fail`）：无
- manifest：`C:\Users\liwend\AppData\Local\Temp\xwpf-sbx.K29LId\manifest.txt`
- manifest 归属行：`repo        : /c/Users/liwend/AppData/Local/Temp/xwpf-gate-clone-d0b`
- manifest SHA-256（跑批脚本记录）：`c609b0918202386815d243641aa31dd19be5f3e06a07950e1e55ff45eefab898`
- manifest SHA-256（本地复算）：`c609b0918202386815d243641aa31dd19be5f3e06a07950e1e55ff45eefab898`
- 沙箱（Windows 路径）：`C:\Users\liwend\AppData\Local\Temp\xwpf-sbx.K29LId`

## 三、怎么引用这一批

- 唯一门禁入口：`tests/run_tests.sh`（`--base-sha d0b2543`）。
- 引用时**必须带**：冻结点 SHA + 汇总行 + 条数 + 退出码 + 台架指纹（`tests/` 指纹已列在上表）。
- 两口径若不一致，**不得**用「全过」表述；须写清哪一口径红、红的条号与判据。
- 沙箱路径与 manifest 指纹用于回查；沙箱被清理后只能作「据 … 群正文 DONE 转述」引用。

## 四、本批不覆盖的范围（不得据此宣称）

- 真机 103 复测（凭据在 Chief 侧）：未做。
- 展示端遗留二轮：未做。
- T40 判定器「多值 ⇒ 命中即绿」修复若在本批之后落地，属 `tests/**` 变更，按里程碑制只跑受影响子集验证，不重跑全量。
