import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sm_core/sm_core.dart';

/// Курьер: профиль и смена, заказы, отправка геопозиции во время смены.
class CourierState extends ChangeNotifier {
  CourierState(this.api) {
    api.addListener(() {
      if (!api.loggedIn) {
        _stopTracking();
        me = null;
        orders = [];
        notifyListeners();
      }
    });
  }
  final Api api;

  Map<String, dynamic>? me;
  List<Map<String, dynamic>> orders = [];

  /// Нет права orders.deliver.
  bool notCourier = false;

  /// Геопозиция: null — не запрашивали, иначе последняя ошибка или «ок».
  String? locationProblem;

  bool get onShift => me?['on_shift'] == true;
  String get vehicle => (me?['vehicle'] as String?) ?? 'foot';

  StreamSubscription<Position>? _positions;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> load() async {
    try {
      me = await api.get('/courier/me') as Map<String, dynamic>;
      notCourier = false;
    } on ApiError catch (e) {
      if (e.status == 403) {
        notCourier = true;
        notifyListeners();
        return;
      }
      rethrow;
    }
    await loadOrders();
    if (onShift) await _startTracking();
  }

  Future<void> loadOrders() async {
    orders = await api.list('/courier/orders');
    notifyListeners();
  }

  Future<void> setShift({bool? onShift, String? vehicle}) async {
    me = await api.post('/courier/shift', {
      if (onShift != null) 'on_shift': onShift,
      if (vehicle != null) 'vehicle': vehicle,
    }) as Map<String, dynamic>;
    notifyListeners();
    if (this.onShift) {
      await _startTracking();
    } else {
      _stopTracking();
    }
  }

  /// Забрал заказ / доставил — ответ сервера заменяет заказ в списке.
  Future<Map<String, dynamic>> act(String orderId, String action) async {
    final r = await api.post('/courier/orders/$orderId/$action') as Map<String, dynamic>;
    final i = orders.indexWhere((o) => (o['order'] as Map)['id'] == orderId);
    if (i >= 0) orders[i] = r;
    notifyListeners();
    return r;
  }

  Future<void> _startTracking() async {
    if (_positions != null) return;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        locationProblem = 'Включите геолокацию на телефоне';
        notifyListeners();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        locationProblem = 'Разрешите доступ к геопозиции — без неё покупатель не видит курьера';
        notifyListeners();
        return;
      }
      locationProblem = null;
      notifyListeners();
      final LocationSettings settings = switch (defaultTargetPlatform) {
        TargetPlatform.android => AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 15,
            intervalDuration: const Duration(seconds: 10),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Вы на смене',
              notificationText: 'Покупатели видят, где их заказ',
              enableWakeLock: true,
            ),
          ),
        TargetPlatform.iOS => AppleSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 15,
            activityType: ActivityType.automotiveNavigation,
            pauseLocationUpdatesAutomatically: false,
            allowBackgroundLocationUpdates: true,
            showBackgroundLocationIndicator: true,
          ),
        _ => const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 15),
      };
      _positions = Geolocator.getPositionStream(locationSettings: settings).listen(_send, onError: (Object e) {
        locationProblem = 'Геопозиция недоступна: $e';
        notifyListeners();
      });
    } catch (e) {
      locationProblem = 'Геопозиция недоступна: $e';
      notifyListeners();
    }
  }

  void _stopTracking() {
    _positions?.cancel();
    _positions = null;
  }

  /// Не чаще раза в 10 секунд.
  Future<void> _send(Position p) async {
    final now = DateTime.now();
    if (now.difference(_lastSent) < const Duration(seconds: 10)) return;
    _lastSent = now;
    try {
      await api.post('/courier/location', {
        'lat': p.latitude,
        'lng': p.longitude,
        'accuracy': p.accuracy.round(),
        if (p.heading >= 0 && p.heading < 360) 'heading': p.heading.floor(),
      });
    } catch (_) {
      // Сеть пропала — пришлём следующую точку.
    }
  }

  @override
  void dispose() {
    _stopTracking();
    super.dispose();
  }
}
