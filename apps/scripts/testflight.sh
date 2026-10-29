#!/usr/bin/env bash
# Сборка и загрузка в TestFlight одной командой: покупатель (client), «SM Магазин» (store),
# «SM Курьер» (courier), «SM Сотрудник» (employee), «SM Агент» (distributor). Нужны Mac, Flutter 3.44 и Xcode 26, вход в Xcode под Apple ID команды
# (Xcode → Settings → Accounts) — или ключ App Store Connect API (см. ниже).
#
#   bash apps/scripts/testflight.sh                 # все три приложения
#   bash apps/scripts/testflight.sh store courier   # только выбранные
#
# Каждое приложение: проверка кода → сборка архива → загрузка в App Store Connect
# (xcodebuild -exportArchive с destination=upload). Через 10–30 минут сборки в TestFlight.
# Номер сборки iOS — дата и время (ГГГГММДДЧЧММ), всегда больше прошлых: TestFlight предлагает
# обновление только если номер больше установленного. Свой номер: BUILD=202610100900 bash ...
#
# Ключ API (необязательно, если Xcode уже вошёл в аккаунт): App Store Connect → Users and Access →
# Integrations → App Store Connect API → «+», роль App Manager; файл AuthKey_<ID>.p8 положить в
# ~/.appstoreconnect/private_keys/ и запускать с ASC_KEY_ID=<ID> ASC_ISSUER_ID=<Issuer ID>.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
apps=("$@")
[ ${#apps[@]} -eq 0 ] && apps=(client store courier)

opts="$(mktemp -d)/ExportOptions.plist"
cat > "$opts" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

auth=()
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  auth=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

build="${BUILD:-$(date +%Y%m%d%H%M)}"

ok=() failed=()
for app in "${apps[@]}"; do
  case "$app" in client|store|courier|employee|distributor) ;; *) echo "Неизвестное приложение: $app (client, store, courier, employee, distributor)"; exit 1 ;; esac
  dir="$root/apps/$app"
  echo
  echo "=== $app · $(grep '^version:' "$dir/pubspec.yaml") · сборка iOS $build"
  (
    set -e
    cd "$dir"
    # У магазина и курьера папки платформ создаёт flutter create; название, иконки,
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
    # Старый архив убираем: если сборка упадёт, нельзя загрузить вчерашний.
    rm -rf build/ios/archive build/ios/upload
    flutter build ipa --release --build-number="$build"
    xcodebuild -exportArchive \
      -archivePath build/ios/archive/Runner.xcarchive \
      -exportPath build/ios/upload \
      -exportOptionsPlist "$opts" \
      -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
  )
  # Не «( … ) && ok || failed»: в таком списке bash не выполняет set -e внутри скобок,
  # и после ошибки сборки скрипт шёл дальше и загружал старый архив.
  if [ $? -eq 0 ]; then ok+=("$app"); else failed+=("$app"); fi
done

echo
[ ${#ok[@]} -gt 0 ] && echo "✓ Загружено в App Store Connect: ${ok[*]} (сборка $build) — через 10–30 минут появится в TestFlight"
if [ ${#failed[@]} -gt 0 ]; then
  echo "✗ Не получилось: ${failed[*]} — смотрите вывод выше."
  echo "  Архив можно загрузить вручную: open apps/<app>/build/ios/archive/Runner.xcarchive → Distribute App."
  exit 1
fi
