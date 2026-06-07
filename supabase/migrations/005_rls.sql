-- ============================================================
-- 005_rls.sql
-- Row Level Security policies for all tables
-- ============================================================
-- Access model:
--   PUBLIC (anon / unauthenticated)
--     • restaurant_tables  → SELECT (active only)
--     • reservations       → INSERT only
--
--   AUTHENTICATED (logged-in staff whose email is in admins)
--     • restaurant_tables  → SELECT, INSERT, UPDATE, DELETE
--     • reservations       → SELECT, INSERT, UPDATE, DELETE
--     • admins             → SELECT (own row only)
--
--   SUPERADMIN (role = 'superadmin' in admins table)
--     • admins             → SELECT, INSERT, UPDATE, DELETE
--
--   SERVICE ROLE (backend server.js / Supabase Edge Functions)
--     • Bypasses all RLS automatically (Supabase built-in behaviour)
-- ============================================================


-- ── Enable RLS on all tables ─────────────────────────────────
ALTER TABLE restaurant_tables  ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservations        ENABLE ROW LEVEL SECURITY;
ALTER TABLE admins              ENABLE ROW LEVEL SECURITY;


-- ════════════════════════════════════════════════════════════
--  HELPER FUNCTION: is_admin
--  Returns TRUE if the current authenticated user's email
--  exists in the admins table.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION is_admin ()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM admins
     WHERE email = (SELECT email FROM auth.users WHERE id = auth.uid())
  );
$$;

COMMENT ON FUNCTION is_admin IS
  'Returns TRUE when the authenticated user has a row in the admins table.';


-- ════════════════════════════════════════════════════════════
--  HELPER FUNCTION: is_superadmin
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION is_superadmin ()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM admins
     WHERE email = (SELECT email FROM auth.users WHERE id = auth.uid())
       AND role  = 'superadmin'
  );
$$;

COMMENT ON FUNCTION is_superadmin IS
  'Returns TRUE when the authenticated user is a superadmin.';


-- ════════════════════════════════════════════════════════════
--  POLICIES: restaurant_tables
-- ════════════════════════════════════════════════════════════

-- Public: read active tables (for availability check on booking form)
DROP POLICY IF EXISTS "public_read_active_tables" ON restaurant_tables;
CREATE POLICY "public_read_active_tables"
  ON restaurant_tables
  FOR SELECT
  TO anon, authenticated
  USING (active = TRUE);

-- Admin: full read (including inactive tables)
DROP POLICY IF EXISTS "admin_read_all_tables" ON restaurant_tables;
CREATE POLICY "admin_read_all_tables"
  ON restaurant_tables
  FOR SELECT
  TO authenticated
  USING (is_admin());

-- Admin: insert new tables
DROP POLICY IF EXISTS "admin_insert_tables" ON restaurant_tables;
CREATE POLICY "admin_insert_tables"
  ON restaurant_tables
  FOR INSERT
  TO authenticated
  WITH CHECK (is_admin());

-- Admin: update tables (e.g., toggle active, change seats)
DROP POLICY IF EXISTS "admin_update_tables" ON restaurant_tables;
CREATE POLICY "admin_update_tables"
  ON restaurant_tables
  FOR UPDATE
  TO authenticated
  USING    (is_admin())
  WITH CHECK (is_admin());

-- Superadmin only: delete tables
DROP POLICY IF EXISTS "superadmin_delete_tables" ON restaurant_tables;
CREATE POLICY "superadmin_delete_tables"
  ON restaurant_tables
  FOR DELETE
  TO authenticated
  USING (is_superadmin());


-- ════════════════════════════════════════════════════════════
--  POLICIES: reservations
-- ════════════════════════════════════════════════════════════

-- Public: create a reservation (unauthenticated users / website visitors)
DROP POLICY IF EXISTS "public_insert_reservation" ON reservations;
CREATE POLICY "public_insert_reservation"
  ON reservations
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (
    -- Must select an active table
    EXISTS (
      SELECT 1 FROM restaurant_tables
       WHERE id = table_id AND active = TRUE
    )
    -- Date must not be in the past
    AND reservation_date >= CURRENT_DATE
  );

-- Public: read own reservation (by email match — for confirmation page)
-- Uses a session variable set by the app after successful insert.
-- Guests cannot browse other people's reservations.
DROP POLICY IF EXISTS "public_read_own_reservation" ON reservations;
CREATE POLICY "public_read_own_reservation"
  ON reservations
  FOR SELECT
  TO anon, authenticated
  USING (
    -- Allow if the request carries the reservation id via app logic
    -- In practice: the app reads the row immediately after INSERT
    -- and stores it in the session. Anon users can't list reservations.
    FALSE   -- intentionally restrictive; app uses service role for reads
  );

-- Admin: read all reservations
DROP POLICY IF EXISTS "admin_read_reservations" ON reservations;
CREATE POLICY "admin_read_reservations"
  ON reservations
  FOR SELECT
  TO authenticated
  USING (is_admin());

-- Admin: update reservation status
DROP POLICY IF EXISTS "admin_update_reservation" ON reservations;
CREATE POLICY "admin_update_reservation"
  ON reservations
  FOR UPDATE
  TO authenticated
  USING    (is_admin())
  WITH CHECK (is_admin());

-- Superadmin: delete reservations
DROP POLICY IF EXISTS "superadmin_delete_reservation" ON reservations;
CREATE POLICY "superadmin_delete_reservation"
  ON reservations
  FOR DELETE
  TO authenticated
  USING (is_superadmin());


-- ════════════════════════════════════════════════════════════
--  POLICIES: admins
-- ════════════════════════════════════════════════════════════

-- Admin: read own row (to confirm role etc.)
DROP POLICY IF EXISTS "admin_read_own_row" ON admins;
CREATE POLICY "admin_read_own_row"
  ON admins
  FOR SELECT
  TO authenticated
  USING (
    email = (SELECT email FROM auth.users WHERE id = auth.uid())
  );

-- Superadmin: read all admin rows
DROP POLICY IF EXISTS "superadmin_read_all_admins" ON admins;
CREATE POLICY "superadmin_read_all_admins"
  ON admins
  FOR SELECT
  TO authenticated
  USING (is_superadmin());

-- Superadmin: create new admin accounts
DROP POLICY IF EXISTS "superadmin_insert_admin" ON admins;
CREATE POLICY "superadmin_insert_admin"
  ON admins
  FOR INSERT
  TO authenticated
  WITH CHECK (is_superadmin());

-- Superadmin: update admin roles
DROP POLICY IF EXISTS "superadmin_update_admin" ON admins;
CREATE POLICY "superadmin_update_admin"
  ON admins
  FOR UPDATE
  TO authenticated
  USING    (is_superadmin())
  WITH CHECK (is_superadmin());

-- Superadmin: remove admins
DROP POLICY IF EXISTS "superadmin_delete_admin" ON admins;
CREATE POLICY "superadmin_delete_admin"
  ON admins
  FOR DELETE
  TO authenticated
  USING (is_superadmin());
