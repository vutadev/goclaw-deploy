#!/bin/sh
set -e

# ── Fix volume ownership (root context only) ──
# Docker named volumes may initialize as root-owned.
# Ensure goclaw user owns all writable directories.
if [ "$(id -u)" = "0" ]; then
  # Fix workspace volume permissions first (Docker volumes may have wrong ownership)
  chown goclaw:goclaw /app/workspace 2>/dev/null || true
  chmod 755 /app/workspace 2>/dev/null || true

  # Workspace volume — create teams dir if missing
  mkdir -p /app/workspace/teams

  # Check if goclaw can write, if not use chmod g+w
  if ! su-exec goclaw test -w /app/workspace/teams 2>/dev/null; then
    echo "Note: Fixing permissions for /app/workspace/teams"
    chmod -R g+w /app/workspace/teams 2>/dev/null || true
    chmod g+s /app/workspace/teams 2>/dev/null || true  # SetGID for new files
  fi

  # Ensure readable/executable by all
  chmod 755 /app/workspace 2>/dev/null || true

  # Data volume — goclaw owns root and direct children (except .runtime)
  chown goclaw:goclaw /app/data || echo "Warning: data chown failed (may already be correct)"
  find /app/data -maxdepth 1 ! -name .runtime ! -name data -exec chown goclaw:goclaw {} \; 2>/dev/null || true
  chown -R goclaw:goclaw /app/data/skills 2>/dev/null || true

  # Agent workspace directory
  chown -R goclaw:goclaw /app/.goclaw 2>/dev/null || true
fi

# ── Runtime directory setup ──
# Rootfs may be read-only; /app/data is a writable Docker volume.
RUNTIME_DIR="/app/data/.runtime"
mkdir -p "$RUNTIME_DIR/pip" "$RUNTIME_DIR/npm-global/lib" "$RUNTIME_DIR/pip-cache" || true

# Fix .runtime ownership for split root/goclaw access.
# .runtime itself must be root-owned so pkg-helper (root) can write apk-packages.
# Subdirs pip/, npm-global/, pip-cache/ must be goclaw-owned for runtime installs.
if [ "$(id -u)" = "0" ] && [ -d "$RUNTIME_DIR" ]; then
  chown root:goclaw "$RUNTIME_DIR" 2>/dev/null || true
  chmod 0750 "$RUNTIME_DIR" 2>/dev/null || true
  chown -R goclaw:goclaw "$RUNTIME_DIR/pip" "$RUNTIME_DIR/npm-global" "$RUNTIME_DIR/pip-cache" 2>/dev/null || true
fi

# ── Python/Node writable install paths ──
export PYTHONPATH="$RUNTIME_DIR/pip:${PYTHONPATH:-}"
export PIP_TARGET="$RUNTIME_DIR/pip"
export PIP_BREAK_SYSTEM_PACKAGES=1
export PIP_CACHE_DIR="$RUNTIME_DIR/pip-cache"

export NPM_CONFIG_PREFIX="$RUNTIME_DIR/npm-global"
export NODE_PATH="/usr/local/lib/node_modules:$RUNTIME_DIR/npm-global/lib/node_modules:${NODE_PATH:-}"
export PATH="$RUNTIME_DIR/npm-global/bin:$RUNTIME_DIR/pip/bin:$PATH"

# ── Re-install persisted system packages ──
APK_LIST="$RUNTIME_DIR/apk-packages"
if [ "$(id -u)" = "0" ]; then
  touch "$APK_LIST" 2>/dev/null || true
  chown root:goclaw "$APK_LIST" 2>/dev/null || true
  chmod 0640 "$APK_LIST" 2>/dev/null || true
fi
if [ -f "$APK_LIST" ] && [ -s "$APK_LIST" ]; then
  echo "Re-installing persisted system packages..."
  VALID_PKGS=""
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    pkg="$(printf '%s' "$pkg" | tr -d '[:space:]')"
    case "$pkg" in
      [a-zA-Z0-9@]*) VALID_PKGS="$VALID_PKGS $pkg" ;;
      "") ;;
      *) echo "WARNING: skipping invalid package: $pkg" ;;
    esac
  done < "$APK_LIST"
  if [ -n "$VALID_PKGS" ]; then
    # shellcheck disable=SC2086
    apk add --no-cache $VALID_PKGS 2>/dev/null || \
      echo "Warning: some packages failed to install"
  fi
fi

# ── Start pkg-helper (root-privileged package installer) ──
if [ -x /app/pkg-helper ] && [ "$(id -u)" = "0" ]; then
  /app/pkg-helper &
  PKG_PID=$!
  for _i in 1 2 3 4; do
    [ -S /tmp/pkg.sock ] && break
    sleep 0.5
  done
  if ! [ -S /tmp/pkg.sock ]; then
    echo "ERROR: pkg-helper failed to start (PID $PKG_PID)"
    kill "$PKG_PID" 2>/dev/null || true
  fi
fi

# ── Helpers ──
run_as_goclaw() {
  if command -v su-exec >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    su-exec goclaw "$@"
  else
    "$@"
  fi
}

# ── Main ──
case "${1:-serve}" in
    serve)
        # Auto-upgrade (schema migrations + data hooks) before starting
        if [ -n "$GOCLAW_POSTGRES_DSN" ]; then
            echo "Running database upgrade..."
            run_as_goclaw /app/goclaw upgrade || \
                echo "Upgrade warning (may already be up-to-date)"
        fi

        # Start goclaw (as goclaw user)
        # Note: cannot use exec with shell function, use su-exec directly
        if command -v su-exec >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
            exec su-exec goclaw /app/goclaw
        else
            exec /app/goclaw
        fi
        ;;
    upgrade)
        shift
        run_as_goclaw /app/goclaw upgrade "$@"
        ;;
    migrate)
        shift
        run_as_goclaw /app/goclaw migrate "$@"
        ;;
    onboard)
        run_as_goclaw /app/goclaw onboard
        ;;
    version)
        run_as_goclaw /app/goclaw version
        ;;
    *)
        run_as_goclaw /app/goclaw "$@"
        ;;
esac
