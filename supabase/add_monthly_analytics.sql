-- ============================================================
-- add_monthly_analytics.sql
-- Run in Supabase SQL Editor.
-- Adds get_monthly_analytics() RPC function.
-- ============================================================

CREATE OR REPLACE FUNCTION get_monthly_analytics (
  p_year  INT DEFAULT EXTRACT(YEAR  FROM CURRENT_DATE)::INT,
  p_month INT DEFAULT EXTRACT(MONTH FROM CURRENT_DATE)::INT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_start  DATE;
  v_end    DATE;
  v_totals JSON;
  v_daily  JSON;
BEGIN
  v_start := make_date(p_year, p_month, 1);
  v_end   := (v_start + INTERVAL '1 month - 1 day')::DATE;

  -- Monthly totals
  SELECT json_build_object(
    'total',        COUNT(*),
    'completed',    COUNT(*) FILTER (WHERE status = 'completed'),
    'cancelled',    COUNT(*) FILTER (WHERE status = 'cancelled'),
    'no_show',      COUNT(*) FILTER (WHERE status = 'no_show'),
    'pending',      COUNT(*) FILTER (WHERE status = 'pending'),
    'confirmed',    COUNT(*) FILTER (WHERE status = 'confirmed'),
    'total_guests', COALESCE(SUM(guest_count), 0),
    'revenue',      COALESCE(SUM(payment_amount) FILTER (WHERE status = 'completed'), 0),
    'cash',         COALESCE(SUM(payment_amount) FILTER (WHERE status = 'completed' AND payment_method = 'cash'), 0),
    'card',         COALESCE(SUM(payment_amount) FILTER (WHERE status = 'completed' AND payment_method = 'card'), 0)
  ) INTO v_totals
  FROM reservations
  WHERE reservation_date BETWEEN v_start AND v_end;

  -- Per-day breakdown (includes days with 0 reservations)
  SELECT json_agg(
    json_build_object(
      'date',      gs.d::DATE,
      'total',     COALESCE(COUNT(r.id), 0),
      'completed', COALESCE(COUNT(r.id) FILTER (WHERE r.status = 'completed'), 0),
      'cancelled', COALESCE(COUNT(r.id) FILTER (WHERE r.status = 'cancelled'), 0),
      'no_show',   COALESCE(COUNT(r.id) FILTER (WHERE r.status = 'no_show'), 0),
      'guests',    COALESCE(SUM(r.guest_count), 0),
      'revenue',   COALESCE(SUM(r.payment_amount) FILTER (WHERE r.status = 'completed'), 0),
      'cash',      COALESCE(SUM(r.payment_amount) FILTER (WHERE r.status = 'completed' AND r.payment_method = 'cash'), 0),
      'card',      COALESCE(SUM(r.payment_amount) FILTER (WHERE r.status = 'completed' AND r.payment_method = 'card'), 0)
    ) ORDER BY gs.d
  ) INTO v_daily
  FROM generate_series(v_start, v_end, '1 day'::INTERVAL) AS gs(d)
  LEFT JOIN reservations r ON r.reservation_date = gs.d::DATE;

  RETURN json_build_object(
    'year',   p_year,
    'month',  p_month,
    'totals', v_totals,
    'daily',  COALESCE(v_daily, '[]'::JSON)
  );
END;
$$;
