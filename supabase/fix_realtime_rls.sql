-- ============================================================
-- fix_realtime_rls.sql
-- Run in Supabase SQL Editor.
--
-- Problem: Supabase Realtime postgres_changes requires the
-- subscribing user to pass RLS for SELECT on the table.
-- Anon users currently have USING (FALSE) on reservations,
-- so they never receive events.
--
-- Fix: create a security-definer view that exposes only the
-- non-sensitive columns needed to determine table availability
-- (no customer PII), grant anon SELECT on it, and subscribe
-- to realtime on the view instead of the raw table.
-- ============================================================

-- ── 1. View: reservation_slots (no PII) ─────────────────────
CREATE OR REPLACE VIEW reservation_slots AS
  SELECT
    table_id,
    reservation_date,
    reservation_time,
    status
  FROM reservations;

-- Grant anon SELECT (no PII exposed — just slot data)
GRANT SELECT ON reservation_slots TO anon, authenticated;

-- ── 2. Add view to realtime publication ─────────────────────
-- (Run each statement separately if either fails)
ALTER PUBLICATION supabase_realtime ADD TABLE reservation_slots;

-- Also ensure the reservations base table is published
-- (needed for admin authenticated users)
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE reservations;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
