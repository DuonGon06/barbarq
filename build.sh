#!/bin/bash
# build.sh - Build BBQQHook.dylib KHÔNG cần Theos, chỉ cần Xcode trên Mac
# Chạy: chmod +x build.sh && ./build.sh
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "[*] SDK: $SDK"

# Nếu có libs/libdobby.a thì link vào, không có vẫn build được bản test load
DOBBY_FLAGS=""
if [ -f "libs/libdobby.a" ]; then
  DOBBY_FLAGS="-Iinclude -Llibs -ldobby"
  echo "[*] Tim thay Dobby, se link hook"
fi

xcrun -sdk iphoneos clang++ -dynamiclib \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=12.0 \
  -framework Foundation \
  -install_name "@rpath/BBQQHook.dylib" \
  $DOBBY_FLAGS \
  -o BBQQHook.dylib \
  BBQQHook.mm

echo "[+] Xong: BBQQHook.dylib"
file BBQQHook.dylib
otool -L BBQQHook.dylib

# Ký ad-hoc (bắt buộc, nếu không dyld sẽ từ chối load trên máy non-jailbreak)
# Khi tiêm bằng ESign/Sideloadly/app ký, bước này sẽ được ký lại cùng app - vẫn nên ký trước
ldid -S BBQQHook.dylib 2>/dev/null || codesign -f -s - BBQQHook.dylib
echo "[+] Da ky ad-hoc. Sang buoc tiem: ./inject.sh <file.ipa>"
