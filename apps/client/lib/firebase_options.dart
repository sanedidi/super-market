// Настройки Firebase (проект super-market-c7b84) — из google-services.json и
// GoogleService-Info.plist. Это не секреты: ключи клиентских приложений.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions? get currentPlatform => switch (defaultTargetPlatform) {
        TargetPlatform.android when !kIsWeb => android,
        TargetPlatform.iOS when !kIsWeb => ios,
        _ => null,
      };

  static const android = FirebaseOptions(
    apiKey: 'AIzaSyA0B1SkpzE6i27bgy3QgpWQxzVP70V0X6I',
    appId: '1:707728920683:android:3f0e4f4454ce9ee32fa12e',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
  );

  static const ios = FirebaseOptions(
    apiKey: 'AIzaSyBhDVsD-loVhOvwQhOeh74bSHpwMma2AGo',
    appId: '1:707728920683:ios:aea665a7161bba722fa12e',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
    iosBundleId: 'uz.supermarket.smClient',
  );
}
