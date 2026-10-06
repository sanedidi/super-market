# Выпуск приложений в Google Play и App Store

Приложения: покупатель (`apps/client`), магазин (`apps/store`, «SM Магазин»), курьер (`apps/courier`, «SM Курьер»).

| Приложение | Android (package, навсегда после первой загрузки) | iOS (bundle id) |
|---|---|---|
| Покупатель | `uz.supermarket.sm_client` | `uz.supermarket.smClient` |
| Магазин | `uz.supermarket.sm_store` | `uz.supermarket.smStore` |
| Курьер | `uz.supermarket.sm_courier` | `uz.supermarket.smCourier` |

## Android: ключ загрузки (один раз)

Google Play принимает только AAB, подписанный **ключом загрузки** (upload key). Debug-подпись Play отклоняет.
Один ключ загрузки подходит для всех трёх приложений.

### 1. Создать ключ

Нужна Java (keytool входит в JDK / Android Studio):

```sh
keytool -genkeypair -v -keystore upload-keystore.jks -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

keytool спросит пароль хранилища, имя/организацию и пароль ключа (можно тот же самый).
Пароль без символа `\` — так проще.

**Сохраните `upload-keystore.jks` и пароли в менеджере паролей.** Файл не кладите в git
(`*.jks` и `key.properties` уже в `.gitignore`).

### 2. Добавить секреты в GitHub

Нужен [GitHub CLI](https://cli.github.com) (`gh auth login`). Из папки, где лежит `upload-keystore.jks`:

```sh
# macOS
base64 -i upload-keystore.jks | gh secret set ANDROID_KEYSTORE_BASE64 --repo sanedidi/super-market
# Linux
base64 -w0 upload-keystore.jks | gh secret set ANDROID_KEYSTORE_BASE64 --repo sanedidi/super-market

gh secret set ANDROID_KEYSTORE_PASSWORD --repo sanedidi/super-market   # введите пароль хранилища
gh secret set ANDROID_KEY_ALIAS --repo sanedidi/super-market --body upload
gh secret set ANDROID_KEY_PASSWORD --repo sanedidi/super-market        # введите пароль ключа

# Ключ Яндекс MapKit для приложения покупателя (без него сборка пройдёт, но карта не загрузится)
gh secret set YANDEX_MAPKIT_KEY --repo sanedidi/super-market
```

Проверить: `gh secret list --repo sanedidi/super-market`.

Если секретов нет, workflow `release` падает с сообщением «Не заданы секреты репозитория: …».

### 3. Play App Signing

При создании приложения в Play Console оставьте **Play App Signing** включённым (по умолчанию для новых приложений):
Google хранит ключ подписи приложения и сам переподписывает сборки, а наш `upload-keystore.jks` — только ключ загрузки.
Если ключ загрузки потеряется, его можно сбросить через Play Console (Настройка → Целостность приложения),
приложение при этом не теряется. SHA-1/SHA-256 для внешних сервисов (если понадобятся) берите
из Play Console → «Целостность приложения» → сертификат ключа подписи приложения.

## Android: сборка AAB

Workflow **release** (`.github/workflows/release.yml`) собирает три AAB, подписанные ключом загрузки:

- вручную: GitHub → Actions → **release** → Run workflow (или `gh workflow run release.yml --repo sanedidi/super-market --ref main`);
- по тегу: `git tag v1.0.0 && git push origin v1.0.0`.

Ручной запуск появляется в Actions после того, как `release.yml` попадёт в ветку по умолчанию (`main`).

**versionCode** = номер запуска workflow (`github.run_number`), растёт с каждым запуском — повторная загрузка
в Play не упрётся в «версия уже использована». Если в Play уже загружена сборка с бо́льшим кодом, задайте
число в поле `build_number` при ручном запуске (`gh workflow run release.yml ... -f build_number=120`).
**versionName** — из `version:` в `pubspec.yaml` каждого приложения.

**Где взять AAB:** страница запуска workflow → Artifacts → `client-aab`, `store-aab`, `courier-aab`
(внутри `app-release.aab`), или `gh run download <id запуска> --repo sanedidi/super-market -n client-aab`.
Файл загружается в Play Console → «Тестирование» / «Рабочая версия» → «Создать выпуск».

Workflow проверяет, что AAB не подписан debug-ключом, и удаляет ключ с раннера после сборки.

### Как устроена подпись

- **client**: `android/app/build.gradle.kts` читает `android/key.properties`. Есть файл — release подписывается
  ключом загрузки; нет — debug-ключом, чтобы `flutter run --release` работал локально.
- **store, courier**: папки платформ создаёт `flutter create`, затем `branding/apply.sh` вызывает
  `apps/scripts/android_release_signing.py` — он добавляет то же самое в созданный `build.gradle.kts`.

Локальная подписанная сборка — создайте `android/key.properties` в папке приложения:

```properties
storeFile=/полный/путь/upload-keystore.jks
storePassword=пароль хранилища
keyAlias=upload
keyPassword=пароль ключа
```

и запустите `flutter build appbundle --release`.

### targetSdk

Google Play с 31 августа 2026 требует targetSdk 36. CI собирает на Flutter 3.44.x (как требует
`apps/client/pubspec.lock`), у него по умолчанию compileSdk и targetSdk = 36. Дополнительно
`build.gradle.kts` всех трёх приложений задаёт `maxOf(flutter.targetSdkVersion, 36)` — ниже 36 не опустится
даже на более старом Flutter.

### Что заполнить в Play Console

- **Безопасность данных (Data safety)** — так же, как манифест конфиденциальности iOS ниже.
- **Курьер**: разрешение фоновой службы `FOREGROUND_SERVICE_LOCATION` — в «Содержание приложения» →
  «Разрешения фоновых служб» описать: курьер сам включает смену, пока смена идёт — уведомление «Вы на смене»
  и отправка точки покупателю; нужно короткое видео. `ACCESS_BACKGROUND_LOCATION` приложение не запрашивает.
- **Только HTTPS**: в release HTTP запрещён (`usesCleartextTraffic` есть только в debug-манифесте покупателя
  для локального backend).

## iOS / App Store

- **Xcode 26** (iOS 26 SDK) обязателен: с 28 апреля 2026 App Store Connect принимает только сборки на нём.
- **Сборка:** покупатель — `flutter build ipa` в `apps/client`; магазин и курьер —
  `bash apps/store/branding/build_ios.sh`, `bash apps/courier/branding/build_ios.sh`. Номер сборки — `+N` в `pubspec.yaml`.
- **Манифест конфиденциальности** `PrivacyInfo.xcprivacy` (требование Apple):
  - покупатель — `apps/client/ios/Runner/PrivacyInfo.xcprivacy`, добавлен в ресурсы цели Runner в `project.pbxproj`;
  - магазин и курьер — `apps/<app>/branding/ios/PrivacyInfo.xcprivacy`; `branding/apply.sh` копирует его в
    `ios/Runner/` и добавляет в проект скриптом `apps/scripts/ios_add_resource.py`.

  Содержимое: отслеживания нет (`NSPrivacyTracking = false`, доменов нет); собираемые данные связаны
  с аккаунтом и нужны только для работы приложения (App Functionality):
  покупатель — телефон, имя, адрес доставки, точная геопозиция, ID пользователя, история покупок;
  магазин — телефон, имя, точная геопозиция (точка магазина), фото (накладные, полки), ID пользователя;
  курьер — телефон, имя, точная геопозиция, ID пользователя.
  API с обязательной причиной: UserDefaults `CA92.1` (shared_preferences), у магазина ещё FileTimestamp `C617.1`
  (файлы фото). Данные о сбоях не собираются. Ответы в App Store Connect → «Конфиденциальность приложения»
  должны совпадать с манифестом. Проверка: Xcode → Organizer → архив → Generate Privacy Report.
  Если появится новый сбор данных (аналитика, Crashlytics и т.п.) — обновите манифест и анкеты в обоих магазинах.
- **Push (`aps-environment`)**: в `Runner.entitlements` стоит `development`, чтобы работали отладочные сборки.
  При Distribute App / `flutter build ipa` Xcode переподписывает приложение профилем App Store, и в нём
  `production` — менять файл вручную не нужно. Проверить в готовом `.ipa`:
  `codesign -d --entitlements - Payload/Runner.app` → `aps-environment = production`.
- **Только HTTPS**: исключение App Transport Security (`NSAllowsArbitraryLoads`) убрано — API и медиа на
  `https://api.super-market.uz`. Для локального backend по HTTP на iPhone исключение не коммитьте.
