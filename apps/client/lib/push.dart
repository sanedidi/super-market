// Push-уведомления: Firebase Cloud Messaging.
//
// После входа спрашиваем разрешение, отправляем токен устройства на сервер
// (POST /client/devices; гостю push не регистрируем — токен привязан к аккаунту) и обновляем его при смене. Нажатие на уведомление
// открывает нужный экран (links.dart): заказ, магазин, товар, раздел…
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import 'firebase_options.dart';
import 'links.dart';

/// Навигатор приложения — чтобы открыть заказ из уведомления.
final navigatorKey = GlobalKey<NavigatorState>();

class Push {
  Push._();

  static bool _ready = false;
  static StreamSubscription<String>? _refresh;

  /// Переходы из уведомлений подключены (register зовётся после каждого входа).
  static bool _listening = false;

  /// Запуск Firebase. Ошибка (например, нет сети при первом запуске) не мешает приложению.
  static Future<void> init() async {
    final options = DefaultFirebaseOptions.currentPlatform;
    if (options == null) return;
    try {
      await Firebase.initializeApp(options: options);
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
      _ready = true;
    } catch (e) {
      debugPrint('Firebase: $e');
    }
  }

  /// После входа: разрешение, токен на сервер, переходы из уведомлений.
  static Future<void> register(Api api) async {
    if (!_ready) return;
    final fm = FirebaseMessaging.instance;
    try {
      final settings = await fm.requestPermission(alert: true, badge: true, sound: true);
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      Future<void> send(String token) async {
        try {
          await api.post('/client/devices', {
            'token': token,
            'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
          });
        } catch (e) {
          debugPrint('push: регистрация устройства: $e');
        }
      }

      // На iOS токен FCM появляется после токена APNs — подождём его.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        for (var i = 0; i < 10 && await fm.getAPNSToken() == null; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      // Подписка до getToken: если APNs ответит позже, токен всё равно уйдёт на сервер.
      await _refresh?.cancel();
      _refresh = fm.onTokenRefresh.listen(send);
      String? token;
      for (var i = 0; i < 3 && token == null; i++) {
        try {
          token = await fm.getToken();
        } catch (e) {
          debugPrint('push: токен: $e');
          await Future<void>.delayed(const Duration(seconds: 5));
        }
      }
      if (token != null) await send(token);

      if (_listening) return;
      _listening = true;
      FirebaseMessaging.onMessageOpenedApp.listen(_open);
      final initial = await fm.getInitialMessage();
      if (initial != null) _open(initial);
      // Android не показывает уведомление, пока приложение открыто, — покажем сами.
      FirebaseMessaging.onMessage.listen((m) {
        if (defaultTargetPlatform != TargetPlatform.android) return;
        final ctx = navigatorKey.currentContext;
        final n = m.notification;
        if (ctx == null || n == null) return;
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text([n.title, n.body].whereType<String>().join('\n')),
          action: m.data['type'] == null
              ? null
              : SnackBarAction(label: tr('Открыть', 'Ochish'), onPressed: () => _open(m)),
        ));
      });
    } catch (e) {
      debugPrint('push: $e');
    }
  }

  static void _open(RemoteMessage m) => openNotification(m.data);
}
