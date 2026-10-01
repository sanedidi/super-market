import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sm_core/sm_core.dart';

import 'logic.dart';

/// Состояние курьера: профиль и смена, заказы (обновляются каждые 15 секунд),
/// отправка геопозиции, пока курьер на смене.
class CourierState extends ChangeNotifier {
  CourierState(this.api) {
    api.addListener(_onAuth);
  }
  final Api api;

  Map<String, dynamic>? me;
  List<CourierOrder> orders = [];
  bool loading = false;
  Object? error;

  /// Нет права доставки или вход отключён — показываем экран «нет доступа».
  String? noAccess;

  /// Проблема с геопозицией (null — всё в порядке).
  String? locationProblem;

  /// Когда последний раз ушла точка на сервер.
  DateTime? lastLocationAt;

  /// Заказы, которые появились с прошлого обновления (подсветка в списке).
  Set<String> fresh = {};

  bool get onShift => me?['on_shift'] == true;
  String get vehicle => '${me?['vehicle'] ?? 'foot'}';

  Timer? _poll;
  StreamSubscription<Position>? _positions;

  void _onAuth() {
    if (!api.loggedIn) {
      _stopTracking();
      _poll?.cancel();
      _poll = null;
      me = null;
      orders = [];
      noAccess = null;
      error = null;
      fresh = {};
      _loadedOnce = false;
      notifyListeners();
    }
  }

  /// Первая загрузка после входа и «Повторить».
  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      me = await api.get('/courier/me') as Map<String, dynamic>;
      noAccess = null;
      await refreshOrders();
      if (onShift) unawaited(_startTracking());
      _poll ??= Timer.periodic(const Duration(seconds: 15), (_) => refreshOrders().catchError((_) {}));
    } on ApiError catch (e) {
      if (e.status == 403) {
        noAccess = e.message;
      } else {
        error = e;
      }
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  bool _loadedOnce = false;

  /// Обновить заказы. Новые (кроме первой загрузки) — вибрация и подсветка.
  Future<void> refreshOrders() async {
    final list = await api.list('/courier/orders');
    final added = newOrderIds(orders, list);
    final first = !_loadedOnce;
    _loadedOnce = true;
    orders = list;
    if (added.isNotEmpty && !first) {
      fresh = {...fresh, ...added};
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    }
    notifyListeners();
  }

  /// Заказ прочитан — снять подсветку.
  void seen(String id) {
    if (fresh.remove(id)) notifyListeners();
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

  /// «Забрал» (picked-up) или «Доставил» (delivered). Ответ заменяет заказ в списке.
  Future<CourierOrder> act(String id, String action) async {
    final r = await api.post('/courier/orders/$id/$action') as Map<String, dynamic>;
    final i = orders.indexWhere((c) => idOf(c) == id);
    if (i >= 0) {
      orders = [...orders]..[i] = r;
    }
    notifyListeners();
    return r;
  }

  Future<CourierOrder> order(String id) async => await api.get('/courier/orders/$id') as Map<String, dynamic>;

  Future<Map<String, dynamic>> history(String period) async => await api.get('/courier/history', {'period': period}) as Map<String, dynamic>;

  Future<void> logout() async {
    try {
      if (onShift) await setShift(onShift: false);
    } catch (_) {
      // Сеть пропала — всё равно выходим.
    }
    await api.logout();
  }

  /// Ещё раз попробовать включить геопозицию (после настроек телефона).
  Future<void> retryLocation() async {
    _stopTracking();
    if (onShift) await _startTracking();
  }

  Future<void> openLocationSettings() async {
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
    } else if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
    } else {
      await retryLocation();
    }
  }

  Future<void> _startTracking() async {
    if (_positions != null) return;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        locationProblem = 'Геолокация на телефоне выключена';
        notifyListeners();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        locationProblem = 'Нет доступа к геопозиции';
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
        locationProblem = 'Геопозиция недоступна';
        _positions = null;
        notifyListeners();
      });
      // Первая точка сразу — не ждём, пока курьер сдвинется на 15 метров.
      unawaited(Geolocator.getCurrentPosition().then(_send, onError: (Object _) {}));
    } catch (e) {
      locationProblem = 'Геопозиция недоступна';
      notifyListeners();
    }
  }

  void _stopTracking() {
    _positions?.cancel();
    _positions = null;
  }

  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

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
      lastLocationAt = now;
      if (locationProblem != null) locationProblem = null;
      notifyListeners();
    } catch (_) {
      // Сеть пропала — пришлём следующую точку.
    }
  }

  @override
  void dispose() {
    api.removeListener(_onAuth);
    _stopTracking();
    _poll?.cancel();
    super.dispose();
  }
}
