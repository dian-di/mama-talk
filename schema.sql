-- ============================================================================
-- 英语学习 App · 内容库 DDL
-- 目标库：PostgreSQL 15+
--
-- 三条设计主线：
--   A. 标签走「受控词表 + 关联表」，不用 enum 也不裸 text[]（见 §1 / §5 注释）
--   B. 媒体（音频/图片）统一入 media_asset，业务表只存引用 + 语义参数
--   C. 内容与用户进度彻底分表；进度表不出现任何内容字段
-- ============================================================================


-- 扩展：模糊检索。托管 PG（腾讯云 / RDS）需在控制台确认该扩展已放行
CREATE EXTENSION IF NOT EXISTS pg_trgm;


-- ============================ 枚举类型 ======================================
-- 只放「结构稳定、几乎不会新增」的维度。会持续扩张的（场景/语用/语法）走词表表。

CREATE TYPE content_status  AS ENUM ('draft', 'in_review', 'published', 'archived');
CREATE TYPE cefr_level      AS ENUM ('A1', 'A2', 'B1', 'B2', 'C1', 'C2');
CREATE TYPE register_type   AS ENUM ('formal', 'neutral', 'casual', 'slang');
CREATE TYPE accent_type     AS ENUM ('us', 'uk', 'au');
CREATE TYPE media_kind      AS ENUM ('audio', 'image', 'video');
CREATE TYPE relation_type   AS ENUM ('variant', 'confusable', 'see_also', 'antonym');


-- ============================ §1 标签词表 ===================================

CREATE TABLE tag_dimension (
  code          text     PRIMARY KEY,        -- scene / function / tone / grammar / topic
  name_zh       text     NOT NULL,
  multi_select  boolean  NOT NULL DEFAULT true,
  sort_order    smallint NOT NULL DEFAULT 0
);

-- 受控词表。运营加标签是 INSERT，不是 DDL 迁移，也不需要发版。
CREATE TABLE tag (
  id          bigint   GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dimension   text     NOT NULL REFERENCES tag_dimension(code) ON UPDATE CASCADE,
  code        text     NOT NULL,             -- dining / work / confirmation
  name_zh     text     NOT NULL,
  name_en     text     NOT NULL,
  sort_order  smallint NOT NULL DEFAULT 0,
  is_active   boolean  NOT NULL DEFAULT true,
  UNIQUE (dimension, code)
);

INSERT INTO tag_dimension (code, name_zh, multi_select, sort_order) VALUES
  ('scene',    '场景',   true,  1),
  ('function', '语用功能', true,  2),
  ('tone',     '语气',   true,  3),
  ('grammar',  '语法点', true,  4),
  ('topic',    '主题',   true,  5);


-- ============================ §2 句子主表 ===================================

CREATE TABLE sentence (
  id                bigint          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  slug              text            NOT NULL UNIQUE,
  en_text           text            NOT NULL,
  -- 去标点、折叠空白、小写。用途：去重、跟读比对、模糊检索归一化
  en_normalized     text            NOT NULL,
  cefr              cefr_level      NOT NULL DEFAULT 'A2',
  register          register_type   NOT NULL DEFAULT 'neutral',
  word_count        smallint        NOT NULL DEFAULT 0,
  -- 单一数据源：字符数由文本推导，避免应用层写入不一致
  char_count        smallint        GENERATED ALWAYS AS (char_length(en_text)) STORED,
  usage_note        text,                       -- 语用提示：什么时候不能说 / 易误解点
  status            content_status  NOT NULL DEFAULT 'draft',
  is_human_reviewed boolean         NOT NULL DEFAULT false,
  created_at        timestamptz     NOT NULL DEFAULT now(),
  updated_at        timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX sentence_normalized_uniq ON sentence (en_normalized);
CREATE INDEX sentence_status_cefr_idx ON sentence (status, cefr);
-- 模糊搜索（"Let go" / "Let's go" 这类近似句必须能搜到彼此）
CREATE INDEX sentence_en_text_trgm_idx ON sentence USING gin (en_text gin_trgm_ops);


-- ---- 译文（一句多译是资产，不是冗余）---------------------------------------
CREATE TABLE sentence_translation (
  id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sentence_id bigint      NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  lang        text        NOT NULL DEFAULT 'zh-Hans',
  text        text        NOT NULL,
  is_primary  boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sentence_id, lang, text)
);

-- 同语言只允许一条主译，其余作为多译法 / 选择题干扰项来源
CREATE UNIQUE INDEX sentence_translation_primary_uniq
  ON sentence_translation (sentence_id, lang) WHERE is_primary;


-- ---- 音标：与音频解耦（可以只有音标没有音频）-------------------------------
CREATE TABLE sentence_phonetic (
  sentence_id bigint      NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  accent      accent_type NOT NULL,
  ipa         text        NOT NULL,
  PRIMARY KEY (sentence_id, accent)
);


-- ============================ §3 媒体资产 ===================================
-- 关键决策：不存第三方 TTS 外链。理由见交付说明中的实测数据。
-- 表里存自有对象存储的相对 key，换 CDN 域名只改配置不改数据。

CREATE TABLE media_asset (
  id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind        media_kind  NOT NULL,
  storage_key text        NOT NULL UNIQUE,   -- audio/us/a1/i-see-001.mp3
  public_url  text        NOT NULL,
  mime_type   text        NOT NULL,
  bytes       integer     NOT NULL,
  checksum    text,                          -- 内容校验，重复生成时比对
  -- audio 专用
  duration_ms integer,
  engine      text,                          -- azure / openai / youdao / volc
  voice       text,                          -- en-US-JennyNeural
  -- image 专用
  width       integer,
  height      integer,
  alt_text    text,
  prompt      text,                          -- 生图 prompt，换风格时可批量重刷
  license     text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (kind <> 'audio' OR duration_ms IS NOT NULL)
);

CREATE INDEX media_asset_kind_idx ON media_asset (kind, created_at DESC);


-- ---- 句子 ↔ 音频 -----------------------------------------------------------
CREATE TABLE sentence_audio (
  id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sentence_id    bigint      NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  media_asset_id bigint      NOT NULL REFERENCES media_asset(id),
  accent         accent_type NOT NULL,
  speed          numeric(3,2) NOT NULL DEFAULT 1.00,   -- 1.00 常速 / 0.75 慢速
  is_primary     boolean     NOT NULL DEFAULT false,
  -- 词级时间戳：[{"t":"I","s":0,"e":180},{"t":"quit","s":200,"e":560}]
  -- 只读整块、不参与过滤 => 用 jsonb；拆成行会让一次朗读查几十条记录
  word_timings   jsonb,
  -- 生成音频时的文本指纹；文本改了但哈希没变即视为音频过期
  text_hash      text        NOT NULL,
  UNIQUE (sentence_id, accent, speed, media_asset_id)
);

-- 每个 (sentence, speed) 只许一条主音频，避免播放时选错
CREATE UNIQUE INDEX sentence_audio_primary_uniq
  ON sentence_audio (sentence_id, speed) WHERE is_primary;


-- ---- 句子 ↔ 图片 -----------------------------------------------------------
CREATE TABLE sentence_image (
  id             bigint   GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sentence_id    bigint   NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  media_asset_id bigint   REFERENCES media_asset(id),
  role           text     NOT NULL DEFAULT 'hero',    -- hero / scene / thumbnail
  emoji          text,                                -- 零成本兜底，图挂了也不会空窗
  sort_order     smallint NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX sentence_image_hero_uniq
  ON sentence_image (sentence_id) WHERE role = 'hero';


-- ============================ §4 分词 =======================================
-- 前端要能长按取词、逐词高亮。char_start/char_end 比 split(' ') 可靠：
-- "p.m." / "don't" 这类按空格切会碎。

CREATE TABLE word (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  lemma   text   NOT NULL,
  pos     text   NOT NULL,
  ipa_us  text,
  ipa_uk  text,
  UNIQUE (lemma, pos)
);

CREATE TABLE sentence_token (
  sentence_id bigint   NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  idx         smallint NOT NULL,
  surface     text     NOT NULL,          -- 原样文本，保留大小写与标点
  word_id     bigint   REFERENCES word(id),
  ipa         text,
  pos         text,
  char_start  smallint NOT NULL,
  char_end    smallint NOT NULL,
  start_ms    integer,                    -- 与 sentence_audio.word_timings 对齐
  end_ms      integer,
  PRIMARY KEY (sentence_id, idx)
);


-- ============================ §5 句子 ↔ 标签 ================================

CREATE TABLE sentence_tag (
  sentence_id bigint   NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  tag_id      bigint   NOT NULL REFERENCES tag(id)      ON DELETE CASCADE,
  weight      smallint NOT NULL DEFAULT 100 CHECK (weight BETWEEN 0 AND 100),
  is_primary  boolean  NOT NULL DEFAULT false,   -- 主场景，用于卡片配色与归类
  PRIMARY KEY (sentence_id, tag_id)
);

CREATE INDEX sentence_tag_tag_idx ON sentence_tag (tag_id, weight DESC);


-- ============================ §6 上下文对话 =================================

CREATE TABLE sentence_dialogue (
  id          bigint   GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sentence_id bigint   NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  title       text,
  sort_order  smallint NOT NULL DEFAULT 0
);

CREATE TABLE dialogue_line (
  dialogue_id    bigint   NOT NULL REFERENCES sentence_dialogue(id) ON DELETE CASCADE,
  idx            smallint NOT NULL,
  speaker        char(1)  NOT NULL CHECK (speaker IN ('A', 'B')),
  en_text        text     NOT NULL,
  translation    text     NOT NULL,
  media_asset_id bigint   REFERENCES media_asset(id),
  PRIMARY KEY (dialogue_id, idx)
);


-- ============================ §7 句子关系 ===================================
-- Let go! / Let's go! 属 confusable；Me too. / Same here. 属 variant

CREATE TABLE sentence_relation (
  from_id  bigint        NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  to_id    bigint        NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  relation relation_type NOT NULL,
  note     text,
  PRIMARY KEY (from_id, to_id, relation),
  CHECK (from_id <> to_id)
);


-- ============================ §8 课程 / 句单 ================================

CREATE TABLE lesson (
  id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code           text        NOT NULL UNIQUE,
  title          text        NOT NULL,
  cefr           cefr_level,
  cover_media_id bigint      REFERENCES media_asset(id),
  sort_order     smallint    NOT NULL DEFAULT 0,
  is_published   boolean     NOT NULL DEFAULT false
);

CREATE TABLE lesson_sentence (
  lesson_id   bigint   NOT NULL REFERENCES lesson(id)   ON DELETE CASCADE,
  sentence_id bigint   NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  sort_order  smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (lesson_id, sentence_id)
);


-- ============================ §9 用户维度 ===================================
-- 与内容库物理隔离：不同生命周期、不同写频率、不同分库策略。

CREATE TABLE app_user (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_sentence_progress (
  user_id           uuid     NOT NULL REFERENCES app_user(id)   ON DELETE CASCADE,
  sentence_id       bigint   NOT NULL REFERENCES sentence(id)   ON DELETE CASCADE,
  ease              numeric(4,2) NOT NULL DEFAULT 2.50,   -- SM-2
  interval_days     smallint NOT NULL DEFAULT 0,
  reps              smallint NOT NULL DEFAULT 0,
  lapses            smallint NOT NULL DEFAULT 0,
  due_at            timestamptz  NOT NULL DEFAULT now(),
  last_reviewed_at  timestamptz,
  last_shadow_score smallint   CHECK (last_shadow_score BETWEEN 0 AND 100),
  PRIMARY KEY (user_id, sentence_id)
);

-- 「今天该复习哪些」是最高频查询，必须有这个复合索引
CREATE INDEX user_progress_due_idx ON user_sentence_progress (user_id, due_at);

CREATE TABLE user_review_log (
  id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid        NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  sentence_id bigint      NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  reviewed_at timestamptz NOT NULL DEFAULT now(),
  grade       smallint    NOT NULL CHECK (grade BETWEEN 0 AND 5),
  response_ms integer
);

CREATE INDEX user_review_log_idx ON user_review_log (user_id, reviewed_at DESC);
