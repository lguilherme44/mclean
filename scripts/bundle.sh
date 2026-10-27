#!/usr/bin/env bash
# Builds dist/MClean.app (release, ad-hoc signed). Usage: scripts/bundle.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MCleanApp
app=dist/MClean.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/MCleanApp "$app/Contents/MacOS/MClean"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift Resources
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.lellis.mclean</string>
  <key>CFBundleName</key><string>MClean</string>
  <key>CFBundleDisplayName</key><string>MClean</string>
  <key>CFBundleExecutable</key><string>MClean</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A STABLE identity keeps macOS permissions (removable volumes, Full Disk Access) across rebuilds:
# with ad-hoc signing every build is a "new app" and macOS asks again, blocking until answered.
identity="${MCLEAN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" "$app"
else
  echo "aviso: sem certificado de desenvolvimento; assinatura ad-hoc (o macOS vai pedir permissões a cada build)"
  codesign --force --sign - "$app"
fi
codesign -dv "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | head -2 || true
echo "ok: $app"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "$HOME/Applications/MClean.app"
  mkdir -p "$HOME/Applications"
  cp -R "$app" "$HOME/Applications/"
  echo "instalado em ~/Applications/MClean.app"
fi
