# GoClaw Deploy

All-in-one Docker deployment for GoClaw — an AI agent gateway platform. This repo packages the upstream `goclaw-core` into a containerized setup with nginx reverse proxy, PostgreSQL database, and pgvector extension.

## What is GoClaw?

GoClaw is a Go-based AI agent gateway with a React web dashboard. It supports multiple LLM providers (OpenAI, Anthropic, Gemini, Deepseek, etc.), chat channels (Telegram, Discord, Lark, Zalo), and vector storage.

## Quick Start

### Prerequisites
- Docker & Docker Compose
- At least one LLM provider API key (OpenAI, Anthropic, Gemini, etc.)

### 1. Configure Environment

```bash
cp .env.example .env
```

Edit `.env` and add:
- At least one LLM provider key (e.g., `GOCLAW_ANTHROPIC_API_KEY`)
- Random values for `GOCLAW_GATEWAY_TOKEN` and `GOCLAW_ENCRYPTION_KEY`
- PostgreSQL password: `POSTGRES_PASSWORD`

### 2. Start the Service

**Production (pre-built image from Docker Hub):**
```bash
docker compose up -d
```

**Local build (from source):**
```bash
docker compose -f docker-compose-build.yml up -d --build
```

**Dokploy deployment (external network):**
```bash
docker compose -f docker-compose-dokploy.yml up -d
```

### 3. Access Dashboard

Open http://localhost:3000 in your browser.

## Compose Variants

| Compose File | Use Case | Build | Image Source |
|---|---|---|---|
| `docker-compose.yml` | Production | Fast (no build) | Docker Hub (`itsddvn/goclaw`) |
| `docker-compose-build.yml` | Development | From source | Local Dockerfile |
| `docker-compose-dokploy.yml` | Dokploy PaaS | Pre-built | Docker Hub (external network) |

All variants use PostgreSQL 18 with pgvector extension for vector storage (internal only, not exposed externally).

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Container (Alpine Linux)                               │
│  ┌─────────────────────────────────────────────────┐   │
│  │  nginx (port 8080)                              │   │
│  │  - Reverse proxy for /v1/ (API)                 │   │
│  │  - WebSocket proxy for /ws                      │   │
│  │  - SPA static files (React build)               │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  GoClaw backend (port 18790)                    │   │
│  │  - Go binary with migrations                    │   │
│  │  - Auto-upgrade on startup (managed mode)       │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
           ↓ (port 3000 mapped)
┌─────────────────────────────────────────────────────────┐
│  PostgreSQL 18 + pgvector                               │
│  - Vector database for embeddings                       │
│  - User, sessions, config storage                       │
└─────────────────────────────────────────────────────────┘
```

## Deployment Modes

### Production (docker-compose.yml)
Uses pre-built image from Docker Hub. Fastest startup, no build step required.

```bash
docker compose up -d
# Dashboard: http://localhost:3000
```

### Development (docker-compose-build.yml)
Builds from source (requires `../goclaw-core` sibling directory). Useful for testing changes.

```bash
docker compose -f docker-compose-build.yml up -d --build
# Container rebuilds on every compose up --build
```

### Dokploy (docker-compose-dokploy.yml)
Uses external Dokploy network. For PaaS platforms like Dokploy that provide DNS & reverse proxy.

```bash
docker compose -f docker-compose-dokploy.yml up -d
# Services connect via dokploy-network
```

## Release Workflow

Automated release process via `release.sh`:

```bash
./release.sh sync       # Sync upstream → merge main & develop
./release.sh publish    # Tag, build, push to Docker Hub, smoke test
./release.sh full       # sync + publish (default)
```

Steps:
1. Fetch from upstream (goclaw-core)
2. Merge upstream/main → fork/main → fork/develop
3. Auto-review config diffs (Dockerfile, nginx.conf)
4. Build & test locally
5. Tag version from git
6. Build multi-arch (linux/amd64) and push to Docker Hub
7. Smoke test with pulled image
8. Commit compose file updates

## Environment Variables

### LLM Providers (at least one required)
```
GOCLAW_OPENROUTER_API_KEY=
GOCLAW_ANTHROPIC_API_KEY=
GOCLAW_OPENAI_API_KEY=
GOCLAW_GEMINI_API_KEY=
GOCLAW_DEEPSEEK_API_KEY=
GOCLAW_GROQ_API_KEY=
GOCLAW_MISTRAL_API_KEY=
GOCLAW_XAI_API_KEY=
GOCLAW_COHERE_API_KEY=
GOCLAW_PERPLEXITY_API_KEY=
GOCLAW_MINIMAX_API_KEY=
```

### Gateway Security (required)
```
GOCLAW_GATEWAY_TOKEN=             # Random token for external access
GOCLAW_ENCRYPTION_KEY=            # Random encryption key
```

### Channels (optional)
```
GOCLAW_TELEGRAM_TOKEN=
GOCLAW_DISCORD_TOKEN=
GOCLAW_LARK_APP_ID=
GOCLAW_LARK_APP_SECRET=
GOCLAW_ZALO_TOKEN=
```

### Database (managed mode)
```
POSTGRES_USER=goclaw             # Default
POSTGRES_PASSWORD=               # Required, set in .env
POSTGRES_DB=goclaw               # Default
```

### Ports
```
GOCLAW_UI_PORT=3000              # External port (maps to 8080 in container)
GOCLAW_PORT=18790                # Internal backend port (do not change)
```

## Troubleshooting

### Health check failed
```
docker compose logs goclaw --tail=50
```
Common causes:
- Database not ready: Check `postgres` health in `docker compose ps`
- Migration failed: Check logs for SQL errors
- Port conflict: `lsof -i :3000` (check if port 3000 is in use)

### Containers won't start
```
docker compose down -v
docker compose up -d
```

### Database needs reset
```
docker compose down -v  # Remove all volumes
docker compose up -d    # Fresh start
```

### Build errors
For local build variant:
```bash
# Ensure goclaw-core exists
ls -la ../goclaw-core

# Check Docker buildx availability
docker buildx version

# Rebuild (clears build cache)
docker compose -f docker-compose-build.yml up -d --build --no-cache
```

## File Structure

| File | Purpose |
|---|---|
| `Dockerfile` | 3-stage: Go build → React build → Alpine runtime |
| `entrypoint.sh` | Container startup: auto-migrate, start goclaw & nginx |
| `nginx.conf` | Reverse proxy config: /v1/ API, /ws WebSocket, SPA static |
| `docker-compose.yml` | Production: uses pre-built image |
| `docker-compose-build.yml` | Development: builds from source |
| `docker-compose-dokploy.yml` | Dokploy: external network config |
| `release.sh` | Automated release workflow |

## Security

- Non-root user (`goclaw`) inside container
- No new privileges, all capabilities dropped
- `/tmp` mounted noexec for exploit prevention
- Resource limits: 1GB RAM, 2 CPU, 200 PIDs
- Request body limit: 10MB for LLM chat payloads
- Security headers: X-Content-Type-Options, X-Frame-Options, Referrer-Policy
- GZIP compression enabled
- Static asset caching (1 year, immutable)

## Support

For issues with goclaw-core, see https://github.com/nextlevelbuilder/goclaw

For deployment issues, check the docs/ directory for detailed guides.
