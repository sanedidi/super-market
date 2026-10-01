import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/journal.dart';
import '../core/money.dart';
import '../core/pin.dart';
import '../data/api.dart';
import '../data/outbox.dart';
import '../data/store.dart';

/// Где сейчас касса.
enum Stage { loading, activate, login, openShift, work }

/// Отложенный чек (F7): покупатель отошёл, кассир обслуживает следующего.
class HeldCart {
  HeldCart(this.at, this.cart);
  final DateTime at;
  final Cart cart;

  Map<String, dynamic> toJson() => {'at': at.toUtc().toIso8601String(), 'lines': cart.toJson()};
  factory HeldCart.fromJson(Map<String, dynamic> j) =>
      HeldCart(DateTime.parse(j['at'] as String).toLocal(), Cart.fromJson(j['lines'] as List));
}

/// Состояние кассы: устройство, каталог, кассир, смена, очередь на сервер.
/// Всё, что касается продажи, работает без интернета.
class PosController extends ChangeNotifier {
  PosController({required this.store, required this.api, this.appVersion = '0.2.0', DateTime Function()? now})
      : _now = now ?? DateTime.now {
    outbox = Outbox(store, api)
      ..onShiftOpened = _shiftOpened
      ..onSaleSent = _saleSent;
  }

  final FileStore store;
  final PosApi api;
  final String appVersion;
  final DateTime Function() _now;
  late final Outbox outbox;
  static const _uuid = Uuid();

  Stage stage = Stage.loading;
  Catalog catalog = Catalog();
  DateTime? catalogAt;
  Cashier? cashier;
  LocalShift? shift;
  final List<Object> journal = [];
  final List<HeldCart> held = [];
  int _saleSeq = 0;

  /// Номера чеков на сервере: client_uid → номер.
  final Map<String, int> serverNumbers = {};

  /// Смены, закрытые на кассе (id на сервере) — не подхватывать их снова.
  final Set<String> _closedServerShifts = {};

  bool online = true;
  bool revoked = false;
  bool syncing = false;
  final PinGuard pins = PinGuard();
  Timer? _timer;
  DateTime? _lastCatalog;

  /// Фискальный модуль подключается на этапе 3; пока — тестовый режим чека.
  bool get fiscalMode => false;

  int get queue => outbox.pending;
  int get failed => outbox.failed.length;

  ShiftReport get report => ShiftReport(shift!, journal);

  // ------------------------------------------------------------ запуск

  Future<void> init() async {
    final dev = await store.readJson('device.json');
    api.token = dev?['token'] as String?;
    final cat = await store.readJson('catalog.json');
    if (cat != null) {
      catalog = Catalog.fromJson(cat);
      final at = cat['saved_at'] as String?;
      catalogAt = at == null ? null : DateTime.tryParse(at)?.toLocal();
    }
    final st = await store.readJson('state.json');
    if (st != null) {
      _saleSeq = (st['sale_seq'] as int?) ?? 0;
      if (st['shift'] != null) shift = LocalShift.fromJson(st['shift'] as Map<String, dynamic>);
      for (final h in (st['held'] as List?) ?? const []) {
        held.add(HeldCart.fromJson(h as Map<String, dynamic>));
      }
      for (final id in (st['closed_shifts'] as List?) ?? const []) {
        _closedServerShifts.add('$id');
      }
      (st['server_numbers'] as Map<String, dynamic>?)?.forEach((k, v) => serverNumbers[k] = v as int);
    }
    await outbox.load();
    if (shift != null) {
      shift!.serverId ??= outbox.shiftIds[shift!.uid];
      await _loadJournal();
    }
    stage = api.token == null ? Stage.activate : Stage.login;
    notifyListeners();
    if (api.token != null) _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => sync());
    unawaited(sync(catalog: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _saveState() => store.writeJson('state.json', {
        'sale_seq': _saleSeq,
        'shift': shift?.toJson(),
        'held': [for (final h in held) h.toJson()],
        'closed_shifts': _closedServerShifts.toList(),
        'server_numbers': serverNumbers,
      });

  String _journalName(String shiftUid) => 'journal${Platform.pathSeparator}$shiftUid.jsonl';

  Future<void> _loadJournal() async {
    journal
      ..clear()
      ..addAll((await store.readLines(_journalName(shift!.uid))).map(journalEntry));
  }

  // -------------------------------------------------------- активация

  /// Код из панели магазина → постоянный токен кассы, затем полный каталог.
  Future<void> activate(String code) async {
    final res = await api.post('/pos/activate', {'code': code, 'app_version': appVersion}) as Map<String, dynamic>;
    api.token = res['token'] as String;
    await store.writeJson('device.json', res);
    catalog = Catalog();
    final ok = await syncCatalog();
    if (!ok) throw ApiError(0, 'network', 'Касса подключена, но каталог не загрузился — проверьте интернет');
    stage = Stage.login;
    notifyListeners();
    _startTimer();
  }

  // ---------------------------------------------------- синхронизация

  /// Каталог: первый раз целиком, дальше — изменения.
  Future<bool> syncCatalog() async {
    try {
      final q = <String, String>{if (catalog.version != null && catalog.length > 0) 'since': catalog.version!};
      final res = await api.get('/pos/catalog', query: q) as Map<String, dynamic>;
      catalog.apply(res);
      catalogAt = _now();
      _lastCatalog = catalogAt;
      await store.writeJson('catalog.json', {...catalog.toJson(), 'saved_at': catalogAt!.toUtc().toIso8601String()});
      online = true;
      notifyListeners();
      return true;
    } on ApiError catch (e) {
      _netError(e);
      return false;
    }
  }

  void _netError(ApiError e) {
    if (e.status == 0) online = false;
    if (e.status == 401 && e.code == 'unauthorized') revoked = true;
    notifyListeners();
  }

  /// Отправить очередь; каталог — не чаще раза в минуту.
  Future<void> sync({bool catalog = false}) async {
    if (syncing || api.token == null) return;
    syncing = true;
    try {
      final r = await outbox.flush();
      if (r.offline) online = false;
      if (r.sent > 0) online = true;
      if (r.revoked) revoked = true;
      final due = _lastCatalog == null || _now().difference(_lastCatalog!) > const Duration(minutes: 1);
      if (catalog || due) await syncCatalog();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> _shiftOpened(String uid, String id, int number) async {
    if (shift?.uid == uid) {
      shift!
        ..serverId = id
        ..number = number;
      await _saveState();
    }
  }

  Future<void> _saleSent(String uid, String id, int number) async {
    serverNumbers[uid] = number;
    // Храним номера только последних чеков.
    if (serverNumbers.length > 500) serverNumbers.remove(serverNumbers.keys.first);
    await _saveState();
  }

  // ------------------------------------------------------------- кассир

  /// Вход по ПИНу — проверка на кассе, без сервера. Возвращает ошибку или null.
  String? login(Cashier c, String pin) {
    final wait = pins.lockedFor(c.id);
    if (wait != null) return 'Слишком много попыток — подождите ${wait.inMinutes + 1} мин';
    if (!pins.check(c.id, c.pinHash, pin)) {
      final w = pins.lockedFor(c.id);
      return w != null ? 'Вход заблокирован на 5 минут' : 'Неверный ПИН';
    }
    if (!c.can(Perm.pos)) return 'Нет права работать на кассе';
    cashier = c;
    stage = shift == null ? Stage.openShift : Stage.work;
    notifyListeners();
    if (shift == null) unawaited(_adoptServerShift());
    return null;
  }

  /// Проверить ПИН старшего (возврат, скидка без права). Возвращает кассира с правом.
  Cashier? confirm(String perm, String pin) {
    for (final c in catalog.cashiers) {
      if (c.can(perm) && pins.check(c.id, c.pinHash, pin)) return c;
    }
    return null;
  }

  void logout() {
    cashier = null;
    stage = Stage.login;
    notifyListeners();
  }

  /// На сервере уже открыта смена этой кассы (например, после переустановки) —
  /// продолжаем её, а не открываем вторую.
  Future<void> _adoptServerShift() async {
    final id = catalog.openShiftId;
    if (id == null || _closedServerShifts.contains(id) || outbox.pending > 0) return;
    var opening = 0;
    var number = 0;
    var openedAt = _now();
    var openedByName = cashier?.name ?? '';
    try {
      final res = await api.get('/pos/shifts/current', cashier: cashier?.id) as Map<String, dynamic>;
      final sh = res['shift'] as Map<String, dynamic>?;
      if (sh == null || sh['id'] != id) return;
      opening = parseMoney(sh['opening_cash']);
      number = (sh['number'] as num?)?.toInt() ?? 0;
      openedAt = DateTime.tryParse(sh['opened_at'] as String? ?? '')?.toLocal() ?? openedAt;
      openedByName = sh['opened_by_name'] as String? ?? openedByName;
    } on ApiError {
      return;
    }
    if (shift != null) return;
    shift = LocalShift(
      uid: 'srv-$id',
      openedAt: openedAt,
      openingCash: opening,
      openedBy: '',
      openedByName: openedByName,
      serverId: id,
      number: number,
    );
    await outbox.knowShift(shift!.uid, id);
    await _saveState();
    await _loadJournal();
    if (cashier != null) stage = Stage.work;
    notifyListeners();
  }

  // ------------------------------------------------------------- смена

  Future<void> openShift(int openingCash) async {
    final c = cashier!;
    final s = LocalShift(
      uid: _uuid.v4(),
      openedAt: _now(),
      openingCash: openingCash,
      openedBy: c.id,
      openedByName: c.name,
    );
    await outbox.add('shift_open', {
      'client_uid': s.uid,
      'opened_at': s.openedAt.toUtc().toIso8601String(),
      'opening_cash': moneyApi(openingCash),
    }, c.id);
    shift = s;
    journal.clear();
    await _saveState();
    stage = Stage.work;
    notifyListeners();
    unawaited(sync());
  }

  Future<void> cashMove(String kind, int amount, String reason) async {
    final m = CashMoveRecord(
      uid: _uuid.v4(),
      shiftUid: shift!.uid,
      kind: kind,
      amount: amount,
      reason: reason,
      at: _now(),
      cashierId: cashier!.id,
    );
    await store.append(_journalName(shift!.uid), m.toJson());
    await outbox.add('cash_move', m.toJson(), cashier!.id);
    journal.add(m);
    notifyListeners();
    unawaited(sync());
  }

  /// Закрыть смену: пересчёт кассира и причина расхождения. Дальше — вход
  /// следующего кассира и новая смена.
  Future<void> closeShift(int counted, String reason) async {
    final s = shift!;
    await outbox.add('shift_close', {
      'shift_uid': s.uid,
      'counted_cash': counted,
      'diff_reason': reason,
      'closed_at': _now().toUtc().toIso8601String(),
    }, cashier!.id);
    if (s.serverId != null) _closedServerShifts.add(s.serverId!);
    shift = null;
    journal.clear();
    await _saveState();
    cashier = null;
    stage = Stage.login;
    notifyListeners();
    unawaited(sync());
  }

  // ----------------------------------------------------------- продажа

  /// Чек оплачен: в журнал смены и в очередь. Сервер не нужен.
  Future<SaleRecord> recordSale(Cart cart, List<Payment> payments, {int received = 0, Map<String, dynamic>? fiscal}) async {
    _saleSeq++;
    final rec = SaleRecord(
      uid: _uuid.v4(),
      seq: _saleSeq,
      shiftUid: shift!.uid,
      cashierId: cashier!.id,
      cashierName: cashier!.name,
      soldAt: _now(),
      lines: SaleRecord.snapshot(cart),
      payments: payments,
      received: received,
      fiscal: fiscal,
    );
    await store.append(_journalName(rec.shiftUid), rec.toJson());
    await outbox.add('sale', rec.toJson(), rec.cashierId);
    await _saveState();
    journal.add(rec);
    notifyListeners();
    unawaited(sync());
    return rec;
  }

  int get nextSeq => _saleSeq + 1;

  Future<void> hold(Cart cart) async {
    held.add(HeldCart(_now(), cart));
    await _saveState();
    notifyListeners();
  }

  Future<Cart?> unhold(int index) async {
    if (index < 0 || index >= held.length) return null;
    final h = held.removeAt(index);
    await _saveState();
    notifyListeners();
    return h.cart;
  }

  // ----------------------------------------------------------- возврат

  /// Найти чек для возврата: номер с чека или QR (client_uid). Нужен интернет.
  Future<Map<String, dynamic>> findSale(String q) async {
    q = q.trim().replaceFirst('№', '');
    // Чек этой кассы, который ещё не дошёл до сервера.
    final pendingSale = outbox.failed.any((i) => i.body['uid'] == q);
    if (pendingSale) throw ApiError(400, 'not_sent', 'Этот чек не принят сервером — возврат невозможен');
    await sync();
    final res = await api.get('/pos/sales', query: {'q': q}, cashier: cashier!.id) as Map<String, dynamic>;
    final items = (res['items'] as List?) ?? const [];
    if (items.isEmpty) {
      throw ApiError(404, 'not_found', online ? 'Чек $q не найден' : 'Нет связи — возврат проводится только онлайн');
    }
    final id = (items.first as Map<String, dynamic>)['id'] as String;
    return await api.get('/pos/sales/$id', cashier: cashier!.id) as Map<String, dynamic>;
  }

  /// Провести возврат на сервере. [by] — кассир с правом на возврат (может
  /// быть старший, который ввёл ПИН).
  Future<ReturnRecord> createReturn({
    required Map<String, dynamic> sale,
    required PayMethod method,
    required List<Map<String, dynamic>> items,
    required String reason,
    required Cashier by,
  }) async {
    await sync();
    final shiftId = shift!.serverId ?? outbox.shiftIds[shift!.uid];
    if (shiftId == null) throw ApiError(0, 'network', 'Смена ещё не дошла до сервера — нужен интернет');
    final res = await api.post('/pos/returns', {
      'sale_id': sale['id'],
      'payment_method_id': method.id,
      'reason': reason,
      'shift_id': shiftId,
      'items': items,
    }, cashier: by.id) as Map<String, dynamic>;
    final rec = ReturnRecord(
      id: res['id'] as String,
      shiftUid: shift!.uid,
      saleNumber: (res['sale_number'] as num?)?.toInt() ?? 0,
      total: parseMoney(res['total']),
      kind: method.kind,
      methodName: method.name,
      at: _now(),
    );
    await store.append(_journalName(shift!.uid), rec.toJson());
    journal.add(rec);
    notifyListeners();
    return rec;
  }
}
