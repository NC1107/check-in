# Multi-stage build producing a tiny static binary on a distroless base.
FROM golang:1.26-alpine AS build
WORKDIR /src

# Fetches, filters, and packs the places gazetteer's dataset from a pinned GeoNames URL
# (see internal/gazetteer/data/SOURCE.md and fetch_and_pack.sh) - never committed to this
# repo, never fetched at container boot. This is a build-time download, not a runtime
# external call, so it doesn't touch the app's own no-phoning-home posture (see
# internal/gazetteer's own doc comment): only whoever builds the image needs the network;
# everyone who pulls the finished image doesn't. Placed before COPY go.mod/COPY . . and
# depending only on this one script and the packer it calls (not on the rest of the
# source), so an ordinary code change never invalidates this layer's Docker cache - the
# dataset itself doesn't change from release to release, and re-downloading ~420MB on
# every build would be a real cost otherwise.
RUN apk add --no-cache curl python3 unzip
COPY internal/gazetteer/data/pack_places.py internal/gazetteer/data/fetch_and_pack.sh internal/gazetteer/data/
RUN sh internal/gazetteer/data/fetch_and_pack.sh

# Cache modules next.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO disabled → fully static binary.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server
# Pre-create the media dir so a freshly-created named volume inherits nonroot ownership
# (Docker seeds a new empty volume from the image path's contents + permissions). Without
# this the volume defaults to root-owned and the nonroot server can't write uploads.
RUN mkdir -p /data/media && touch /data/media/.keep
RUN mkdir -p /out/data && cp internal/gazetteer/data/places.bin /out/data/places.bin

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
# The gazetteer dataset first, the server binary second: each COPY is its own image layer,
# and the binary changes on every release while the dataset almost never does. Keeping the
# stable, much larger layer first means a routine release only pushes/pulls the small
# binary layer - the dataset layer stays cached.
COPY --from=build /out/data/places.bin /app/data/places.bin
COPY --from=build /out/server /app/server
COPY --from=build --chown=65532:65532 /data/media /data/media
# Media is written to a mounted volume.
VOLUME ["/data/media"]
ENV CHECKIN_MEDIA_DIR=/data/media
ENV CHECKIN_GAZETTEER_PATH=/app/data/places.bin
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app/server"]
