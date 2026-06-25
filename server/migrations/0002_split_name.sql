-- Record a member's full name split into first/last. The existing `name` column stays
-- as the display name (what everyone sees), which may differ from the legal/full name.
ALTER TABLE users ADD COLUMN first_name TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN last_name  TEXT NOT NULL DEFAULT '';
