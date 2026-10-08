// Ограничения онлайн-кассы (ПКМ № 943): смена не длиннее 24 часов, без связи
// с ОФД касса работает не дольше 24 часов. Здесь — только расчёт, без UI.

import 'package:sm_core/sm_core.dart' show tr;

/// Смена и работа без связи — не дольше суток.
const limit24h = Duration(hours: 24);

/// За сколько до конца смены предупреждать кассира.
const shiftWarnBefore = Duration(hours: 2);

enum LimitState { ok, warn, blocked }

/// Сколько идёт смена и сколько осталось до 24 часов.
class ShiftLimit {
  ShiftLimit(this.openedAt, this.now);

  final DateTime openedAt;
  final DateTime now;

  Duration get age => now.difference(openedAt);
  Duration get left => limit24h - age;

  LimitState get state {
    if (left <= Duration.zero) return LimitState.blocked;
    if (left <= shiftWarnBefore) return LimitState.warn;
    return LimitState.ok;
  }
}

/// Касса без связи: с какого момента чеки не уходят и сколько ещё можно работать.
/// [since] — время самого старого неотправленного события; null — очередь пуста.
class OfflineLimit {
  OfflineLimit({required this.since, required this.online, required this.queue, required this.now});

  final DateTime? since;
  final bool online;
  final int queue;
  final DateTime now;

  Duration get age => since == null ? Duration.zero : now.difference(since!);
  Duration get left => limit24h - age;

  LimitState get state {
    if (since == null || queue == 0) return LimitState.ok;
    if (left <= Duration.zero) return LimitState.blocked;
    // Связь есть и очередь уходит — не пугаем кассира.
    if (online && age < const Duration(minutes: 5)) return LimitState.ok;
    return LimitState.warn;
  }
}

/// «22 ч 40 мин», «45 мин», «0 мин».
String fmtDuration(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return tr('$m мин', '$m daq');
  return m == 0 ? tr('$h ч', '$h soat') : tr('$h ч $m мин', '$h soat $m daq');
}
