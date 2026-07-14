#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 <current-tag> [repo-path]" >&2
  exit 2
}

if [ $# -lt 1 ]; then
  usage
fi

CURRENT_TAG="$1"
REPO_PATH="${2:-.}"

cd "$REPO_PATH"

PREV_TAG=$(git describe --tags --abbrev=0 "${CURRENT_TAG}^" 2>/dev/null || true)

if [ -n "$PREV_TAG" ]; then
  RANGE="$PREV_TAG..$CURRENT_TAG"
else
  RANGE="$CURRENT_TAG"
fi

COMMITS=$(git log "$RANGE" --pretty=format:'%s')

FEATS=$(echo "$COMMITS" | grep -E '^feat(\(.+\))?:' || true)
FIXES=$(echo "$COMMITS" | grep -E '^fix(\(.+\))?:' || true)
OTHERS=$(echo "$COMMITS" | grep -vE '^(feat|fix)(\(.+\))?:' || true)

print_section() {
  local title="$1"
  local items="$2"
  if [ -n "$items" ]; then
    echo "## $title"
    echo ""
    echo "$items" | sed -E 's/^[a-z]+(\([^)]+\))?: */- /'
    echo ""
  fi
}

print_section "Features" "$FEATS"
print_section "Fixes" "$FIXES"
print_section "Other" "$OTHERS"
