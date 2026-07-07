-- A per-group accent color (a palette id like 'coral'), admin-set and shown to every
-- member so groups are told apart at a glance in the combined feed. Empty means no color
-- was chosen - clients fall back to a deterministic color derived from the group id.
ALTER TABLE server_config ADD COLUMN color TEXT NOT NULL DEFAULT '';
