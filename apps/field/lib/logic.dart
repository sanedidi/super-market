import 'dart:convert';
import 'dart:math' as math;

import 'package:sm_core/sm_core.dart';

// Логика без экранов: сетка клеток, форматирование, подписи результатов,
// очередь точек пути. Проверяется test/logic_test.dart.

/// Размер клетки сетки обхода в градусах (приходит с сервера в `grid`).
class Grid {
  const Grid(this.lat, this.lng);

  /// По умолчанию — как на сервере: 100 м, долгота — для широты Ташкента.
  static const tashkent = Grid(0.0008983111749910168, 0.0011957328121093094);

  final double lat;
  final double lng;

  static Grid from(Object? json) {
    if (json is Map) {
      final lat = (json['lat'] as num?)?.toDouble();
      final lng = (json['lng'] as num?)?.toDouble();
      if (lat != null && lng != null && lat > 0 && lng > 0) return Grid(lat, lng);
    }
    return tashkent;
  }

  /// Номер клетки точки: (cx, cy).
  (int, int) cellOf(double latitude, double longitude) => ((longitude / lng).floor(), (latitude / lat).floor());

  /// Границы клетки: юг, запад, север, восток.
  (double, double, double, double) bounds(int cx, int cy) => (cy * lat, cx * lng, (cy + 1) * lat, (cx + 1) * lng);
}

/// Расстояние между точками, м.
double distanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = (lat2 - lat1) * math.pi / 180, dl = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// «380 м», «3,8 км» / «3,8 km».
String formatDistance(Object? meters) {
  final m = (meters is num ? meters : num.tryParse('${meters ?? ''}') ?? 0).toDouble();
  if (m < 1000) return '${(m / 10).round() * 10} ${tr('м', 'm')}';
  final km = (m / 100).round() / 10;
  final s = km == km.roundToDouble() ? km.toStringAsFixed(0) : km.toStringAsFixed(1).replaceAll('.', ',');
  return '$s ${tr('км', 'km')}';
}

/// Таймер обхода: «1:24:10», «24:10».
String formatClock(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// «4 ч 12 мин» / «4 soat 12 daq».
String formatDuration(int seconds) {
  final m = (seconds / 60).round();
  final h = m ~/ 60, mm = m % 60;
  if (h == 0) return '$mm ${tr('мин', 'daq')}';
  if (mm == 0) return '$h ${tr('ч', 'soat')}';
  return '$h ${tr('ч', 'soat')} $mm ${tr('мин', 'daq')}';
}

/// Процент с одним знаком: 38.4 → «38,4%», 41.0 → «41%».
String formatPct(Object? v) {
  final n = (v is num ? v : num.tryParse('${v ?? ''}') ?? 0).toDouble();
  final r = (n * 10).round() / 10;
  final s = r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toStringAsFixed(1).replaceAll('.', ',');
  return '$s%';
}

/// Короткая дата: «12 окт» / «12-okt».
String shortDate(Object? v) {
  final d = v is DateTime ? v : DateTime.tryParse('${v ?? ''}');
  if (d == null) return '';
  final l = d.toLocal();
  const ru = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
  const uz = ['yan', 'fev', 'mar', 'apr', 'may', 'iyn', 'iyl', 'avg', 'sen', 'okt', 'noy', 'dek'];
  return Lang.instance.isUz ? '${l.day}-${uz[l.month - 1]}' : '${l.day} ${ru[l.month - 1]}';
}

/// «9:12».
String hm(Object? v) {
  final d = v is DateTime ? v : DateTime.tryParse('${v ?? ''}');
  if (d == null) return '';
  final l = d.toLocal();
  return '${l.hour}:${l.minute.toString().padLeft(2, '0')}';
}

/// Дата «прийти позже»: «сегодня», «завтра», «12 нояб».
String remindLabel(String? ymd, {DateTime? now}) {
  if (ymd == null || ymd.isEmpty) return '';
  final d = DateTime.tryParse(ymd);
  if (d == null) return ymd;
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return tr('сегодня', 'bugun');
  if (diff == 1) return tr('завтра', 'ertaga');
  if (diff < 0) return tr('просрочено · ${shortDate(d)}', 'muddati oʻtgan · ${shortDate(d)}');
  return shortDate(d);
}

/// Результат визита.
String resultLabel(String result) => switch (result) {
      'lead' => tr('Подключить', 'Ulash'),
      'refused' => tr('Отказ', 'Rad etdi'),
      'closed' => tr('Закрыт', 'Yopiq'),
      'later' => tr('Прийти позже', 'Keyinroq kelish'),
      'ours' => tr('Уже с Super Market', 'Allaqachon Super Market’da'),
      _ => result,
    };

/// Статус заявки «Подключить».
String leadStatusLabel(String status) => switch (status) {
      'pending' => tr('заявка ждёт решения', 'ariza qarorni kutmoqda'),
      'connected' => tr('подключён', 'ulandi'),
      'rejected' => tr('заявка отклонена', 'ariza rad etildi'),
      'expired' => tr('срок заявки истёк', 'ariza muddati tugadi'),
      _ => '',
    };

/// Причины отказа (коды — как на сервере).
const refuseReasons = ['expensive', 'has_program', 'not_interested', 'no_trust', 'owner_against', 'other'];

String reasonLabel(String code) => switch (code) {
      'expensive' => tr('Дорого', 'Qimmat'),
      'has_program' => tr('Уже есть программа', 'Dasturi bor'),
      'not_interested' => tr('Не интересно', 'Qiziq emas'),
      'no_trust' => tr('Не доверяют', 'Ishonmaydi'),
      'owner_against' => tr('Владелец против', 'Egasi qarshi'),
      'other' => tr('Другое', 'Boshqa'),
      _ => code,
    };

/// Программы, которые уже стоят у магазина.
const programs = ['billz', 'regos', '1c', 'notebook', 'other'];

String programLabel(String code) => switch (code) {
      'billz' => 'BILLZ',
      'regos' => 'REGOS',
      '1c' => '1С',
      'notebook' => tr('Тетрадь', 'Daftar'),
      'other' => tr('Другая', 'Boshqa'),
      _ => code,
    };

/// Направление до белой зоны: «на восток» / «sharqqa».
String directionLabel(String d) => switch (d) {
      'n' => tr('на север', 'shimolga'),
      'ne' => tr('на северо-восток', 'shimoli-sharqqa'),
      'e' => tr('на восток', 'sharqqa'),
      'se' => tr('на юго-восток', 'janubi-sharqqa'),
      's' => tr('на юг', 'janubga'),
      'sw' => tr('на юго-запад', 'janubi-gʻarbga'),
      'w' => tr('на запад', 'gʻarbga'),
      'nw' => tr('на северо-запад', 'shimoli-gʻarbga'),
      _ => '',
    };

/// «3 магазина» / «3 ta doʻkon».
String storesCount(int n) {
  if (Lang.instance.isUz) return '$n ta doʻkon';
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return '$n магазин';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return '$n магазина';
  return '$n магазинов';
}

/// Точка пути для очереди отправки.
class TrackPoint {
  const TrackPoint({required this.at, required this.lat, required this.lng, required this.accuracy, this.mocked = false});

  final DateTime at;
  final double lat;
  final double lng;
  final double accuracy;
  final bool mocked;

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'lat': lat,
        'lng': lng,
        'accuracy': accuracy,
        'mocked': mocked,
      };

  static TrackPoint? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    if (at == null || lat == null || lng == null) return null;
    return TrackPoint(at: at, lat: lat, lng: lng, accuracy: (j['accuracy'] as num?)?.toDouble() ?? 0, mocked: j['mocked'] == true);
  }
}

/// Очередь точек: копится в телефоне (без интернета), уходит пачками.
class PointQueue {
  PointQueue([List<TrackPoint>? points]) : points = points ?? [];

  /// Сколько точек держим, если интернета долго нет (≈ 8 часов по точке в 5 с).
  static const limit = 6000;

  /// Сколько отправляем за раз.
  static const batch = 500;

  final List<TrackPoint> points;

  bool get isEmpty => points.isEmpty;
  int get length => points.length;

  /// Добавить точку; та же или более ранняя по времени, чем последняя, — не добавляется.
  bool add(TrackPoint p) {
    if (points.isNotEmpty && !p.at.isAfter(points.last.at)) return false;
    points.add(p);
    if (points.length > limit) points.removeRange(0, points.length - limit);
    return true;
  }

  List<TrackPoint> next() => points.take(batch).toList();

  /// Убрать отправленные (первые [n]).
  void sent(int n) => points.removeRange(0, math.min(n, points.length));

  String encode() => jsonEncode(points.map((p) => p.toJson()).toList());

  static PointQueue decode(String? raw) {
    if (raw == null || raw.isEmpty) return PointQueue();
    try {
      final list = jsonDecode(raw);
      if (list is! List) return PointQueue();
      return PointQueue(list.map(TrackPoint.fromJson).whereType<TrackPoint>().toList());
    } catch (_) {
      return PointQueue();
    }
  }
}

/// Показывать ли баннер П3 «Здесь уже прошёл …»: продажник в клетке, которую
/// первым обошёл другой продажник, и баннер не закрыт. Закрытый баннер снова
/// покажется, когда продажник выйдет из чужих клеток и опять зайдёт в них.
bool showOtherBanner(Map<String, dynamic>? here, {required bool dismissed}) => here != null && here['state'] == 'other' && !dismissed;

/// Ключ клетки «cx:cy» из ответа сервера (here).
String cellKey(Map<String, dynamic> here) => '${here['cx']}:${here['cy']}';
