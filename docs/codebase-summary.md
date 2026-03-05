# GoClaw Deploy — Codebase Summary

Complete breakdown of the goclaw-deploy repository structure, file purposes, and key components.

## Repository Overview

**Purpose:** Docker all-in-one packaging for GoClaw, a multi-LLM AI agent gateway platform.

**Scope:** 8 source files, ~1,039 LOC total, focused on deployment and containerization.

**Key Technologies:**
- Docker & Docker Compose (container orchestration)
- Dockerfile (3-stage multi-arch build)
- nginx (reverse proxy & SPA server)
- PostgreSQL 18 + pgvector (vector database)
- Go 1.25 (backend binary compilation)
- Node 22 + pnpm (React SPA build)
- Alpine Linux 3.22 (runtime)
- Shell scripting (release automation, container entrypoint)

## File-by-File Breakdown

### Core Container Files

#### Dockerfile (86 LOC)
Multi-stage container build orchestrating Go binary compilation, React SPA build, and Alpine runtime.

**Stages:**
1. **go-builder** (`golang:1.25-bookworm`): Compiles Go binary with cross-compilation support (TARGETARCH), strips binaries, embeds VERSION
2. **web-builder** (`node:22-alpine`): Installs pnpm, builds React SPA from `ui/web/` source
3. **runtime** (`alpine:3.22`): Alpine OS + nginx, copies compiled binary and SPA, runs as non-root

**Key Features:**
- Cross-platform support via BUILDPLATFORM/TARGETARCH
- cgexecGO disabled (statically linked binary)
- Migrations copied from source
- Non-root user (goclaw:goclaw)
- Environment defaults set (GOCLAW_* paths, GOCLAW_PORT=18790)
- Healthcheck via wget on /health
- Security: CAP_DROP ALL, tmpfs /tmp with noexec/nosuid

**Exposed Ports:** 8080 (nginx)

#### entrypoint.sh (55 LOC)
Container startup script handling process lifecycle and mode-specific initialization.

**Modes:**
- `serve` (default): Auto-upgrade on startup (if GOCLAW_MODE=managed), daemonizes goclaw & nginx, graceful shutdown trap
- `upgrade`: Runs `goclaw upgrade` (schema migrations + data hooks)
- `migrate`: Runs `goclaw migrate` (database migrations)
- `onboard`: Runs `goclaw onboard` (interactive setup)
- `version`: Prints version info
- `*`: Pass-through to goclaw binary

**Critical Logic:**
```bash
if [ "$GOCLAW_MODE" = "managed" ] && [ -n "$GOCLAW_POSTGRES_DSN" ]; then
    /app/goclaw upgrade  # Auto-migrate before serving
fi
```

**Process Management:** Runs goclaw & nginx as background processes, kills both on SIGTERM/SIGINT.

#### nginx.conf (57 LOC)
Reverse proxy configuration serving React SPA and proxying API requests.

**Key Routes:**
| Location | Target | Purpose |
|---|---|---|
| `/assets/` | Static files | Cache 1 year, immutable (Vite hashed names) |
| `/ws` | http://127.0.0.1:18790 | WebSocket proxy with Upgrade headers, 86400s timeout |
| `/v1/` | http://127.0.0.1:18790 | API proxy with X-Real-IP/X-Forwarded-For |
| `/health` | http://127.0.0.1:18790 | Health check proxy |
| `/` (SPA fallback) | /index.html | Try files, fall back to index.html |

**Security Headers:**
- X-Content-Type-Options: nosniff
- X-Frame-Options: SAMEORIGIN
- Referrer-Policy: strict-origin-when-cross-origin

**Performance:**
- Gzip compression (min 256 bytes)
- Client max body size: 10MB (for LLM chat payloads)

### Docker Compose Files

#### docker-compose.yml (65 LOC)
Production composition: uses pre-built image from Docker Hub, no build step.

**Services:**
- **goclaw**: image `itsddvn/goclaw:v0.4.0-12-g231e112` (pinned version)
  - Managed mode with PostgreSQL DSN
  - 5 named volumes: data, workspace, skills, sessions, .goclaw dotdir
  - Port mapping: GOCLAW_PORT (default 3000) → 8080
  - Security: no-new-privileges, CAP_DROP ALL, tmpfs /tmp
  - Resources: 1GB RAM, 2 CPU, 200 PIDs limit
  - Health check dependency on postgres

- **postgres**: image `pgvector/pgvector:pg18`
  - Vector database with pgvector extension (internal only)
  - Environment credentials from .env
  - Healthcheck: pg_isready
  - Not exposed externally on port 5432

**Volumes:** Named Docker volumes for data persistence.

**Environment:** Loads .env (optional), sets GOCLAW_MODE=managed and GOCLAW_POSTGRES_DSN.

#### docker-compose-build.yml (75 LOC)
Development composition: builds from source, useful for testing changes.

**Differences from docker-compose.yml:**
- `build:` instead of `image:` — builds Dockerfile from ../goclaw-core context
- Dockerfile from $(PWD)/Dockerfile (deploy repo)
- Additional contexts: deploy=. (enables COPY --from=deploy)
- Platform: linux/amd64 (explicit, no multi-arch)
- GOCLAW_VERSION build arg (default: dev)
- Otherwise identical to production (volumes, security, resources)

**Prerequisites:** Requires ../goclaw-core sibling directory with go.mod, ui/web/, migrations/.

#### docker-compose-dokploy.yml (71 LOC)
Dokploy PaaS deployment with external network.

**Differences:**
- External network: dokploy-network (for Dokploy-managed reverse proxy)
- Both services join dokploy-network
- Otherwise identical to docker-compose.yml (pre-built image)

**Use Case:** When Dokploy handles DNS, SSL, and reverse proxying externally.

### Configuration & Automation

#### release.sh (391 LOC)
Fully automated release workflow: sync upstream, review configs, build, push, smoke test.

**Commands:**
- `./release.sh sync` — Fetch upstream, merge into main & develop, auto-review configs, test build
- `./release.sh publish` — Tag version, build multi-arch, push to Docker Hub, smoke test
- `./release.sh full` — sync + publish (default)

**Preflight Checks:**
- goclaw-core exists at ../goclaw-core
- Upstream remote configured in goclaw-core
- Docker and docker buildx available
- Lock file (prevents concurrent runs)

**Detailed Workflow:**

*Sync phase:*
1. Checkout main, fetch upstream, merge upstream/main
2. Checkout develop, merge main into develop
3. Auto-review: diff deploy configs (Dockerfile, nginx.conf) vs core
4. Clean: stop containers, remove volumes
5. Test build: docker-compose-build.yml up, health check

*Publish phase:*
1. Get VERSION from git tags in goclaw-core
2. Confirm push to Docker Hub
3. Build multi-arch (linux/amd64) with docker buildx
4. Verify image can be pulled
5. Update docker-compose.yml and docker-compose-dokploy.yml with new version tag
6. Smoke test: docker-compose.yml up, health check
7. Commit compose files with message "release: update image to {VERSION}"

**Helpers:**
- `health_check()` — Polls endpoint (default 30 attempts, 5s interval)
- `sed_i()` — Platform-agnostic sed (macOS/Linux compatibility)
- `escape_sed()` — Escapes special chars for sed substitution


#### .env.example (35 LOC)
Template for environment variables (copy to .env before running).

**Sections:**
1. **LLM Providers** (11 keys) — At least one required (OpenRouter, Anthropic, OpenAI, Gemini, Deepseek, Groq, Mistral, xAI, Cohere, Perplexity, MiniMax)
2. **Gateway** (2 keys) — GOCLAW_GATEWAY_TOKEN, GOCLAW_ENCRYPTION_KEY (generate random values)
3. **Channels** (5 keys) — Telegram, Discord, Lark, Zalo integrations (optional)
4. **Database** (1 key) — POSTGRES_PASSWORD (managed mode only)
5. **Ports** (1 key, commented) — GOCLAW_UI_PORT (optional, default 3000)

#### .gitignore (3 items)
Ignores:
- `.env` — Secrets, API keys
- `config.json` — Generated config
- `plans/` — Development/documentation plans

#### .dockerignore (3 items)
Prevents bloat in build context:
- `.git/` — Git metadata
- `.env` — Secrets
- `*.md` — Documentation

#### LICENSE (MIT)
Copyright 2026 Duc Nguyen.

## Architecture Patterns

### Multi-Stage Docker Build
Separates concerns:
1. **Go compilation** — Heavy toolchain, discarded
2. **React bundling** — Build tools removed, output only
3. **Runtime** — Minimal Alpine with only binary + SPA + nginx

Result: ~500MB final image (Alpine 3.22 base ~7MB + GoClaw ~150MB + nginx ~20MB + React SPA ~100MB).

### Named Docker Build Context
Allows copying deploy repo files into image without including entire deploy repo in Docker build context:
```dockerfile
COPY --from=deploy nginx.conf /etc/nginx/http.d/default.conf
COPY --from=deploy entrypoint.sh /app/entrypoint.sh
```

Build command:
```bash
docker buildx build --build-context deploy=. -f Dockerfile -t image:tag ../goclaw-core
```

### Managed Mode + Auto-Migration
Detects environment and auto-upgrades schema on startup:
```bash
if [ "$GOCLAW_MODE" = "managed" ] && [ -n "$GOCLAW_POSTGRES_DSN" ]; then
    /app/goclaw upgrade
fi
```

Enables zero-downtime deployments: pull new image → container starts → auto-migrates → serves requests.

### Compose Variants for Different Scenarios
Single Dockerfile, three compositions:
- **docker-compose.yml** — Fast production (pre-built)
- **docker-compose-build.yml** — Dev (from source)
- **docker-compose-dokploy.yml** — PaaS (external network)

Reduces duplication (all share same services, volumes, env) while supporting different deployment patterns.

### Release Automation
Fully scripted pipeline:
1. Version from git tags (immutable)
2. Auto-merge upstream with conflict detection
3. Config review (diffs highlighted)
4. Local test build before push
5. Multi-arch cross-compilation (linux/amd64 minimum)
6. Smoke test post-push
7. Compose file updates + commit

Reduces human error and ensures consistency.

## Dependencies

### External Docker Images
- `golang:1.25-bookworm` — Go compiler, build-only
- `node:22-alpine` — Node.js + pnpm, build-only
- `alpine:3.22` — Minimal runtime OS
- `pgvector/pgvector:pg18` — PostgreSQL 18 with vector extension

### Build Requirements
- Docker & Docker Compose (v2+)
- docker buildx (multi-arch support)
- bash 4+ (for release.sh)
- git (for version detection)
- curl, wget (for health checks)

### Runtime Requirements
- Docker daemon with buildx capability
- 2GB+ RAM per container (default limit 1GB)
- ~500MB disk per image layer

## Environment Variable Flow

```
.env (git-ignored)
  ↓
docker compose up
  ↓
Passes to goclaw container via env_file + environment: {}
  ↓
entrypoint.sh uses GOCLAW_MODE, GOCLAW_POSTGRES_DSN
  ↓
goclaw binary reads all GOCLAW_* vars
```

## Security Considerations

### Container-Level
- Non-root user (goclaw:goclaw)
- `security_opt: no-new-privileges:true`
- `cap_drop: ALL` (no capabilities)
- tmpfs /tmp with noexec, nosuid (prevents exploit execution)
- Resource limits (prevent DoS)

### Network
- nginx security headers (XSS, clickjacking prevention)
- Reverse proxy (API backend not directly exposed)
- WebSocket proxying (long-lived connections)
- Client max body size limit (10MB)

### Data
- PostgreSQL credentials from .env (git-ignored)
- Vector embeddings stored in pgvector
- Session storage in named volume
- Config persistence in /app/data

## Common Operations

### Upgrade to New Version
```bash
# In goclaw-deploy repo
./release.sh full
git push
# Compose files updated with new tag
```

### Local Development Build
```bash
docker compose -f docker-compose-build.yml up -d --build
# Edits to ../goclaw-core reflect on rebuild
```

### Reset Database
```bash
docker compose down -v
docker compose up -d
# Fresh PostgreSQL init
```

### View Logs
```bash
docker compose logs goclaw -f --tail=50
docker compose logs postgres -f
```

### Inspect Health
```bash
docker compose ps
curl http://localhost:3000/health
docker exec -it <container> /app/goclaw version
```
