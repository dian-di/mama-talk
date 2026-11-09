# 03 数据模型

以下为字段定义与约束，**不含可执行 DDL**。实现时据此落库表与索引。所有表同处一个 PostgreSQL 库，保证中文翻译、别名、embedding、日志、打标在同一事务内可更新。

## 1. `entry` — 学习条目

一条记录 = 一个可返回给用户的英文表达。

| 字段 | 类型（概念） | 说明 |
|---|---|---|
| `id` | 主键 | |
| `english_text` | 文本 | 英文原文，唯一性按 `(english_text, corpus_type)` 约束 |
| `canonical_zh` | 文本 | 主中文翻译；人工核验后可修改 |
| `corpus_type` | 枚举 | `word` / `phrase` / `sentence`；仅用于离线与评测，**不用于在线路由** |
| `embedding` | `vector(1024)` | BGE-M3 dense；中文译义编码 |
| `source` | 枚举 | `dictionary` / `textbook` / `manual` |
| `updated_at` | 时间戳 | 人工修正 `canonical_zh` 时同事务刷新 embedding |

索引：B-tree（`canonical_zh`）、GIN pg_trgm（`canonical_zh`）、pgvector（`embedding`，**精确暴力扫描，不建 HNSW**）。

## 2. `sense` — 词典义项

主要服务于 10,000 个单词。权威词典的义项结构必须保留，不得压平成单个中文串。

| 字段 | 类型（概念） | 说明 |
|---|---|---|
| `id` | 主键 | |
| `entry_id` | 外键 → `entry` | |
| `sense_no` | 整数 | 词典义项序号 |
| `pos` | 文本 | 词性 |
| `zh_gloss` | 文本 | 该义项的中文译义 |
| `example` | 文本，可空 | 词典例句 |

示例：`run` 的义项包含「跑 / 经营 / 运转 / 流淌」。多个义项共同支撑「并列精确对应」。

## 3. `alias` — 中文别名与译法

全库检索的核心表，约 6–9 万行。`zh_text` 与 `entry_id` 是**多对多**，同一中文串允许指向多条英文。

| 字段 | 类型（概念） | 说明 |
|---|---|---|
| `id` | 主键 | |
| `entry_id` | 外键 → `entry` | |
| `zh_text` | 文本 | 中文说法 |
| `alias_type` | 枚举 | `dict_gloss` / `canonical` / `consensus_translation` / `colloquial` / `literal_variant` |
| `relation_type` | 枚举 | `parallel_exact`（并列精确对应）/ `variant`（表达变体）/ `unresolved` |
| `source` | 枚举 | `dictionary` / `llm_batch` / `human` |
| `verified` | 布尔 | 人工核验通过；LLM 回填默认 false |
| `is_ambiguous` | 布尔 | 由歧义检测计算得出，见第 4 节 |

索引：B-tree（`zh_text`，支撑 S0/S2 精确命中）、GIN pg_trgm（`zh_text`，支撑 S3 宽召回）、复合索引（`zh_text`, `entry_id`）。

## 4. 歧义检测与并列精确对应

这是全模型最容易实现错的一处。同一 `zh_text` 指向多个 `entry_id` 时，**不能直接判定为歧义**，也不能直接短路：

| 数据状态 | 归类 | S0 行为 | 打标 |
|---|---|---|---|
| 全部关联行 `verified = true` 且 `relation_type = parallel_exact` | 并列精确对应 | 允许短路，**全部返回** | 否 |
| 全部关联行 `verified = true` 且均为 `variant` | 表达变体 | 允许短路，返回对应条目 | 否 |
| 存在 `verified = false`、`relation_type = unresolved` 或来源冲突 | 译法歧义 | **禁止短路，强制走 L2** | 是，`translation_ambiguity` |

`is_ambiguous` 由离线 pipeline 依据上表计算并落库，在线只读该标志。区分依据是数据状态，不依赖模型置信度，因此可复现、可人工修正。

**为何必须这样切分**：权威词典天然存在「明白 → see / understand / realize」这类一对多，若一律判为歧义，打标队列会被正常的多对多关系淹没；若一律允许短路，未经核验的 LLM 回填又会直接返回错误答案。

## 5. `query_log` — 查询日志

| 字段 | 类型（概念） | 说明 |
|---|---|---|
| `id` | 主键 | |
| `query_text` | 文本 | 原始中文 query |
| `normalized_text` | 文本，可空 | S1/S3 归一化结果 |
| `query_type` | 枚举 | `word_query` / `phrase_sentence_query` / `variant_query`，见 `05-evaluation.md` |
| `s_level_hit` | 枚举 | `S0` / `S1` / `S2` / `S3`；用于统计 `r` |
| `verdict` | 枚举 | `exact` / `parallel_exact` / `related` / `irrelevant` |
| `top_candidates` | JSON | 候选条目 ID、各路分数、reranker 判定与置信度 |
| `latency_ms` | 整数 | |
| `created_at` | 时间戳 | |

`top_candidates` 保留完整判定依据，供人工核验与回归分析消费。`r`（落到 S3 的占比）**只能由此表统计**。

## 6. `tag_queue` — 打标队列

| 字段 | 类型（概念） | 说明 |
|---|---|---|
| `id` | 主键 | |
| `tag_type` | 枚举 | `missing_corpus` / `translation_fix` / `missing_alias` / `translation_ambiguity` |
| `low_confidence` | 布尔 | 附加标志，优先级最高 |
| `query_text` | 文本 | |
| `entry_id_ref` | 外键，可空 | 疑似相关条目 |
| `hit_count` | 整数 | 同一 query 累计次数，人工排序依据 |
| `status` | 枚举 | `pending` / `reviewing` / `resolved` |
| `reviewer_note` | 文本，可空 | 人工核验结论 |
| `created_at` / `updated_at` | 时间戳 | |

## 7. `golden_case` — 评测用例

| 字段 | 类型（概念） | 说明 |
|---|---|---|
| `id` | 主键 | |
| `query_text` | 文本 | |
| `query_type` | 枚举 | 同 `query_log` |
| `expected_entry_ids` | 数组 | 期望命中的条目 |
| `expected_verdict` | 枚举 | 期望三分类结果 |
| `group_tag` | 文本 | 所属专项组，见 `05-evaluation.md` |
| `notes` | 文本，可空 | 如「最小对立对，count me out 必须判不相关」 |

## 8. 一致性约束

- 人工修改 `entry.canonical_zh` → 同事务内重算该条 embedding、刷新相关 `alias` 的 trigram 索引、写 `query_log` 审计记录。
- S3 回填 `alias` 时，若目标 `zh_text` 已存在 `verified = true` 的行，只新增 `verified = false` 的关联，不修改既有行。
- 离线批量生成变体失败不得留下半批数据：以批次为事务边界。
