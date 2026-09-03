#!/usr/bin/env bash
set -euo pipefail

# 배포 가능한 OpenUsage.app 빌드, Developer ID 서명·공증 후 DMG 생성.
# 앱은 Apple Silicon과 Intel Mac에서 모두 실행 가능한 universal binary(arm64 + x86_64), DMG만 출력.
# appcast는 release.yml의 Sparkle generate_appcast가 별도로 생성하며 EdDSA key로 DMG 서명 후
# appcast.xml 작성·갱신. 동일한 환경 변수로 CI(release.yml)와 로컬 Mac에서 실행 가능.
# GitHub push는 수행하지 않음.
#
# 필수 환경 변수:
#   CODESIGN_IDENTITY            Developer ID Application ID(이름 또는 hash)
#   ICLOUD_PROVISIONING_PROFILE  운영 iCloud container용 Developer ID provisioning profile
#   SPARKLE_PUBLIC_KEY           Info.plist의 SUPublicEDKey에 넣을 base64 EdDSA public key.
#                                서명용 private key와 일치할 때만 generate_appcast가 DMG에 서명
#   OPENUSAGE_TAG                릴리스 태그(예: v0.10.0)
# 선택 환경 변수:
#   OPENUSAGE_BUILD              단조 증가하는 CFBundleVersion. 기본값은 git commit 수
#   FEED_URL                     앱에 넣을 appcast URL. 기본값은 GitHub Pages project URL
#   공증 인증 정보: NOTARY_APPLE_ID / NOTARY_APP_PASSWORD / NOTARY_TEAM_ID
#                                notarytool용 Apple ID, 앱 전용 비밀번호, team ID.
#                                세 값을 모두 지정하면 앱과 DMG 공증·staple
#   ALLOW_UNNOTARIZED=1          로컬 dry run에서 공증 생략.
#                                미지정 시 공증 정보 누락을 오류로 처리해 CI의 미공증 빌드 배포 차단

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/script/version.sh"

: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to your Developer ID Application identity}"
: "${ICLOUD_PROVISIONING_PROFILE:?set ICLOUD_PROVISIONING_PROFILE to the iCloud provisioning profile path}"
: "${SPARKLE_PUBLIC_KEY:?set SPARKLE_PUBLIC_KEY to your base64 EdDSA public key}"
: "${OPENUSAGE_TAG:?set OPENUSAGE_TAG, e.g. v0.10.0}"

APP_NAME="OpenUsage"
BUNDLE_ID="com.kimchanhyung98.openusage"
MIN_SYSTEM_VERSION="15.0"
VERSION="$(openusage_version_from_tag "$OPENUSAGE_TAG")"
# CFBundleShortVersionString에 pre-release 접미사를 포함한 전체 버전(예: "0.10.0-beta.1") 저장.
# Sparkle 업데이트 안내와 앱 footer/About에 표시되는 문자열이므로 항상 동일해야 함.
# Sparkle은 이 문자열이 아닌 아래 단조 증가 commit 수인 CFBundleVersion으로 빌드 비교.
# Developer ID 공증은 숫자 형식을 요구하지 않음(Sparkle 문서의 beta short version 예: "2.0b1").
BUILD="${OPENUSAGE_BUILD:-$(git rev-list --count HEAD)}"
FEED_URL="${FEED_URL:-https://openusage.chanhyung.kim/appcast.xml}"
DMG_NAME="$APP_NAME-$VERSION.dmg"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_BINARY="$APP_HELPERS/openusage"
DMG_PATH="$DIST_DIR/$DMG_NAME"
# crash symbolication용 dSYM으로 release.yml에서 PostHog에 업로드.
# posthog-cli의 `dsym upload --directory`와 Sparkle 모두 단일 경로가 아닌 bundle 디렉터리를 요구.
DSYM_DIR="$DIST_DIR/dSYMs"
APP_DSYM="$DSYM_DIR/$APP_NAME.app.dSYM"
ENTITLEMENTS_TEMPLATE="$ROOT_DIR/script/OpenUsage.release.entitlements.plist"
ENTITLEMENTS="$DIST_DIR/OpenUsage.release.resolved.entitlements.plist"

# 공증 여부를 사전 결정. CI는 항상 공증 인증 정보 제공.
# 로컬 dry run은 ALLOW_UNNOTARIZED=1로 생략 가능하며 해당 빌드는 다른 Mac의 Gatekeeper에 차단됨.
# 명시적 생략 없이 인증 정보가 누락되면 오류 처리해 CI의 미공증 DMG 배포 차단.
NOTARIZE=0
if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_APP_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
  NOTARIZE=1
elif [ "${ALLOW_UNNOTARIZED:-}" = "1" ]; then
  echo "WARNING: ALLOW_UNNOTARIZED=1 — build will NOT be notarized (other Macs will block it)." >&2
else
  echo "Notarization creds missing (NOTARY_APPLE_ID / NOTARY_APP_PASSWORD / NOTARY_TEAM_ID)." >&2
  echo "Set them, or set ALLOW_UNNOTARIZED=1 for a local dry run." >&2
  exit 1
fi

notarize() {  # $1: 제출할 artifact(.zip 또는 .dmg)
  xcrun notarytool submit "$1" \
    --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_APP_PASSWORD" --team-id "$NOTARY_TEAM_ID" --wait
}

echo "==> building $APP_NAME $VERSION ($BUILD) — universal (arm64 + x86_64)"
# 두 architecture slice를 빌드하고 SwiftPM이 하나의 universal binary로 lipo 병합.
# 여러 --arch 사용 시 --show-bin-path는 *.bundle resource도 포함한 병합 product 디렉터리
# (.build/apple/Products/Release)를 반환하므로 아래 배치 loop 변경 없음.
# `-Xswiftc -g`로 DWARF를 생성해 `dsymutil`이 crash symbolication용 line-level dSYM 생성 가능.
# 배포 binary 크기는 증가하지 않음. Mach-O는 binary debug map이 참조하는 .o 파일에 DWARF를 보관하고
# dsymutil이 .dSYM으로 추출하며 실행 파일에는 symbol table만 포함.
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -g --product OpenUsage
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -g --product openusage-cli
BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 -Xswiftc -g --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_CLI_BINARY="$BUILD_DIR/openusage-cli"
[ -x "$BUILD_BINARY" ] || { echo "missing built binary: $BUILD_BINARY" >&2; exit 1; }
[ -x "$BUILD_CLI_BINARY" ] || { echo "missing built CLI: $BUILD_CLI_BINARY" >&2; exit 1; }

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$CLI_BINARY"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CLI_BINARY"
# --arch 누락 등으로 단일 architecture 빌드가 되면 명확히 실패.
# fat binary 보장이 필요하며 generate_appcast도 여기서 Sparkle hardwareRequirements를 유도.
lipo -archs "$APP_BINARY" | grep -q "x86_64" && lipo -archs "$APP_BINARY" | grep -q "arm64" \
  || { echo "Expected a universal (arm64 + x86_64) binary, got: $(lipo -archs "$APP_BINARY")" >&2; exit 1; }
lipo -archs "$CLI_BINARY" | grep -q "x86_64" && lipo -archs "$CLI_BINARY" | grep -q "arm64" \
  || { echo "Expected a universal CLI, got: $(lipo -archs "$CLI_BINARY")" >&2; exit 1; }

# SwiftPM은 실제 컴파일 SDK가 아닌 deployment target(macOS 15)을 LC_BUILD_VERSION의 `sdk`로 기록.
# macOS는 link된 SDK로 최신 Liquid Glass control 외형 적용 여부를 판단하므로 "15.0"이면 AppKit이
# 기존 Aqua control로 fallback. minos는 MIN_SYSTEM_VERSION으로 유지하고 sdk만 Tahoe 26.0으로
# 다시 기록해 macOS 15 실행 호환성과 최신 control 외형을 함께 확보.
# universal binary의 모든 slice에 적용 후 아래에서 재서명.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"
# vtool이 조용히 아무 작업도 하지 않아 기존 control이 배포되지 않도록 이전 SDK가 남은 slice 검출.
if vtool -show-build "$APP_BINARY" | grep -q "sdk 15.0"; then
  echo "SDK restamp failed: $APP_BINARY still reports sdk 15.0" >&2
  exit 1
fi

# vtool 재기록 후 실제 배포 binary에서 crash symbolication용 dSYM을 생성해 Mach-O UUID 일치 보장.
# `vtool -set-build-version`은 build-version load command만 다시 쓰고 LC_UUID는 유지하므로
# SDK 재기록이 symbol 업로드에 영향 없음.
# dsymutil은 binary debug map을 따라 같은 빌드에 남아 있는 .build/*.o 파일에서 DWARF 추출.
# 이후 서명은 UUID를 변경하지 않으므로 dSYM과 binary의 일치 유지.
echo "==> generating dSYM (crash symbolication)"
rm -rf "$DSYM_DIR"
mkdir -p "$DSYM_DIR"
dsymutil "$APP_BINARY" -o "$APP_DSYM"
# 배포 binary의 모든 architecture UUID가 dSYM에 포함되는지 검증.
# 누락 시 업로드한 symbol이 crash report와 일치하지 않아 "no symbols" 형태의 조용한 실패 발생.
for uuid in $(dwarfdump --uuid "$APP_BINARY" | awk '{print $2}'); do
  dwarfdump --uuid "$APP_DSYM" | grep -q "$uuid" \
    || { echo "dSYM UUID mismatch: $uuid (binary) absent from $APP_DSYM — symbolication would fail." >&2; exit 1; }
done
echo "    dSYM: $APP_DSYM"

shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# 앱 아이콘 설치 시 사전 컴파일한 catalog 우선 사용.
# GitHub runner의 actool(Xcode 26.4.1·26.5)은 Icon Composer `.icon` refractivity 기능에서 crash 발생
# (Apple regression FB20183399)해 CI 컴파일 불가.
# 정상 actool에서 script/compile_icon.sh로 생성한 Assets.car를 commit하며 assets/AppIcon.icon 변경 시 재생성.
# 로컬처럼 actool이 동작하는 환경에서는 fallback으로 직접 컴파일.
if [ -f "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" ]; then
  echo "==> installing prebuilt app icon"
  cp "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" "$APP_RESOURCES/Assets.car"
  [ -f "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" ] \
    && cp "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
  echo "==> compiling app icon"
  xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
    --app-icon AppIcon --enable-on-demand-resources NO --development-region en \
    --target-device mac --platform macosx --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --output-partial-info-plist /dev/null --output-format human-readable-text --errors --warnings
fi

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
  <key>NSUbiquitousContainers</key>
  <dict>
    <key>iCloud.com.kimchanhyung98.openusage</key>
    <dict>
      <key>NSUbiquitousContainerIsDocumentScopePublic</key><false/>
      <key>NSUbiquitousContainerName</key><string>OpenUsage</string>
      <key>NSUbiquitousContainerSupportedFolderLevels</key><string>None</string>
    </dict>
  </dict>
</dict>
</plist>
PLIST

cp "$ICLOUD_PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
"$ROOT_DIR/script/render_icloud_entitlements.sh" \
  "$ENTITLEMENTS_TEMPLATE" "$ICLOUD_PROVISIONING_PROFILE" "$ENTITLEMENTS" \
  "iCloud.com.kimchanhyung98.openusage"

# Sparkle embed 및 서명(Developer ID, hardened runtime, secure timestamp).
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "$CODESIGN_IDENTITY" "--options runtime --timestamp"
codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$CLI_BINARY"

echo "==> signing app (Developer ID, hardened runtime)"
# --deep 미사용: 위에서 서명한 Sparkle framework의 서명 유지 필요.
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
  --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -d --entitlements :- "$APP_BUNDLE" 2>&1 | grep -Fq '<string>iCloud.com.kimchanhyung98.openusage</string>' \
  || { echo "signed app is missing the production iCloud entitlement" >&2; exit 1; }

# DMG뿐 아니라 앱 자체도 공증·staple해 Sparkle 업데이트가 disk image에서 추출한 뒤
# offline 상태에서도 정상 실행 보장.
if [ "$NOTARIZE" = "1" ]; then
  echo "==> notarizing app (this can take a few minutes)"
  APP_ZIP="$DIST_DIR/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
  notarize "$APP_ZIP"
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$APP_ZIP"
fi

echo "==> building $DMG_PATH"
STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"

# 최초 수동 다운로드가 Gatekeeper에 차단되지 않도록 DMG도 공증·staple.
if [ "$NOTARIZE" = "1" ]; then
  echo "==> notarizing dmg"
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "==> notarized + stapled"
fi

echo "==> done"
echo "    DMG:  $DMG_PATH"
echo "    dSYM: $APP_DSYM (uploaded to PostHog for crash symbolication by release.yml)."
echo "    The appcast is generated from this DMG by generate_appcast (see release.yml)."
