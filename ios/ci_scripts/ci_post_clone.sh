#!/bin/sh
set -e

# Install Flutter
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# Make Flutter available system-wide for Xcode build phases
ln -sf $HOME/flutter/bin/flutter /usr/local/bin/flutter
ln -sf $HOME/flutter/bin/dart /usr/local/bin/dart

# Pre-cache iOS engine artifacts
flutter precache --ios

# Build Flutter iOS (--no-codesign = no device needed)
# This generates Generated.xcconfig and all required Flutter build artifacts
cd $CI_PRIMARY_REPOSITORY_PATH
flutter build ios --release --no-codesign

# Install CocoaPods dependencies
cd ios
pod install --repo-update

echo "ci_post_clone.sh completed successfully"
