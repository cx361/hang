#!/bin/sh
set -e

# Install Flutter
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# Make Flutter available system-wide for Xcode build phases
ln -sf $HOME/flutter/bin/flutter /usr/local/bin/flutter
ln -sf $HOME/flutter/bin/dart /usr/local/bin/dart

# Pre-cache iOS engine artifacts (required before pod install)
flutter precache --ios

# Get Flutter dependencies and generate Generated.xcconfig
cd $CI_PRIMARY_REPOSITORY_PATH
flutter pub get

# Install CocoaPods dependencies
cd ios
pod install --repo-update

echo "ci_post_clone.sh completed successfully"
