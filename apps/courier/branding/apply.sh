#!/usr/bin/env bash
# Папки платформ приложения курьера: название, логотип, разрешения на
# геопозицию во время смены (Android — фоновая служба с уведомлением «Вы на смене»,
# разрешение «только во время использования»), звонки и ссылки, подпись release
# для Google Play, манифест конфиденциальности iOS (PrivacyInfo.xcprivacy).
# Запускать из apps/courier после
#   flutter create --platforms=android,ios --org uz.supermarket --project-name sm_courier .
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="SM Курьер"

if [ -d android ]; then
  for d in branding/android/mipmap-*; do
    cp "$d/ic_launcher.png" "android/app/src/main/res/$(basename "$d")/ic_launcher.png"
  done
  python3 - "$NAME" <<'PY'
import re, sys
name = sys.argv[1]
p = 'android/app/src/main/AndroidManifest.xml'
s = open(p, encoding='utf-8').read()
s = re.sub(r'android:label="[^"]*"', f'android:label="{name}"', s, count=1)
# ACCESS_BACKGROUND_LOCATION не нужен: точка отправляется из фоновой службы (foreground service
# type location), которую курьер запускает сам, — Google Play требует для неё только FOREGROUND_SERVICE_LOCATION.
perms = ['INTERNET', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION',
         'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_LOCATION', 'WAKE_LOCK', 'VIBRATE', 'POST_NOTIFICATIONS']
# Убрать из манифеста, созданного прежней версией этого скрипта.
s = re.sub(r'[ \t]*<uses-permission android:name="android\.permission\.ACCESS_BACKGROUND_LOCATION"\s*/>\n?', '', s)
add = ''.join(f'    <uses-permission android:name="android.permission.{x}"/>\n' for x in perms
              if f'android.permission.{x}"' not in s)
s = s.replace('<application', add + '    <application', 1)
# Звонок и карты: Android 11+ должен «видеть» приложения для этих ссылок.
q = '''        <intent>
            <action android:name="android.intent.action.DIAL"/>
            <data android:scheme="tel"/>
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:scheme="https"/>
        </intent>
'''
if '<queries>' in s:
    if 'android.intent.action.DIAL' not in s:
        s = s.replace('<queries>', '<queries>\n' + q, 1)
else:
    s = s.replace('</manifest>', '    <queries>\n' + q + '    </queries>\n</manifest>', 1)
open(p, 'w', encoding='utf-8').write(s)
PY
  # Подпись release ключом загрузки (android/key.properties) и targetSdk >= 36.
  python3 ../scripts/android_release_signing.py android
fi

if [ -d ios ]; then
  rm -rf ios/Runner/Assets.xcassets/AppIcon.appiconset
  cp -r branding/ios/AppIcon.appiconset ios/Runner/Assets.xcassets/
  python3 - "$NAME" <<'PY'
import plistlib, sys
p = 'ios/Runner/Info.plist'
with open(p, 'rb') as f:
    d = plistlib.load(f)
d['CFBundleDisplayName'] = sys.argv[1]
d['NSLocationWhenInUseUsageDescription'] = 'Покупатель видит, где его заказ, пока вы везёте'
d['NSLocationAlwaysAndWhenInUseUsageDescription'] = 'Покупатель видит, где его заказ, даже когда приложение свёрнуто'
d['NSLocationAlwaysUsageDescription'] = 'Покупатель видит, где его заказ, даже когда приложение свёрнуто'
modes = set(d.get('UIBackgroundModes', []))
modes.add('location')
d['UIBackgroundModes'] = sorted(modes)
schemes = set(d.get('LSApplicationQueriesSchemes', []))
schemes.update(['tel', 'https', 'yandexmaps', 'yandexnavi'])
d['LSApplicationQueriesSchemes'] = sorted(schemes)
d['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationPortrait']
d['ITSAppUsesNonExemptEncryption'] = False
with open(p, 'wb') as f:
    plistlib.dump(d, f)
PY
  # Манифест конфиденциальности (требование App Store): файл + ресурс цели Runner.
  cp branding/ios/PrivacyInfo.xcprivacy ios/Runner/PrivacyInfo.xcprivacy
  python3 ../scripts/ios_add_resource.py ios PrivacyInfo.xcprivacy
  # Команда разработчика Apple — подпись при сборке без ручной настройки в Xcode.
  python3 - <<'PY2'
import re
p = 'ios/Runner.xcodeproj/project.pbxproj'
s = open(p, encoding='utf-8').read()
if 'DEVELOPMENT_TEAM' not in s:
    s = re.sub(r'(\n(\t+)PRODUCT_BUNDLE_IDENTIFIER = uz\.supermarket\.smCourier;)',
               r'\n\2DEVELOPMENT_TEAM = Z5984ANP34;\1', s)
# Только iPhone: iPad не поддерживаем (иначе App Store требует скриншоты и проверку на iPad).
s = s.replace('TARGETED_DEVICE_FAMILY = "1,2";', 'TARGETED_DEVICE_FAMILY = 1;')
open(p, 'w', encoding='utf-8').write(s)
PY2
fi
echo "Готово: $NAME"
