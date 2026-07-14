#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 <app-path> <volume-name> <output-dmg-path>" >&2
  exit 2
}

if [ $# -lt 3 ]; then
  usage
fi

APP_PATH="$1"
VOLUME_NAME="$2"
OUTPUT_DMG="$3"

if [ ! -d "$APP_PATH" ]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUTPUT_DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDZO "$OUTPUT_DMG" >/dev/null

echo "$OUTPUT_DMG"
