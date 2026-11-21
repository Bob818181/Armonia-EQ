#!/bin/bash
# Compila Armonia EQ e crea build/ArmoniaEQ.app (universale Apple Silicon + Intel se possibile).
# Requisiti: Xcode 13.2 o successivo (su Monterey: Xcode 13.2–14.2).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ArmoniaEQ.app"
mkdir -p build

echo "==> Test del motore DSP"
cc -O2 -DAEQ_NO_SAFETY_CLAMP -I Sources/ArmoniaDSP/include Tests/dsp_test.c \
   Sources/ArmoniaDSP/dsp.c Sources/ArmoniaDSP/presets.c -lm -o build/dsp_test
build/dsp_test > build/dsp_test.log && tail -n 1 build/dsp_test.log

echo "==> Compilazione (release)"
if swift build -c release --arch arm64 --arch x86_64; then
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    echo "!! Build universale non disponibile (serve Xcode completo): compilo per l'architettura di questo Mac"
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi

echo "==> Creazione del bundle $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ArmoniaEQ" "$APP/Contents/MacOS/ArmoniaEQ"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Firma ad-hoc"
codesign --force --sign - "$APP"

echo "==> Verifiche"
lipo -archs "$APP/Contents/MacOS/ArmoniaEQ"
(vtool -show-build "$APP/Contents/MacOS/ArmoniaEQ" 2>/dev/null || otool -l "$APP/Contents/MacOS/ArmoniaEQ") | grep -E "minos|platform|version" | sort -u
echo "Fatto: $APP"
