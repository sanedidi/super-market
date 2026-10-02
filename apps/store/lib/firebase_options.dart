// Firebase проекта super-market-c7b84: приложение магазина (iOS uz.supermarket.smStore,
// Android uz.supermarket.sm_store). Ключи — публичные ключи приложений, не серверные.
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
    appId: '1:707728920683:android:9e2550eaa11faf802fa12e',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
  );

  static const ios = FirebaseOptions(
    apiKey: 'AIzaSyBhDVsD-loVhOvwQhOeh74bSHpwMma2AGo',
    appId: '1:707728920683:ios:fbc5f5b12e9352b12fa12e',
    messagingSenderId: '707728920683',
    projectId: 'super-market-c7b84',
    storageBucket: 'super-market-c7b84.firebasestorage.app',
    iosBundleId: 'uz.supermarket.smStore',
  );
}
