-- Profile titles v1: a member's standout award for a period becomes a small persistent
-- badge on their profile ("Quiet Achiever" under their post count), bestowed instead of
-- the removed "Awards Night" recap panel - see internal/db/recap.go's BestowTitles.
--
-- Values are the existing award ids from recap_select.go's awardOrder. Bestowal is pass 1
-- of that algorithm only (each member's own best qualifying category, full stop - no
-- claim/contention pass, no leftover-fill): a member who qualifies for nothing keeps
-- whatever title they already have, so title persists until replaced and is never cleared
-- by a quiet period.
ALTER TABLE users ADD COLUMN title TEXT
  CHECK (title IN (
    'most_liked', 'night_owl', 'early_bird', 'most_travelled', 'chatterbox',
    'biggest_fan', 'quiet_achiever', 'most_tagged', 'longest_thread'
  ));
ALTER TABLE users ADD COLUMN title_set_at TIMESTAMPTZ;
