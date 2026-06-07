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
