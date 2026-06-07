-- ============================================================
-- 001_schema.sql
-- Core tables: restaurant_tables, reservations, admins
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── ENUM: reservation status ────────────────────────────────
DO $$ BEGIN
  CREATE TYPE reservation_status AS ENUM (
    'pending',
    'confirmed',
    'cancelled',
    'completed'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- ── ENUM: table area ────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE table_area AS ENUM (
    'Indoor',
    'Garden Terrace',
    'VIP'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ════════════════════════════════════════════════════════════
--  TABLE: restaurant_tables
-- ════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS restaurant_tables (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  table_number  TEXT          NOT NULL UNIQUE,   -- e.g. T1, G3, VIP1
  area          table_area    NOT NULL,
  seats         INTEGER       NOT NULL CHECK (seats > 0),
  active        BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  restaurant_tables               IS 'Physical tables in the restaurant.';
COMMENT ON COLUMN restaurant_tables.table_number  IS 'Human-readable table ID shown on floor plan (T1, G1, VIP1…).';
COMMENT ON COLUMN restaurant_tables.area          IS 'Section of the restaurant.';
COMMENT ON COLUMN restaurant_tables.seats         IS 'Maximum seating capacity.';
COMMENT ON COLUMN restaurant_tables.active        IS 'FALSE = table is closed / under maintenance.';


-- ════════════════════════════════════════════════════════════
--  TABLE: reservations
-- ════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS reservations (
  id                UUID               PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at        TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ        NOT NULL DEFAULT NOW(),

  -- Guest info
  customer_name     TEXT               NOT NULL CHECK (char_length(customer_name) >= 2),
  customer_email    TEXT               NOT NULL CHECK (customer_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  customer_phone    TEXT               NOT NULL CHECK (char_length(customer_phone) >= 6),
  guest_count       INTEGER            NOT NULL CHECK (guest_count BETWEEN 1 AND 20),

  -- Booking slot
  reservation_date  DATE               NOT NULL,
  reservation_time  TIME               NOT NULL,
  table_id          UUID               NOT NULL REFERENCES restaurant_tables (id) ON DELETE RESTRICT,

  -- Extras
  special_requests  TEXT,
  status            reservation_status NOT NULL DEFAULT 'pending',

  -- Prevent past bookings at DB level
  CONSTRAINT no_past_dates CHECK (reservation_date >= CURRENT_DATE)
);

COMMENT ON TABLE  reservations                    IS 'Guest reservation bookings.';
COMMENT ON COLUMN reservations.customer_email     IS 'Validated e-mail format via CHECK constraint.';
COMMENT ON COLUMN reservations.guest_count        IS 'Number of guests (1–20).';
COMMENT ON COLUMN reservations.reservation_date   IS 'Date of the reservation (no past dates allowed).';
COMMENT ON COLUMN reservations.reservation_time   IS 'Slot time (HH:MM).';
COMMENT ON COLUMN reservations.table_id           IS 'FK → restaurant_tables.id.';


-- ════════════════════════════════════════════════════════════
--  TABLE: admins
-- ════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS admins (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT        NOT NULL UNIQUE,
  role        TEXT        NOT NULL DEFAULT 'admin' CHECK (role IN ('admin', 'superadmin')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  admins        IS 'Restaurant staff with admin dashboard access.';
COMMENT ON COLUMN admins.email  IS 'Must match auth.users email for RLS policies to work.';
COMMENT ON COLUMN admins.role   IS 'admin = standard staff, superadmin = full control.';
-- ============================================================
-- 002_indexes.sql
-- Performance indexes for all query patterns
-- ============================================================


-- ── reservations ────────────────────────────────────────────

-- Most common admin query: all reservations for a given date
CREATE INDEX IF NOT EXISTS idx_reservations_date
  ON reservations (reservation_date);

-- Time-slot conflict detection
CREATE INDEX IF NOT EXISTS idx_reservations_time
  ON reservations (reservation_time);

-- Composite: availability check (date + time + table)
CREATE INDEX IF NOT EXISTS idx_reservations_slot
  ON reservations (reservation_date, reservation_time, table_id)
  WHERE status NOT IN ('cancelled');

-- Filter by table across dates
CREATE INDEX IF NOT EXISTS idx_reservations_table_id
  ON reservations (table_id);

-- Filter/count by status (dashboard stats)
CREATE INDEX IF NOT EXISTS idx_reservations_status
  ON reservations (status);

-- Today's reservations fast lookup
CREATE INDEX IF NOT EXISTS idx_reservations_today
  ON reservations (reservation_date, status)
  WHERE status IN ('pending', 'confirmed');

-- Customer search by email
CREATE INDEX IF NOT EXISTS idx_reservations_email
  ON reservations (customer_email);

-- Sort by most recent first (default admin list view)
CREATE INDEX IF NOT EXISTS idx_reservations_created_at
  ON reservations (created_at DESC);

-- Combined date + status (upcoming filter)
CREATE INDEX IF NOT EXISTS idx_reservations_date_status
  ON reservations (reservation_date, status);


-- ── restaurant_tables ────────────────────────────────────────

-- Filter active tables only
CREATE INDEX IF NOT EXISTS idx_tables_active
  ON restaurant_tables (active)
  WHERE active = TRUE;

-- Filter by area (Indoor / Garden Terrace / VIP)
CREATE INDEX IF NOT EXISTS idx_tables_area
  ON restaurant_tables (area);

-- Composite: active tables per area (availability query)
CREATE INDEX IF NOT EXISTS idx_tables_area_active
  ON restaurant_tables (area, active);


-- ── admins ───────────────────────────────────────────────────

-- RLS policy lookup: is this email an admin?
CREATE INDEX IF NOT EXISTS idx_admins_email
  ON admins (email);
-- ============================================================
-- 003_functions.sql
-- Availability checks, validation helpers, dashboard stats
-- ============================================================


-- ════════════════════════════════════════════════════════════
--  FUNCTION: check_table_availability
--  Returns TRUE if the table is bookable for the given slot.
--
--  Rules:
--    1. Table must be active.
--    2. Table capacity must be >= p_guest_count.
--    3. No confirmed/pending reservation exists for same
--       date + time + table (excluding p_exclude_id for edits).
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION check_table_availability (
  p_table_id    UUID,
  p_date        DATE,
  p_time        TIME,
  p_guest_count INTEGER,
  p_exclude_id  UUID DEFAULT NULL   -- pass existing reservation id when updating
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_active  BOOLEAN;
  v_seats   INTEGER;
  v_conflict INTEGER;
BEGIN
  -- 1. Check table exists, is active, and has enough seats
  SELECT active, seats
    INTO v_active, v_seats
    FROM restaurant_tables
   WHERE id = p_table_id;

  IF NOT FOUND THEN
    RETURN FALSE;   -- table doesn't exist
  END IF;

  IF NOT v_active THEN
    RETURN FALSE;   -- table is closed
  END IF;

  IF v_seats < p_guest_count THEN
    RETURN FALSE;   -- not enough seats
  END IF;

  -- 2. Check for conflicting reservation
  SELECT COUNT(*) INTO v_conflict
    FROM reservations
   WHERE table_id         = p_table_id
     AND reservation_date = p_date
     AND reservation_time = p_time
     AND status NOT IN ('cancelled')
     AND (p_exclude_id IS NULL OR id != p_exclude_id);

  RETURN v_conflict = 0;
END;
$$;

COMMENT ON FUNCTION check_table_availability IS
  'Returns TRUE when the table is active, seats >= guests, and has no conflicting booking.';


-- ════════════════════════════════════════════════════════════
--  FUNCTION: get_available_tables
--  Returns all tables that can be booked for a given slot.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_available_tables (
  p_date        DATE,
  p_time        TIME,
  p_guest_count INTEGER DEFAULT 1
)
RETURNS TABLE (
  id            UUID,
  table_number  TEXT,
  area          table_area,
  seats         INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    t.id,
    t.table_number,
    t.area,
    t.seats
  FROM restaurant_tables t
  WHERE t.active = TRUE
    AND t.seats  >= p_guest_count
    AND NOT EXISTS (
      SELECT 1
        FROM reservations r
       WHERE r.table_id         = t.id
         AND r.reservation_date = p_date
         AND r.reservation_time = p_time
         AND r.status NOT IN ('cancelled')
    )
  ORDER BY t.area, t.seats, t.table_number;
END;
$$;

COMMENT ON FUNCTION get_available_tables IS
  'Returns tables that are active, have enough seats, and are not already booked for the slot.';


-- ════════════════════════════════════════════════════════════
--  FUNCTION: validate_reservation
--  Full pre-insert validation. Returns an error message or
--  empty string if valid.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION validate_reservation (
  p_table_id    UUID,
  p_date        DATE,
  p_time        TIME,
  p_guest_count INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_active  BOOLEAN;
  v_seats   INTEGER;
  v_conflict INTEGER;
BEGIN
  -- Date must not be in the past
  IF p_date < CURRENT_DATE THEN
    RETURN 'Reservation date cannot be in the past.';
  END IF;

  -- Same-day reservations must be in the future
  IF p_date = CURRENT_DATE AND p_time <= CURRENT_TIME THEN
    RETURN 'Reservation time has already passed for today.';
  END IF;

  -- Guest count sanity
  IF p_guest_count < 1 THEN
    RETURN 'Guest count must be at least 1.';
  END IF;
  IF p_guest_count > 20 THEN
    RETURN 'Guest count cannot exceed 20. Please contact us directly.';
  END IF;

  -- Table existence + active
  SELECT active, seats
    INTO v_active, v_seats
    FROM restaurant_tables
   WHERE id = p_table_id;

  IF NOT FOUND THEN
    RETURN 'Selected table does not exist.';
  END IF;

  IF NOT v_active THEN
    RETURN 'Selected table is not currently available.';
  END IF;

  -- Capacity
  IF v_seats < p_guest_count THEN
    RETURN FORMAT(
      'Selected table seats %s but you requested %s guests.',
      v_seats, p_guest_count
    );
  END IF;

  -- Double-booking
  SELECT COUNT(*) INTO v_conflict
    FROM reservations
   WHERE table_id         = p_table_id
     AND reservation_date = p_date
     AND reservation_time = p_time
     AND status NOT IN ('cancelled');

  IF v_conflict > 0 THEN
    RETURN 'This table is already reserved for the selected date and time.';
  END IF;

  RETURN '';  -- empty string = valid
END;
$$;

COMMENT ON FUNCTION validate_reservation IS
  'Returns an error message string, or empty string when the reservation is valid.';


-- ════════════════════════════════════════════════════════════
--  FUNCTION: get_dashboard_stats
--  Returns aggregate counts for the admin dashboard.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_dashboard_stats ()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_today       DATE := CURRENT_DATE;
  v_total       INTEGER;
  v_pending     INTEGER;
  v_confirmed   INTEGER;
  v_today_count INTEGER;
  v_upcoming    INTEGER;
  v_cancelled   INTEGER;
  v_completed   INTEGER;
BEGIN
  SELECT
    COUNT(*)                                                   AS total,
    COUNT(*) FILTER (WHERE status = 'pending')                 AS pending,
    COUNT(*) FILTER (WHERE status = 'confirmed')               AS confirmed,
    COUNT(*) FILTER (WHERE status = 'cancelled')               AS cancelled,
    COUNT(*) FILTER (WHERE status = 'completed')               AS completed,
    COUNT(*) FILTER (WHERE reservation_date = v_today
                       AND status IN ('pending','confirmed'))   AS today,
    COUNT(*) FILTER (WHERE reservation_date > v_today
                       AND status IN ('pending','confirmed'))   AS upcoming
  INTO v_total, v_pending, v_confirmed, v_cancelled, v_completed, v_today_count, v_upcoming
  FROM reservations;

  RETURN json_build_object(
    'total',     v_total,
    'pending',   v_pending,
    'confirmed', v_confirmed,
    'cancelled', v_cancelled,
    'completed', v_completed,
    'today',     v_today_count,
    'upcoming',  v_upcoming
  );
END;
$$;

COMMENT ON FUNCTION get_dashboard_stats IS
  'Aggregate reservation counts for the admin dashboard (total, by status, today, upcoming).';


-- ════════════════════════════════════════════════════════════
--  FUNCTION: get_reservations_for_date
--  Returns all non-cancelled reservations for a given date,
--  joined with table info. Used by admin day-view.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_reservations_for_date (p_date DATE)
RETURNS TABLE (
  id                UUID,
  customer_name     TEXT,
  customer_email    TEXT,
  customer_phone    TEXT,
  guest_count       INTEGER,
  reservation_time  TIME,
  table_number      TEXT,
  area              table_area,
  seats             INTEGER,
  special_requests  TEXT,
  status            reservation_status,
  created_at        TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    r.id,
    r.customer_name,
    r.customer_email,
    r.customer_phone,
    r.guest_count,
    r.reservation_time,
    t.table_number,
    t.area,
    t.seats,
    r.special_requests,
    r.status,
    r.created_at
  FROM reservations  r
  JOIN restaurant_tables t ON t.id = r.table_id
  WHERE r.reservation_date = p_date
    AND r.status != 'cancelled'
  ORDER BY r.reservation_time, t.table_number;
END;
$$;

COMMENT ON FUNCTION get_reservations_for_date IS
  'All active reservations for a specific date, joined with table details.';


-- ════════════════════════════════════════════════════════════
--  FUNCTION: search_reservations
--  Flexible search used by admin search bar.
--  Matches on customer name, email, phone, or table number.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION search_reservations (
  p_query       TEXT,
  p_status      reservation_status DEFAULT NULL,
  p_date_from   DATE               DEFAULT NULL,
  p_date_to     DATE               DEFAULT NULL,
  p_limit       INTEGER            DEFAULT 50,
  p_offset      INTEGER            DEFAULT 0
)
RETURNS TABLE (
  id                UUID,
  customer_name     TEXT,
  customer_email    TEXT,
  customer_phone    TEXT,
  guest_count       INTEGER,
  reservation_date  DATE,
  reservation_time  TIME,
  table_number      TEXT,
  area              table_area,
  special_requests  TEXT,
  status            reservation_status,
  created_at        TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    r.id,
    r.customer_name,
    r.customer_email,
    r.customer_phone,
    r.guest_count,
    r.reservation_date,
    r.reservation_time,
    t.table_number,
    t.area,
    r.special_requests,
    r.status,
    r.created_at
  FROM reservations r
  JOIN restaurant_tables t ON t.id = r.table_id
  WHERE
    (p_query IS NULL OR p_query = '' OR (
        r.customer_name  ILIKE '%' || p_query || '%'
     OR r.customer_email ILIKE '%' || p_query || '%'
     OR r.customer_phone ILIKE '%' || p_query || '%'
     OR t.table_number   ILIKE '%' || p_query || '%'
    ))
    AND (p_status    IS NULL OR r.status           = p_status)
    AND (p_date_from IS NULL OR r.reservation_date >= p_date_from)
    AND (p_date_to   IS NULL OR r.reservation_date <= p_date_to)
  ORDER BY r.reservation_date DESC, r.reservation_time ASC
  LIMIT  p_limit
  OFFSET p_offset;
END;
$$;

COMMENT ON FUNCTION search_reservations IS
  'Flexible reservation search with optional filters for status, date range, and text query.';
-- ============================================================
-- 004_triggers.sql
-- Auto-update timestamps + double-booking prevention
-- ============================================================


-- ════════════════════════════════════════════════════════════
--  TRIGGER FUNCTION: set_updated_at
--  Automatically sets updated_at = NOW() on any UPDATE.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION set_updated_at ()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Apply to reservations
DROP TRIGGER IF EXISTS trg_reservations_updated_at ON reservations;
CREATE TRIGGER trg_reservations_updated_at
  BEFORE UPDATE ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- Apply to restaurant_tables
DROP TRIGGER IF EXISTS trg_tables_updated_at ON restaurant_tables;
CREATE TRIGGER trg_tables_updated_at
  BEFORE UPDATE ON restaurant_tables
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();


-- ════════════════════════════════════════════════════════════
--  TRIGGER FUNCTION: prevent_double_booking
--  Fires BEFORE INSERT or UPDATE on reservations.
--  Raises an exception if the slot is already taken,
--  acting as the last-line-of-defense against race conditions.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION prevent_double_booking ()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_conflict_id UUID;
  v_table_active BOOLEAN;
  v_table_seats  INTEGER;
BEGIN
  -- Only enforce for non-cancelled reservations
  IF NEW.status = 'cancelled' THEN
    RETURN NEW;
  END IF;

  -- Verify table is active and has enough seats
  SELECT active, seats
    INTO v_table_active, v_table_seats
    FROM restaurant_tables
   WHERE id = NEW.table_id;

  IF NOT v_table_active THEN
    RAISE EXCEPTION
      'Table is not active and cannot be reserved.'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_table_seats < NEW.guest_count THEN
    RAISE EXCEPTION
      'Table capacity (%) is less than requested guest count (%).',
      v_table_seats, NEW.guest_count
      USING ERRCODE = 'P0002';
  END IF;

  -- Check for conflicting booking (same table, date, time)
  SELECT id INTO v_conflict_id
    FROM reservations
   WHERE table_id         = NEW.table_id
     AND reservation_date = NEW.reservation_date
     AND reservation_time = NEW.reservation_time
     AND status NOT IN ('cancelled')
     AND id != COALESCE(NEW.id, gen_random_uuid())   -- exclude self on UPDATE
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION
      'Table % is already booked on % at %. Reservation conflict: %.',
      NEW.table_id,
      NEW.reservation_date,
      NEW.reservation_time,
      v_conflict_id
      USING ERRCODE = 'P0003';
  END IF;

  RETURN NEW;
END;
$$;

-- Apply to reservations — fires before every insert or update
DROP TRIGGER IF EXISTS trg_prevent_double_booking ON reservations;
CREATE TRIGGER trg_prevent_double_booking
  BEFORE INSERT OR UPDATE ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION prevent_double_booking();

COMMENT ON FUNCTION prevent_double_booking IS
  'Last-line-of-defense trigger: blocks double bookings, inactive tables, and capacity violations at the DB level.';


-- ════════════════════════════════════════════════════════════
--  TRIGGER FUNCTION: normalize_reservation_data
--  Trims whitespace and normalises casing on guest data
--  before storing, preventing duplicate-looking records.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION normalize_reservation_data ()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.customer_name  = TRIM(NEW.customer_name);
  NEW.customer_email = LOWER(TRIM(NEW.customer_email));
  NEW.customer_phone = TRIM(NEW.customer_phone);
  IF NEW.special_requests IS NOT NULL THEN
    NEW.special_requests = TRIM(NEW.special_requests);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_reservation ON reservations;
CREATE TRIGGER trg_normalize_reservation
  BEFORE INSERT OR UPDATE ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION normalize_reservation_data();

COMMENT ON FUNCTION normalize_reservation_data IS
  'Trims whitespace and lowercases email before insert/update.';
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
-- ============================================================
-- 006_seed.sql
-- Restaurant tables seed data — all start as active/available.
-- No sample reservations are created.
-- ============================================================
-- Floor plan matches the SVG in index.html:
--   Indoor  : T1–T10
--   Garden  : G1–G6
--   VIP     : V1–V2  (premium room)
-- ============================================================

INSERT INTO restaurant_tables (table_number, area, seats, active) VALUES

  -- ── INDOOR ──────────────────────────────────────────────
  ('T1',  'Indoor',          2, TRUE),
  ('T2',  'Indoor',          2, TRUE),
  ('T3',  'Indoor',          4, TRUE),
  ('T4',  'Indoor',          4, TRUE),
  ('T5',  'Indoor',          4, TRUE),
  ('T6',  'Indoor',          4, TRUE),
  ('T7',  'Indoor',          6, TRUE),
  ('T8',  'Indoor',          6, TRUE),
  ('T9',  'Indoor',          8, TRUE),
  ('T10', 'Indoor',          8, TRUE),

  -- ── GARDEN TERRACE ──────────────────────────────────────
  ('G1',  'Garden Terrace',  2, TRUE),
  ('G2',  'Garden Terrace',  2, TRUE),
  ('G3',  'Garden Terrace',  4, TRUE),
  ('G4',  'Garden Terrace',  4, TRUE),
  ('G5',  'Garden Terrace',  6, TRUE),
  ('G6',  'Garden Terrace',  6, TRUE),

  -- ── VIP ─────────────────────────────────────────────────
  ('V1',  'VIP',             4, TRUE),
  ('V2',  'VIP',             8, TRUE)

ON CONFLICT (table_number) DO NOTHING;

-- ── Verification query (run after seed to confirm) ──────────
-- SELECT area, table_number, seats, active
--   FROM restaurant_tables
--  ORDER BY area, table_number;
