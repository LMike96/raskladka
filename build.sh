#!/bin/bash
# Сборка «Раскладки»:  ./build.sh      — на своём Mac: собрать, установить в /Applications и запустить
#                     ./build.sh dmg  — то же + Raskladka.dmg
#                     build.sh ci     — только сборка .app (используется GitHub Actions)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Raskladka"
DISPLAY_NAME="Раскладка"
BUNDLE_ID="com.raskladka.switcher"
VERSION="1.0"
MIN_OS="12.0"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

c_ok()   { printf "\033[32m✔ %s\033[0m\n" "$1"; }
c_info() { printf "\033[36m→ %s\033[0m\n" "$1"; }
c_err()  { printf "\033[31m✖ %s\033[0m\n" "$1"; }

# 1. Инструменты разработчика
if ! xcrun --find swiftc >/dev/null 2>&1; then
    c_err "Не найдены Command Line Tools. Сейчас откроется установщик — после установки запустите ./build.sh ещё раз."
    xcode-select --install || true
    exit 1
fi
c_ok "Swift: $(xcrun swiftc --version 2>&1 | head -1)"

# 2. Компиляция (универсальный бинарник Apple Silicon + Intel)
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
FRAMEWORKS=(-framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement)
NATIVE_ARCH="$(uname -m)"
BINARIES=()
for ARCH in arm64 x86_64; do
    c_info "Компиляция для ${ARCH}…"
    if xcrun swiftc -O -whole-module-optimization -target "${ARCH}-apple-macos${MIN_OS}" \
        Sources/*.swift "${FRAMEWORKS[@]}" -o "${BUILD_DIR}/${APP_NAME}-${ARCH}" 2> "${BUILD_DIR}/log-${ARCH}.txt"; then
        BINARIES+=("${BUILD_DIR}/${APP_NAME}-${ARCH}")
        c_ok "${ARCH} готово"
    elif [ "${ARCH}" = "${NATIVE_ARCH}" ]; then
        c_err "Ошибка компиляции:"; cat "${BUILD_DIR}/log-${ARCH}.txt"; exit 1
    else
        c_info "${ARCH} пропущен (не обязателен для этого Mac)"
    fi
done

# 3. Сборка .app
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/* "${APP}/Contents/Resources/"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key><string>ru</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Автопереключение раскладки RU ⇄ EN</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --identifier "${BUNDLE_ID}" "${APP}" >/dev/null 2>&1
c_ok "Собрано: ${APP}"

if [ "${1:-}" = "ci" ]; then
    exit 0
fi

# 4. Установка в «Программы»
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP}" "/Applications/"
xattr -cr "/Applications/${APP_NAME}.app" 2>/dev/null || true
c_ok "Установлено в /Applications/${APP_NAME}.app"

# Новая сборка = новая подпись, поэтому сбрасываем старое разрешение,
# иначе macOS будет показывать галочку, но не пускать приложение к клавиатуре.
tccutil reset Accessibility "${BUNDLE_ID}" >/dev/null 2>&1 || true
tccutil reset ListenEvent "${BUNDLE_ID}" >/dev/null 2>&1 || true

# 5. DMG для других компьютеров (по желанию)
if [ "${1:-}" = "dmg" ]; then
    DMG_DIR="${BUILD_DIR}/dmg"
    mkdir -p "${DMG_DIR}"
    cp -R "${APP}" "${DMG_DIR}/"
    ln -s /Applications "${DMG_DIR}/Applications"
    hdiutil create -volname "${DISPLAY_NAME}" -srcfolder "${DMG_DIR}" -ov -format UDZO "${BUILD_DIR}/${APP_NAME}.dmg" >/dev/null
    c_ok "DMG: ${BUILD_DIR}/${APP_NAME}.dmg"
fi

open "/Applications/${APP_NAME}.app"
echo
c_info "Разрешите доступ: Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → «${APP_NAME}»."
c_info "Иконка RU/EN появится в строке меню, как только доступ будет выдан."
