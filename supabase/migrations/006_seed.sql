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
