# Sokoj Restoran — Supabase Database Setup

## Migration order

Run migrations in numeric order inside the Supabase SQL editor
(Dashboard → SQL Editor → New query):

| File | Purpose |
|------|---------|
| `001_schema.sql` | Tables, ENUMs, constraints |
| `002_indexes.sql` | Performance indexes |
| `003_functions.sql` | Availability, validation, stats |
| `004_triggers.sql` | Auto-timestamps, double-booking guard |
| `005_rls.sql` | Row Level Security + policies |
| `006_seed.sql` | Restaurant tables (no reservations) |

## First-time admin setup

After running the migrations, add your first admin user:

```sql
-- 1. The user must have already signed up via Supabase Auth.
-- 2. Then insert their email into the admins table:
INSERT INTO admins (email, role)
VALUES ('your-admin@email.com', 'superadmin');
```

## Key functions

```sql
-- Check if a specific table is free
SELECT check_table_availability(
  '<table-uuid>',
  '2025-08-15'::DATE,
  '19:00'::TIME,
  4   -- guest count
);

-- Get all tables available for a slot
SELECT * FROM get_available_tables(
  '2025-08-15'::DATE,
  '19:00'::TIME,
  4
);

-- Validate before insert (returns error string or '')
SELECT validate_reservation(
  '<table-uuid>',
  '2025-08-15'::DATE,
  '19:00'::TIME,
  4
);

-- Dashboard stats
SELECT get_dashboard_stats();

-- All reservations for a date
SELECT * FROM get_reservations_for_date('2025-08-15'::DATE);

-- Search reservations
SELECT * FROM search_reservations(
  p_query     => 'Marko',
  p_status    => 'confirmed',
  p_date_from => '2025-08-01'::DATE,
  p_date_to   => '2025-08-31'::DATE
);
```

## Environment variables

Add to your server `.env`:

```
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

Use the **service role key** in `server.js` for all admin operations
(it bypasses RLS). Use the **anon key** for public-facing calls.

## Security notes

- Public visitors can only INSERT reservations and SELECT active tables.
- The `prevent_double_booking` trigger is the last line of defense
  against race conditions — it fires even if the app-level check is bypassed.
- Admins are identified by their `auth.users` email matching a row in `admins`.
- Superadmins can manage other admin accounts and delete records.
- All functions use `SECURITY DEFINER` so they run with elevated privileges
  regardless of the calling user's role.
