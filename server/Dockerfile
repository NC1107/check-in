# Multi-stage build producing a tiny static binary on a distroless base.
FROM golang:1.24-alpine AS build
WORKDIR /src

# Cache modules first.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO disabled → fully static binary.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/server /app/server
# Media is written to a mounted volume.
VOLUME ["/data/media"]
ENV CHECKIN_MEDIA_DIR=/data/media
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app/server"]
