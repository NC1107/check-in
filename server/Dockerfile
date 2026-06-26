# Multi-stage build producing a tiny static binary on a distroless base.
FROM golang:1.26-alpine AS build
WORKDIR /src

# Cache modules first.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO disabled → fully static binary.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server
# Pre-create the media dir so a freshly-created named volume inherits nonroot ownership
# (Docker seeds a new empty volume from the image path's contents + permissions). Without
# this the volume defaults to root-owned and the nonroot server can't write uploads.
RUN mkdir -p /data/media && touch /data/media/.keep

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/server /app/server
COPY --from=build --chown=65532:65532 /data/media /data/media
# Media is written to a mounted volume.
VOLUME ["/data/media"]
ENV CHECKIN_MEDIA_DIR=/data/media
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app/server"]
