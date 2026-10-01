#!/usr/bin/env bash
# Логотип и название кассы в папках платформ, которые создаёт `flutter create`.
# Запускать из apps/pos после `flutter create --platforms=windows,android .`
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -d windows ]; then
  cp branding/app_icon.ico windows/runner/resources/app_icon.ico
  # Имя exe и заголовок окна (латиницей — исходники C++ собираются не в UTF-8).
  sed -i.bak 's/set(BINARY_NAME "sm_pos")/set(BINARY_NAME "SuperMarketPOS")/' windows/CMakeLists.txt
  sed -i.bak 's/L"sm_pos"/L"Super Market POS"/' windows/runner/main.cpp
  # ProductName не трогаем: по нему Windows выбирает папку данных кассы (%APPDATA%).
  sed -i.bak 's/"FileDescription", "sm_pos"/"FileDescription", "Super Market POS"/; s/"sm_pos.exe"/"SuperMarketPOS.exe"/' windows/runner/Runner.rc
  rm -f windows/CMakeLists.txt.bak windows/runner/main.cpp.bak windows/runner/Runner.rc.bak
fi

if [ -d android ]; then
  for d in branding/android/mipmap-*; do
    cp "$d/ic_launcher.png" "android/app/src/main/res/$(basename "$d")/ic_launcher.png"
  done
  m=android/app/src/main/AndroidManifest.xml
  sed -i.bak 's/android:label="sm_pos"/android:label="Касса Super Market"/' "$m"
  grep -q 'android.permission.INTERNET' "$m" || \
    sed -i.bak 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$m"
  rm -f "$m.bak"
fi
