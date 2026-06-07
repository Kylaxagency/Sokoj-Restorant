-- ============================================================
-- fix_admins_rls.sql
-- Run this in Supabase SQL Editor to fix the admins table
-- RLS policies. The original policy used a subquery against
-- auth.users which can be blocked in the RLS evaluation
-- context. Replaced with auth.email() built-in.
-- ============================================================

-- Fix: read own admin row
DROP POLICY IF EXISTS "admin_read_own_row" ON admins;
CREATE POLICY "admin_read_own_row"
  ON admins
  FOR SELECT
  TO authenticated
  USING (email = auth.email());

-- Fix: superadmin reads all admin rows
DROP POLICY IF EXISTS "superadmin_read_all_admins" ON admins;
CREATE POLICY "superadmin_read_all_admins"
  ON admins
  FOR SELECT
  TO authenticated
  USING (
    auth.email() IN (
      SELECT email FROM admins WHERE role = 'superadmin'
    )
  );

-- Fix: is_admin() helper — use auth.email() instead of subquery
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM admins WHERE email = auth.email()
  );
$$;

-- Fix: is_superadmin() helper
CREATE OR REPLACE FUNCTION is_superadmin()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM admins WHERE email = auth.email() AND role = 'superadmin'
  );
$$;

-- Verify: this should return your admin row if everything is correct
-- SELECT * FROM admins WHERE email = auth.email();
