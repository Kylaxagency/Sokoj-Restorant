-- ============================================================
-- completed_reservations_system.sql
-- Run in Supabase SQL Editor.
--
-- Creates the completed_reservations ledger table, a trigger
-- to auto-populate it when a reservation is completed, and
-- analytics RPCs that read from it exclusively.
-- ============================================================

-- ── 1. Completed reservations ledger ─────────────────────────
CREATE TABLE IF NOT EXISTS completed_reservations (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id       UUID NOT NULL REFERENCES reservations(id) ON DELETE SET NULL,
  customer_name        TEXT NOT NULL,
  customer_phone       TEXT,
  table_number         TEXT NOT NULL,
  reservation_date     DATE NOT NULL,
  reservation_start_time TIME NOT NULL,
  reservation_end_time TIME,
  guest_count          INTEGER NOT NULL DEFAULT 1,
  payment_method       TEXT NOT NULL CHECK (payment_method IN ('cash', 'card')),
  payment_amount_rsd   INTEGER NOT NULL CHECK (payment_amount_rsd > 0),
  completed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_by_admin   TEXT,
  UNIQUE(reservation_id)
);

-- RLS: only admins can read, insert is via trigger (SECURITY DEFINER)
ALTER TABLE completed_reservations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_read_completed" ON completed_reservations;
CREATE POLICY "admin_read_completed"
  ON completed_reservations FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "admin_insert_completed" ON completed_reservations;
CREATE POLICY "admin_insert_completed"
  ON completed_reservations FOR INSERT
  TO authenticated
  WITH CHECK (true);

-- ── 2. Trigger: auto-create ledger record on completion ──────
CREATE OR REPLACE FUNCTION fn_on_reservation_completed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS NULL OR OLD.status != 'completed') THEN
    INSERT INTO completed_reservations (
      reservation_id, customer_name, customer_phone,
      table_number, reservation_date, reservation_start_time,
      guest_count, payment_method, payment_amount_rsd,
      completed_at, completed_by_admin
    )
    SELECT
      NEW.id,
      NEW.customer_name,
      NEW.customer_phone,
      t.table_number,
      NEW.reservation_date,
      NEW.reservation_time,
      NEW.guest_count,
      COALESCE(NEW.payment_method, 'cash'),
      COALESCE(NEW.payment_amount, 0),
      NOW(),
      auth.email()
    FROM restaurant_tables t
    WHERE t.id = NEW.table_id
    ON CONFLICT (reservation_id) DO UPDATE SET
      payment_method     = EXCLUDED.payment_method,
      payment_amount_rsd = EXCLUDED.payment_amount_rsd,
      completed_at       = NOW(),
      completed_by_admin = EXCLUDED.completed_by_admin;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reservation_completed ON reservations;
CREATE TRIGGER trg_reservation_completed
  AFTER UPDATE ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION fn_on_reservation_completed();


-- ── 3. Analytics RPCs from completed_reservations ────────────

-- Daily analytics from the ledger
CREATE OR REPLACE FUNCTION get_daily_analytics(p_date DATE DEFAULT CURRENT_DATE)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_completed   INTEGER;
  v_revenue     BIGINT;
  v_cash        BIGINT;
  v_card        BIGINT;
  v_cash_count  INTEGER;
  v_card_count  INTEGER;
  v_guests      INTEGER;
  v_no_show     INTEGER;
  v_cancelled   INTEGER;
  v_avg         NUMERIC;
BEGIN
  SELECT
    COUNT(*),
    COALESCE(SUM(payment_amount_rsd), 0),
    COALESCE(SUM(payment_amount_rsd) FILTER (WHERE payment_method = 'cash'), 0),
    COALESCE(SUM(payment_amount_rsd) FILTER (WHERE payment_method = 'card'), 0),
    COUNT(*) FILTER (WHERE payment_method = 'cash'),
    COUNT(*) FILTER (WHERE payment_method = 'card'),
    COALESCE(SUM(guest_count), 0)
  INTO v_completed, v_revenue, v_cash, v_card, v_cash_count, v_card_count, v_guests
  FROM completed_reservations
  WHERE reservation_date = p_date;

  IF v_completed > 0 THEN
    v_avg := ROUND(v_revenue::NUMERIC / v_completed);
  ELSE
    v_avg := 0;
  END IF;

  SELECT COUNT(*) INTO v_no_show
    FROM reservations WHERE reservation_date = p_date AND status = 'no_show';
  SELECT COUNT(*) INTO v_cancelled
    FROM reservations WHERE reservation_date = p_date AND status = 'cancelled';

  RETURN json_build_object(
    'completed',   v_completed,
    'revenue',     v_revenue,
    'cash',        v_cash,
    'card',        v_card,
    'cash_count',  v_cash_count,
    'card_count',  v_card_count,
    'guests',      v_guests,
    'avg_spend',   v_avg,
    'no_show',     v_no_show,
    'cancelled',   v_cancelled
  );
END;
$$;


-- Monthly analytics from the ledger
CREATE OR REPLACE FUNCTION get_monthly_analytics(
  p_year  INT DEFAULT EXTRACT(YEAR  FROM CURRENT_DATE)::INT,
  p_month INT DEFAULT EXTRACT(MONTH FROM CURRENT_DATE)::INT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_start       DATE;
  v_end         DATE;
  v_completed   INTEGER;
  v_revenue     BIGINT;
  v_cash        BIGINT;
  v_card        BIGINT;
  v_cash_count  INTEGER;
  v_card_count  INTEGER;
  v_guests      INTEGER;
  v_no_show     INTEGER;
  v_cancelled   INTEGER;
  v_avg         NUMERIC;
  v_daily       JSON;
BEGIN
  v_start := make_date(p_year, p_month, 1);
  v_end   := (v_start + INTERVAL '1 month - 1 day')::DATE;

  -- Totals from ledger
  SELECT
    COUNT(*),
    COALESCE(SUM(payment_amount_rsd), 0),
    COALESCE(SUM(payment_amount_rsd) FILTER (WHERE payment_method = 'cash'), 0),
    COALESCE(SUM(payment_amount_rsd) FILTER (WHERE payment_method = 'card'), 0),
    COUNT(*) FILTER (WHERE payment_method = 'cash'),
    COUNT(*) FILTER (WHERE payment_method = 'card'),
    COALESCE(SUM(guest_count), 0)
  INTO v_completed, v_revenue, v_cash, v_card, v_cash_count, v_card_count, v_guests
  FROM completed_reservations
  WHERE reservation_date BETWEEN v_start AND v_end;

  IF v_completed > 0 THEN v_avg := ROUND(v_revenue::NUMERIC / v_completed);
  ELSE v_avg := 0; END IF;

  SELECT COUNT(*) INTO v_no_show
    FROM reservations WHERE reservation_date BETWEEN v_start AND v_end AND status = 'no_show';
  SELECT COUNT(*) INTO v_cancelled
    FROM reservations WHERE reservation_date BETWEEN v_start AND v_end AND status = 'cancelled';

  -- Per-day breakdown
  SELECT json_agg(row ORDER BY row->>'date') INTO v_daily
  FROM (
    SELECT json_build_object(
      'date',       gs.d::DATE,
      'completed',  COALESCE(COUNT(c.id), 0),
      'revenue',    COALESCE(SUM(c.payment_amount_rsd), 0),
      'cash',       COALESCE(SUM(c.payment_amount_rsd) FILTER (WHERE c.payment_method = 'cash'), 0),
      'card',       COALESCE(SUM(c.payment_amount_rsd) FILTER (WHERE c.payment_method = 'card'), 0),
      'guests',     COALESCE(SUM(c.guest_count), 0),
      'no_show',    (SELECT COUNT(*) FROM reservations r2 WHERE r2.reservation_date = gs.d::DATE AND r2.status = 'no_show'),
      'cancelled',  (SELECT COUNT(*) FROM reservations r3 WHERE r3.reservation_date = gs.d::DATE AND r3.status = 'cancelled')
    ) AS row
    FROM generate_series(v_start, v_end, '1 day'::INTERVAL) AS gs(d)
    LEFT JOIN completed_reservations c ON c.reservation_date = gs.d::DATE
    GROUP BY gs.d
  ) sub;

  RETURN json_build_object(
    'year',       p_year,
    'month',      p_month,
    'completed',  v_completed,
    'revenue',    v_revenue,
    'cash',       v_cash,
    'card',       v_card,
    'cash_count', v_cash_count,
    'card_count', v_card_count,
    'guests',     v_guests,
    'avg_spend',  v_avg,
    'no_show',    v_no_show,
    'cancelled',  v_cancelled,
    'daily',      COALESCE(v_daily, '[]'::JSON)
  );
END;
$$;


-- KPI: quick summary for dashboard top cards
CREATE OR REPLACE FUNCTION get_kpi_summary()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_today         DATE := CURRENT_DATE;
  v_month_start   DATE := date_trunc('month', CURRENT_DATE)::DATE;
  v_rev_today     BIGINT;
  v_rev_month     BIGINT;
  v_comp_today    INTEGER;
  v_comp_month    INTEGER;
  v_noshow_month  INTEGER;
  v_avg           NUMERIC;
BEGIN
  SELECT COALESCE(SUM(payment_amount_rsd), 0), COUNT(*)
  INTO v_rev_today, v_comp_today
  FROM completed_reservations WHERE reservation_date = v_today;

  SELECT COALESCE(SUM(payment_amount_rsd), 0), COUNT(*)
  INTO v_rev_month, v_comp_month
  FROM completed_reservations WHERE reservation_date >= v_month_start;

  IF v_comp_month > 0 THEN v_avg := ROUND(v_rev_month::NUMERIC / v_comp_month);
  ELSE v_avg := 0; END IF;

  SELECT COUNT(*) INTO v_noshow_month
  FROM reservations WHERE reservation_date >= v_month_start AND status = 'no_show';

  RETURN json_build_object(
    'revenue_today',       v_rev_today,
    'revenue_month',       v_rev_month,
    'completed_today',     v_comp_today,
    'completed_month',     v_comp_month,
    'no_show_month',       v_noshow_month,
    'avg_spend',           v_avg
  );
END;
$$;
