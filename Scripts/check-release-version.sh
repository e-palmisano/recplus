#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 <tag> [project.yml path]" >&2
  exit 2
}

if [ $# -lt 1 ]; then
  usage
fi

TAG="$1"
PROJECT_YML="${2:-$(dirname "$0")/../project.yml}"

if [ ! -f "$PROJECT_YML" ]; then
  echo "error: project.yml not found at $PROJECT_YML" >&2
  exit 1
fi

TAG_VERSION="${TAG#v}"
PLIST_VERSION=$(grep -m1 'MARKETING_VERSION:' "$PROJECT_YML" | sed -E 's/.*MARKETING_VERSION: *"([^"]+)".*/\1/')

if [ -z "$PLIST_VERSION" ]; then
  echo "error: could not find MARKETING_VERSION in $PROJECT_YML" >&2
  exit 1
fi

if [ "$TAG_VERSION" != "$PLIST_VERSION" ]; then
  echo "error: tag version '$TAG_VERSION' does not match MARKETING_VERSION '$PLIST_VERSION' in $PROJECT_YML" >&2
  exit 1
fi

BUILD_VERSION=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed -E 's/.*CURRENT_PROJECT_VERSION: *"([^"]+)".*/\1/')

if [ "$TAG_VERSION" != "$BUILD_VERSION" ]; then
  echo "error: tag version '$TAG_VERSION' does not match CURRENT_PROJECT_VERSION '$BUILD_VERSION' in $PROJECT_YML" >&2
  exit 1
fi

echo "$PLIST_VERSION"
