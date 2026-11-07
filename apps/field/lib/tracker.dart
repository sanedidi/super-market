import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

import 'logic.dart';

/// Доступ к геопозиции.
enum LocationAccess { ok, denied, deniedForever, serviceOff }

/// Проверить (и при [ask] — запросить) разрешение на геопозицию.
Future<LocationAccess> locationAccess({bool ask = false}) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceOff;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied && ask) perm = await Geolocator.requestPermission();
    // iPhone сначала даёт «При использовании»; «Всегда» спросит сам позже —
    // путь пишется и так: фоновый режим location и синяя стрелка в статус-баре.
    if (perm == LocationPermission.whileInUse && ask) {
      final again = await Geolocator.requestPermission();
      if (again == LocationPermission.always) perm = again;
    }
    return switch (perm) {
      LocationPermission.always || LocationPermission.whileInUse => LocationAccess.ok,
      LocationPermission.deniedForever => LocationAccess.deniedForever,
      _ => LocationAccess.denied,
    };
  } catch (_) {
    return LocationAccess.denied;
  }
}

/// Где сейчас телефон (null — нет разрешения или GPS не ответил).
Future<Position?> currentPosition() async {
  try {
    if (await locationAccess() != LocationAccess.ok) return null;
    return await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high))
        .timeout(const Duration(seconds: 12));
  } catch (_) {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }
}

/// Запись пути во время обхода (П2). Геопозиция приходит потоком (на Android —
/// служба с уведомлением «Идёт обход», на iPhone — фоновый режим), точки
/// копятся в очереди на телефоне и раз в 30 секунд уходят на сервер пачкой.
/// Нет интернета — точки ждут; приложение закрыли — очередь и номер обхода
/// сохранены и отправятся при следующем запуске.
class Tracker extends ChangeNotifier {
  Tracker(this.api);

  final Api api;

  static const _queueKey = 'sm_field_queue';
  static const _walkKey = 'sm_field_walk';

  /// Открытый обход.
  String? walkId;

  /// Последний ответ сервера об обходе (статус, км, время, магазины).
  Map<String, dynamic>? walk;
  DateTime _walkAt = DateTime.now();

  /// Клетка, где сейчас продажник: state new / mine / other (П3).
  Map<String, dynamic>? here;

  /// Открытый флажок «зайти потом» ближе 100 м (из ответа на точки) или null.
  Map<String, dynamic>? nearFlag;

  /// Последняя геопозиция.
  Position? position;

  /// Путь этой сессии — рисуется сразу, не дожидаясь сервера.
  final List<LatLng> trail = [];

  PointQueue _queue = PointQueue();
  StreamSubscription<Position>? _sub;
  Timer? _timer;
  bool _sending = false;

  /// Ошибка отправки или GPS (null — всё хорошо).
  String? error;
  DateTime? sentAt;

  /// Сервер закончил обход сам (21:00, блокировка) — экран обхода закрывается.
  VoidCallback? onEnded;

  bool get running => _sub != null;
  int get pending => _queue.length;
  String get status => '${walk?['status'] ?? ''}';
  bool get paused => status == 'paused';

  /// Ручная пауза: путь не пишется. Автопаузу (стоит на месте) сервер снимет сам.
  bool get manualPause => paused && walk?['auto_paused'] != true;

  /// Время в обходе без пауз, с — тикает между ответами сервера.
  int get activeSec {
    final base = (walk?['active_sec'] as num?)?.toInt() ?? 0;
    if (status != 'active') return base;
    return base + DateTime.now().difference(_walkAt).inSeconds;
  }

  /// Прочитать очередь и открытый обход после перезапуска.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _queue = PointQueue.decode(prefs.getString(_queueKey));
    walkId = prefs.getString(_walkKey);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, _queue.encode());
    if (walkId == null) {
      await prefs.remove(_walkKey);
    } else {
      await prefs.setString(_walkKey, walkId!);
    }
  }

  /// Новый ответ сервера об обходе (старт, пауза, продолжить).
  void setWalk(Map<String, dynamic> w) {
    walk = w;
    _walkAt = DateTime.now();
    notifyListeners();
  }

  LocationSettings _settings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 8,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: tr('Идёт обход', 'Aylanish davom etmoqda'),
          notificationText: tr('Super Market записывает ваш путь. Нажмите, чтобы открыть карту',
              'Super Market yoʻlingizni yozib boryapti. Xaritani ochish uchun bosing'),
          enableWakeLock: true,
        ),
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 8,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 8);
  }

  /// Начать запись (после «Начать обход» или при открытии приложения посреди обхода).
  Future<void> start(Map<String, dynamic> w) async {
    final id = '${w['id']}';
    if (walkId != id) {
      trail.clear();
      here = null;
      nearFlag = null;
    }
    walkId = id;
    setWalk(w);
    await _save();
    _sub ??= Geolocator.getPositionStream(locationSettings: _settings()).listen(
      _onPosition,
      onError: (Object e) {
        error = tr('Нет сигнала GPS — проверьте, что геопозиция включена', 'GPS signali yoʻq — geojoylashuv yoqilganini tekshiring');
        notifyListeners();
      },
    );
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => flush());
    notifyListeners();
    unawaited(flush());
  }

  void _onPosition(Position p) {
    position = p;
    if (!manualPause) {
      final pt = TrackPoint(at: p.timestamp, lat: p.latitude, lng: p.longitude, accuracy: p.accuracy, mocked: p.isMocked);
      if (_queue.add(pt)) {
        if (p.accuracy <= 30 && !p.isMocked) trail.add(LatLng(p.latitude, p.longitude));
        unawaited(_save());
      }
    }
    if (error != null && !_sending) error = null;
    notifyListeners();
  }

  /// Отправить накопленные точки.
  Future<void> flush() async {
    final id = walkId;
    if (id == null || _sending || _queue.isEmpty) return;
    _sending = true;
    final batch = _queue.next();
    try {
      final res = await api.post('/field/walks/$id/points', {'points': batch.map((p) => p.toJson()).toList()}) as Map<String, dynamic>;
      _queue.sent(batch.length);
      final w = res['walk'];
      if (w is Map<String, dynamic>) {
        walk = w;
        _walkAt = DateTime.now();
      }
      final h = res['here'];
      if (h is Map<String, dynamic>) here = h;
      final fl = res['flag'];
      nearFlag = fl is Map<String, dynamic> ? fl : null;
      sentAt = DateTime.now();
      error = null;
      await _save();
    } on ApiError catch (e) {
      if (e.code == 'walk_ended' || e.status == 404 || e.status == 401) {
        // Обход закрыт на сервере (21:00, блокировка) — точки больше не нужны.
        _queue = PointQueue();
        await _save();
        await stop();
        onEnded?.call();
      } else if (e.isNetwork) {
        error = tr('Нет интернета — путь сохраняется в телефоне и отправится позже',
            'Internet yoʻq — yoʻl telefonda saqlanadi va keyinroq yuboriladi');
      } else {
        // Пачку, которую сервер не принял, не держим — иначе очередь застрянет.
        if (e.status == 400) _queue.sent(batch.length);
        error = e.message;
        await _save();
      }
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  /// Остановить запись (точки, которые не ушли, остаются в очереди).
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  /// Обход закончен на сервере («Закончить»): забыть обход. Остаток точек
  /// экран отправляет до запроса «Закончить» ([flush]).
  Future<void> finish() async {
    onEnded = null;
    await stop();
    walkId = null;
    walk = null;
    here = null;
    nearFlag = null;
    trail.clear();
    _queue = PointQueue();
    await _save();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}
