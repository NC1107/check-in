-- Round-4 device feedback: the default recap cadence flips from weekly to monthly. A week
-- rarely accumulates enough check-ins for a recap to feel like anything but "the same
-- handful of photos you just scrolled past" - a month gives a group time to actually forget
-- what happened, so the ranked collage reads as a genuine recap instead of a rerun. The
-- monthly collage cap (20 vs weekly's 12, see selectCollageCards' collageCardCap) already
-- assumed this cadence would be the norm; this migration is what makes it the default.
ALTER TABLE server_config ALTER COLUMN recap_cadence SET DEFAULT 'monthly';

-- Every server still sitting on the untouched schema default is moved onto the new one too,
-- not just new installs going forward - but only when it is actually safe to: a server that
-- has never fired a scheduled recap yet has no history to disturb, so flipping its standing
-- cadence changes what happens next, not what a member has already seen. The NOT EXISTS
-- guard makes that safety condition an enforced invariant of the migration itself, rather
-- than just an assumption about which servers happen to be running this migration soon
-- after 0018-0020 - a host who has genuinely been receiving weekly recaps keeps receiving
-- them, unchanged.
UPDATE server_config
SET recap_cadence = 'monthly'
WHERE recap_cadence = 'weekly'
  AND NOT EXISTS (
    SELECT 1 FROM recaps WHERE origin = 'scheduled' AND cadence = 'weekly'
  );
