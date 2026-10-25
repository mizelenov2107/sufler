#!/bin/bash
# Сборка суфлёра в приложение. Запуск: ./sborka.sh
set -e
cd "$(dirname "$0")"

IMYA="Суфлёр"
APP="build/$IMYA.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Суфлёр</string>
  <key>CFBundleDisplayName</key><string>Суфлёр</string>
  <key>CFBundleExecutable</key><string>sufler</string>
  <key>CFBundleIdentifier</key><string>local.sufler</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Суфлёр слушает речь, чтобы вести текст вслед за вами.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Распознавание речи нужно, чтобы подсвечивать место в тексте.</string>
</dict>
</plist>
PLIST

swiftc -O \
  Sources/Skript.swift Sources/Sovpadenie.swift Sources/Sluh.swift Sources/Vybor.swift \
  Sources/Okno.swift Sources/main.swift \
  -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation \
  -framework Carbon \
  -o "$APP/Contents/MacOS/sufler"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "собрано: $APP"
