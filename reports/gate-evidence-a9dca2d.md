# 门禁留证：台架 v2.16.0（登记 97 条）树 `a9dca2d` 的全量双口径

> 本文件由「大厨」在跑批结束后自动抄写，字段全部取自跑批产物原文，**未手工编辑**。
> 抄写时间：2026-10-26 15:05:04

## 一、冻结点与被测树

| 项 | 值 |
|---|---|
| 冻结点（被测树） | `a9dca2d` |
| 被测树 checkout | 干净 clone + `git checkout --detach a9dca2d`（工作区 0 改动） |
| 台架版本 | `"v2.16.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + ` |
| 登记条数 | 97 |
| case 文件数 | 24 |
| 工作区改动行数 | 0 |
| 行尾检查 | `i/lf    w/lf    attr/text eol=lf      	tests/run_tests.sh` |
| 冻结点树对象 | `a8a74bd686102ad97ea724bc0f03b53c2375bee7` |
| `tests/` 内容指纹 | `2b7d82e7d31d6f3259e46ea7e5ab85d9ffd353af7e67789b2c6bf91747f071a0` |
| `lib/` 内容指纹 | `c0b712dd69c3e772d71884f4fc5347e4eb0a158ebca2e2f2081d31a8b81baa2b` |
| `cmd/` 内容指纹 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `docs/` 内容指纹 | `f2ec691d4b1b7deb5b5fae7091534c528343485c58b375c1951d0ca9f03f4cbd` |
| `xwFailover.sh` 指纹 | `ee662ea10b210e77fb5796cf325495fd7625134cf48efd879cccbe533d5c90d0` |

> 指纹算法：`git ls-tree -r <冻结点> -- <目录>` 的 `(mode, type, sha1, path)` 行集合取 SHA-256；
> **不随 rebase / 换基线而变** ⇒ 可跨分支平移。

## 二、与上一批（`d0b2543`）的差异面

- `tests/` 指纹：`139ae23740fe57e5576cfdedf8cd49eef44353fd531dd4eba97d9c901e7fd935` → `2b7d82e7d31d6f3259e46ea7e5ab85d9ffd353af7e67789b2c6bf91747f071a0`（**台架面已变** ⇒ 本批为重跑全量，不继承上一批结论）
- `lib/` 指纹：`c0b712dd69c3e772d71884f4fc5347e4eb0a158ebca2e2f2081d31a8b81baa2b` → `c0b712dd69c3e772d71884f4fc5347e4eb0a158ebca2e2f2081d31a8b81baa2b`
- `cmd/` 指纹：`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` → `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `docs/` 指纹：`c3c9a82c1e09bf7e10a29f7d03c1793bc7bc8534af93ddaec6fdca723b5d2558` → `f2ec691d4b1b7deb5b5fae7091534c528343485c58b375c1951d0ca9f03f4cbd`
- 产品面（`lib/` `cmd/` `xwFailover.sh`）指纹是否与上一批一致：**一致**
- 本批新增内容：T115/T116（认领候选门槛 + 身份优先）、T54 判定器 7b 降级（结构断言 → 语义断言 + 正反对照）。

## 三、两口径实况

| 口径 | 退出码 | 汇总行 | `.meta` | 非空 `.fails` | manifest SHA-256 | 沙箱 |
|---|---|---|---|---|---|---|
| ambient | **0** | `汇总: 总计 97 条，通过 97，失败 0，预期红 0` | 97 | **0** | `303a46d71444188d` | `/tmp/xwpf-sbx.Wt9X40` |
| C.UTF-8 | **0** | `汇总: 总计 97 条，通过 97，失败 0，预期红 0` | 97 | **0** | `29f2b16763df6440` | `/tmp/xwpf-sbx.JKULhT` |

### ambient

- 起止：14:45:25 LC_ALL=ambient → 14:55:06
- 退出码：**0**
- 汇总行：`汇总: 总计 97 条，通过 97，失败 0，预期红 0`
- 沙箱：`/tmp/xwpf-sbx.Wt9X40`
- `base_sha_in_output`：`a9dca2d6aed65351c5eca06962234f5ba62175ff`
- `DONE` 原文：

```
exit=0
finished=2026-10-26 14:55:06
harness=v2.16.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t32-copy-form-2 + t32-anchor-guard + t32-clause-exempt + t53-helper-count + t53-neg-floor + history-preflight + preflight-empty-guard + preflight-exit-passthrough + t54-ui-eof-closure-invariants + t54-judge-selfcheck + t53-rel-threshold + only-unregistered-exit4 + registry-selfcheck + t40-case-count-contract + probe-budget-10s + install-list-from-product + t63-t67-quality-observation + t68-t76-switch-reliability + t77-t84-weight10-exclusive + t85-t88-n4-probe-regen + run-lock-done-marker + t114-readend-collapse + expect-fail-exit5 + t54-affirm-default-7b + t115-t116-claim-gate-identity)
base_sha=a9dca2d6aed65351c5eca06962234f5ba62175ff
```
- `.meta` 数：97；`.fails` 文件数：97；**非空 `.fails`：0**
- 预期红标注文件（`*.expect_fail`）：无
- manifest：`C:\Users\liwend\AppData\Local\Temp\xwpf-sbx.Wt9X40\manifest.txt`
- manifest 归属行：`repo        : /c/Users/liwend/AppData/Local/Temp/xwpf-next-clone`
- manifest SHA-256（跑批脚本记录）：`303a46d71444188dd39e8454d286cd65a1b7a342f35b83dcba82398b22f31115`
- manifest SHA-256（本地复算）：`303a46d71444188dd39e8454d286cd65a1b7a342f35b83dcba82398b22f31115`
- 沙箱（Windows 路径）：`C:\Users\liwend\AppData\Local\Temp\xwpf-sbx.Wt9X40`
- harness 记录行：`harness     : v2.16.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t32-copy-form-2 + t32-anchor-guard + t32-clause-exempt + t53-helper-count + t53-neg-floor + history-preflight + preflight-empty-guard + preflight-exit-passthrough + t54-ui-eof-closure-invariants + t54-judge-selfcheck + t53-rel-threshold + only-unregistered-exit4 + registry-selfcheck + t40-case-count-contract + probe-budget-10s + install-list-from-product + t63-t67-quality-observation + t68-t76-switch-reliability + t77-t84-weight10-exclusive + t85-t88-n4-probe-regen + run-lock-done-marker + t114-readend-collapse + expect-fail-exit5 + t54-affirm-default-7b + t115-t116-claim-gate-identity)`

### C.UTF-8

- 起止：14:55:06 LC_ALL=C.UTF-8 → 15:04:45
- 退出码：**0**
- 汇总行：`汇总: 总计 97 条，通过 97，失败 0，预期红 0`
- 沙箱：`/tmp/xwpf-sbx.JKULhT`
- `base_sha_in_output`：`a9dca2d6aed65351c5eca06962234f5ba62175ff`
- `DONE` 原文：

```
exit=0
finished=2026-10-26 15:04:44
harness=v2.16.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t32-copy-form-2 + t32-anchor-guard + t32-clause-exempt + t53-helper-count + t53-neg-floor + history-preflight + preflight-empty-guard + preflight-exit-passthrough + t54-ui-eof-closure-invariants + t54-judge-selfcheck + t53-rel-threshold + only-unregistered-exit4 + registry-selfcheck + t40-case-count-contract + probe-budget-10s + install-list-from-product + t63-t67-quality-observation + t68-t76-switch-reliability + t77-t84-weight10-exclusive + t85-t88-n4-probe-regen + run-lock-done-marker + t114-readend-collapse + expect-fail-exit5 + t54-affirm-default-7b + t115-t116-claim-gate-identity)
base_sha=a9dca2d6aed65351c5eca06962234f5ba62175ff
```
- `.meta` 数：97；`.fails` 文件数：97；**非空 `.fails`：0**
- 预期红标注文件（`*.expect_fail`）：无
- manifest：`C:\Users\liwend\AppData\Local\Temp\xwpf-sbx.JKULhT\manifest.txt`
- manifest 归属行：`repo        : /c/Users/liwend/AppData/Local/Temp/xwpf-next-clone`
- manifest SHA-256（跑批脚本记录）：`29f2b16763df6440b549d91b742509a5ffda2d64ae3159c2e52db277b6b46f95`
- manifest SHA-256（本地复算）：`29f2b16763df6440b549d91b742509a5ffda2d64ae3159c2e52db277b6b46f95`
- 沙箱（Windows 路径）：`C:\Users\liwend\AppData\Local\Temp\xwpf-sbx.JKULhT`
- harness 记录行：`harness     : v2.16.0 (frozen-base + probe-unique + M1/M2/M5/M7/M8 + commit-msg-contract + T32-form-agnostic + T43-T52-coverage + health-target-hostport + n1r1-no-wide-key + t34-hard-lineref + t34-en-possessive + negctl-selfcheck + t45-portable-equiv + t45-win-mv-truth + t32-locale-pin + t53-menu-eof + t32-copy-form-2 + t32-anchor-guard + t32-clause-exempt + t53-helper-count + t53-neg-floor + history-preflight + preflight-empty-guard + preflight-exit-passthrough + t54-ui-eof-closure-invariants + t54-judge-selfcheck + t53-rel-threshold + only-unregistered-exit4 + registry-selfcheck + t40-case-count-contract + probe-budget-10s + install-list-from-product + t63-t67-quality-observation + t68-t76-switch-reliability + t77-t84-weight10-exclusive + t85-t88-n4-probe-regen + run-lock-done-marker + t114-readend-collapse + expect-fail-exit5 + t54-affirm-default-7b + t115-t116-claim-gate-identity)`

## 四、这批冻结点是怎么来的（含一次真实的门禁自伤）

1. 两笔台架提交先落在本地 `next-batch`：`ebfa0fa`（新增 T115/T116）+ `f170d00`（T54 判定器 7b 降级）。
2. 首跑全量时 **T40 判红**：「声称全过却没引用唯一入口实测口径的提交数 期望[0] 实际[1]」。
   原因：`ebfa0fa` 的**说明文字**里出现了词表词「全绿」（原句：*门槛失效时六场景照样全绿（测不出来）*）——
   T40 是**字面词表**判定，描述性提及与声明性陈述没有区别 ⇒ 自己的说明把自己判红。
3. 处理：**只改提交说明，不动树内容**。`全绿` → `会被判为通过`（避开词表），并保留原有含义。
   改写后新冻结点 `0f02b8c` / `a9dca2d`；**树对象与改写前逐字相同**（`git rev-parse <旧>^{tree}` == `git rev-parse <新>^{tree}` == `a8a74bd686102ad97ea724bc0f03b53c2375bee7`），`git diff --stat` 为空。
4. 定向复核：新冻结点 `--only T40` ⇒ 汇总「总计 1 条，通过 1，失败 0」、退出码 0。
5. 因冻结点 SHA 变了 ⇒ **重跑全量双口径**（不继承上一批），结果即本文件第三节。

> 留档价值：这次是**门禁自己有牙齿**的实证——它抓的是提交说明，不是产品。
> 同时也是「描述性提及 vs 声明」的现成样本，可用于后续收窄 T40 的 claim 词表。

## 五、怎么引用这一批

- 唯一门禁入口：`tests/run_tests.sh`（`--base-sha a9dca2d`）。
- 引用时**必须带**：冻结点 SHA + 汇总行 + 条数 + 退出码 + 台架指纹（`tests/` 指纹已列在上表）。
- 两口径若不一致，**不得**用「全过」表述；须写清哪一口径红、红的条号与判据。
- 沙箱路径与 manifest 指纹用于回查；沙箱被清理后只能作「据 … 群正文 DONE 转述」引用。

## 六、本批不覆盖的范围（不得据此宣称）

- 真机 103 复测（凭据在 Chief 侧）：未做 ⇒ 主备切换链、`10,0` 主备、时延显示的真机行为**未被本批覆盖**。
- 本批只证明**台架层面**的判定结果，不等于生产环境行为已验证。
- 台架自身不等于产品：新增/改写的判据仍需复核抽样制抽检。

## 七、落库后的链路说明（提交信息与本文件的对应关系）

- 本留证文件所在提交的父提交链：`134ed8a` → `0f02b8c`（新增 T115/T116）→ `a9dca2d`（T54 判定器 7b 降级）→ `8b64be0`（归档第 21 轮交接单，`reports/` 一个新增文件）→ 本留证提交。
- `8b64be0` 是审稿那笔「归档第 21 轮交接单」在 rebase 后的 SHA（内容、作者、说明逐字不变；它当时只在本地未推送，故 rebase 使 SHA 变更）。
- 冻结点 `a9dca2d` 仍是本链的祖先 ⇒ **可引用、锚点可达**。
- `a9dca2d` 之后只多了两份 `reports/` 文档（`reports/r21-handoff-T115T116.md`、`reports/gate-evidence-a9dca2d.md`）⇒
  `tests/` 与产品面（`lib/` `cmd/` `xwFailover.sh`）**逐字未变** ⇒ 第三节的门禁结论对本链末端继续成立。
