# Flutter-приложения

```
apps/
  core/     общий пакет: API-клиент с токенами, вход по коду из Telegram, форматирование
  client/   приложение покупателя (Android, iOS)
  pos/      POS для кассы (Android-планшет, телефон, Windows, macOS)
```

> Код написан без запуска Flutter (в среде сборки не было Flutter SDK). Перед первым запуском
> выполните шаги ниже; если анализатор найдёт ошибки — они будут мелкими (имена параметров плагинов).

## Первый запуск

Платформенные папки (`android/`, `ios/`, `windows/`, `macos/`) не хранятся в репозитории — их создаёт Flutter:

```sh
cd apps/client
flutter create --org uz.supermarket --project-name sm_client --platforms android,ios .
flutter pub get
flutter run --dart-define=API_URL=http://169.58.31.233:8090/api/v1

cd ../pos
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

1. Получите ключ MapKit Mobile SDK в кабинете разработчика Яндекса.
2. Android — `android/app/src/main/kotlin/.../MainActivity.kt`:
   ```kotlin
   import com.yandex.mapkit.MapKitFactory
   import io.flutter.embedding.android.FlutterActivity
   import io.flutter.embedding.engine.FlutterEngine

   class MainActivity : FlutterActivity() {
       override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
           MapKitFactory.setLocale("ru_RU")
           MapKitFactory.setApiKey("ВАШ_КЛЮЧ")
           super.configureFlutterEngine(flutterEngine)
       }
   }
   ```
   В манифесте — разрешения:
   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
   <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
   ```
   `minSdkVersion` — не ниже 26 (требование yandex_mapkit).
3. iOS — `ios/Runner/AppDelegate.swift`:
   ```swift
   import YandexMapsMobile
   // в application(_:didFinishLaunchingWithOptions:) до GeneratedPluginRegistrant:
   YMKMapKit.setLocale("ru_RU")
   YMKMapKit.setApiKey("ВАШ_КЛЮЧ")
   ```
   В `Info.plist`: `NSLocationWhenInUseUsageDescription` — «Чтобы показать магазины рядом».
   Platform в `ios/Podfile` — не ниже 13.0.

Вся работа с картой — в `client/lib/map_view.dart`.

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
