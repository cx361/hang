-- ─────────────────────────────────────────────────────────────────────────────
-- Silent Zones
-- Run this once in Supabase → SQL editor.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Table (mirrors safe_zones exactly)
CREATE TABLE IF NOT EXISTS public.silent_zones (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID         NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name            VARCHAR      NOT NULL,
  h3_index_res9   VARCHAR      NOT NULL,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- 2. RLS — users can only read/write their own rows
ALTER TABLE public.silent_zones ENABLE ROW LEVEL SECURITY;

CREATE POLICY "silent_zones_select_own"
  ON public.silent_zones FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "silent_zones_insert_own"
  ON public.silent_zones FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "silent_zones_delete_own"
  ON public.silent_zones FOR DELETE
  USING (user_id = auth.uid());

-- 3. Cached flag on profiles (updated on every GPS tick, just like is_in_safe_zone)
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_in_silent_zone BOOLEAN NOT NULL DEFAULT false;
