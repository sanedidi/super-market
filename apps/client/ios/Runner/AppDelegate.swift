import Flutter
import UIKit
import YandexMapsMobile

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Push: с неявным движком (UIScene) плагины регистрируются уже после запуска,
    // и firebase_messaging не успевает запросить токен APNs — без него нет токена FCM
    // и уведомления не приходят. Регистрируемся сами, токен Firebase подхватит сам.
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Ключ MapKit — до регистрации плагинов, иначе yandex_mapkit падает при старте.
    // Язык карты — язык приложения (Lang в sm_core хранит его в shared_preferences,
    // ключ flutter.sm_lang). Меняется со следующего запуска.
    let lang = UserDefaults.standard.string(forKey: "flutter.sm_lang") ?? "uz"
    YMKMapKit.setLocale(lang == "ru" ? "ru_RU" : "uz_UZ")
    // Ключ задаётся в ios/Flutter/Secrets.xcconfig (не хранится в git), см. apps/README.md.
    let key = Bundle.main.object(forInfoDictionaryKey: "YandexMapkitApiKey") as? String ?? ""
    YMKMapKit.setApiKey(key)
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
