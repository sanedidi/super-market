#!/usr/bin/env bash
# Сборка «SM Магазин» для TestFlight на Mac (нужны Flutter и Xcode).
# Запуск из корня репозитория: bash apps/store/branding/build_ios.sh
# Номер сборки берётся из pubspec.yaml; для повторной загрузки — поднять +N там.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -d ios ]; then
  flutter create --platforms=android,ios --org uz.supermarket --project-name sm_store .
  rm -f test/widget_test.dart
fi
bash branding/apply.sh
flutter pub get
flutter analyze --no-fatal-infos
flutter build ipa --release
open build/ios/archive/Runner.xcarchive
echo "Готово: архив открыт в Xcode → Distribute App → TestFlight & App Store"
