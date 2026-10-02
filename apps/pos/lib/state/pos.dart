import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/journal.dart';
import '../core/limits.dart';
import '../core/money.dart';
import '../core/pin.dart';
import '../data/api.dart';
import '../data/outbox.dart';
import '../data/store.dart';
import '../fiscal/fiscal.dart';
import '../printer/receipts.dart';
import '../printer/transport.dart';

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
  PosController({required this.store, required this.api, this.appVersion = '0.3.0', DateTime Function()? now})
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

  /// Фискальный модуль. Пока ОФД не выдал протокол — тестовый: чеки не фискальные.
  FiscalModule fiscal = TestFiscalModule();
  FiscalStatus? fiscalStatus;

  bool get fiscalMode => fiscal.real;

  /// Чековый принтер и последняя ошибка печати (показывается в верхней строке).
  PrinterConfig printer = PrinterConfig();
  String? printError;

  /// Сколько идёт смена (правило 24 часов).
  ShiftLimit? get shiftLimit => shift == null ? null : ShiftLimit(shift!.openedAt, _now());

  /// Работа без связи (правило 24 часов): по очереди на сервер и очереди модуля в ОФД.
  OfflineLimit get offlineLimit {
    DateTime? since = outbox.oldestPendingAt;
    final f = fiscalStatus?.oldestPending;
    if (f != null && (since == null || f.isBefore(since))) since = f;
    return OfflineLimit(since: since, online: online, queue: outbox.pending + (fiscalStatus?.pending ?? 0), now: _now());
  }

  /// Можно ли сейчас продавать; иначе — причина.
  String? get saleBlocked {
    if (shiftLimit?.state == LimitState.blocked) {
      return 'Смена идёт больше 24 часов — закройте смену (Z-отчёт)';
    }
    if (offlineLimit.state == LimitState.blocked) {
      return 'Касса без связи больше 24 часов — подключите интернет, чтобы отправить чеки';
    }
    return null;
  }

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
    printer = PrinterConfig.fromJson(await store.readJson('printer.json'));
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
    revoked = false;
    // События, которые сервер отклонил, пока касса была отключена, — отправить снова.
    for (final item in List.of(outbox.failed)) {
      if ((item.error ?? '').startsWith('касса отключена')) await outbox.retry(item);
    }
    stage = cashier == null ? Stage.login : (shift == null ? Stage.openShift : Stage.work);
    notifyListeners();
    _startTimer();
  }

  /// Касса отключена в панели: забыть старый токен и подключиться новым кодом.
  /// Смена, чеки и очередь остаются — после подключения уйдут на сервер.
  Future<void> reconnect() async {
    _timer?.cancel();
    api.token = null;
    await store.delete('device.json');
    revoked = false;
    stage = Stage.activate;
    notifyListeners();
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
    if (deviceRejected(e)) revoked = true;
    notifyListeners();
  }

  /// Отправить очередь; каталог — не чаще раза в минуту.
  Future<void> sync({bool catalog = false}) async {
    if (syncing || api.token == null) return;
    syncing = true;
    try {
      try {
        fiscalStatus = await fiscal.status();
      } catch (_) {
        fiscalStatus = null;
      }
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
    }, c.id, at: s.openedAt);
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
    await outbox.add('cash_move', m.toJson(), cashier!.id, at: m.at);
    journal.add(m);
    notifyListeners();
    unawaited(sync());
  }

  /// Закрыть смену: пересчёт кассира и причина расхождения. Дальше — вход
  /// следующего кассира и новая смена.
  Future<void> closeShift(int counted, String reason) async {
    final s = shift!;
    final now = _now();
    FiscalResult? z;
    if (fiscalMode) {
      try {
        z = await fiscal.closeShift(shiftNumber: s.number ?? 0, at: now);
      } on FiscalError catch (e) {
        throw CartError('Фискальный модуль не закрыл смену: ${e.message}');
      }
    }
    final rep = report;
    unawaited(_print(() => shiftReport(
          s: catalog.settings,
          rep: rep,
          z: true,
          at: now,
          counted: counted,
          diffReason: reason,
          vat: rep.vat,
          queue: outbox.pending,
          fiscal: z,
          paperMm: printer.paperMm,
          codePage: printer.codePage,
        )));
    await outbox.add('shift_close', {
      'shift_uid': s.uid,
      'counted_cash': counted,
      'diff_reason': reason,
      'closed_at': now.toUtc().toIso8601String(),
    }, cashier!.id, at: now);
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

  /// Чек оплачен: фискальный модуль (если подключён), журнал смены, очередь,
  /// печать. Сервер не нужен.
  Future<SaleRecord> recordSale(Cart cart, List<Payment> payments, {int received = 0, Map<String, dynamic>? fiscal}) async {
    final blocked = saleBlocked;
    if (blocked != null) throw CartError(blocked);
    final uid = _uuid.v4();
    final soldAt = _now();
    var draft = SaleRecord(
      uid: uid,
      seq: _saleSeq + 1,
      shiftUid: shift!.uid,
      cashierId: cashier!.id,
      cashierName: cashier!.name,
      soldAt: soldAt,
      lines: SaleRecord.snapshot(cart),
      payments: payments,
      received: received,
      fiscal: fiscal,
    );
    if (fiscalMode && fiscal == null) {
      final receipt = FiscalReceipt.sale(draft);
      final problems = receiptProblems(receipt);
      if (problems.isNotEmpty) throw CartError(problems.first);
      try {
        final res = await this.fiscal.register(receipt);
        draft = SaleRecord.fromJson({...draft.toJson(), 'fiscal': res.toSale()});
      } on FiscalError catch (e) {
        throw CartError('Фискальный модуль: ${e.message}');
      }
    }
    _saleSeq++;
    final rec = draft;
    await store.append(_journalName(rec.shiftUid), rec.toJson());
    await outbox.add('sale', rec.toJson(), rec.cashierId, at: rec.soldAt);
    await _saveState();
    journal.add(rec);
    notifyListeners();
    unawaited(sync());
    unawaited(printSale(rec));
    return rec;
  }

  String get _shiftLabel => '${catalog.settings.deviceName.isEmpty ? 'Касса' : catalog.settings.deviceName}'
      '${shift?.number != null ? ' · смена ${shift!.number}' : ''}';

  /// Напечатать чек продажи (и открыть ящик при наличных). Ошибка не мешает продаже.
  Future<bool> printSale(SaleRecord rec) => _print(() => saleReceipt(
        s: catalog.settings,
        sale: rec,
        shiftLabel: _shiftLabel,
        serverNumber: serverNumbers[rec.uid],
        paperMm: printer.paperMm,
        codePage: printer.codePage,
        openDrawer: printer.drawer,
      ));

  /// X-отчёт на принтер.
  Future<bool> printX() => _print(() => shiftReport(
        s: catalog.settings,
        rep: report,
        z: false,
        at: _now(),
        vat: report.vat,
        queue: outbox.pending,
        paperMm: printer.paperMm,
        codePage: printer.codePage,
      ));

  Future<bool> testPrint() => _print(() => testPage(s: catalog.settings, paperMm: printer.paperMm, codePage: printer.codePage));

  Future<bool> openDrawer() => _print(drawerPulse);

  Future<bool> _print(List<int> Function() build) async {
    if (!printer.enabled) return false;
    try {
      await sendToPrinter(printer, Uint8List.fromList(build()));
      printError = null;
      notifyListeners();
      return true;
    } catch (e) {
      printError = '$e';
      notifyListeners();
      return false;
    }
  }

  Future<void> savePrinter(PrinterConfig c) async {
    printer = c;
    printError = null;
    await store.writeJson('printer.json', c.toJson());
    notifyListeners();
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
    final blocked = shiftLimit?.state == LimitState.blocked ? 'Смена идёт больше 24 часов — закройте смену (Z-отчёт)' : null;
    if (blocked != null) throw ApiError(409, 'shift_expired', blocked);
    final shiftId = shift!.serverId ?? outbox.shiftIds[shift!.uid];
    if (shiftId == null) throw ApiError(0, 'network', 'Смена ещё не дошла до сервера — нужен интернет');
    final saleSign = '${sale['fiscal_sign'] ?? ''}';
    if (fiscalMode && saleSign.isEmpty) {
      throw ApiError(409, 'not_fiscal', 'Исходный чек не фискальный — возврат через фискальный модуль невозможен');
    }
    final res = await api.post('/pos/returns', {
      'sale_id': sale['id'],
      'payment_method_id': method.id,
      'reason': reason,
      'shift_id': shiftId,
      'items': items,
    }, cashier: by.id) as Map<String, dynamic>;
    final id = res['id'] as String;
    final total = parseMoney(res['total']);
    final at = _now();

    // Чек возврата: строки — из ответа сервера (суммы с учётом скидки), реквизиты — из исходного чека.
    final saleItems = ((sale['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final lines = <FiscalLine>[];
    for (final it in ((res['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final src = saleItems.firstWhere((x) => x['line'] == it['sale_line'], orElse: () => {'product_name': it['product_name']});
      lines.add(refundLine(src, parseQty(it['qty']), parseMoney(it['total'])));
    }
    final receipt = FiscalReceipt(
      kind: ReceiptKind.refund,
      uid: id,
      at: at,
      cashier: by.name,
      lines: lines,
      cash: method.kind == 'cash' ? total : 0,
      card: method.kind == 'cash' ? 0 : total,
      ref: saleSign.isEmpty
          ? null
          : FiscalRef(
              number: '${sale['fiscal_number'] ?? ''}',
              sign: saleSign,
              module: '${sale['fiscal_module'] ?? ''}',
              at: DateTime.tryParse('${sale['sold_at'] ?? ''}')?.toLocal() ?? at,
            ),
    );
    FiscalResult? fr;
    String? fiscalError;
    if (fiscalMode) {
      try {
        fr = await fiscal.register(receipt);
        await api.post('/pos/returns/$id/fiscal', fr.toReturn(), cashier: by.id);
      } on FiscalError catch (e) {
        fiscalError = 'Возврат проведён, но фискальный модуль не пробил чек: ${e.message}';
      } on ApiError catch (e) {
        fiscalError = 'Чек возврата пробит, но сервер не сохранил признак: ${e.message}';
      }
    }
    final rec = ReturnRecord(
      id: id,
      shiftUid: shift!.uid,
      saleNumber: (res['sale_number'] as num?)?.toInt() ?? 0,
      total: total,
      kind: method.kind,
      methodName: method.name,
      at: at,
      number: (res['number'] as num?)?.toInt() ?? 0,
      fiscal: fr?.toJson(),
    );
    await store.append(_journalName(shift!.uid), rec.toJson());
    journal.add(rec);
    notifyListeners();
    unawaited(_print(() => refundReceipt(
          s: catalog.settings,
          r: receipt,
          returnNumber: rec.number,
          saleNumber: rec.saleNumber,
          shiftLabel: _shiftLabel,
          by: by.name,
          reason: reason,
          methodName: method.name,
          fiscal: fr,
          paperMm: printer.paperMm,
          codePage: printer.codePage,
        )));
    if (fiscalError != null) {
      printError = fiscalError;
      notifyListeners();
    }
    return rec;
  }
}
