import Flutter
import UIKit
import YandexMapsMobile

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Ключ MapKit — до регистрации плагинов, иначе yandex_mapkit падает при старте.
    YMKMapKit.setLocale("ru_RU")
    // Ключ задаётся в ios/Flutter/Secrets.xcconfig (не хранится в git), см. apps/README.md.
    let key = Bundle.main.object(forInfoDictionaryKey: "YandexMapkitApiKey") as? String ?? ""
    YMKMapKit.setApiKey(key)
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
