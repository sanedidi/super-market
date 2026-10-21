// Экран кухни и экран выдачи: данные с сервера и ожидание изменений.
// Устройство держит длинный запрос «/pos/kitchen/wait?v=N»: сервер отвечает,
// как только в магазине что-то поменялось (новый заказ, «Готово», стоп-лист),
// или через ~25 секунд. Нет связи — повтор через несколько секунд.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../data/api.dart';

class KMod {
  KMod(this.name, this.action, this.qty);
  final String name;
  final String action;
  final int qty;

  factory KMod.fromJson(Map<String, dynamic> j) =>
      KMod(j['name'] as String? ?? '', j['action'] as String? ?? 'none', (j['qty'] as num?)?.toInt() ?? 1);
}

/// Количество с сервера («2», «0.5») → число.
double _num(Object? v) => double.tryParse('${v ?? 0}') ?? 0;

String qtyText(double q) => q == q.roundToDouble() ? q.toInt().toString() : q.toString().replaceAll('.', ',');

class KItem {
  KItem({required this.id, required this.name, required this.qty, required this.mods, required this.note, required this.done, required this.cancelled});
  final String id;
  final String name;
  final double qty;
  final List<KMod> mods;
  final String note;
  final bool done;
  final double cancelled;

  bool get allCancelled => cancelled > 0 && cancelled >= qty;

  factory KItem.fromJson(Map<String, dynamic> j) => KItem(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        qty: _num(j['qty']),
        mods: [for (final m in (j['mods'] as List?) ?? const []) KMod.fromJson(m as Map<String, dynamic>)],
        note: j['note'] as String? ?? '',
        done: j['done'] == true,
        cancelled: _num(j['cancelled_qty']),
      );
}

class KTicket {
  KTicket({required this.id, this.workshopId, required this.status, required this.cookMinutes, this.startedAt, this.readyAt, this.cancelledAt, required this.items});
  final String id;
  final String? workshopId;
  final String status;
  final int cookMinutes;
  final DateTime? startedAt;
  final DateTime? readyAt;
  final DateTime? cancelledAt;
  final List<KItem> items;

  /// Бегунок цеха без экрана: касса сразу отметила «выдан» и напечатала его.
  bool get untracked => status == 'served' && readyAt == null;

  factory KTicket.fromJson(Map<String, dynamic> j) => KTicket(
        id: j['id'] as String,
        workshopId: j['workshop_id'] as String?,
        status: j['status'] as String? ?? 'new',
        cookMinutes: (j['cook_minutes'] as num?)?.toInt() ?? 15,
        startedAt: _time(j['started_at']),
        readyAt: _time(j['ready_at']),
        cancelledAt: _time(j['cancelled_at']),
        items: [for (final i in (j['items'] as List?) ?? const []) KItem.fromJson(i as Map<String, dynamic>)],
      );
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

class KOrder {
  KOrder({
    String? id,
    required this.saleId,
    this.billId,
    this.orderNo,
    this.tableLabel = '',
    this.waiter = '',
    required this.orderType,
    required this.paidAt,
    required this.cashier,
    required this.tickets,
  }) : id = id ?? saleId;

  /// Карточка: продажа у прилавка или отправка счёта стола («счёт-партия»).
  final String id;
  final String saleId;
  final String? billId;
  final int? orderNo;

  /// Стол счёта («7») и официант.
  final String tableLabel;
  final String waiter;
  final String orderType;
  final DateTime paidAt;
  final String cashier;
  final List<KTicket> tickets;

  factory KOrder.fromJson(Map<String, dynamic> j) => KOrder(
        id: j['id'] as String?,
        saleId: j['sale_id'] as String? ?? '',
        billId: j['bill_id'] as String?,
        orderNo: (j['order_no'] as num?)?.toInt(),
        tableLabel: j['table_label'] as String? ?? '',
        waiter: j['waiter'] as String? ?? '',
        orderType: j['order_type'] as String? ?? 'here',
        paidAt: _time(j['paid_at']) ?? DateTime.now(),
        cashier: j['cashier'] as String? ?? '',
        tickets: [for (final t in (j['tickets'] as List?) ?? const []) KTicket.fromJson(t as Map<String, dynamic>)],
      );

  /// Бегунки, которые видит вкладка (null — все цеха).
  List<KTicket> visible(String? workshopId) =>
      [for (final t in tickets) if (!t.untracked && (workshopId == null || t.workshopId == workshopId)) t];

  /// Заголовок карточки: «Стол 7» у счёта, «№ 047» у продажи.
  String get title => tableLabel.isNotEmpty ? '${tr('Стол', 'Stol')} $tableLabel' : '№ ${orderNo?.toString().padLeft(3, '0') ?? '—'}';

  /// Состояние по видимым бегункам: waiting («по команде»), new, cooking,
  /// ready, served, cancelled.
  static String statusOf(List<KTicket> ts) {
    var anyNew = false, anyCooking = false, anyReady = false, anyServed = false, anyWaiting = false;
    for (final t in ts) {
      switch (t.status) {
        case 'waiting':
          anyWaiting = true;
        case 'new':
          anyNew = true;
        case 'cooking':
          anyCooking = true;
        case 'ready':
          anyReady = true;
        case 'served':
          anyServed = true;
      }
    }
    if (anyNew && !anyCooking && !anyReady && !anyServed) return 'new';
    if (anyNew || anyCooking) return 'cooking';
    if (anyReady) return 'ready';
    if (anyServed) return 'served';
    if (anyWaiting) return 'waiting';
    return 'cancelled';
  }

  /// Норма заказа — самая долгая среди видимых цехов.
  int cookMinutes(List<KTicket> ts) => ts.fold(0, (m, t) => t.cookMinutes > m ? t.cookMinutes : m);

  DateTime? readyAt(List<KTicket> ts) {
    DateTime? r;
    for (final t in ts) {
      final x = t.readyAt;
      if (x != null && (r == null || x.isAfter(r))) r = x;
    }
    return r;
  }
}

/// Номера на экране выдачи.
class DisplayData {
  DisplayData({this.storeName = '', this.showCooking = true, this.cooking = const [], this.ready = const []});
  final String storeName;
  final bool showCooking;
  final List<int> cooking;
  final List<int> ready;

  factory DisplayData.fromJson(Map<String, dynamic> j) => DisplayData(
        storeName: j['store_name'] as String? ?? '',
        showCooking: j['show_cooking'] != false,
        cooking: [for (final n in (j['cooking'] as List?) ?? const []) (n as num).toInt()],
        ready: [for (final n in (j['ready'] as List?) ?? const []) (n as num).toInt()],
      );
}

/// Загрузка и ожидание изменений. [load] — что перечитать после изменения.
class LiveFeed extends ChangeNotifier {
  LiveFeed({required String baseUrl, required String? token, required this.load}) : _api = PosApi(baseUrl, timeout: const Duration(seconds: 40)) {
    _api.token = token;
  }

  final PosApi _api;
  final Future<int> Function(PosApi api) load;

  bool online = true;
  String? error;
  int version = 0;
  bool _stopped = false;
  bool _running = false;

  PosApi get api => _api;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_stopped) {
      try {
        version = await load(_api);
        online = true;
        error = null;
        if (!_stopped) notifyListeners();
        // Ждём перемен. Версия не выросла (истекло ожидание) — ждём снова.
        while (!_stopped) {
          final res = await _api.get('/pos/kitchen/wait', query: {'v': '$version'}) as Map<String, dynamic>;
          final v = (res['version'] as num?)?.toInt() ?? version;
          if (v > version) break;
        }
      } on ApiError catch (e) {
        online = e.status != 0;
        error = e.message;
        if (!_stopped) notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 3));
      } catch (e) {
        online = false;
        error = '$e';
        if (!_stopped) notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  /// Перечитать сейчас (после своего действия ответ уже свежий — не нужно).
  Future<void> refresh() async {
    try {
      version = await load(_api);
      online = true;
      error = null;
    } on ApiError catch (e) {
      online = e.status != 0;
      error = e.message;
    }
    if (!_stopped) notifyListeners();
  }

  @override
  void dispose() {
    _stopped = true;
    super.dispose();
  }
}
