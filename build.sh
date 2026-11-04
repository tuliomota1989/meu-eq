#!/bin/bash
# Compila e monta o MeuEQ.app nesta pasta. Só precisa das Command Line Tools (sem Xcode).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=MeuEQ.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeuEQ "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

# A imagem vai para dentro do app e vira o ícone (o original tem 512 px, então o ícone para aí).
mkdir -p "$APP/Contents/Resources"
cp assets/mascote.png "$APP/Contents/Resources/"
ICONSET=$(mktemp -d)/MeuEQ.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256; do
    sips -z $s $s assets/mascote.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) assets/mascote.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/MeuEQ.icns"

codesign --force --sign - "$APP"
echo "Pronto: $PWD/$APP"
