# Fix: Skills Rescan Permission Denied

## Issue

The goclaw binary (v2.42.3) failed during skill rescan with:
```
mkdir /home/goclaw: permission denied
```

This affected all bundled skills requiring re-copying: docx, pdf, pptx, skill-creator, xlsx.

## Root Cause

The goclaw user is created with `-h /app` (Dockerfile:56), making `/etc/passwd` home = `/app`.

However, the goclaw binary resolves its skills-store path as `/home/goclaw/.goclaw/skills-store/` — this directory didn't exist and the goclaw user couldn't create it.

Error flow:
```
rescan → managed path: /home/goclaw/.goclaw/skills-store/{slug}/{ver}/scripts/
       → missing → fallback to bundled-skills/{slug}
       → tries to re-copy bundled → managed
       → mkdir /home/goclaw → PERMISSION DENIED
```

## Solution

Two-file change to create `/home/goclaw/.goclaw` at build time + ensure ownership at runtime:

### 1. `Dockerfile` (after line 56)

```dockerfile
# Skills-store home directory (binary resolves to /home/goclaw/.goclaw)
RUN mkdir -p /home/goclaw/.goclaw && chown -R goclaw:goclaw /home/goclaw
```

### 2. `entrypoint.sh` (after line 23, in root block)

```sh
# Skills-store home — binary writes to /home/goclaw/.goclaw/skills-store/
mkdir -p /home/goclaw/.goclaw && chown -R goclaw:goclaw /home/goclaw
```

## Verification

```bash
# No permission errors
docker compose logs goclaw 2>&1 | grep "permission denied"
# Output: (empty)

# Directory exists with correct ownership
docker compose exec goclaw ls -la /home/goclaw/
# Output: drwxr-xr-x goclaw goclaw .goclaw

# Service running with all skills seeded
docker compose logs goclaw --tail=20
# Output: skill seeded: docx, pdf, pptx, skill-creator, xlsx (5/5)
```

## Related

Same pattern as prior workspace fix documented in `fix-workspace-permissions.md`.

## Files Modified

- `Dockerfile` — Added RUN layer after adduser to create `/home/goclaw/.goclaw`
- `entrypoint.sh` — Added mkdir + chown in root block for runtime directory creation

## Status

✅ Fixed in v2.42.3+ (2026-03-29)
