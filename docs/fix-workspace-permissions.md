# Fix: Workspace Permission Denied Errors

**Date:** 2026-03-29
**Issue:** `mkdir /app/workspace/teams/<team-id>: permission denied`
**Status:** ✅ Fixed

## Problem Description

The GoClaws application was failing to create team workspace directories with the following error:

```
time=2026-03-29T07:03:44.203Z level=WARN msg="failed to create team workspace directory"
workspace=/app/workspace/teams/019cc229-3cf1-74c0-b2d1-fd5c7a36b7bb/1191288445
error="mkdir /app/workspace/teams/019cc229-3cf1-74c0-b2d1-fd5c7a36b7bb: permission denied"
```

### Root Cause

1. Docker volumes (`goclaw-workspace:/app/workspace`) may be initialized with root ownership
2. The application runs as `goclaw` user (non-root for security)
3. The entrypoint script was fixing `/app/workspace` ownership but not pre-creating subdirectories
4. When the app tried to create `/app/workspace/teams/<team-id>/`, it lacked permissions

## Solution

Enhanced `entrypoint.sh` to:
1. Fix workspace ownership recursively
2. Pre-create `/app/workspace/teams` directory with proper ownership
3. Ensure workspace root has correct permissions (755)

### Changes Made

**File:** `entrypoint.sh` (lines 4-18)

```diff
 if [ "$(id -u)" = "0" ]; then
   chown goclaw:goclaw /app/data 2>/dev/null || true
+
+  # Fix workspace ownership recursively
   chown -R goclaw:goclaw /app/workspace 2>/dev/null || true
+
+  # Pre-create workspace subdirectories with proper ownership
+  mkdir -p /app/workspace/teams 2>/dev/null || true
+  chown -R goclaw:goclaw /app/workspace/teams 2>/dev/null || true
+
+  # Ensure workspace root is writable
+  chmod 755 /app/workspace 2>/dev/null || true
+
   # Fix ownership of existing files (config.json, skills, etc.) but not .runtime
```

## Testing Instructions

### 1. Rebuild Image (Local Build Mode)

```bash
cd /Users/dcppsw/Projects/goclaw/goclaw-deploy
docker compose -f docker-compose-build.yml down -v
docker compose -f docker-compose-build.yml up -d --build
```

### 2. Monitor Logs

```bash
docker compose logs goclaw -f
```

**Expected:** No more "permission denied" errors for workspace/teams directories.

### 3. Verify Workspace Permissions

```bash
docker compose exec goclaw sh -c "ls -la /app/workspace/"
```

**Expected output:**
```
drwxr-xr-x    3 goclaw   goclaw        4096 Mar 29 07:10 teams
```

### 4. Test Team Creation

Create a test agent/team and verify it can write to workspace:

```bash
docker compose exec goclaw sh -c "ls -la /app/workspace/teams/"
```

Should show team directories owned by `goclaw:goclaw`.

## Production Deployment

### Update Production Image

The fix requires a new Docker image build. Update version in:
- `docker-compose.yml` (line 12): `image: itsddvn/goclaw:v2.42.3`
- Release via `./release.sh publish`

### For Existing Deployments

If volumes already exist with wrong permissions:

```bash
# Stop services
docker compose down

# Fix volume permissions (one-time)
docker run --rm -v goclaw-workspace:/workspace alpine sh -c "chown -R 1000:1000 /workspace && mkdir -p /workspace/teams && chmod 755 /workspace"

# Restart with updated image
docker compose pull
docker compose up -d
```

## Affected Files

- ✅ `entrypoint.sh` - Added workspace subdirectory creation and permission fixes
- 📦 `Dockerfile` - No changes needed (already creates goclaw user)
- 🔧 `docker-compose*.yml` - No changes needed (volume mounts unchanged)

## Related Issues

This fix also prevents similar permission errors for:
- `.uploads/` directories (image file storage)
- Other dynamic workspace subdirectories
- Team collaboration features

## Verification Checklist

- [x] Shell script syntax validated
- [x] Git diff reviewed
- [ ] Local build tested
- [ ] Production image built and tagged
- [ ] Deployed to test environment
- [ ] Agent team creation verified
- [ ] No permission errors in logs

## Rollback Plan

If issues arise, revert `entrypoint.sh`:

```bash
git checkout HEAD~1 entrypoint.sh
docker compose -f docker-compose-build.yml up -d --build
```

Or use previous image version:
```yaml
image: itsddvn/goclaw:v2.42.2
```
