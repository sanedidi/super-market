# Flutter-приложения

```
apps/
  core/     общий пакет: API-клиент с токенами, вход по коду из Telegram, форматирование
  client/   приложение покупателя (Android, iOS)
  pos/      POS для кассы (Android-планшет, телефон, Windows, macOS)
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
flutter run --dart-define=API_URL=http://169.58.31.233:8090/api/v1
```

Иконку и splash нужно пересоздавать только после смены картинок в `assets/branding/`.

Структура `lib/`: `ui/theme.dart` — цвета, шрифт Inter, типографика из Figma; `ui/widgets.dart` —
общие компоненты (кнопки, чипы, карточки товара и магазина, плитки категорий, нижнее меню);
`screens/` — экраны; `state.dart` — адреса, магазины рядом, корзина.

## POS (apps/pos)

Платформенные папки POS пока не созданы:

```sh
cd apps/pos
flutter create --org uz.supermarket --project-name sm_pos --platforms android,ios,windows,macos .
flutter pub get
flutter run --dart-define=API_URL=http://169.58.31.233:8090/api/v1
```

Локальный backend: `--dart-define=API_URL=http://10.0.2.2:8080/api/v1` (эмулятор Android) или
`http://localhost:8080/api/v1` (iOS-симулятор, десктоп).

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

**POS:** вход сотрудника с правом `sales.pos`; выбор магазина; каталог с ценами магазина хранится на
устройстве; поиск по названию и сканер штрихкодов (сканер-клавиатура: код + Enter); чек с количеством
и скидкой (право `sales.discount`); оплата по нескольким способам и сдача; **работа без интернета** —
продажа сохраняется на устройстве и досылается каждые 30 секунд, повтор безопасен (`client_uid`);
продажи за сегодня; ввод номера и фискального признака чека кассового аппарата.
Возвраты и отчёты — в веб-панели магазина.
