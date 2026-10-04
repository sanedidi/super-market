# Flutter-приложения

```
apps/
  core/     общий пакет: API-клиент с токенами, вход по коду из Telegram, форматирование
  client/   приложение покупателя (Android, iOS)
  pos/      касса (Windows, Android): быстрый режим, работа без интернета
  courier/  приложение курьера магазина (Android, iOS)
  store/    приложение магазина: приход по фото накладной, склад (Android, iOS)
```

## Приложение покупателя (apps/client)

Код один для iOS и Android — в `lib/`. Папки `android/` и `ios/` — настройки платформ
(разрешения, ключ карт, иконка), они хранятся в репозитории.

Требуется Flutter 3.27 или новее.

### Ключ Яндекс MapKit (не хранится в git)

- iOS — создайте `apps/client/ios/Flutter/Secrets.xcconfig`:
  ```
  YANDEX_MAPKIT_API_KEY = ваш-ключ
  ```
- Android — добавьте строку в `apps/client/android/local.properties`:
  ```
  yandex.mapkit.key=ваш-ключ
  ```

### Запуск

```sh
cd apps/client
flutter pub get
dart run flutter_launcher_icons          # иконка приложения из assets/branding
dart run flutter_native_splash:create    # белый экран с логотипом при запуске
flutter run 
```

Иконку и splash нужно пересоздавать только после смены картинок в `assets/branding/`.

Структура `lib/`: `ui/theme.dart` — цвета, шрифт Inter, типографика из Figma; `ui/widgets.dart` —
общие компоненты (кнопки, чипы, карточки товара и магазина, плитки категорий, нижнее меню);
`screens/` — экраны; `state.dart` — адреса, магазины рядом, корзина.

### Push-уведомления (Firebase)

Проект Firebase — `super-market-c7b84`. Настройки для приложения уже в коде: `lib/firebase_options.dart`
(файлы `google-services.json` и `GoogleService-Info.plist` лежат рядом для справки). Логика — в `lib/push.dart`:
после входа приложение спрашивает разрешение, отправляет токен на сервер (`POST /client/devices`),
нажатие на уведомление о заказе открывает экран заказа.

- iOS: включены `aps-environment` (`ios/Runner/Runner.entitlements`) и фоновый режим `remote-notification`.
  Чтобы push доходили на iPhone, в Firebase → Project settings → Cloud Messaging загрузите APNs-ключ (.p8)
  из Apple Developer. Для выпуска в App Store поменяйте `aps-environment` на `production`.
- Сервер: ключ сервисного аккаунта в `FCM_CREDENTIALS` (base64) в секрете `PROD_ENV`.

## Касса (apps/pos)

Касса для Windows и Android: быстрый режим с клавиатуры, работа без интернета. Готовые сборки
делает CI (workflow `apps`): артефакты **pos-windows** (папка с `SuperMarketPOS.exe`) и **pos-android** (APK).
Логотип и название — в `apps/pos/branding/`, их подставляет `branding/apply.sh` после `flutter create`.

Своя сборка на Windows (нужны Flutter и Visual Studio с «Desktop development with C++»):

```sh
cd apps/pos
flutter create --platforms=windows --org uz.supermarket --project-name sm_pos .
bash branding/apply.sh   # логотип и название (Git Bash)
flutter pub get
flutter build windows --release
# готово: build\windows\x64\runner\Release\SuperMarketPOS.exe (запускать вместе со всей папкой)
```

Локальный backend: `--dart-define=API_URL=http://localhost:8080/api/v1`.

Устройство кода: `lib/core` — чек, деньги, коды без Flutter (покрыто тестами); `lib/data` — API, файлы
на диске, очередь отправки; `lib/state` — касса и продажа; `lib/ui` — экраны из Figma «POS · касса».
Данные кассы — JSON-файлы в папке приложения (`pos/`): каталог, журнал смены, очередь `outbox/`.

## Курьер (apps/courier) — «SM Курьер»

Вход — по **логину и паролю**, которые выдаёт магазин: панель магазина → «Курьеры» → «Выдать логин и пароль».
Курьер — сотрудник, у роли которого есть право «Курьер: доставка заказов». После 5 неверных паролей вход
закрывается на 15 минут; смена пароля в панели выкидывает курьера на всех телефонах.

Экраны — Figma «Курьер · приложение»: вход, смена и транспорт, заказы («Везу» и «Забрать в магазине»,
новые подсвечиваются и телефон вибрирует), карточка заказа (магазин, покупатель, звонки, маршрут в Яндекс
Картах, состав, оплата — сколько взять наличными), «Забрал» и «Доставил» (для наличных — подтверждение суммы),
история за сегодня / вчера / неделю с суммой наличных для кассы, профиль. Пока курьер на смене, приложение
раз в 10 секунд отправляет точку — покупатель видит курьера на карте. Заказы обновляются каждые 15 секунд.

Устройство кода: `lib/logic.dart` — подписи, группы заказов, адрес, время (тесты в `test/`); `lib/state.dart` —
курьер, заказы, смена, геопозиция; `lib/screens/` — экраны; `lib/ui/` — цвета, шрифт Inter, кнопки.

**Android:** готовый APK собирает GitHub Actions → workflow `apps` → артефакт `courier-android`.

**iPhone (TestFlight)** — один раз создать папки платформ и приложение в App Store Connect
(bundle id `uz.supermarket.smCourier`), дальше как у приложения покупателя:

```sh
cd apps/courier
flutter create --platforms=android,ios --org uz.supermarket --project-name sm_courier .
rm -f test/widget_test.dart
bash branding/apply.sh        # название «SM Курьер», логотип, разрешения на геопозицию
flutter build ipa
open build/ios/archive/Runner.xcarchive   # Distribute App → App Store Connect
```

`branding/apply.sh` добавляет разрешения: геопозиция (в том числе в фоне), фоновая служба Android с
уведомлением «Вы на смене», вибрация, ссылки на звонок и карты. Логотип — из `branding/`.

## Настройки платформ

### Сервер пока по HTTP

Пока у сервера нет домена и HTTPS, разрешите HTTP:

- Android — `android/app/src/main/AndroidManifest.xml`, в `<application ...>`:
  `android:usesCleartextTraffic="true"`
- iOS/macOS — `Info.plist`:
  ```xml
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  ```
- macOS (POS) — в `macos/Runner/DebugProfile.entitlements` и `Release.entitlements`:
  `<key>com.apple.security.network.client</key><true/>`

После перехода на HTTPS эти исключения нужно убрать.

### Приложение покупателя: Яндекс Карты и геолокация

Уже настроено в `android/` и `ios/`: ключ MapKit читается из секретов выше (iOS — `AppDelegate.swift`
через `Info.plist`, Android — `MainActivity.kt` через `BuildConfig`) и задаётся до регистрации
плагинов; разрешения на геолокацию, `minSdk = 26`. Вся работа с картой — в `client/lib/map_view.dart`.

## Что умеют приложения

**Покупатель:** вход по коду из Telegram-бота; адреса доставки с точкой на карте; магазины, которые
доставляют по адресу (списком и на карте, три ближайших открытых — «Рядом»); каталог магазина с
категориями и поиском; корзина одного магазина с пересчётом на сервере (наличие, минимальная сумма,
доставка, бесплатная доставка от суммы); оплата Payme или Click (открывается страница оплаты);
заказы со статусом, который обновляется сам, отмена до принятия, повторная оплата.

**Касса:** подключение кодом из панели; вход кассира по ПИНу (проверка на кассе, без интернета);
смена с разменом, внесения, изъятия, X-отчёт, закрытие со слепым пересчётом и причиной расхождения;
продажа: скан, короткий код + Enter, весовые этикетки, DataMatrix, количество (`*` или кнопка), скидка F6,
отложенные F7, поиск F2; оплата в окнах — Enter или «Оплатить» → способ (1–4) → наличные с клавиатурой
на экране, «Ровно» (пробел) и подсказками купюр, карта, Payme·Click, смешанная; всё работает и пальцем; возврат по чеку F9 (онлайн, ПИН старшего). Всё пишется в очередь и досылается само.
Пока тестовый режим чека — фискальный модуль и принтер подключаются на этапе 3.

## Магазин (apps/store) — «SM Магазин»

Сотрудники магазина входят по номеру и коду из Telegram (токен `store`, права как в панели).
Версия 0.1: главная, склад, приход по фото накладной (ИИ читает накладную, строки сопоставляются
с каталогом, «Провести»), выбор магазина. Заказы и финансы — следующие версии.
ИИ-сервис настраивает супер-админ (раздел «ИИ-сервис»); без него приход по фото недоступен.
Первый вход владельца новой сети — мастер «Первая настройка» (магазин и точка на карте, часы работы, доставка);
карта — OpenStreetMap через flutter_map, ключи не нужны, разрешение на геолокацию добавляет `branding/apply.sh`.

**iPhone:** `bash apps/store/branding/build_ios.sh` (создаёт папки платформ, настраивает камеру и подпись,
проверяет код `flutter analyze`, собирает архив и открывает его в Xcode → Distribute App).
Bundle ID — `uz.supermarket.smStore`, запись в App Store Connect нужно создать перед первой загрузкой.
