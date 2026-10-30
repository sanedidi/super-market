// Firebase проекта super-market-c7b84: приложение «SM Сотрудник»
// (Android uz.supermarket.sm_employee, iOS uz.supermarket.smEmployee).
// Зарегистрировано в Firebase 30 окт 2026 (SM Sotrudnik Android / iOS);
// ключ APNs — в Cloud Messaging → SM Sotrudnik iOS. Пустой appId выключает
// пуши на платформе (currentPlatform == null).
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class EmployeeFirebaseOptions {
  static FirebaseOptions? get currentPlatform => switch (defaultTargetPlatform) {
        TargetPlatform.android when !kIsWeb && android.appId != '' => android,
        TargetPlatform.iOS when !kIsWeb && ios.appId != '' => ios,
        _ => null,
      };

  static const android = FirebaseOptions(
    apiKey: 'AIzaSyA0B1SkpzE6i27bgy3QgpWQxzVP70V0X6I',
    appId: '1:707728920683:android:0037e64c63c99eda2fa12e',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
  );

  static const ios = FirebaseOptions(
    apiKey: 'AIzaSyBhDVsD-loVhOvwQhOeh74bSHpwMma2AGo',
    appId: '1:707728920683:ios:d5ae1733bd64a0bf2fa12e',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
    iosBundleId: 'uz.supermarket.smEmployee',
  );
}
