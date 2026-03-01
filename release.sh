#!/usr/bin/env bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$SCRIPT_DIR"
CORE_DIR="$(dirname "$DEPLOY_DIR")/goclaw-core"
IMAGE="itsddvn/goclaw"
HEALTH_RETRIES=30
HEALTH_INTERVAL=5
COMPOSE_BUILD="docker-compose-build.yml"
COMPOSE_PROD="docker-compose.yml"
COMPOSE_DOKPLOY="docker-compose-dokploy.yml"
TOTAL_STEPS=10
LOCKFILE="/tmp/goclaw-release.lock"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}ℹ ${NC}$*"; }
warn()    { echo -e "${YELLOW}⚠ ${NC}$*"; }
error()   { echo -e "${RED}✗ ${NC}$*" >&2; }
success() { echo -e "${GREEN}✓ ${NC}$*"; }

step() {
  local n=$1; shift
  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  [${n}/${TOTAL_STEPS}] $*${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

confirm() {
  echo ""
  read -r -p "$(echo -e "${YELLOW}? ${NC}$1 [Y/n] ")" answer
  case "${answer:-y}" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

health_check() {
  local url=$1
  local retries=${2:-$HEALTH_RETRIES}
  local interval=${3:-$HEALTH_INTERVAL}

  info "Waiting for health check: $url"
  for i in $(seq 1 "$retries"); do
    if curl -sf "$url" > /dev/null 2>&1; then
      success "Health check passed (attempt $i/$retries)"
      return 0
    fi
    echo -n "."
    sleep "$interval"
  done
  echo ""
  error "Health check failed after $retries attempts"
  error "Common causes: DB not ready, port in use (lsof -i :3000), migration failure"
  return 1
}

# macOS-compatible sed -i
sed_i() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Escape special regex chars for sed
escape_sed() {
  printf '%s\n' "$1" | sed 's/[[\.*^$()+?{|]/\\&/g'
}

# ── Lock file ───────────────────────────────────────────────────────────────
acquire_lock() {
  if [[ -f "$LOCKFILE" ]]; then
    local pid
    pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      error "Release script already running (PID $pid)"
      error "If stuck, remove: $LOCKFILE"
      exit 1
    else
      warn "Stale lock file found, removing"
      rm -f "$LOCKFILE"
    fi
  fi
  echo $$ > "$LOCKFILE"
}

release_lock() {
  rm -f "$LOCKFILE"
}

# ── Cleanup trap ────────────────────────────────────────────────────────────
COMPOSE_RUNNING=""

cleanup() {
  if [[ -n "$COMPOSE_RUNNING" ]]; then
    warn "Cleaning up Docker resources..."
    docker compose -f "$DEPLOY_DIR/$COMPOSE_RUNNING" down -v --remove-orphans 2>/dev/null || true
  fi
  release_lock
}
trap cleanup EXIT

acquire_lock

# ── Preflight checks ───────────────────────────────────────────────────────
if [[ ! -d "$CORE_DIR" ]]; then
  error "goclaw-core not found at: $CORE_DIR"
  exit 1
fi

if ! git -C "$CORE_DIR" remote get-url upstream > /dev/null 2>&1; then
  error "No 'upstream' remote in goclaw-core. Add it with:"
  error "  git -C $CORE_DIR remote add upstream <upstream-url>"
  exit 1
fi

if ! command -v docker &> /dev/null; then
  error "docker not found"
  exit 1
fi

if ! docker buildx version &> /dev/null; then
  error "docker buildx not available. Ensure Docker >= 20.10"
  exit 1
fi

# ── Step 1: SYNC ────────────────────────────────────────────────────────────
step 1 "SYNC — Fetch & merge upstream"

info "Fetching upstream..."
git -C "$CORE_DIR" fetch upstream

CURRENT_BRANCH=$(git -C "$CORE_DIR" branch --show-current)
info "Merging upstream/main into $CURRENT_BRANCH..."

if ! git -C "$CORE_DIR" merge upstream/main --no-edit; then
  error "Merge conflict detected in $CORE_DIR"
  error ""
  error "Resolution steps:"
  error "  1. cd $CORE_DIR"
  error "  2. Resolve conflicts (git status, edit files)"
  error "  3. git add <resolved-files>"
  error "  4. git merge --continue"
  error "  5. Re-run: ./release.sh"
  exit 1
fi

success "Upstream synced"

# ── Step 2: DIFF ────────────────────────────────────────────────────────────
step 2 "DIFF — Check Docker-related changes"

info "Changes in goclaw-core since last commit (Docker-related):"
git -C "$CORE_DIR" diff HEAD~1 -- \
  Dockerfile docker-compose* entrypoint.sh nginx.conf \
  2>/dev/null || warn "No previous commit to diff against"

echo ""
info "Changes in goclaw-deploy:"
git -C "$DEPLOY_DIR" diff HEAD -- \
  Dockerfile entrypoint.sh nginx.conf docker-compose* \
  2>/dev/null || warn "No changes in deploy"

# ── Step 3: UPDATE (manual pause) ───────────────────────────────────────────
step 3 "UPDATE — Review & update deploy config"

warn "Review the changes above."
warn "If deploy configs (Dockerfile, entrypoint.sh, nginx.conf) need updating, do it now."
read -r -p "$(echo -e "${YELLOW}? ${NC}Press Enter to continue or Ctrl+C to abort... ")"

# ── Step 4: CLEAN ───────────────────────────────────────────────────────────
step 4 "CLEAN — Remove old containers & volumes"

info "Stopping and removing project containers..."
docker compose -f "$DEPLOY_DIR/$COMPOSE_BUILD" down -v --remove-orphans 2>/dev/null || true
docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" down -v --remove-orphans 2>/dev/null || true

success "Cleaned"

# ── Step 5: TEST BUILD ──────────────────────────────────────────────────────
step 5 "TEST — Build from source & health check"

COMPOSE_RUNNING="$COMPOSE_BUILD"
info "Building and starting with $COMPOSE_BUILD..."
docker compose -f "$DEPLOY_DIR/$COMPOSE_BUILD" up -d --build

# compose-build.yml maps 3000:8080, use longer timeout for cold builds
health_check "http://localhost:3000/health" 60 5

success "Build test passed"

# Stop test containers
docker compose -f "$DEPLOY_DIR/$COMPOSE_BUILD" down -v --remove-orphans
COMPOSE_RUNNING=""

# ── Step 6: TAG ─────────────────────────────────────────────────────────────
step 6 "TAG — Get version from goclaw-core"

VERSION=$(git -C "$CORE_DIR" describe --tags 2>/dev/null) || {
  error "Failed to get version from git tags."
  error "Ensure tags are fetched: git -C $CORE_DIR fetch upstream --tags"
  exit 1
}

if [[ -z "$VERSION" ]]; then
  error "Empty version string. No tags in repo?"
  exit 1
fi

if [[ "$VERSION" == *"dirty"* ]]; then
  error "Working tree is dirty: '$VERSION'"
  error "Commit or stash changes in $CORE_DIR first."
  exit 1
fi

info "Detected version: ${CYAN}${VERSION}${NC}"

# ── Step 7: BUILD + PUSH ────────────────────────────────────────────────────
step 7 "BUILD — Build & push to Docker Hub"

confirm "Push ${IMAGE}:${VERSION} to Docker Hub?"

info "Building image..."
if ! docker buildx build \
  --platform linux/amd64 \
  --build-context deploy="$DEPLOY_DIR" \
  -f "$DEPLOY_DIR/Dockerfile" \
  --build-arg VERSION="$VERSION" \
  -t "$IMAGE:$VERSION" \
  -t "$IMAGE:latest" \
  --push \
  "$CORE_DIR"; then
  error "Docker build or push failed"
  error "Check credentials: docker login"
  exit 1
fi

# Verify image is pullable
info "Verifying pushed image..."
if ! docker pull "$IMAGE:$VERSION" > /dev/null 2>&1; then
  error "Cannot pull $IMAGE:$VERSION — push may have partially failed"
  exit 1
fi

success "Pushed and verified ${IMAGE}:${VERSION}"

# ── Step 8: UPDATE TAGS ─────────────────────────────────────────────────────
step 8 "UPDATE — Write new tag into compose files"

IMAGE_ESCAPED=$(escape_sed "$IMAGE")
VERSION_ESCAPED=$(escape_sed "$VERSION")

for f in "$COMPOSE_PROD" "$COMPOSE_DOKPLOY"; do
  filepath="$DEPLOY_DIR/$f"
  if [[ -f "$filepath" ]]; then
    sed_i "s|image: ${IMAGE_ESCAPED}:.*|image: ${IMAGE}:${VERSION}|" "$filepath"
    success "Updated $f → ${VERSION}"
  else
    warn "$f not found, skipping"
  fi
done

# ── Step 9: SMOKE TEST ──────────────────────────────────────────────────────
step 9 "SMOKE — Pull image & verify"

COMPOSE_RUNNING="$COMPOSE_PROD"
info "Starting with pulled image ($COMPOSE_PROD)..."
docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" up -d

# compose.yml has no port mapping — check container health status directly
info "Waiting for goclaw container to be healthy..."
for i in $(seq 1 "$HEALTH_RETRIES"); do
  STATUS=$(docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" ps goclaw --format '{{.Health}}' 2>/dev/null || echo "")
  if [[ "$STATUS" == "healthy" ]]; then
    success "Smoke test passed (attempt $i/$HEALTH_RETRIES)"
    break
  fi
  if [[ $i -eq $HEALTH_RETRIES ]]; then
    error "Smoke test failed — goclaw container not healthy"
    docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" logs goclaw --tail=20
    exit 1
  fi
  echo -n "."
  sleep "$HEALTH_INTERVAL"
done

docker compose -f "$DEPLOY_DIR/$COMPOSE_PROD" down -v --remove-orphans
COMPOSE_RUNNING=""

success "Smoke test passed"

# ── Step 10: COMMIT ─────────────────────────────────────────────────────────
step 10 "COMMIT — Stage & commit changes"

info "Files to commit:"
git -C "$DEPLOY_DIR" diff --name-only
git -C "$DEPLOY_DIR" diff --staged --name-only

confirm "Commit release ${VERSION}?"

cd "$DEPLOY_DIR"
git add "$COMPOSE_PROD" "$COMPOSE_DOKPLOY"
git commit -m "release: update image to ${VERSION}"

success "Committed release ${VERSION}"

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Release ${VERSION} complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
info "Next: git push to deploy"
