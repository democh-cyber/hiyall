# Hiyall API image: the API (/api), the migration runner (/migrate) and the SQL migrations (/migrations).
#
# Build from the REPOSITORY ROOT, because the migrations live outside services/api:
#   docker build -f services/api/Dockerfile -t hiyall-api .
# Run the API:        docker run --env-file api.env -p 8080:8080 hiyall-api
# Run the migrations: docker run --env-file api.env --entrypoint /migrate hiyall-api
#
# Tags below were checked to exist on 2026-10-13: golang:1.27.2-alpine3.24 (go.mod says go 1.27.2) and
# gcr.io/distroless/static-debian13:nonroot. Move both when go.mod's version moves. They are tags, not
# digests: for a reproducible build resolve them to @sha256 digests in the deploy pipeline.

FROM golang:1.27.2-alpine3.24 AS build
# go.mod's version is the toolchain; never download another one during the build.
ENV GOTOOLCHAIN=local CGO_ENABLED=0 GOFLAGS=-mod=readonly
WORKDIR /src/services/api
COPY services/api/go.mod services/api/go.sum ./
RUN go mod download
COPY services/api/ ./
# Static, stripped, no build paths or VCS stamps in the binary.
RUN go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/api ./cmd/api \
 && go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/migrate ./cmd/migrate

# distroless/static: CA certificates, tzdata and a non-root user, no shell and no package manager.
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/api /api
COPY --from=build /out/migrate /migrate
COPY database/migrations /migrations
# Listen on every interface inside the container; METRICS_ADDR keeps its loopback default (set it, with
# METRICS_TOKEN, to scrape from outside). MIGRATIONS_DIR serves /migrate and the /readyz schema check.
ENV LISTEN_ADDR=0.0.0.0:8080 MIGRATIONS_DIR=/migrations
USER nonroot:nonroot
EXPOSE 8080
# No shell, curl or wget in the image: the binary checks itself (liveness, no database involved).
HEALTHCHECK --interval=15s --timeout=4s --start-period=10s --retries=3 CMD ["/api", "healthcheck"]
ENTRYPOINT ["/api"]
