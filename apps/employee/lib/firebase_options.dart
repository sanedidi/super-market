// Firebase проекта super-market-c7b84: приложение «SM Сотрудник»
// (Android uz.supermarket.sm_employee, iOS uz.supermarket.smEmployee).
// Приложение ещё не зарегистрировано в Firebase — пуши выключены
// (currentPlatform == null). Зарегистрируйте его в консоли Firebase и
// впишите appId сюда (apiKey и проект — общие, как у «SM Магазин»).
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
    appId: '',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
  );

  static const ios = FirebaseOptions(
    apiKey: 'AIzaSyBhDVsD-loVhOvwQhOeh74bSHpwMma2AGo',
    appId: '',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
    iosBundleId: 'uz.supermarket.smEmployee',
  );
}
