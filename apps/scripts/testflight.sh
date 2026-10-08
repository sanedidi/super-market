#!/usr/bin/env bash
# Сборка и загрузка в TestFlight: покупатель (client), «SM Магазин» (store), «SM Курьер» (courier).
# Нужны Mac, Flutter 3.44 и Xcode 26 (App Store Connect принимает сборки только на нём).
#
#   bash apps/scripts/testflight.sh                 # все три приложения
#   bash apps/scripts/testflight.sh store courier   # только выбранные
#
# Номер сборки — «+N» в version: pubspec.yaml; для повторной загрузки поднять его.
# Загрузка: если заданы ASC_KEY_ID и ASC_ISSUER_ID (ключ App Store Connect API лежит в
# ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8), .ipa уходит в App Store Connect
# сам. Иначе открывается архив в Xcode → Distribute App → App Store Connect → Upload.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
apps=("$@")
[ ${#apps[@]} -eq 0 ] && apps=(client store courier)

for app in "${apps[@]}"; do
  case "$app" in client|store|courier) ;; *) echo "Неизвестное приложение: $app (client, store, courier)"; exit 1 ;; esac
  dir="$root/apps/$app"
  echo
  echo "=== $app · $(grep '^version:' "$dir/pubspec.yaml")"
  cd "$dir"

  # У магазина и курьера папки платформ создаёт flutter create, название, иконки,
  # разрешения и манифест конфиденциальности — branding/apply.sh.
  if [ "$app" != client ]; then
    if [ ! -d ios ]; then
      flutter create --platforms=android,ios --org uz.supermarket --project-name "sm_$app" .
      rm -f test/widget_test.dart
    fi
    bash branding/apply.sh
  fi

  flutter pub get
  flutter analyze --no-fatal-infos
  flutter build ipa --release

  ipa="$(ls build/ios/ipa/*.ipa 2>/dev/null | head -1 || true)"
  if [ -n "$ipa" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    xcrun altool --upload-app --type ios --file "$ipa" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    echo "✓ $app загружено в App Store Connect — через 10–30 минут появится в TestFlight"
  else
    open build/ios/archive/Runner.xcarchive
    echo "→ $app: в Xcode Organizer нажмите Distribute App → App Store Connect → Upload"
  fi
done
