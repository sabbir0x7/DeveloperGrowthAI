#!/usr/bin/env bash
# Script to build Flutter Web on Render.com Static Site

# Exit on error
set -e

# Go to frontend directory if not already there
cd frontend || true

echo "Downloading Flutter SDK..."
# Clone flutter to a temporary directory
if [ ! -d "flutter" ]; then
  git clone https://github.com/flutter/flutter.git -b stable
fi

# Add flutter to path
export PATH="$PATH:`pwd`/flutter/bin"

echo "Flutter version:"
flutter --version

echo "Enabling Web..."
flutter config --enable-web

echo "Getting dependencies..."
flutter pub get

echo "Building web app..."
flutter build web --release

echo "Build complete! Publish directory should be set to: frontend/build/web"
