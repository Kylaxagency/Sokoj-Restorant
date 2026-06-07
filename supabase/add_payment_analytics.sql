-- ============================================================
-- add_payment_analytics.sql
-- Run in Supabase SQL Editor.
-- Adds payment tracking and daily analytics to reservations.
-- ============================================================

-- ── 1. Add payment columns ───────────────────────────────────
ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS payment_method TEXT
    CHECK (payment_method IN ('cash', 'card')),
  ADD COLUMN IF NOT EXISTS payment_amount  INTEGER
    CHECK (payment_amount >= 0);

-- ── 2. Daily analytics function ──────────────────────────────
CREATE OR REPLACE FUNCTION get_daily_analytics (p_date DATE DEFAULT CURRENT_DATE)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total        INTEGER;
  v_completed    INTEGER;
  v_cancelled    INTEGER;
  v_no_show      INTEGER;
  v_pending      INTEGER;
  v_confirmed    INTEGER;
  v_total_guests INTEGER;
  v_revenue      BIGINT;
  v_cash         BIGINT;
  v_card         BIGINT;
BEGIN
  SELECT
    COUNT(*)                                                       AS total,
    COUNT(*) FILTER (WHERE status = 'completed')                   AS completed,
    COUNT(*) FILTER (WHERE status = 'cancelled')                   AS cancelled,
    COUNT(*) FILTER (WHERE status = 'no_show')                     AS no_show,
    COUNT(*) FILTER (WHERE status = 'pending')                     AS pending,
    COUNT(*) FILTER (WHERE status = 'confirmed')                   AS confirmed,
    COALESCE(SUM(guest_count), 0)                                  AS total_guests,
    COALESCE(SUM(payment_amount) FILTER (WHERE status = 'completed'), 0) AS revenue,
    COALESCE(SUM(payment_amount) FILTER (WHERE status = 'completed' AND payment_method = 'cash'), 0) AS cash,
    COALESCE(SUM(payment_amount) FILTER (WHERE status = 'completed' AND payment_method = 'card'), 0) AS card
  INTO v_total, v_completed, v_cancelled, v_no_show, v_pending, v_confirmed,
       v_total_guests, v_revenue, v_cash, v_card
  FROM reservations
  WHERE reservation_date = p_date;

  RETURN json_build_object(
    'date',         p_date,
    'total',        v_total,
    'completed',    v_completed,
    'cancelled',    v_cancelled,
    'no_show',      v_no_show,
    'pending',      v_pending,
    'confirmed',    v_confirmed,
    'total_guests', v_total_guests,
    'revenue',      v_revenue,
    'cash',         v_cash,
    'card',         v_card
  );
END;
$$;
