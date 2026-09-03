#!/usr/bin/env bash
set -euo pipefail

# OpenUsage 빌드 후 dist/에 서명된 .app 번들 준비 및 해당 위치에서 실행 — /Applications 설치 없음.
# 개발 빌드 특성:
#   - 안정적인 Apple Development ID로 서명해 재빌드 후에도 키체인·권한 허용 유지
#     (macOS는 설치 위치가 아닌 서명 ID와 bundle ID를 기준으로 권한 관리)
#   - 전용 bundle ID(com.kimchanhyung98.openusage.dev) 사용으로 운영 앱의 설정·키체인과 격리.
#     운영 앱 데이터로 실행하려면 아래 BUNDLE_ID를 com.kimchanhyung98.openusage로 지정
#   - Sparkle feed를 포함하지 않아 업데이트 확인·설치 없음
#     (업데이트 검증은 실제 서명·공증한 릴리스 빌드 사용)
#
# 사용법: script/build_and_run.sh [run|build|logs|verify]
# 환경 변수:
#   CODESIGN_IDENTITY            서명 ID 재정의(정확한 이름 또는 hash)
#   CONFIG                       "release"(기본값) 또는 "debug"
#   OPENUSAGE_DEV_VERSION        로컬 개발 번들 버전 재정의. 릴리스 버전과 구분하도록 `-dev` 접미사 유지
#   ICLOUD_PROVISIONING_PROFILE  개발용 provisioning profile 재정의.
#                                미지정 시 일치하는 최신 설치 profile 자동 선택

MODE="${1:-run}"
CONFIG="${CONFIG:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.sh"

# 버전·빌드 번호를 git 이력에서 유도하므로 ZIP 같은 소스 export에서는 명확히 실패.
if ! git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "$ROOT_DIR is not a git worktree — the dev bundle version and build number come from git history" >&2
  exit 1
fi

TARGET_NAME="OpenUsage"                 # SwiftPM target 및 binary 이름
APP_DISPLAY="OpenUsage"                 # 사용자 노출 앱 이름
BUNDLE_ID="${BUNDLE_ID:-com.kimchanhyung98.openusage.dev}"
ICLOUD_CONTAINER_ID="${ICLOUD_CONTAINER_ID:-iCloud.${BUNDLE_ID}}"
MIN_SYSTEM_VERSION="15.0"
# 로컬 번들은 가장 가까운 릴리스 태그 사용. 테스트용 재정의 값도 동일한 태그 검증 적용.
# 로컬 번들이 릴리스 버전을 나타내지 않도록 -dev 접미사 항상 유지.
if [ -n "${OPENUSAGE_DEV_VERSION:-}" ]; then
  DEV_VERSION_OVERRIDE="${OPENUSAGE_DEV_VERSION#v}"
  APP_VERSION="$(openusage_version_from_tag "v${DEV_VERSION_OVERRIDE%-dev}")-dev"
else
  APP_VERSION="$(openusage_development_version "$ROOT_DIR")"
fi
APP_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$TARGET_NAME"
CLI_BINARY="$APP_HELPERS/openusage"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RESOURCE_BUNDLE_NAME="${TARGET_NAME}_${TARGET_NAME}.bundle"
ENTITLEMENTS="$ROOT_DIR/script/OpenUsage.dev.entitlements.plist"
SIGN_ENTITLEMENTS="$ROOT_DIR/script/OpenUsage.local.entitlements.plist"

pkill -x "$TARGET_NAME" >/dev/null 2>&1 || true

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$TARGET_NAME"
BUILD_CLI_BINARY="$BUILD_DIR/openusage-cli"

if [ ! -x "$BUILD_BINARY" ]; then
  echo "missing built binary: $BUILD_BINARY" >&2
  exit 1
fi
if [ ! -x "$BUILD_CLI_BINARY" ]; then
  echo "missing built CLI: $BUILD_CLI_BINARY" >&2
  exit 1
fi

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$CLI_BINARY"
# 일회성 CLI는 updater를 초기화하지 않지만 공유 모듈이 Sparkle과 link됨.
# Helpers는 Contents 아래 한 단계에 있으므로 앱 binary와 동일한 embedded framework 위치를 dyld에 제공.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CLI_BINARY"

# SwiftPM은 실제 컴파일 SDK가 아닌 deployment target(macOS 15)을 LC_BUILD_VERSION의 `sdk`로 기록.
# macOS는 link된 SDK로 최신 Liquid Glass control 외형 적용 여부를 판단하므로 "15.0"이면 AppKit이
# 기존 Aqua control로 fallback. minos는 MIN_SYSTEM_VERSION으로 유지하고 sdk만 Liquid Glass가 도입된
# Tahoe 26.0으로 다시 기록해 macOS 15 실행 호환성과 최신 control 외형을 함께 확보. 아래에서 재서명.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"
# 빌드에서 생성된 모든 SwiftPM resource bundle을 표준 앱 경로인 Contents/Resources에 배치.
# 앱 전용 OpenUsage_OpenUsage.bundle에 provider SVG와 model manifest 포함.
# Bundle.openUsageResources는 Support/ResourceBundle.swift에서 해당 경로를 사용해 로드.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Icon Composer 원본(assets/AppIcon.icon)을 Assets.car로 컴파일해 Tahoe에서 실제 Liquid Glass 아이콘 표시.
# 아래 CFBundleIconName은 .icon 파일명("AppIcon")과 일치해야 함.
# 최소 지원 버전인 macOS 15에서는 기존 .icns fallback 필요(릴리스 빌드에서 제공).
# 개발 빌드는 Assets.car만 배치하고 maintainer의 현재 OS에서 실행.
echo "==> compiling app icon (actool)"
PREBUILT_ICON_DIR="$ROOT_DIR/assets/AppIcon.prebuilt"
if xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --output-partial-info-plist /dev/null \
  --output-format human-readable-text --errors --warnings; then
  : # 아이콘 신규 컴파일 완료
elif [ -f "$PREBUILT_ICON_DIR/Assets.car" ]; then
  # 일부 toolchain의 actool 오류 대응. commit 08863d7의 사전 빌드 아이콘을 릴리스 CI와 동일하게 재사용.
  # actool 실패가 set -e에서 개발 빌드를 중단하지 않으며 실제 앱 아이콘 유지.
  echo "==> actool failed; using prebuilt icon (assets/AppIcon.prebuilt)"
  cp "$PREBUILT_ICON_DIR/Assets.car" "$APP_RESOURCES/Assets.car"
  [ -f "$PREBUILT_ICON_DIR/AppIcon.icns" ] && cp "$PREBUILT_ICON_DIR/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
  echo "WARNING: actool failed and no prebuilt icon found; continuing without an icon" >&2
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$TARGET_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSUbiquitousContainers</key>
  <dict>
    <key>$ICLOUD_CONTAINER_ID</key>
    <dict>
      <key>NSUbiquitousContainerIsDocumentScopePublic</key>
      <false/>
      <key>NSUbiquitousContainerName</key>
      <string>OpenUsage</string>
      <key>NSUbiquitousContainerSupportedFolderLevels</key>
      <string>None</string>
    </dict>
  </dict>
</dict>
</plist>
PLIST

if [ -n "${ICLOUD_PROVISIONING_PROFILE:-}" ] && [ ! -f "$ICLOUD_PROVISIONING_PROFILE" ]; then
  echo "iCloud provisioning profile not found: $ICLOUD_PROVISIONING_PROFILE" >&2
  exit 1
fi

if [ -z "${ICLOUD_PROVISIONING_PROFILE:-}" ]; then
  ICLOUD_PROVISIONING_PROFILE=$("$ROOT_DIR/script/find_icloud_provisioning_profile.sh" \
    "$BUNDLE_ID" "$ICLOUD_CONTAINER_ID" || true)
fi

if [ -n "${ICLOUD_PROVISIONING_PROFILE:-}" ]; then
  echo "==> using iCloud provisioning profile: $ICLOUD_PROVISIONING_PROFILE"
  cp "$ICLOUD_PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
  SIGN_ENTITLEMENTS="$DIST_DIR/OpenUsage.dev.resolved.entitlements.plist"
  "$ROOT_DIR/script/render_icloud_entitlements.sh" \
    "$ENTITLEMENTS" "$ICLOUD_PROVISIONING_PROFILE" "$SIGN_ENTITLEMENTS" \
    "$ICLOUD_CONTAINER_ID"
else
  echo "WARNING: no matching installed iCloud provisioning profile was found; iCloud Sync will be unavailable in this build." >&2
fi

# ad-hoc cdhash 변경으로 재빌드마다 권한 요청이 다시 나타나지 않도록 안정적인 Apple Development ID 선택.
# 일치하는 ID가 없을 때만 ad-hoc으로 fallback.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development:/ { print $2; exit }')
fi

# 앱 봉인 전에 Sparkle.framework embed 및 서명.
# updater는 위 Info.plist에 SUFeedURL이 없어 비활성(UpdaterController 참고)이지만 실행 파일이 Sparkle과
# link되므로 framework를 embed하지 않으면 빌드 실행 실패.
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "$CODESIGN_IDENTITY" "--options runtime"

if [ -n "$CODESIGN_IDENTITY" ]; then
  /usr/bin/codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$CLI_BINARY" >/dev/null
  # --deep 미사용: 위에서 서명한 Sparkle framework의 서명 유지 필요.
  /usr/bin/codesign --force --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$SIGN_ENTITLEMENTS" \
    "$APP_BUNDLE" >/dev/null
  echo "==> signed with: $CODESIGN_IDENTITY"
else
  /usr/bin/codesign --force --sign - "$CLI_BINARY" >/dev/null
  /usr/bin/codesign --force --sign - --entitlements "$SIGN_ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  echo "WARNING: no Apple Development identity found; ad-hoc signed." >&2
fi

launch_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    launch_app
    echo "==> launched $APP_DISPLAY (dist/$APP_DISPLAY.app)"
    ;;
  build)
    : # 빌드·배치·서명만 수행
    ;;
  logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$TARGET_NAME\""
    ;;
  verify)
    launch_app
    sleep 1
    pgrep -x "$TARGET_NAME" >/dev/null && echo "==> running"
    ;;
  *)
    echo "usage: $0 [run|build|logs|verify]" >&2
    exit 2
    ;;
esac
