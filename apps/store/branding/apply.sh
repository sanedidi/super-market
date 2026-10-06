#!/usr/bin/env bash
# Папки платформ приложения магазина: название, логотип, камера и фото
# (снимок накладной), геолокация (точка магазина на карте), push-уведомления, подпись iOS,
# подпись release для Google Play, манифест конфиденциальности iOS (PrivacyInfo.xcprivacy).
# Запускать из apps/store после
#   flutter create --platforms=android,ios --org uz.supermarket --project-name sm_store .
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="SM Магазин"

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
perms = ['INTERNET', 'CAMERA', 'VIBRATE', 'POST_NOTIFICATIONS', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION']
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
  # Face ID / отпечаток (local_auth): нужен FragmentActivity.
  for f in $(find android/app/src/main -name 'MainActivity.kt' -o -name 'MainActivity.java'); do
    sed -i.bak -e 's/io\.flutter\.embedding\.android\.FlutterActivity/io.flutter.embedding.android.FlutterFragmentActivity/' \
      -e 's/: FlutterActivity()/: FlutterFragmentActivity()/' -e 's/extends FlutterActivity/extends FlutterFragmentActivity/' "$f"
    rm -f "$f.bak"
  done
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
d['NSCameraUsageDescription'] = 'Сфотографировать накладную поставщика, чтобы сделать приход'
d['NSPhotoLibraryUsageDescription'] = 'Выбрать фото накладной из галереи'
d['NSFaceIDUsageDescription'] = 'Входить в приложение магазина по Face ID вместо кода'
d['NSLocationWhenInUseUsageDescription'] = 'Поставить метку магазина на карте там, где вы сейчас'
schemes = set(d.get('LSApplicationQueriesSchemes', []))
schemes.update(['https', 'tg'])
d['LSApplicationQueriesSchemes'] = sorted(schemes)
d['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationPortrait']
d['ITSAppUsesNonExemptEncryption'] = False
modes = set(d.get('UIBackgroundModes', []))
modes.add('remote-notification')
d['UIBackgroundModes'] = sorted(modes)
with open(p, 'wb') as f:
    plistlib.dump(d, f)
PY
  # Манифест конфиденциальности (требование App Store): файл + ресурс цели Runner.
  cp branding/ios/PrivacyInfo.xcprivacy ios/Runner/PrivacyInfo.xcprivacy
  python3 ../scripts/ios_add_resource.py ios PrivacyInfo.xcprivacy
  # Push: право aps-environment. В файле — development, чтобы работали отладочные сборки;
  # при архиве и выгрузке в App Store (Distribute App / flutter build ipa) Xcode переподписывает
  # приложение профилем App Store, и в нём aps-environment = production.
  cat > ios/Runner/Runner.entitlements <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
</dict>
</plist>
XML
  python3 - <<'PY2'
import re
p = 'ios/Runner.xcodeproj/project.pbxproj'
s = open(p, encoding='utf-8').read()
if 'DEVELOPMENT_TEAM' not in s:
    s = re.sub(r'(\n(\t+)PRODUCT_BUNDLE_IDENTIFIER = uz\.supermarket\.smStore;)',
               r'\n\2DEVELOPMENT_TEAM = Z5984ANP34;\1', s)
if 'CODE_SIGN_ENTITLEMENTS' not in s:
    s = re.sub(r'(\n(\t+)PRODUCT_BUNDLE_IDENTIFIER = uz\.supermarket\.smStore;)',
               r'\n\2CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\1', s)
open(p, 'w', encoding='utf-8').write(s)
PY2
fi
echo "Готово: $NAME"
