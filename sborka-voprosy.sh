#!/bin/bash
# Сборка «Суфлёр · вопросы»: ответы на вопросы по материалам доклада по звуку созвона. Запуск: ./sborka-voprosy.sh
set -e
cd "$(dirname "$0")"

APP="build/Суфлёр · вопросы.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Суфлёр · вопросы</string>
  <key>CFBundleDisplayName</key><string>Суфлёр · вопросы</string>
  <key>CFBundleExecutable</key><string>sufler-voprosy</string>
  <key>CFBundleIdentifier</key><string>local.sufler.voprosy</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Суфлёр слушает вопросы по докладу, если звук созвона недоступен.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Распознавание речи превращает вопрос в текст.</string>
</dict>
</plist>
PLIST

swiftc -O -target arm64-apple-macos14.0 Voprosy/main.swift \
  -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation \
  -framework ScreenCaptureKit -framework CoreMedia -framework Carbon \
  -o "$APP/Contents/MacOS/sufler-voprosy" 2>&1 | grep -v "^$" || true
test -x "$APP/Contents/MacOS/sufler-voprosy"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "собрано: $APP"
