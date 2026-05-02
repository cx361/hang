#!/bin/sh
set -e

# Install Flutter
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# Get Flutter dependencies
cd $CI_PRIMARY_REPOSITORY_PATH
flutter pub get

# Install CocoaPods dependencies
cd ios
pod install

echo "ci_post_clone.sh completed successfully"
