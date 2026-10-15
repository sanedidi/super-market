// Firebase проекта super-market-c7b84: приложение «SM Агент» (iOS uz.supermarket.smDistributor).
// Ключ — общий публичный iOS-ключ проекта (как у «SM Магазин»), не серверный.
// Android-сборки у агента пока нет — на Android пуши выключены.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class AgentFirebaseOptions {
  static FirebaseOptions? get currentPlatform => switch (defaultTargetPlatform) {
        TargetPlatform.iOS when !kIsWeb => ios,
        _ => null,
      };

  static const ios = FirebaseOptions(
    apiKey: 'AIzaSyBhDVsD-loVhOvwQhOeh74bSHpwMma2AGo',
    appId: '1:707728920683:ios:81e5b1f9876c37d92fa12e',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
    iosBundleId: 'uz.supermarket.smDistributor',
  );
}
