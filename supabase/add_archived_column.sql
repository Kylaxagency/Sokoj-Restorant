-- ============================================================
-- add_archived_column.sql
-- Run in Supabase SQL Editor.
--
-- Adds soft-delete (archive) support to completed_reservations.
-- Also fixes the reservation_id constraint to allow SET NULL.
-- ============================================================

-- 1. Fix reservation_id to allow NULL (needed for ON DELETE SET NULL to work)
ALTER TABLE completed_reservations
  ALTER COLUMN reservation_id DROP NOT NULL;

-- 2. Add archived column
ALTER TABLE completed_reservations
  ADD COLUMN IF NOT EXISTS archived BOOLEAN NOT NULL DEFAULT false;

-- 3. Add archived_at timestamp
ALTER TABLE completed_reservations
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

-- 4. Add archived_by admin email
ALTER TABLE completed_reservations
  ADD COLUMN IF NOT EXISTS archived_by TEXT;

-- 5. Allow admins to update completed_reservations (for archiving)
DROP POLICY IF EXISTS "admin_update_completed" ON completed_reservations;
CREATE POLICY "admin_update_completed"
  ON completed_reservations FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- 6. Allow admins to delete from reservations (for cleaning up after archive)
DROP POLICY IF EXISTS "admin_delete_reservations" ON reservations;
CREATE POLICY "admin_delete_reservations"
  ON reservations FOR DELETE
  TO authenticated
  USING (true);
