#!/usr/bin/env python3
"""Настраивает android/app/build.gradle.kts после `flutter create` (store, courier):

- release подписывается ключом загрузки из android/key.properties, если файл есть
  (его пишет workflow release или разработчик локально, см. docs/release.md);
  нет файла — debug-ключ, как в шаблоне Flutter, локальные сборки не ломаются;
- compileSdk и targetSdk не ниже 36 (требование Google Play с 31.08.2026).

    python3 ../scripts/android_release_signing.py android

Повторный запуск ничего не меняет.
"""
import re
import sys

MARK = '// sm: release-signing'
MIN_SDK_TARGET = 36

LOADER = f'''
{MARK}
// Ключ загрузки для Google Play: android/key.properties (не в git, см. docs/release.md).
// Нет файла — release подписывается debug-ключом, чтобы `flutter run --release` работал локально.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {{
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use {{ load(it) }}
}}
'''

SIGNING = '''    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

'''

RELEASE_SIGNING = '''signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }'''


def die(msg):
    sys.exit(f'android_release_signing: {msg}')


def main():
    if len(sys.argv) != 2:
        die('использование: android_release_signing.py <папка android>')
    android = sys.argv[1]
    path = f'{android}/app/build.gradle.kts'
    try:
        s = open(path, encoding='utf-8').read()
    except FileNotFoundError:
        die(f'нет {path} (flutter create должен создавать Kotlin DSL; build.gradle на Groovy не поддерживается)')

    if MARK in s:
        print('build.gradle.kts: подпись release уже настроена')
        return

    # 0. import java.util.Properties — в начало файла. Полное имя java.util.Properties
    #    в Kotlin DSL не работает: `java` там — расширение проекта (java { }).
    if not re.search(r'^import java\.util\.Properties$', s, re.M):
        s = 'import java.util.Properties\n\n' + s

    # 1. Чтение key.properties — сразу после блока plugins { }.
    m = re.search(r'^plugins \{.*?^\}\n', s, re.S | re.M)
    if not m:
        die('не найден блок plugins { } в build.gradle.kts')
    s = s[:m.end()] + LOADER + s[m.end():]

    # 2. Конфигурация подписи release и выбор ключа.
    m = re.search(r'^    buildTypes \{', s, re.M)
    if not m:
        die('не найден блок buildTypes { } в build.gradle.kts')
    s = s[:m.start()] + SIGNING + s[m.start():]
    s, n = re.subn(r'(release \{.*?)signingConfig = signingConfigs\.getByName\("debug"\)',
                   lambda x: x.group(1) + RELEASE_SIGNING, s, count=1, flags=re.S)
    if n != 1:
        die('не найдено signingConfig = signingConfigs.getByName("debug") в release { }')

    # 3. compileSdk / targetSdk не ниже 36.
    s, n1 = re.subn(r'compileSdk = flutter\.compileSdkVersion',
                    f'compileSdk = maxOf(flutter.compileSdkVersion, {MIN_SDK_TARGET})', s, count=1)
    s, n2 = re.subn(r'targetSdk = flutter\.targetSdkVersion',
                    f'targetSdk = maxOf(flutter.targetSdkVersion, {MIN_SDK_TARGET})', s, count=1)
    if n1 != 1 or n2 != 1:
        die('не найдены compileSdk/targetSdk = flutter.*SdkVersion — проверьте шаблон flutter create')

    open(path, 'w', encoding='utf-8').write(s)
    print('build.gradle.kts: подпись release из key.properties, targetSdk >= 36')


if __name__ == '__main__':
    main()
