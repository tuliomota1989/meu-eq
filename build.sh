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
codesign --force --sign - "$APP"
echo "Pronto: $PWD/$APP"
