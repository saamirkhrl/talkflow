-- The install counter: one row holding one number (docs/telemetry.md).
-- Safe to run more than once. Nothing here drops, deletes or resets data.
--
-- `id` is a boolean primary key that must be true, so the table can only ever
-- hold the single row inserted below.

CREATE TABLE IF NOT EXISTS install_counter (
  id    boolean PRIMARY KEY DEFAULT true CONSTRAINT install_counter_single_row CHECK (id),
  count bigint  NOT NULL DEFAULT 0
);

INSERT INTO install_counter (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
