# syntax=docker/dockerfile:1
#
# GoClaw All-in-One Image
# Build context: ../goclaw (upstream source)
# Named context: deploy=. (this repo's config files)
#
# Build:
#   docker buildx build --build-context deploy=. -f Dockerfile -t itsddvn/goclaw ../goclaw

# ── Stage 1: Build Go binary (cross-compile on build platform) ──
FROM --platform=$BUILDPLATFORM golang:1.25-bookworm AS go-builder

ARG TARGETARCH
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION=dev

RUN CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH \
    go build -ldflags="-s -w -X github.com/nextlevelbuilder/goclaw/cmd.Version=${VERSION}" \
    -o /out/goclaw .

# ── Stage 2: Build React SPA (platform-independent static output) ──
FROM --platform=$BUILDPLATFORM node:22-alpine AS web-builder

RUN corepack enable && corepack prepare pnpm@10.28.2 --activate

WORKDIR /app

COPY ui/web/package.json ui/web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY ui/web/ .
RUN pnpm build

# ── Stage 3: Runtime (Alpine + nginx) ──
FROM alpine:3.22

RUN apk add --no-cache ca-certificates wget nginx

# Non-root user
RUN addgroup -S goclaw && adduser -S -G goclaw goclaw

WORKDIR /app

# Copy Go binary and migrations
COPY --from=go-builder /out/goclaw /app/goclaw
COPY --from=go-builder /src/migrations/ /app/migrations/

# Copy React SPA to nginx html directory
COPY --from=web-builder /app/dist /usr/share/nginx/html

# Copy deploy-specific config files (from named build context)
COPY --from=deploy nginx.conf /etc/nginx/http.d/default.conf
COPY --from=deploy entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Create data directories and set permissions
RUN mkdir -p /app/workspace /app/data /app/sessions /app/skills /app/.goclaw \
    && mkdir -p /run/nginx /var/lib/nginx/logs /var/log/nginx \
    && chown -R goclaw:goclaw /app /run/nginx /usr/share/nginx/html \
        /var/lib/nginx /var/log/nginx

# Default environment
ENV GOCLAW_CONFIG=/app/config.json \
    GOCLAW_WORKSPACE=/app/workspace \
    GOCLAW_DATA_DIR=/app/data \
    GOCLAW_SESSIONS_STORAGE=/app/sessions \
    GOCLAW_SKILLS_DIR=/app/skills \
    GOCLAW_MIGRATIONS_DIR=/app/migrations \
    GOCLAW_HOST=0.0.0.0 \
    GOCLAW_PORT=18790

USER goclaw

EXPOSE 8080 18790

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["serve"]
