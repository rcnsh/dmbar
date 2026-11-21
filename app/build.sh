#!/bin/sh
# Builds build/dmbar.app: the Swift app with the Go daemon inside it.
#   ./build.sh           build
#   ./build.sh install   build, copy to /Applications and open
set -eu
cd "$(dirname "$0")"

swift build -c release --arch arm64
OUT="$(swift build -c release --arch arm64 --show-bin-path)"

APP=build/dmbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Dmbar" "$APP/Contents/MacOS/Dmbar"
# The daemon sits beside the executable, where Bundle.url(forAuxiliaryExecutable:) looks.
(cd .. && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o "app/$APP/Contents/MacOS/dmbard" ./cmd/dmbard)
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the Developer ID when it is in the keychain, else ad hoc. A stable
# identity keeps the notification and login-item permissions across rebuilds.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
sign() { codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$@"; }
sign --identifier sh.rcn.dmbar.dmbard "$APP/Contents/MacOS/dmbard"
sign --identifier sh.rcn.dmbar "$APP"
echo "built $APP (signed: ${SIGN_IDENTITY:-ad hoc})"

if [ "${1:-}" = install ]; then
  pkill -x Dmbar 2>/dev/null || true
  rm -rf /Applications/dmbar.app
  cp -R "$APP" /Applications/dmbar.app
  open /Applications/dmbar.app
  echo "installed /Applications/dmbar.app"
fi
