-- Recap system v1: a periodic system post per group summarizing its check-ins as a
-- swipeable deck of typed panels (the payload; see internal/db/recap.go). Ships the
-- ranked collage ("The Wall") and a superlatives panel ("Awards Night"); the map and
-- social-graph panels are v1.5.
--
-- posts.kind gains 'recap'. A recap post carries zero media attachments on purpose: the
-- shipped App Store client gates on kind == 'image' while the current client gates on
-- media.isNotEmpty, and only a medialess post makes both degrade identically to a
-- caption-only card. author_id has no system-user escape hatch, so a recap is authored by
-- the admin; the serializer overrides authorName/authorPhotoId to the group's own
-- identity for kind = 'recap' rows (see the CASE expressions in queries.go), and the real
-- author_id gives the admin delete-recap for free via the existing author-scoped DELETE.
ALTER TABLE posts DROP CONSTRAINT posts_kind_check;
ALTER TABLE posts ADD CONSTRAINT posts_kind_check
  CHECK (kind IN ('text', 'image', 'video', 'recap'));

CREATE TABLE recaps (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  post_id      BIGINT NOT NULL UNIQUE REFERENCES posts(id) ON DELETE CASCADE,
  cadence      TEXT NOT NULL CHECK (cadence IN ('weekly', 'monthly', 'custom')),
  origin       TEXT NOT NULL CHECK (origin IN ('scheduled', 'manual')),
  period_start TIMESTAMPTZ NOT NULL,
  period_end   TIMESTAMPTZ NOT NULL,
  -- Which panel types this recap holds, so the on-demand duplicate check
  -- (periodStart, periodEnd, panels) can query it directly instead of parsing payload
  -- JSON. Always stored sorted, so the same set of panels compares equal regardless of
  -- the order they were requested in.
  panels       TEXT[] NOT NULL,
  payload      JSONB NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Idempotency for the scheduler: one SCHEDULED recap per period, ever. A double tick, a
-- restart mid-period, or two server processes racing all lose harmlessly - see
-- CreateRecapPost's advisory lock, which this index backs up as a hard guarantee even if
-- that lock is ever bypassed. Manual recaps are exempt; the on-demand endpoint has its
-- own confirm-before-replace flow (periodStart/periodEnd/panels, not this index).
CREATE UNIQUE INDEX recaps_scheduled_idx
  ON recaps (cadence, period_start) WHERE origin = 'scheduled';

-- Host settings, mirroring the digest hour/offset precedent in 0013. recap_since is the
-- backfill guard: a period starting before this is never generated, so turning the
-- feature on for an existing group cannot suddenly produce a recap for months of history
-- nobody asked for - only future periods are eligible.
ALTER TABLE server_config ADD COLUMN recap_cadence TEXT     NOT NULL DEFAULT 'weekly'
  CHECK (recap_cadence IN ('off', 'weekly', 'monthly'));
ALTER TABLE server_config ADD COLUMN recap_weekday SMALLINT NOT NULL DEFAULT 1;  -- ISO, 1=Mon
ALTER TABLE server_config ADD COLUMN recap_hour    SMALLINT NOT NULL DEFAULT 19;
ALTER TABLE server_config ADD COLUMN recap_offset  SMALLINT NOT NULL DEFAULT 0;  -- min east of UTC
ALTER TABLE server_config ADD COLUMN recap_since   TIMESTAMPTZ NOT NULL DEFAULT now();

-- Coordinates ship in v1 even though the map panel is v1.5, so two or three weeks of real
-- data have accumulated by the time it needs them. The client rounds to 2 decimal places
-- (~1.1km) before sending - strictly coarser than the "City, Country" string already
-- stored, so this leaks nothing new (see 0003's contract for that column). DOUBLE
-- PRECISION, not REAL: the value is always rounded to 2 decimal places before it is
-- written (normalizeCoord in queries.go), and REAL's float32 representation cannot hold
-- that round trip exactly, which would make a stored value compare unequal to the one that
-- was written.
ALTER TABLE posts ADD COLUMN lat DOUBLE PRECISION;
ALTER TABLE posts ADD COLUMN lng DOUBLE PRECISION;
