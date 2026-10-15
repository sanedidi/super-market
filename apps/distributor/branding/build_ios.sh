#!/usr/bin/env bash
# Сборка «SM Агент» для TestFlight на Mac (нужны Flutter и Xcode).
# Запуск из корня репозитория: bash apps/distributor/branding/build_ios.sh
# Номер сборки — дата-время (каждая загрузка уникальна); можно задать BUILD=N.
# UPLOAD=0 — только архив, без загрузки в TestFlight.
# Лог — apps/distributor/build_ios.log.
set -euo pipefail
cd "$(dirname "$0")/.."
exec > >(tee build_ios.log) 2>&1
echo "== $(date)"
if [ ! -d ios ]; then
  flutter create --platforms=ios --org uz.supermarket --project-name sm_distributor .
  rm -f test/widget_test.dart
fi
bash branding/apply.sh
flutter pub get
flutter analyze --no-fatal-infos || echo "!! analyze: есть замечания (см. выше)"
flutter test
# Архив: Xcode сам зарегистрирует bundle id uz.supermarket.smDistributor и создаст профиль.
BUILD="${BUILD:-$(date +%y%m%d%H%M)}"
echo "== сборка $BUILD"
flutter build ios --release --no-codesign --build-number="$BUILD"
cd ios
pod install >/dev/null || true
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release \
  -archivePath ../build/ios/archive/Runner.xcarchive -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=Z5984ANP34 CODE_SIGN_STYLE=Automatic archive | tail -40
cd ..
echo "== АРХИВ ГОТОВ: build/ios/archive/Runner.xcarchive"
if [ "${UPLOAD:-1}" = "1" ]; then
  # Загрузка в App Store Connect (TestFlight) аккаунтом, который вошёл в Xcode.
  cat > build/ios/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>Z5984ANP34</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive \
    -exportOptionsPlist build/ios/ExportOptions.plist -exportPath build/ios/export \
    -allowProvisioningUpdates | tail -30
  echo "== ЗАГРУЖЕНО В TESTFLIGHT: сборка $BUILD (обработка в App Store Connect ~10–20 мин)"
else
  open build/ios/archive/Runner.xcarchive
fi
