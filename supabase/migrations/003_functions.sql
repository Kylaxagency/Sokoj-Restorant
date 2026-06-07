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
