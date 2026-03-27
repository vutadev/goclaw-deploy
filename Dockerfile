# syntax=docker/dockerfile:1
#
# GoClaw All-in-One Image (full skills, nginx reverse proxy)
# Build context: ../goclaw-core (upstream source)
# Named context: deploy=. (this repo's config files)
#
# Build:
#   docker buildx build --build-context deploy=. -f Dockerfile -t itsddvn/goclaw ../goclaw-core

# ── Stage 1: Build Go binaries (cross-compile on build platform) ──
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS go-builder

ARG TARGETARCH
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION=dev

RUN CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH \
    go build -ldflags="-s -w -X github.com/nextlevelbuilder/goclaw/cmd.Version=${VERSION}" \
    -o /out/goclaw . && \
    CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH \
    go build -ldflags="-s -w" -o /out/pkg-helper ./cmd/pkg-helper

# ── Stage 2: Build React SPA (platform-independent static output) ──
FROM --platform=$BUILDPLATFORM node:22-alpine AS web-builder

RUN corepack enable && corepack prepare pnpm@10.28.2 --activate

WORKDIR /app

COPY --from=web package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY --from=web . .
RUN pnpm build

# ── Stage 3: Runtime (Alpine + nginx + full skills) ──
FROM alpine:3.22

# All skill dependencies installed unconditionally (all-in-one image)
RUN apk add --no-cache \
        ca-certificates wget nginx su-exec \
        python3 py3-pip nodejs npm pandoc github-cli poppler-utils bash && \
    pip3 install --no-cache-dir --break-system-packages \
        pypdf openpyxl pandas python-pptx markitdown defusedxml lxml \
        pdfplumber pdf2image anthropic edge-tts && \
    npm install -g --cache /tmp/npm-cache docx pptxgenjs && \
    rm -rf /tmp/npm-cache /root/.cache /var/cache/apk/*

# Non-root user
RUN addgroup -S goclaw && adduser -S -G goclaw -h /app goclaw

WORKDIR /app

# Copy Go binaries, migrations, and bundled skills
COPY --from=go-builder /out/goclaw /app/goclaw
COPY --from=go-builder /out/pkg-helper /app/pkg-helper
COPY --from=go-builder /src/migrations/ /app/migrations/
COPY --from=go-builder /src/skills/ /app/bundled-skills/

# Copy React SPA to nginx html directory
COPY --from=web-builder /app/dist /usr/share/nginx/html

# Copy deploy-specific config files (from named build context)
COPY --from=deploy nginx-main.conf /etc/nginx/nginx.conf
COPY --from=deploy nginx.conf /etc/nginx/http.d/default.conf
COPY --from=deploy entrypoint.sh /app/entrypoint.sh

# Fix Windows git clone issues:
# 1. CRLF line endings in shell scripts
# 2. Broken symlinks for bundled skills office modules
RUN set -eux; \
    sed -i 's/\r$//' /app/entrypoint.sh; \
    cd /app/bundled-skills; \
    for skill in docx pptx xlsx; do \
        if [ -d "${skill}/scripts" ] && [ ! -d "${skill}/scripts/office" ]; then \
            rm -f "${skill}/scripts/office"; \
            cp -r _shared/office "${skill}/scripts/office"; \
        fi; \
    done

RUN chmod +x /app/entrypoint.sh && \
    chmod 755 /app/pkg-helper && chown root:root /app/pkg-helper

# Create data directories with split ownership.
# .runtime: root owns dir (pkg-helper writes apk-packages),
# pip/npm subdirs are goclaw-owned (runtime installs by app process).
RUN mkdir -p /app/workspace /app/data/.runtime/pip /app/data/.runtime/npm-global/lib \
        /app/data/.runtime/pip-cache /app/skills /app/.goclaw \
    && touch /app/data/.runtime/apk-packages \
    && chown -R goclaw:goclaw /app/workspace /app/skills /app/.goclaw \
    && chown goclaw:goclaw /app/bundled-skills /app/data \
    && chown -R goclaw:goclaw /usr/share/nginx/html \
    && chown root:goclaw /app/data/.runtime /app/data/.runtime/apk-packages \
    && chmod 0750 /app/data/.runtime \
    && chmod 0640 /app/data/.runtime/apk-packages \
    && chown -R goclaw:goclaw /app/data/.runtime/pip /app/data/.runtime/npm-global /app/data/.runtime/pip-cache

# Default environment
ENV GOCLAW_CONFIG=/app/config.json \
    GOCLAW_WORKSPACE=/app/workspace \
    GOCLAW_DATA_DIR=/app/data \
    GOCLAW_SKILLS_DIR=/app/skills \
    GOCLAW_MIGRATIONS_DIR=/app/migrations \
    GOCLAW_HOST=0.0.0.0 \
    GOCLAW_PORT=18790

# Entrypoint runs as root to install persisted packages and start pkg-helper,
# then drops to goclaw user via su-exec before starting the app.

EXPOSE 8080 18790

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["serve"]
