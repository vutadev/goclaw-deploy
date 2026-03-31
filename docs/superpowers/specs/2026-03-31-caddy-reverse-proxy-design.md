# Design: Replace Nginx with Caddy for Reverse Proxy & Auto HTTPS

**Date:** 2026-03-31
**Status:** Approved
**Scope:** goclaw-deploy container internals + docker-compose configuration

## Summary

Replace nginx with Caddy inside the goclaw container to serve as reverse proxy and static file server. Add auto HTTPS capability via `GOCLAW_DOMAIN` environment variable, while maintaining backward-compatible HTTP-only mode for behind-proxy deployments.

## Goals

1. Replace nginx with Caddy as the in-container reverse proxy and static file server
2. Enable auto HTTPS (Let's Encrypt) when `GOCLAW_DOMAIN` is set
3. Fall back to HTTP-only mode (port 80) when no domain is configured
4. Allow users to override port mapping externally via docker-compose
5. Persist certificates across container restarts

## Non-Goals

- Adding Caddy as a separate container (sidecar)
- Changing the goclaw backend application
- Modifying the Dokploy deployment variant

## Architecture

### Current Flow

```
Host:3000 → Container:8080 (nginx)
           ├→ /v1/*    → 127.0.0.1:18790 (API)
           ├→ /ws      → 127.0.0.1:18790 (WebSocket)
           ├→ /health  → 127.0.0.1:18790 (Health)
           └→ /*       → Static SPA files
```

### New Flow

**HTTP mode (no domain):**
```
Host:{GOCLAW_HTTP_PORT:-80} → Container:80 (Caddy)
                              ├→ /v1/*    → 127.0.0.1:18790 (API)
                              ├→ /ws      → 127.0.0.1:18790 (WebSocket)
                              ├→ /health  → 127.0.0.1:18790 (Health)
                              └→ /*       → Static SPA files
```

**HTTPS mode (with domain):**
```
Host:{GOCLAW_HTTP_PORT:-80}  → Container:80  (Caddy, redirect → 443)
Host:{GOCLAW_HTTPS_PORT:-443} → Container:443 (Caddy, auto TLS)
                                ├→ /v1/*    → 127.0.0.1:18790 (API)
                                ├→ /ws      → 127.0.0.1:18790 (WebSocket)
                                ├→ /health  → 127.0.0.1:18790 (Health)
                                └→ /*       → Static SPA files
```

## Approach

**Caddyfile template + entrypoint selection** — Two Caddyfile templates (`Caddyfile.http` and `Caddyfile.https`). The entrypoint script selects and renders the appropriate template based on `GOCLAW_DOMAIN`.

### Why This Approach

- Simple, no extra dependencies beyond `envsubst`/`sed`
- Two separate files are easier to read/debug than conditional logic in one file
- Caddy does not support if/else in Caddyfile, making a single-file approach impractical
- Consistent with existing entrypoint pattern (entrypoint.sh already handles environment-based configuration)

## Detailed Design

### 1. Caddyfile Templates

**`Caddyfile.http`** — HTTP-only mode (behind proxy or local dev):

```caddyfile
:80 {
    root * /app/dist
    encode gzip

    handle /v1/* {
        reverse_proxy 127.0.0.1:18790
    }

    handle /ws {
        reverse_proxy 127.0.0.1:18790
    }

    handle /health {
        reverse_proxy 127.0.0.1:18790
    }

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy strict-origin-when-cross-origin
    }

    @assets path /assets/*
    header @assets Cache-Control "public, max-age=31536000, immutable"

    try_files {path} /index.html
    file_server
}
```

**`Caddyfile.https`** — Auto HTTPS mode with domain:

```caddyfile
${GOCLAW_DOMAIN} {
    root * /app/dist
    encode gzip

    handle /v1/* {
        reverse_proxy 127.0.0.1:18790
    }

    handle /ws {
        reverse_proxy 127.0.0.1:18790
    }

    handle /health {
        reverse_proxy 127.0.0.1:18790
    }

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy strict-origin-when-cross-origin
    }

    @assets path /assets/*
    header @assets Cache-Control "public, max-age=31536000, immutable"

    try_files {path} /index.html
    file_server
}
```

**Preserved from current nginx config:**
- Gzip compression
- Security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy)
- 1-year cache for `/assets/*` (Vite hashed filenames)
- SPA fallback (`try_files`)
- WebSocket proxy (`/ws`)
- Caddy handles max request body via `request_body` directive (50MB)

### 2. Entrypoint Changes

In `entrypoint.sh`, replace nginx startup with Caddy:

```bash
# Select Caddyfile based on GOCLAW_DOMAIN
if [ -n "$GOCLAW_DOMAIN" ]; then
    cp /app/Caddyfile.https /app/Caddyfile
    sed -i "s/\${GOCLAW_DOMAIN}/$GOCLAW_DOMAIN/g" /app/Caddyfile
else
    cp /app/Caddyfile.http /app/Caddyfile
fi

# Start Caddy (non-root, requires NET_BIND_SERVICE capability)
caddy run --config /app/Caddyfile --adapter caddyfile &
CADDY_PID=$!
```

Process monitoring remains the same — watch both Caddy PID and goclaw PID, exit on either failure.

### 3. Dockerfile Changes

```dockerfile
# Replace: apk add nginx
# With:    apk add caddy

# Remove: COPY nginx.conf nginx-main.conf
# Add:    COPY Caddyfile.http Caddyfile.https /app/

# Change exposed ports
EXPOSE 80 443

# Update healthcheck
HEALTHCHECK CMD wget -qO- http://localhost:80/health
```

### 4. Docker Compose Changes

**docker-compose.yml** and **docker-compose-build.yml:**

```yaml
services:
  goclaw:
    ports:
      - "${GOCLAW_HTTP_PORT:-80}:80"
      - "${GOCLAW_HTTPS_PORT:-443}:443"
    volumes:
      - caddy-data:/data
      # ... existing volumes unchanged
    environment:
      - GOCLAW_DOMAIN=${GOCLAW_DOMAIN:-}
      # ... existing env unchanged
    cap_add:
      - SETUID
      - SETGID
      - CHOWN
      - NET_BIND_SERVICE  # New: allows Caddy to bind 80/443 as non-root

volumes:
  caddy-data:
  # ... existing volumes unchanged
```

**docker-compose-dokploy.yml** — no changes.

### 5. Environment Variables

**.env.example** additions:

```bash
# Domain for auto HTTPS via Let's Encrypt (leave empty to disable)
# When set: Caddy serves HTTPS on 443, redirects HTTP 80 → 443
# When empty: Caddy serves HTTP on port 80 (for behind-proxy or local dev)
# GOCLAW_DOMAIN=example.com

# Port mapping (host ports, container always uses 80/443)
# GOCLAW_HTTP_PORT=80
# GOCLAW_HTTPS_PORT=443
```

### 6. Security

**Improvements over nginx:**
- Caddy runs as non-root user `goclaw` (nginx currently runs as root)
- `NET_BIND_SERVICE` capability added to allow non-root port 80/443 binding

**Certificate storage:**
- Volume `caddy-data:/data` persists Let's Encrypt certificates
- Contains: certs, ACME account keys, OCSP staples
- User `goclaw` needs write permission to `/data`

## Usage Scenarios

| Scenario | Environment Config | Port Mapping |
|----------|-------------------|--------------|
| VPS with auto HTTPS | `GOCLAW_DOMAIN=example.com` | `80:80`, `443:443` |
| Behind external proxy | No domain set | `8080:80` |
| Local development | No domain set | `3000:80` |

## Files Changed

| Action | File |
|--------|------|
| Add | `Caddyfile.http` |
| Add | `Caddyfile.https` |
| Modify | `Dockerfile` |
| Modify | `entrypoint.sh` |
| Modify | `docker-compose.yml` |
| Modify | `docker-compose-build.yml` |
| Modify | `.env.example` |
| Modify | `Makefile` (healthcheck port reference) |
| Modify | `docs/deployment-guide.md` |
| Delete | `nginx.conf` |
| Delete | `nginx-main.conf` |
