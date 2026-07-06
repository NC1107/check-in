-- Stop a member from flooding the admin report queue with duplicates of the same target.
-- First collapse any existing duplicates (keep the earliest report per reporter+target),
-- then enforce uniqueness going forward with partial indexes (one per target kind).

DELETE FROM content_reports cr
USING content_reports keep
WHERE cr.post_id IS NOT NULL
  AND cr.reporter_id = keep.reporter_id
  AND cr.post_id = keep.post_id
  AND cr.id > keep.id;

DELETE FROM content_reports cr
USING content_reports keep
WHERE cr.comment_id IS NOT NULL
  AND cr.reporter_id = keep.reporter_id
  AND cr.comment_id = keep.comment_id
  AND cr.id > keep.id;

CREATE UNIQUE INDEX content_reports_reporter_post_uniq
    ON content_reports (reporter_id, post_id) WHERE post_id IS NOT NULL;

CREATE UNIQUE INDEX content_reports_reporter_comment_uniq
    ON content_reports (reporter_id, comment_id) WHERE comment_id IS NOT NULL;
