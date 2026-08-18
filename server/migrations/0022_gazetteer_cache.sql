-- The places gazetteer moved off an in-memory index to a disk-backed one (see
-- server/internal/gazetteer's own doc comment) so its now-worldwide, population-agnostic
-- dataset doesn't cost several hundred MB of RAM per server process - a real cost on the
-- self-hosted boxes this app actually runs on, where one host can run several instances at
-- once. A disk read is slower than a RAM lookup, but it doesn't need to be fast: every
-- check-in since coordinate capture shipped already carries its own device-captured
-- lat/lng and never touches the gazetteer at all, so this table only ever backfills the
-- historical location strings that predate that - a real self-hosted group has on the
-- order of ten to fifty of those, ever. This table is what makes that disk read's latency
-- irrelevant: the same normalized location is looked up here first, and only falls through
-- to the gazetteer file on a genuine miss (see db.candidatesCached).
--
-- candidates holds the JSON-encoded []gazetteer.Candidate the gazetteer returned - every
-- real candidate for that name, not buildPlaces' own group-specific disambiguated answer
-- (which depends on THIS group's own anchor places and so can never be cached globally;
-- see buildPlaces' own doc comment). An empty JSON array is a genuine NEGATIVE cache entry
-- - a location this dataset has no row for at all - so an unresolvable string is answered
-- from here too, rather than re-scanning the file on every call.
CREATE TABLE gazetteer_cache (
  normalized_location TEXT NOT NULL PRIMARY KEY,
  candidates           JSONB NOT NULL,
  resolved_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
