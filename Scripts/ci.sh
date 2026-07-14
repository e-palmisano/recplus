#!/bin/bash
# Single verification entrypoint: regenerates the project, builds the app,
# and runs the test suite. Used as the gate for every task and every release.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

# CODE_SIGNING_ALLOWED=NO: this build only needs to compile, not run or be
# distributed — avoids requiring a "Mac Development" cert on CI runners
# that only carry the Developer ID Application cert used for releases.
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build | tail -5

xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test | tail -20

echo "CI OK"
