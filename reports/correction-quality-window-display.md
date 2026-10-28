# 更正：103 收尾执行单里「展示端符号产品里也不存在」这一条不成立

**更正人**：大厨（主 Bot）　**时间**：2026-10-25 11:47
**被更正对象**：`reports/real-machine-acceptance-103-rundown.md`（审稿落库，提交 `9e2c437`）
中「实打实的抽错」一节里关于展示端的那一条表述。

## 结论

该节称：`quality_window_display` 与窗口列 `TARGET|RULE_ID|SAMPLE_SEQ|LAT_SEQ|WINDOW|FAIL_LAT_SEQ`
「**清单里 0 命中、产品里也不存在**」⇒ 并据此把执行单第 10 步「展示端遗留」的标的物
改成了 `get_health_status_record`。

**实测：后半句不成立。** 在合并树 `d0b2543` 上按符号名实测
（`git show d0b2543:<file> | grep -c <符号>`）：

| 符号 | `lib/health.sh` | `lib/rules.sh` |
|---|---|---|
| `quality_window_display` | 3 | 3 |
| `read_quality_window` | 5 | 0 |
| `quality_window_size` | 6 | 0 |
| `get_health_status_record` | 2 | 1 |

⇒ `quality_window_display` **在产品里存在**：`lib/health.sh` 里有定义，`lib/rules.sh` 里有调用点。
执行单原稿写的「展示串单点在 `lib/rules.sh` 调 `quality_window_display`」与产品事实一致。

**误判的成因**：核「产品里有没有这个符号」时只搜了 `reports/` 里的验收清单，没有搜 `lib/`。
「清单里 0 命中」这一半是真的（清单确实没写这个符号），
但「产品里也不存在」是把「**文档没写**」当成了「**代码没有**」。

## 处置

1. 执行单第 10 步「展示端遗留」的标的物应回到 `quality_window_display`（窗口展示串的单点）；
   `get_health_status_record` 是读端取状态那件事，**与展示串不是同一处**，两者不要混。
2. 「清单里 0 命中」仍然成立 ⇒ **验收清单该补一节**（归审稿的活）。
3. 本条是**更正**，不是推翻执行单：执行单其余部分（取证 → 迁端口 → 卸守护 → 改名留档 →
   三条验收 → A-13 五步 → 重测两个时间特性）经审稿对账后成立的部分继续有效。

## 证据可复现

```bash
git show d0b2543:lib/health.sh | grep -c quality_window_display   # => 3
git show d0b2543:lib/rules.sh  | grep -c quality_window_display   # => 3
```
