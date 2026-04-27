#!/usr/bin/env bash
# Pre-push safety scan for the klikit-partner public docs repo.
#
# Reads PreToolUse hook input on stdin. If the tool is `git push`, scans the
# diff that is about to be pushed for content patterns that look like internal
# leakage (real internal hostnames, JWTs, credentials, IPs, leftover TODO
# markers, etc.) and exits 2 with a stderr report on a hit. Exit 0 otherwise.
#
# Override: prefix the git push with LEAKAGE_OVERRIDE=1 to skip this check.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Only act on git push commands.
case "$COMMAND" in
  *"git push"*) ;;
  *) exit 0 ;;
esac

# Manual override path.
case "$COMMAND" in
  *"LEAKAGE_OVERRIDE=1"*) exit 0 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$REPO_ROOT" ]]; then
  exit 0
fi
cd "$REPO_ROOT"

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ -z "$BRANCH" || "$BRANCH" == "HEAD" ]]; then
  exit 0
fi

UPSTREAM="origin/$BRANCH"
# Pathspec excludes: things that don't deploy to the public site.
# (Claude Code settings, git metadata, the scanner script itself.)
EXCLUDES=(":!.claude/" ":!.git/" ":!.gitignore")

if git rev-parse --verify --quiet "$UPSTREAM" >/dev/null; then
  DIFF=$(git diff "$UPSTREAM..HEAD" -- . "${EXCLUDES[@]}" 2>/dev/null || true)
else
  # First push of this branch — scan everything new on it.
  DIFF=$(git log -p --no-merges HEAD -- . "${EXCLUDES[@]}" 2>/dev/null || true)
fi

# Also include staged-but-uncommitted (catches the sneaky `git commit && git push`).
STAGED=$(git diff --cached -- . "${EXCLUDES[@]}" 2>/dev/null || true)
DIFF="$DIFF
$STAGED"

if [[ -z "${DIFF// }" ]]; then
  exit 0
fi

# Only consider added lines (skip diff metadata).
ADDED=$(printf '%s\n' "$DIFF" | grep -E '^\+' | grep -vE '^\+\+\+' || true)
if [[ -z "$ADDED" ]]; then
  exit 0
fi

# --- patterns -------------------------------------------------------------
# Each pattern is one extended regex. Hits are reported with their label.

declare -a LABELS PATTERNS
add_pattern() { LABELS+=("$1"); PATTERNS+=("$2"); }

add_pattern "JWT-shaped tokens"                 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
add_pattern "Internal-looking hostnames"        '(\.internal\b|\.local\b|\.k8s\.|\.cluster\.|internal-[a-z0-9]+\.|admin\.klikit|staging\.klikit|dev-api\.klikit|api-int\.|internal-api\.|\.intra\.)'
add_pattern "Raw IPv4 addresses"                '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)'
add_pattern "Credential-shaped assignments"     '(secret|password|passwd|api[-_]?key|access[-_]?key|private[-_]?key|bearer|client[-_]?secret|webhook[-_]?secret)[[:space:]]*[:=][[:space:]]*[\"'\'']?[A-Za-z0-9+/=_-]{16,}'
add_pattern "AWS-style key IDs"                 '(AKIA|ASIA)[A-Z0-9]{16,}'
add_pattern "Leftover ship-blocker markers"     '\b(TODO|XXX|FIXME|HACK)\b|do not ship|don.?t ship|internal only|CONFIDENTIAL|//[[:space:]]*internal:'

# --- run ------------------------------------------------------------------
HITS=""
HIT_COUNT=0
for i in "${!PATTERNS[@]}"; do
  label="${LABELS[$i]}"
  pat="${PATTERNS[$i]}"
  matches=$(printf '%s\n' "$ADDED" | grep -nE "$pat" | head -5 || true)
  if [[ -n "$matches" ]]; then
    HIT_COUNT=$((HIT_COUNT + 1))
    HITS="${HITS}
[$label]
$matches
"
  fi
done

if [[ $HIT_COUNT -gt 0 ]]; then
  {
    echo "🛑 PUSH BLOCKED — public-docs safety check found $HIT_COUNT category/categories of suspicious content in the diff being pushed:"
    echo
    printf '%s\n' "$HITS"
    echo "---"
    echo "If these are false positives, retry with: LEAKAGE_OVERRIDE=1 $COMMAND"
    echo "If they are real, fix the diff before pushing. This repo deploys to a public docs site."
  } >&2
  exit 2
fi

exit 0
