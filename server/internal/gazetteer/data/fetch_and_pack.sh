#!/bin/sh
# Fetches, filters, and packs the GeoNames gazetteer dataset into places.bin - the one step
# that turns a pinned public URL into the on-disk file gazetteer.go reads (see SOURCE.md
# for why this happens here, at Docker BUILD time, rather than shipping a copy in the repo
# or fetching it at container boot). Run from this directory:
#
#   sh fetch_and_pack.sh
#
# Fails loudly (set -e, plus explicit size checks below) rather than silently packing a
# short or malformed download - a partial gazetteer would be a worse failure mode than no
# gazetteer at all, since nothing about it would look broken until a real check-in failed
# to resolve.
set -e

GEONAMES_URL="https://download.geonames.org/export/dump/allCountries.zip"
# The real download is ~420MB; well below that still catches a truncated transfer or an
# HTML error page saved as if it were the zip.
MIN_ZIP_BYTES=300000000
# The real places.bin is currently ~180MB; a run against a genuinely empty or badly
# malformed filtered export would produce something far smaller than this.
MIN_OUTPUT_BYTES=100000000

cd "$(dirname "$0")"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo "fetch_and_pack: downloading $GEONAMES_URL" >&2
# --proto/--proto-redir pin both the initial request and every redirect to HTTPS. -L alone
# would happily follow a redirect down to plaintext http, and whatever came back would be
# packed into the gazetteer that then ships inside the image - so the transport that
# delivers this dataset has to stay authenticated end to end, not just on the first hop.
curl --proto '=https' --proto-redir '=https' -fL -o "$workdir/allCountries.zip" "$GEONAMES_URL"

zip_size=$(wc -c <"$workdir/allCountries.zip")
if [ "$zip_size" -lt "$MIN_ZIP_BYTES" ]; then
  echo "fetch_and_pack: allCountries.zip is only $zip_size bytes (want at least $MIN_ZIP_BYTES) - a short or failed download, refusing to pack a partial gazetteer" >&2
  exit 1
fi

echo "fetch_and_pack: unzipping" >&2
unzip -q "$workdir/allCountries.zip" -d "$workdir"

echo "fetch_and_pack: filtering to populated places" >&2
awk -F'\t' '$7=="P" && $8!="PPLX" && $8!="PPLQ" && $8!="PPLW" && $8!="PPLH" && $8!="PPLCH"' \
  "$workdir/allCountries.txt" >"$workdir/allCountriesP_filtered.txt"

echo "fetch_and_pack: packing" >&2
python3 pack_places.py "$workdir/allCountriesP_filtered.txt" places.bin

out_size=$(wc -c <places.bin)
if [ "$out_size" -lt "$MIN_OUTPUT_BYTES" ]; then
  echo "fetch_and_pack: places.bin is only $out_size bytes (want at least $MIN_OUTPUT_BYTES) - refusing to ship a partial gazetteer" >&2
  rm -f places.bin
  exit 1
fi

echo "fetch_and_pack: wrote places.bin ($out_size bytes)" >&2
