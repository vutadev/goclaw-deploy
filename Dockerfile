# syntax=docker/dockerfile:1
#
# GoClaw All-in-One Image (core + nginx + web UI)
#
# Requires core image to be built first from goclaw-core/Dockerfile.
# Use the Makefile targets which handle both steps automatically:
#   make build-local   (single arch, loads into Docker)
#   make push          (multi-arch, pushes to registry)

ARG CORE_IMAGE=itsddvn/goclaw:latest-core

# ── Stage 1: Build web UI ──
FROM node:22-alpine AS webbuilder

RUN corepack enable && corepack prepare pnpm@10.28.2 --activate

WORKDIR /app

# Cache dependencies
COPY goclaw-core/ui/web/package.json goclaw-core/ui/web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Copy source and build
COPY goclaw-core/ui/web/ .
RUN pnpm build

# ── Stage 2: All-in-one runtime (core + nginx + web UI) ──
FROM ${CORE_IMAGE}

# Add nginx for serving web UI + reverse proxying to goclaw backend
RUN apk add --no-cache nginx

# Web UI assets
COPY --from=webbuilder /app/dist /usr/share/nginx/html

# Nginx config
COPY nginx-main.conf /etc/nginx/nginx.conf
COPY nginx.conf /etc/nginx/http.d/default.conf

# Consolidated entrypoint (manages both goclaw + nginx)
COPY entrypoint.sh /app/entrypoint.sh
RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# nginx listens on 8080, goclaw on 18790 (internal)
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["serve"]
