import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

/// Сохранённая точка «Дом» или «Работа» — цель маршрута «по пути».
class SavedPlace {
  const SavedPlace(this.key, this.title, this.lat, this.lng);
  final String key;
  final String title;
  final double lat;
  final double lng;
}

/// Состояние режима «по пути»: профиль, лента, мои заказы, геопозиция.
/// Токены — отдельные от штатного курьера (Api с app = crowd).
class CrowdState extends ChangeNotifier {
  CrowdState(this.api) {
    api.addListener(_onAuth);
  }
  final Api api;

  Map<String, dynamic>? me;
  Map<String, dynamic>? feed;
  List<Map<String, dynamic>> orders = [];
  List<Map<String, dynamic>> points = [];
  bool loading = false;
  Object? error;
  String? locationProblem;
  Position? lastPosition;
  Map<String, SavedPlace> places = {};

  /// Новые заказы в ленте с прошлого обновления (вибрация).
  Set<String> _seenOffers = {};

  Timer? _poll;
  StreamSubscription<Position>? _positions;

  bool get loggedIn => api.loggedIn;
  String get status => '${me?['status'] ?? ''}';
  bool get verified => status == 'active';
  bool get online => me?['online'] == true;
  String get vehicle => '${me?['vehicle'] ?? 'foot'}';
  List<Map<String, dynamic>> get offers =>
      ((feed?['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  List<Map<String, dynamic>> get activeOrders =>
      orders.where((o) => const ['picked', 'delivering'].contains('${(o['order'] as Map?)?['status']}')).toList();

  void _onAuth() {
    if (!api.loggedIn) {
      _stop();
      me = null;
      feed = null;
      orders = [];
      points = [];
      error = null;
    }
    // Вход и выход меняют экран приложения.
    notifyListeners();
  }

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      await _loadPlaces();
      me = await api.get('/crowd/me') as Map<String, dynamic>;
      await refresh(first: true);
      _poll ??= Timer.periodic(const Duration(seconds: 15), (_) => refresh().catchError((_) {}));
      unawaited(_syncTracking());
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Map<String, dynamic> get _pos =>
      lastPosition == null ? const {} : {'lat': lastPosition!.latitude, 'lng': lastPosition!.longitude};

  /// Профиль, мои заказы, лента (или точки проверки, пока не проверен).
  Future<void> refresh({bool first = false}) async {
    me = await api.get('/crowd/me') as Map<String, dynamic>;
    if (!verified) {
      points = await api.list('/crowd/points', _pos);
      notifyListeners();
      return;
    }
    orders = await api.list('/crowd/orders');
    feed = await api.get('/crowd/offers', _pos) as Map<String, dynamic>;
    final ids = offers.map((o) => '${o['order_id']}').toSet();
    if (!first && ids.difference(_seenOffers).isNotEmpty) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    }
    _seenOffers = ids;
    notifyListeners();
    unawaited(_syncTracking());
  }

  Future<void> setOnline(bool value) async {
    me = await api.put('/crowd/route', {'online': value}) as Map<String, dynamic>;
    notifyListeners();
    await _syncTracking();
    await refresh();
  }

  /// Куда иду: точка или null — «просто рядом».
  Future<void> setDest(SavedPlace? p) async {
    me = await api.put('/crowd/route', {
      'online': true,
      'dest': p == null ? null : {'lat': p.lat, 'lng': p.lng, 'title': p.title},
    }) as Map<String, dynamic>;
    notifyListeners();
    await _syncTracking();
    await refresh();
  }

  Future<void> setVehicle(String v) async {
    me = await api.put('/crowd/me', {'vehicle': v}) as Map<String, dynamic>;
    notifyListeners();
  }

  Future<Map<String, dynamic>> accept(String orderId) async {
    final r = await api.post('/crowd/offers/$orderId/accept') as Map<String, dynamic>;
    await refresh();
    return r;
  }

  Future<Map<String, dynamic>> order(String id) async => await api.get('/crowd/orders/$id') as Map<String, dynamic>;

  Future<void> release(String id) async {
    await api.post('/crowd/orders/$id/release');
    await refresh();
  }

  Future<Map<String, dynamic>> deliver(String id, String code) async {
    final r = await api.post('/crowd/orders/$id/deliver', {'code': code}) as Map<String, dynamic>;
    await refresh();
    return r;
  }

  Future<void> problem(String id, String kind) async {
    await api.post('/crowd/orders/$id/problem', {'kind': kind});
  }

  Future<Map<String, dynamic>> earnings() async => await api.get('/crowd/earnings') as Map<String, dynamic>;

  Future<void> logout() async {
    try {
      if (online) await api.put('/crowd/route', {'online': false});
    } catch (_) {
      // Сеть пропала — всё равно выходим.
    }
    await api.logout();
  }

  // ------------------------------------------------------------ места

  Future<void> _loadPlaces() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, SavedPlace>{};
    for (final (key, title) in const [('home', 'Дом'), ('work', 'Работа')]) {
      final lat = prefs.getDouble('crowd_place_${key}_lat');
      final lng = prefs.getDouble('crowd_place_${key}_lng');
      if (lat != null && lng != null) out[key] = SavedPlace(key, title, lat, lng);
    }
    places = out;
  }

  /// Запомнить текущее место как «Дом» или «Работа».
  Future<SavedPlace?> saveHere(String key, String title) async {
    final p = await _currentPosition();
    if (p == null) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('crowd_place_${key}_lat', p.latitude);
    await prefs.setDouble('crowd_place_${key}_lng', p.longitude);
    final place = SavedPlace(key, title, p.latitude, p.longitude);
    places = {...places, key: place};
    notifyListeners();
    return place;
  }

  // ------------------------------------------------------- геопозиция

  bool get _needTracking => verified && (online || activeOrders.isNotEmpty);

  Future<Position?> _currentPosition() async {
    if (!await _permission()) return null;
    try {
      final p = await Geolocator.getCurrentPosition();
      lastPosition = p;
      return p;
    } catch (_) {
      locationProblem = 'Геопозиция недоступна';
      notifyListeners();
      return null;
    }
  }

  Future<bool> _permission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      locationProblem = 'Геолокация на телефоне выключена';
      notifyListeners();
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      locationProblem = 'Нет доступа к геопозиции';
      notifyListeners();
      return false;
    }
    locationProblem = null;
    return true;
  }

  Future<void> retryLocation() async {
    _stopTracking();
    await _syncTracking();
    await refresh();
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

  /// Точки для точек проверки — один раз, без постоянного слежения.
  Future<void> locateOnce() async {
    await _currentPosition();
    await refresh();
  }

  Future<void> _syncTracking() async {
    if (!_needTracking) {
      _stopTracking();
      return;
    }
    if (_positions != null) return;
    if (!await _permission()) return;
    final LocationSettings settings = switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20,
          intervalDuration: const Duration(seconds: 15),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Ищу заказы по пути',
            notificationText: 'Super Market подбирает заказы рядом с вами',
            enableWakeLock: true,
          ),
        ),
      TargetPlatform.iOS => AppleSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20,
          activityType: ActivityType.otherNavigation,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: true,
          showBackgroundLocationIndicator: true,
        ),
      _ => const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20),
    };
    _positions = Geolocator.getPositionStream(locationSettings: settings).listen(_send, onError: (Object e) {
      locationProblem = 'Геопозиция недоступна';
      _positions = null;
      notifyListeners();
    });
    unawaited(Geolocator.getCurrentPosition().then(_send, onError: (Object _) {}));
  }

  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _send(Position p) async {
    lastPosition = p;
    final now = DateTime.now();
    if (now.difference(_lastSent) < const Duration(seconds: 10)) return;
    _lastSent = now;
    try {
      await api.post('/crowd/location', {'lat': p.latitude, 'lng': p.longitude, 'accuracy': p.accuracy.round()});
      if (locationProblem != null) {
        locationProblem = null;
        notifyListeners();
      }
    } catch (_) {
      // Сеть пропала — пришлём следующую точку.
    }
  }

  void _stopTracking() {
    _positions?.cancel();
    _positions = null;
  }

  void _stop() {
    _stopTracking();
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    api.removeListener(_onAuth);
    _stop();
    super.dispose();
  }
}
