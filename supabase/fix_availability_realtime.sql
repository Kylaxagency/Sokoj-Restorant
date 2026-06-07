-- ============================================================
-- fix_availability_realtime.sql
-- Run in Supabase SQL Editor.
--
-- 1. Fix availability functions: only pending + confirmed block
--    a table. completed/cancelled reservations free the table.
-- 2. Enable Supabase Realtime on reservations table so the
--    public floor map stays live.
-- ============================================================


-- ── 1. Fix get_available_tables ──────────────────────────────
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
         AND r.status IN ('pending', 'confirmed')
    )
  ORDER BY t.area, t.seats, t.table_number;
END;
$$;


-- ── 2. Fix check_table_availability ─────────────────────────
CREATE OR REPLACE FUNCTION check_table_availability (
  p_table_id    UUID,
  p_date        DATE,
  p_time        TIME,
  p_guest_count INTEGER,
  p_exclude_id  UUID DEFAULT NULL
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
  SELECT active, seats
    INTO v_active, v_seats
    FROM restaurant_tables
   WHERE id = p_table_id;

  IF NOT FOUND THEN RETURN FALSE; END IF;
  IF NOT v_active THEN RETURN FALSE; END IF;
  IF v_seats < p_guest_count THEN RETURN FALSE; END IF;

  SELECT COUNT(*) INTO v_conflict
    FROM reservations
   WHERE table_id         = p_table_id
     AND reservation_date = p_date
     AND reservation_time = p_time
     AND status IN ('pending', 'confirmed')
     AND (p_exclude_id IS NULL OR id != p_exclude_id);

  RETURN v_conflict = 0;
END;
$$;


-- ── 3. Fix validate_reservation ──────────────────────────────
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
  v_active   BOOLEAN;
  v_seats    INTEGER;
  v_conflict INTEGER;
BEGIN
  IF p_date < CURRENT_DATE THEN
    RETURN 'Reservation date cannot be in the past.';
  END IF;
  IF p_date = CURRENT_DATE AND p_time <= CURRENT_TIME THEN
    RETURN 'Reservation time has already passed for today.';
  END IF;
  IF p_guest_count < 1 THEN RETURN 'Guest count must be at least 1.'; END IF;
  IF p_guest_count > 20 THEN RETURN 'Guest count cannot exceed 20. Please contact us directly.'; END IF;

  SELECT active, seats INTO v_active, v_seats
    FROM restaurant_tables WHERE id = p_table_id;

  IF NOT FOUND    THEN RETURN 'Selected table does not exist.'; END IF;
  IF NOT v_active THEN RETURN 'Selected table is not currently available.'; END IF;
  IF v_seats < p_guest_count THEN
    RETURN FORMAT('Selected table seats %s but you requested %s guests.', v_seats, p_guest_count);
  END IF;

  SELECT COUNT(*) INTO v_conflict
    FROM reservations
   WHERE table_id         = p_table_id
     AND reservation_date = p_date
     AND reservation_time = p_time
     AND status IN ('pending', 'confirmed');

  IF v_conflict > 0 THEN
    RETURN 'This table is already reserved for the selected date and time.';
  END IF;

  RETURN '';
END;
$$;


-- ── 4. Enable Supabase Realtime ──────────────────────────────
-- Allows the JS client to subscribe to live changes.
ALTER PUBLICATION supabase_realtime ADD TABLE reservations;
