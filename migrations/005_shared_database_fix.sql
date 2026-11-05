-- VibeMail — Memory layer and attachments for an existing vibemail-backend database
-- Idempotent: safe to run multiple times on the same database (AC-9).
-- DO NOT apply until the checks agreed for this database have passed (CONTRACT.md §2).
--
-- Written for a database that already has the vibemail-backend schema, where
-- messages.id is TEXT and the users token columns are already renamed.
-- Run this file INSTEAD of 003_message_chunks.sql and 004_match_messages.sql:
-- 003 declares message_chunks.message_id as UUID, which cannot reference a TEXT
-- primary key. Do not use `supabase db push` here; it would run 003.
--
-- Additive only: no existing column or row changes, so vibemail-backend keeps
-- working against the same database. Runs as one transaction: all or nothing.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. messages.attachments
-- ─────────────────────────────────────────────────────────────────────────────
-- src/sync/normalize.ts writes this on every upsert, but no earlier migration
-- creates it. Existing rows stay NULL; rowToMessage reads NULL as an empty list.

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS attachments JSONB;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. pgvector
-- ─────────────────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS vector;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. message_chunks
-- ─────────────────────────────────────────────────────────────────────────────
-- Same as 003_message_chunks.sql except message_id is TEXT, to match messages.id.
-- Deleting a message cascades to its chunks in the same transaction.

CREATE TABLE IF NOT EXISTS public.message_chunks (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id   TEXT        NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  chunk_index  INTEGER     NOT NULL,
  chunk_text   TEXT        NOT NULL,               -- sender + subject + body slice that was embedded
  embedding    vector(384) NOT NULL,               -- GTE-small; unit-normalized at write time
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (message_id, chunk_index)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. HNSW index (inner product, not cosine)
-- ─────────────────────────────────────────────────────────────────────────────
-- Unit-normalized vectors: inner product ranks identically to cosine distance.

CREATE INDEX IF NOT EXISTS idx_message_chunks_embedding
  ON public.message_chunks
  USING hnsw (embedding vector_ip_ops);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Row-Level Security
-- ─────────────────────────────────────────────────────────────────────────────
-- Defence-in-depth only, same as messages (memory_contract.md §3). The server
-- uses SUPABASE_SERVICE_ROLE_KEY (bypasses RLS). Do not FORCE.

ALTER TABLE public.message_chunks ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'message_chunks' AND policyname = 'message_chunks_own'
  ) THEN
    CREATE POLICY message_chunks_own ON public.message_chunks
      USING     (user_id = auth.uid())
      WITH CHECK (user_id = auth.uid());
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. match_messages
-- ─────────────────────────────────────────────────────────────────────────────
-- Unchanged from 004_match_messages.sql; see that file for the retrieval notes.

CREATE OR REPLACE FUNCTION public.match_messages(
  p_user_id         uuid,
  p_query_embedding vector(384),
  p_match_threshold double precision,
  p_match_count     integer DEFAULT 8
)
RETURNS TABLE (
  id           public.messages.id%TYPE,
  user_id      public.messages.user_id%TYPE,
  created_at   public.messages.created_at%TYPE,
  updated_at   public.messages.updated_at%TYPE,
  gmail_id     public.messages.gmail_id%TYPE,
  thread_id    public.messages.thread_id%TYPE,
  label_ids    public.messages.label_ids%TYPE,
  from_address public.messages.from_address%TYPE,
  to_address   public.messages.to_address%TYPE,
  subject      public.messages.subject%TYPE,
  date         public.messages.date%TYPE,
  snippet      public.messages.snippet%TYPE,
  body_plain   public.messages.body_plain%TYPE,
  body_html    public.messages.body_html%TYPE,
  is_read      public.messages.is_read%TYPE,
  is_starred   public.messages.is_starred%TYPE,
  status       public.messages.status%TYPE,
  draft_id     public.messages.draft_id%TYPE,
  score        double precision
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH scored AS (
    SELECT
      mc.message_id,
      MIN(mc.embedding <#> p_query_embedding) AS score
    FROM public.message_chunks AS mc
    WHERE mc.user_id = p_user_id
    GROUP BY mc.message_id
    -- <#> is a distance: worse means larger. Keep scores at or below threshold.
    HAVING MIN(mc.embedding <#> p_query_embedding) <= p_match_threshold
  )
  SELECT
    m.id,
    m.user_id,
    m.created_at,
    m.updated_at,
    m.gmail_id,
    m.thread_id,
    m.label_ids,
    m.from_address,
    m.to_address,
    m.subject,
    m.date,
    m.snippet,
    m.body_plain,
    m.body_html,
    m.is_read,
    m.is_starred,
    m.status,
    m.draft_id,
    scored.score
  FROM scored
  INNER JOIN public.messages AS m
    ON m.id::text = scored.message_id::text
   AND m.user_id = p_user_id
  -- Recency nudge: ~0.01 of score per year of age. Relevance still leads;
  -- near-ties prefer the newer message. created_at is Gmail internalDate.
  -- Returned `score` is the raw <#> (not recency-adjusted).
  ORDER BY
    scored.score
      + EXTRACT(EPOCH FROM (now() - m.created_at)) / 31556952.0 * 0.01
    ASC
  LIMIT p_match_count
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Refresh the PostgREST schema cache so the API sees the new objects
-- ─────────────────────────────────────────────────────────────────────────────

NOTIFY pgrst, 'reload schema';

COMMIT;
