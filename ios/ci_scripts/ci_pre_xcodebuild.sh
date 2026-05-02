#!/bin/sh
set -e

export PATH="$PATH:$HOME/flutter/bin"

# Ensure Flutter is on PATH for Xcode build phases
which flutter
flutter --version

echo "ci_pre_xcodebuild.sh completed successfully"
