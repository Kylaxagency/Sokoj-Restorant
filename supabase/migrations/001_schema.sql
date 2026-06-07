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
