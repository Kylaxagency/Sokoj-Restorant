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
