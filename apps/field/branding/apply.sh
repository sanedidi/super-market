#!/usr/bin/env bash
# Папки платформ «SM Продажник»: название, геопозиция в фоне (путь пишется во
# время обхода с выключенным экраном: Android — служба с уведомлением «Идёт
# обход», iOS — фоновый режим location), камера (фото витрины), подпись
# release для Google Play, иконка «SM …» (красный фон + чёрный бейдж
# «продажник», как у «SM Агент» и «SM Сотрудник»).
# Запускать из apps/field после
#   flutter create --platforms=android,ios --org uz.supermarket --project-name sm_field .
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="SM Продажник"

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
# Геопозиция в фоне: служба geolocator (foregroundServiceType="location") держит
# запись пути, пока идёт обход; уведомление «Идёт обход» видно в шторке.
perms = ['INTERNET', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'ACCESS_BACKGROUND_LOCATION',
         'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_LOCATION', 'WAKE_LOCK', 'POST_NOTIFICATIONS',
         'CAMERA', 'VIBRATE']
add = ''.join(f'    <uses-permission android:name="android.permission.{x}"/>\n' for x in perms
              if f'android.permission.{x}"' not in s)
s = s.replace('<application', add + '    <application', 1)
q = '''        <intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:scheme="https"/>
        </intent>
        <intent>
            <action android:name="android.media.action.IMAGE_CAPTURE"/>
        </intent>
'''
if '<queries>' in s:
    if 'IMAGE_CAPTURE' not in s:
        s = s.replace('<queries>', '<queries>\n' + q, 1)
else:
    s = s.replace('</manifest>', '    <queries>\n' + q + '    </queries>\n</manifest>', 1)
open(p, 'w', encoding='utf-8').write(s)
PY
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
loc = 'Во время обхода Super Market записывает ваш путь, чтобы другие продажники не ходили там же. Путь пишется только между «Начать обход» и «Закончить».'
d['NSLocationWhenInUseUsageDescription'] = loc
d['NSLocationAlwaysAndWhenInUseUsageDescription'] = loc
d['NSLocationAlwaysUsageDescription'] = loc
d['NSCameraUsageDescription'] = 'Сфотографировать витрину магазина, чтобы другой продажник его узнал'
d['NSPhotoLibraryUsageDescription'] = 'Выбрать фото витрины магазина'
schemes = set(d.get('LSApplicationQueriesSchemes', []))
schemes.update(['https'])
d['LSApplicationQueriesSchemes'] = sorted(schemes)
d['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationPortrait']
d['ITSAppUsesNonExemptEncryption'] = False
# Путь пишется в фоне, пока идёт обход (синяя стрелка в статус-баре).
modes = set(d.get('UIBackgroundModes', []))
modes.add('location')
d['UIBackgroundModes'] = sorted(modes)
with open(p, 'wb') as f:
    plistlib.dump(d, f)
PY
  # Манифест конфиденциальности (требование App Store): файл + ресурс цели Runner.
  cp branding/ios/PrivacyInfo.xcprivacy ios/Runner/PrivacyInfo.xcprivacy
  python3 ../scripts/ios_add_resource.py ios PrivacyInfo.xcprivacy
  python3 - <<'PY2'
import re
p = 'ios/Runner.xcodeproj/project.pbxproj'
s = open(p, encoding='utf-8').read()
# Команда разработчика (как у остальных приложений): подпись и автосоздание профиля.
if 'DEVELOPMENT_TEAM' not in s:
    s = re.sub(r'(\n(\t+)PRODUCT_BUNDLE_IDENTIFIER = uz\.supermarket\.smField;)',
               r'\n\2DEVELOPMENT_TEAM = Z5984ANP34;\1', s)
# Только iPhone: iPad не поддерживаем.
s = s.replace('TARGETED_DEVICE_FAMILY = "1,2";', 'TARGETED_DEVICE_FAMILY = 1;')
open(p, 'w', encoding='utf-8').write(s)
PY2
fi
echo "Готово: $NAME"
