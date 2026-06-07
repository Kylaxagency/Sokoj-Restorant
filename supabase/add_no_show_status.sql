-- ============================================================
-- add_no_show_status.sql
-- Run in Supabase SQL Editor.
-- Adds 'no_show' to the reservation_status enum.
-- ============================================================

ALTER TYPE reservation_status ADD VALUE IF NOT EXISTS 'no_show';
