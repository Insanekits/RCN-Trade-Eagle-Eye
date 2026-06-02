#!/usr/bin/env bash
# sync.sh — Copy the local OneDrive-synced PCH workbook into the repo,
# commit, and push to main. Vercel auto-deploys from main, so within
# ~30 seconds the dashboard at your Vercel URL is showing the new data.
#
# Usage:
#   ./scripts/sync.sh                          # uses RCN_MIS_SOURCE from sync.env
#   ./scripts/sync.sh /path/to/your.xlsx       # one-off override
#   ./scripts/sync.sh --no-push                # commit but don't push
#   ./scripts/sync.sh --dry-run                # show plan, change nothing
#
# Configuration (scripts/sync.env, gitignored):
#   RCN_MIS_SOURCE   absolute path to the .xlsx in your OneDrive folder (required)
#   RCN_MIS_DEST     repo-relative destination path (default: data/rcn-mis.xlsx)
#   SYNC_BRANCH  branch to push to (default: main)

set -euo pipefail

# ------------------------------------------------------------ paths & config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/sync.env"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$CONFIG_FILE"; set +a
fi

# ------------------------------------------------------------ flag parsing
SOURCE_ARG=""
NO_PUSH=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-push)  NO_PUSH=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    --help|-h)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      if [ -z "$SOURCE_ARG" ]; then SOURCE_ARG="$arg"; fi
      ;;
  esac
done

SOURCE="${SOURCE_ARG:-${RCN_MIS_SOURCE:-}}"
DEST_REL="${RCN_MIS_DEST:-data/rcn-mis.xlsx}"
DEST_ABS="$REPO_DIR/$DEST_REL"
BRANCH="${SYNC_BRANCH:-main}"

# ------------------------------------------------------------ small helpers
log()  { printf "  %s\n" "$*"; }
step() { printf "\n▶ %s\n" "$*"; }
err()  { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

human_size() {
  local bytes=$1
  if   [ "$bytes" -ge 1048576 ]; then awk -v b="$bytes" 'BEGIN{printf "%.1f MB", b/1048576}'
  elif [ "$bytes" -ge 1024 ];    then awk -v b="$bytes" 'BEGIN{printf "%.1f MB", b/1024}'
  else printf "%d B" "$bytes"
  fi
}

# ------------------------------------------------------------ validate source
if [ -z "$SOURCE" ]; then
  cat <<EOF >&2

ERROR: No source path provided.

Either:
  1. Create scripts/sync.env (copy scripts/sync.env.example), set RCN_MIS_SOURCE
  2. Or pass the path as the first argument:
       ./scripts/sync.sh "/Users/$(whoami)/Library/CloudStorage/OneDrive-YourCo/PCH.xlsx"

EOF
  exit 1
fi

# Expand ~ if present
SOURCE="${SOURCE/#\~/$HOME}"

if [ ! -f "$SOURCE" ]; then
  err "Source file not found:
    $SOURCE
  Hint: open it once in Finder/Explorer to make sure OneDrive has downloaded
  the file locally (not just kept it 'online only')."
fi

# ------------------------------------------------------------ size guard (GitHub: 100 MB hard, 50 MB warn)
SIZE_BYTES=$(stat -f%z "$SOURCE" 2>/dev/null || stat -c%s "$SOURCE")
SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
if [ "$SIZE_MB" -gt 100 ]; then
  err "File is ${SIZE_MB} MB — exceeds GitHub's 100 MB file limit. Use Git LFS or shrink the workbook."
fi
if [ "$SIZE_MB" -gt 50 ]; then
  log "Warning: file is ${SIZE_MB} MB; GitHub recommends keeping files under 50 MB."
fi

# ------------------------------------------------------------ validate repo
cd "$REPO_DIR"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "$REPO_DIR is not a git repository.
  Run inside this folder once:
    git init && git remote add origin <your GitHub repo URL> && git fetch origin"
fi
if [ "$NO_PUSH" -eq 0 ] && ! git remote get-url origin >/dev/null 2>&1; then
  err "No 'origin' remote configured. Add one with:
    git remote add origin <your GitHub repo URL>"
fi

# ------------------------------------------------------------ summary
step "Plan"
log "Source:       $SOURCE  ($(human_size "$SIZE_BYTES"))"
log "Destination:  $DEST_REL"
log "Repo:         $REPO_DIR"
log "Branch:       $BRANCH"
log "Push:         $([ "$NO_PUSH" -eq 1 ] && echo no || echo yes)"
[ "$DRY_RUN" -eq 1 ] && { log "Dry run — nothing was changed."; exit 0; }

# ------------------------------------------------------------ copy
step "Copying workbook into repo"
mkdir -p "$(dirname "$DEST_ABS")"
cp "$SOURCE" "$DEST_ABS"
log "Wrote $DEST_REL"

# ------------------------------------------------------------ branch + pull
step "Syncing git branch $BRANCH"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  log "Switching from '$CURRENT_BRANCH' to '$BRANCH'"
  git checkout "$BRANCH"
fi

if git remote get-url origin >/dev/null 2>&1; then
  if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    log "Pulling latest from origin/$BRANCH (rebase)…"
    git pull --rebase origin "$BRANCH"
  else
    log "Remote branch origin/$BRANCH does not exist yet — will create on push."
  fi
fi

# ------------------------------------------------------------ stage + diff check
git add "$DEST_REL"
if git diff --cached --quiet; then
  log "No changes detected — workbook is identical to what's already on $BRANCH."
  exit 0
fi

# ------------------------------------------------------------ commit
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S %Z")
SOURCE_NAME=$(basename "$SOURCE")
COMMIT_MSG="data: sync ${SOURCE_NAME} (${TIMESTAMP})"

step "Committing"
log "$COMMIT_MSG"
git commit -m "$COMMIT_MSG" -- "$DEST_REL"

# ------------------------------------------------------------ push
if [ "$NO_PUSH" -eq 1 ]; then
  log "--no-push set; commit stays local."
  exit 0
fi

step "Pushing to origin/$BRANCH"
# -u just in case the local branch doesn't track yet.
git push -u origin "$BRANCH"

cat <<EOF

✓ Done. Vercel should redeploy in ~20–60 seconds.
  Watch progress at: https://vercel.com/dashboard

  Once the build turns green, refresh your dashboard URL and the new data
  will appear automatically.

EOF

