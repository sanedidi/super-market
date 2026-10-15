#!/usr/bin/env bash
# Сборка «SM Дистрибьютор» для TestFlight на Mac (нужны Flutter и Xcode).
# Запуск из корня репозитория: bash apps/distributor/branding/build_ios.sh
# Номер сборки — +N в pubspec.yaml; для повторной загрузки поднять его.
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
flutter build ios --release --no-codesign
cd ios
pod install >/dev/null || true
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release \
  -archivePath ../build/ios/archive/Runner.xcarchive -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=Z5984ANP34 CODE_SIGN_STYLE=Automatic archive | tail -40
cd ..
echo "== АРХИВ ГОТОВ: build/ios/archive/Runner.xcarchive"
open build/ios/archive/Runner.xcarchive
