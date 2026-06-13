-- =============================================================
-- SENTRA — Schema migration
-- Run once in Supabase SQL Editor.
-- =============================================================

-- 1. Extend profiles with onboarding fields
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS age          integer,
  ADD COLUMN IF NOT EXISTS blood_group  text,
  ADD COLUMN IF NOT EXISTS home_address text;

-- 2. Emergency contacts table
CREATE TABLE IF NOT EXISTS public.emergency_contacts (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  contact_name     text        NOT NULL,
  contact_number   text        NOT NULL,
  relationship     text        NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- 3. RLS — users can only see and write their own contacts
ALTER TABLE public.emergency_contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own emergency contacts" ON public.emergency_contacts;
CREATE POLICY "Users manage own emergency contacts"
  ON public.emergency_contacts
  FOR ALL
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- 4. Index for fast user-scoped queries
CREATE INDEX IF NOT EXISTS emergency_contacts_user_id_idx
  ON public.emergency_contacts (user_id);
