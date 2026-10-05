// Push-уведомления сотруднику: новый заказ, заказ ждёт, курьер по пути взял
// заказ, накладная распознана, итоги дня владельцу, покупатель оспаривает долг. Токен устройства — POST /store/devices.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import 'customers/customer_debts_screen.dart';
import 'firebase_options.dart';
import 'receipt/review_screen.dart';
import 'screens/order_screen.dart';
import 'summary/summary_screen.dart';

/// Навигатор приложения — чтобы открыть заказ или накладную из уведомления.
final navigatorKey = GlobalKey<NavigatorState>();

class Push {
  Push._();

  static bool _ready = false;
  static String? _token;
  static StreamSubscription<String>? _refresh;
  static bool _listening = false;

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
        _token = token;
        try {
          await api.post('/store/devices', {
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

      if (!_listening) {
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
            action: SnackBarAction(label: 'Открыть', onPressed: () => _open(m)),
          ));
        });
      }
    } catch (e) {
      debugPrint('push: $e');
    }
  }

  /// Перед выходом: устройство больше не получает уведомления этого сотрудника.
  static Future<void> unregister(Api api) async {
    final t = _token;
    if (t == null) return;
    try {
      await api.delete('/store/devices/${Uri.encodeComponent(t)}');
    } catch (_) {
      // не страшно: сервер удалит токен, когда FCM скажет, что он недействителен
    }
    _token = null;
  }

  static void _open(RemoteMessage m) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    final d = m.data;
    switch (d['type']) {
      case 'order':
        final id = d['order_id'];
        if (id is String && id.isNotEmpty) nav.push(MaterialPageRoute(builder: (_) => OrderScreen(id: id)));
      case 'invoice':
        final id = d['scan_id'];
        if (id is String && id.isNotEmpty) nav.push(MaterialPageRoute(builder: (_) => ReviewScreen(id: id)));
      case 'debt_dispute':
        nav.push(MaterialPageRoute(builder: (_) => const CustomerDebtsScreen(status: 'disputes')));
      case 'summary':
        final date = d['date'];
        nav.push(MaterialPageRoute(builder: (_) => SummaryScreen(date: date is String ? date : null)));
    }
  }
}
