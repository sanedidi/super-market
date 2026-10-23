import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sm_core/sm_core.dart' show Lang, parseClientQr, tr;
import 'package:uuid/uuid.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/debts.dart';
import '../core/journal.dart';
import '../core/limits.dart';
import '../core/money.dart';
import '../core/pin.dart';
import '../data/api.dart';
import '../data/outbox.dart';
import '../data/store.dart';
import '../fiscal/fiscal.dart';
import '../cafe/bills.dart';
import '../cafe/kitchen_printing.dart';
import '../cafe/tickets.dart';
import '../printer/receipts.dart';
import '../printer/transport.dart';

/// Где сейчас касса.
/// kitchen — экран кухни, display — экран выдачи для гостей (кафе): без
/// кассира и смены, вид устройства задаёт панель.
enum Stage { loading, activate, login, openShift, work, kitchen, display }

/// Отложенный чек (F7): покупатель отошёл, кассир обслуживает следующего.
class HeldCart {
  HeldCart(this.at, this.cart);
  final DateTime at;
  final Cart cart;

  Map<String, dynamic> toJson() => {'at': at.toUtc().toIso8601String(), 'lines': cart.toJson()};
  factory HeldCart.fromJson(Map<String, dynamic> j) =>
      HeldCart(DateTime.parse(j['at'] as String).toLocal(), Cart.fromJson(j['lines'] as List));
}

/// Смена этой кассы, открытая на сервере (GET /pos/shifts/current).
class ServerShift {
  ServerShift({
    required this.id,
    required this.number,
    required this.openedAt,
    required this.openedByName,
    required this.openingCash,
    required this.salesCount,
    required this.salesTotal,
    required this.expectedCash,
  });

  final String id;
  final int number;
  final DateTime openedAt;
  final String openedByName;
  final int openingCash;
  final int salesCount;
  final int salesTotal;

  /// Наличные по расчёту сервера: размен + наличные продажи − возвраты ± внесения/изъятия.
  final int expectedCash;

  factory ServerShift.fromJson(Map<String, dynamic> j) {
    final r = (j['report'] as Map<String, dynamic>?) ?? const {};
    return ServerShift(
      id: j['id'] as String,
      number: (j['number'] as num?)?.toInt() ?? 0,
      openedAt: DateTime.tryParse(j['opened_at'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      openedByName: j['opened_by_name'] as String? ?? '',
      openingCash: parseMoney(j['opening_cash']),
      salesCount: (r['sales_count'] as num?)?.toInt() ?? 0,
      salesTotal: parseMoney(r['sales_total']),
      expectedCash: parseMoney(r['expected_cash'] ?? j['opening_cash']),
    );
  }
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

  /// Кафе: номер заказа дня для гостя («№ 047»), с 1 каждый день на этой кассе.
  int _orderNo = 0;
  String _orderDay = '';

  String _today() {
    final d = _now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// Номер, который получит следующий заказ кафе.
  int get nextOrderNo => _orderDay == _today() ? (_orderNo % 999) + 1 : 1;

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

  /// Язык, на котором загружен каталог (названия товаров и разделов приходят
  /// на языке запроса). Сменили язык кассы — каталог загружается заново целиком.
  String? _catalogLang;

  /// Фискальный модуль. Пока ОФД не выдал протокол — тестовый: чеки не фискальные.
  FiscalModule fiscal = TestFiscalModule();
  FiscalStatus? fiscalStatus;

  bool get fiscalMode => fiscal.real;

  /// Кафе: бегунки на принтеры цехов, очередь непечатанных, тесты печати.
  late final KitchenPrinting kitchen = KitchenPrinting(api: api, store: store, catalog: () => catalog, printer: () => printer);

  /// Экран по виду устройства: касса — вход кассира, экраны кафе — сразу работа.
  Stage _deviceStage() => switch (catalog.settings.deviceKind) {
        'kitchen' => Stage.kitchen,
        'display' => Stage.display,
        _ => cashier == null ? Stage.login : (shift == null ? Stage.openShift : Stage.work),
      };

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
      return tr('Смена идёт больше 24 часов — закройте смену (Z-отчёт)', 'Smena 24 soatdan beri davom etmoqda — smenani yoping (Z-hisobot)');
    }
    if (offlineLimit.state == LimitState.blocked) {
      return tr('Касса без связи больше 24 часов — подключите интернет, чтобы отправить чеки', 'Kassa 24 soatdan beri aloqasiz — cheklarni yuborish uchun internetga ulaning');
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
      _catalogLang = cat['lang'] as String?;
    }
    final st = await store.readJson('state.json');
    if (st != null) {
      _saleSeq = (st['sale_seq'] as int?) ?? 0;
      _orderNo = (st['order_no'] as int?) ?? 0;
      _orderDay = st['order_day'] as String? ?? '';
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
    await kitchen.load();
    if (shift != null) {
      shift!.serverId ??= outbox.shiftIds[shift!.uid];
      await _loadJournal();
    }
    stage = api.token == null ? Stage.activate : _deviceStage();
    notifyListeners();
    Lang.instance.addListener(_langChanged);
    if (api.token != null) _startTimer();
  }

  /// Сменили язык кассы — сразу перезагрузить каталог на новом языке.
  void _langChanged() {
    if (api.token != null) unawaited(sync(catalog: true));
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => sync());
    unawaited(sync(catalog: true));
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    Lang.instance.removeListener(_langChanged);
    super.dispose();
  }

  /// Обмен с сервером может закончиться уже после закрытия кассы — тогда молчим.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> _saveState() => store.writeJson('state.json', {
        'sale_seq': _saleSeq,
        'order_no': _orderNo,
        'order_day': _orderDay,
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
    // Касса подключена к другой точке (например, магазин → кафе): смена и чеки
    // прежней точки сюда не переносятся.
    final prevStore = catalog.settings.storeId;
    final moved = prevStore.isNotEmpty && prevStore != res['store_id'];
    if (moved && shift != null) {
      shift = null;
      journal.clear();
      held.clear();
      cashier = null;
      await _saveState();
    }
    api.token = res['token'] as String;
    await store.writeJson('device.json', res);
    catalog = Catalog();
    final ok = await syncCatalog();
    if (!ok) throw ApiError(0, 'network', tr('Касса подключена, но каталог не загрузился — проверьте интернет', 'Kassa ulandi, lekin katalog yuklanmadi — internetni tekshiring'));
    revoked = false;
    // События, которые сервер отклонил, пока касса была отключена, — отправить снова.
    for (final item in List.of(outbox.failed)) {
      if (moved) break;
      if (item.errorCode == 'device_revoked' || (item.error ?? '').startsWith('касса отключена')) await outbox.retry(item);
    }
    stage = _deviceStage();
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
      // Каталог на другом языке — без since: сервер пришлёт его целиком.
      final lang = Lang.instance.code;
      final q = <String, String>{
        'epoch': '${catalog.epoch}',
        if (lang == _catalogLang && catalog.version != null && catalog.length > 0) 'since': catalog.version!,
      };
      final res = await api.get('/pos/catalog', query: q) as Map<String, dynamic>;
      final kind = catalog.settings.deviceKind;
      catalog.apply(res);
      _applyQueuedPrices();
      // Панель поменяла вид устройства (касса ↔ экран кухни) — другой экран.
      if (kind != catalog.settings.deviceKind && stage != Stage.activate && stage != Stage.loading) {
        if (catalog.settings.deviceKind == 'pos') {
          if (stage == Stage.kitchen || stage == Stage.display) stage = _deviceStage();
        } else if (shift == null) {
          stage = _deviceStage();
        }
      }
      _catalogLang = lang;
      catalogAt = _now();
      _lastCatalog = catalogAt;
      await store.writeJson('catalog.json', {...catalog.toJson(), 'saved_at': catalogAt!.toUtc().toIso8601String(), 'lang': lang});
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
      if (catalog || due || _catalogLang != Lang.instance.code) await syncCatalog();
      if (this.catalog.cafe != null) await kitchen.tick();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Отправить очередь сейчас, без каталога и проверок (касса кафе: операции
  /// со счётом стола видны на других кассах и кухне сразу). Идёт отправка —
  /// она заберёт и новое событие.
  Future<void> push() async {
    if (api.token == null) return;
    final r = await outbox.flush();
    if (r.offline) online = false;
    if (r.sent > 0) online = true;
    if (r.revoked) revoked = true;
    notifyListeners();
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

  /// ПИН кассира — строго 4 цифры (как на сервере).
  static final _pinRe = RegExp(r'^[0-9]{4}$');

  /// Вход по ПИНу — проверка на кассе, без сервера. Возвращает ошибку или null.
  String? login(Cashier c, String pin) {
    if (!_pinRe.hasMatch(pin)) return tr('ПИН — 4 цифры', 'PIN-kod — 4 ta raqam');
    final wait = pins.lockedFor(c.id);
    if (wait != null) return tr('Слишком много попыток — подождите ${wait.inMinutes + 1} мин', 'Urinishlar juda koʻp — ${wait.inMinutes + 1} daqiqa kuting');
    if (!pins.check(c.id, c.pinHash, pin)) {
      final w = pins.lockedFor(c.id);
      return w != null ? tr('Вход заблокирован на 5 минут', 'Kirish 5 daqiqaga bloklandi') : tr('Неверный ПИН', 'PIN-kod notoʻgʻri');
    }
    if (!c.can(Perm.pos)) return tr('Нет права работать на кассе', 'Kassada ishlash huquqi yoʻq');
    cashier = c;
    stage = shift == null ? Stage.openShift : Stage.work;
    notifyListeners();
    if (shift == null) unawaited(_adoptServerShift());
    return null;
  }

  /// Проверить ПИН старшего (возврат, скидка без права). Возвращает кассира с правом.
  Cashier? confirm(String perm, String pin) {
    if (!_pinRe.hasMatch(pin)) return null;
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
    ServerShift? sh;
    try {
      sh = await _currentServerShift();
    } catch (_) {
      return;
    }
    if (sh == null || sh.id != id || shift != null) return;
    await _adopt(sh);
  }

  /// Продолжить серверную смену на кассе (после переустановки или когда
  /// кассир выбрал «Продолжить смену №N» при открытии).
  Future<void> _adopt(ServerShift sh) async {
    shift = LocalShift(
      uid: 'srv-${sh.id}',
      openedAt: sh.openedAt,
      openingCash: sh.openingCash,
      openedBy: '',
      openedByName: sh.openedByName.isEmpty ? (cashier?.name ?? '') : sh.openedByName,
      serverId: sh.id,
      number: sh.number,
    );
    await outbox.knowShift(shift!.uid, sh.id);
    await _saveState();
    await _loadJournal();
    if (cashier != null) stage = Stage.work;
    notifyListeners();
  }

  /// Сколько оставили в ящике на размен при сдаче кассы (сумы, целые) —
  /// подставляется в «Размен на начало смены». null — не знаем или смена уже идёт.
  Future<String?> leftInDrawer() async {
    final res = await api.get('/pos/shifts/current', cashier: cashier?.id) as Map<String, dynamic>;
    if (res['shift'] != null) return null;
    final v = res['left_in_drawer'];
    if (v == null) return null;
    final s = '$v'.split('.').first.replaceAll(RegExp(r'\D'), '');
    return s.isEmpty || s == '0' ? null : s;
  }

  Future<ServerShift?> _currentServerShift() async {
    final res = await api.get('/pos/shifts/current', cashier: cashier?.id) as Map<String, dynamic>;
    final sh = res['shift'] as Map<String, dynamic>?;
    return sh == null ? null : ServerShift.fromJson(sh);
  }

  // ------------------------------------------------ зависшая смена на сервере

  /// Сервер не принял открытие смены: на кассе (на сервере) уже открыта другая
  /// смена — обычно прошлый Z-отчёт не дошёл. Из-за неё отклоняется и всё,
  /// что пробито в текущей смене (Figma «Касса · «Не принято N»», НП1).
  bool get staleShiftBlocks => outbox.failed.any((i) => i.kind == 'shift_open' && i.errorCode == 'shift_open');

  /// Открытая на сервере смена этой кассы, которая не совпадает с текущей
  /// сменой кассы; null — такой нет. Без связи — ApiError.
  Future<ServerShift?> staleServerShift() async {
    final sh = await _currentServerShift();
    if (!online) {
      online = true;
      notifyListeners();
    }
    if (sh == null || sh.id == shift?.serverId) return null;
    // Z-отчёт этой смены ещё в очереди — она не зависла, просто не доотправлена.
    if (outbox.pendingItems.any((i) => i.kind == 'shift_close' && outbox.shiftIds[i.body['shift_uid']] == sh.id)) return null;
    return sh;
  }

  /// Закрыть на сервере старую смену этой кассы (НП2): пересчёта нет — сумма
  /// в ящике по расчёту сервера. Потом всё непринятое уходит заново.
  /// Ошибка — текст, успех — null.
  Future<String?> closeServerShift(ServerShift sh) async {
    try {
      await api.post('/pos/shifts/${sh.id}/close', {'stale': true, 'closed_at': _now().toUtc().toIso8601String()},
          cashier: cashier?.id);
    } on ApiError catch (e) {
      _netError(e);
      return e.isNetwork ? tr('Нет связи с сервером — попробуйте, когда появится интернет', 'Server bilan aloqa yoʻq — internet paydo boʻlganda urinib koʻring') : e.message;
    }
    _closedServerShifts.add(sh.id);
    await _saveState();
    online = true;
    await retryFailed();
    return null;
  }

  /// «Продолжить смену №N» при открытии смены (НП4): касса берёт серверную смену.
  Future<void> continueServerShift(ServerShift sh) async {
    _closedServerShifts.remove(sh.id);
    await _adopt(sh);
  }

  /// «Повторить все»: всё, что сервер не принял, — снова в очередь и на сервер.
  Future<void> retryFailed() async {
    await outbox.retryAll();
    notifyListeners();
    // Идёт отправка — дождаться, иначе sync() сразу вернётся и очередь постоит.
    while (syncing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await sync();
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
        throw CartError(tr('Фискальный модуль не закрыл смену: ${e.message}', 'Fiskal modul smenani yopmadi: ${e.message}'));
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
  Future<SaleRecord> recordSale(Cart cart, List<Payment> payments,
      {int received = 0, Map<String, dynamic>? fiscal, DebtPart? debt, Map<String, dynamic>? order}) async {
    final blocked = saleBlocked;
    if (blocked != null) throw CartError(blocked);
    if (debt != null && fiscalMode) {
      // Как фискализировать продажу в долг, уточняем у ОФД — до этого не продаём.
      throw CartError(tr('Продажа в долг с фискальным модулем пока недоступна — ждём правила ОФД', 'Fiskal modul bilan qarzga sotish hozircha mavjud emas — OFD qoidalarini kutyapmiz'));
    }
    final uid = _uuid.v4();
    final soldAt = _now();
    // Кафе: номер заказа дня выдаёт касса — и без интернета. У оплаты счёта
    // стола номера нет: заказ уже на кухне.
    final orderNo = order == null || order['bill'] != null ? null : nextOrderNo;
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
      debt: debt,
      order: order == null ? null : {...order, if (orderNo != null) 'no': orderNo},
    );
    if (fiscalMode && fiscal == null) {
      final receipt = FiscalReceipt.sale(draft);
      final problems = receiptProblems(receipt);
      if (problems.isNotEmpty) throw CartError(problems.first);
      try {
        final res = await this.fiscal.register(receipt);
        draft = SaleRecord.fromJson({...draft.toJson(), 'fiscal': res.toSale()});
      } on FiscalError catch (e) {
        throw CartError(tr('Фискальный модуль: ${e.message}', 'Fiskal modul: ${e.message}'));
      }
    }
    _saleSeq++;
    if (orderNo != null) {
      _orderNo = orderNo;
      _orderDay = _today();
    }
    final rec = draft;
    await store.append(_journalName(rec.shiftUid), rec.toJson());
    await outbox.add('sale', rec.toJson(), rec.cashierId, at: rec.soldAt);
    await _saveState();
    journal.add(rec);
    notifyListeners();
    unawaited(sync());
    unawaited(printSale(rec).then((_) => printKitchen(rec)));
    return rec;
  }

  /// Кафе: номерок гостю на принтер чеков и бегунки цехов — на принтер цеха
  /// или принтер чеков, если экрана кухни нет (или касса без связи).
  /// Ошибка не мешает продаже.
  Future<bool> printKitchen(SaleRecord rec) async {
    if (catalog.cafe == null || rec.order == null || rec.billId != null) return false;
    final err = await kitchen.printOrder(rec);
    if (err != null || printError != null) {
      printError = err;
      notifyListeners();
    }
    return err == null;
  }

  String get _shiftLabel => '${catalog.settings.deviceName.isEmpty ? tr('Касса', 'Kassa') : catalog.settings.deviceName}'
      '${shift?.number != null ? tr(' · смена ${shift!.number}', ' · smena ${shift!.number}') : ''}';

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

  /// Кафе со столами: пречек гостю на принтер чеков.
  Future<bool> printPrecheck(Bill b) =>
      _print(() => precheckReceipt(s: catalog.settings, bill: b, at: _now(), paperMm: printer.paperMm, codePage: printer.codePage));

  /// Кафе со столами: бегунки цехов по отправке счёта «На кухню», «Подавать»
  /// или отмене. Ошибка не мешает работе.
  Future<void> printTable(Bill b, List<(BillItem, int)> lines, {TableTicket kind = TableTicket.send, String reason = ''}) async {
    final err = await kitchen.printTable(b, lines, kind: kind, reason: reason);
    if (err != null) {
      printError = err;
      notifyListeners();
    }
  }

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

  // ------------------------------------------------------- долги

  /// Продажа в долг доступна: магазин «даёт в долг» и у кассира есть право.
  bool get canDebt => catalog.settings.debtEnabled && (cashier?.can(Perm.debtsGive) ?? false);

  /// Принять погашение долга может любой кассир — если магазин даёт в долг
  /// или долги в сети уже есть (магазин мог выключить продажу в долг).
  /// Быстрые кнопки настраивает кассир с правом «Настройка кассы» (владелец — всегда).
  bool get canQuickKeys => cashier?.can(Perm.posSettings) ?? false;

  /// Закрепить товары на вкладке «Частые» (порядок — как в списке). Сохраняется
  /// на сервере для всех касс магазина. Ошибка — текст, успех — null.
  Future<String?> saveQuickKeys(List<String> productIds) async {
    if (!canQuickKeys) return tr('Нет права «Настройка кассы»', '«Kassa sozlamalari» huquqi yoʻq');
    try {
      final res = await api.send('PUT', '/pos/quick-keys', body: {'product_ids': productIds}, cashier: cashier?.id)
          as Map<String, dynamic>;
      catalog.quickPinned = ((res['pinned'] as List?) ?? const []).map((e) => '$e').toList();
      catalog.quickTop = ((res['top'] as List?) ?? catalog.quickTop).map((e) => '$e').toList();
      await _keepCatalog();
      online = true;
      notifyListeners();
      return null;
    } on ApiError catch (e) {
      _netError(e);
      return e.isNetwork ? tr('Нет связи с сервером — быстрые кнопки сохраняются на сервере, попробуйте позже', 'Server bilan aloqa yoʻq — tezkor tugmalar serverda saqlanadi, keyinroq urinib koʻring') : e.message;
    }
  }

  /// Каталог на диске после правки на месте: время загрузки с сервера не меняется.
  Future<void> _keepCatalog() => store.writeJson('catalog.json', {
        ...catalog.toJson(),
        if (catalogAt != null) 'saved_at': catalogAt!.toUtc().toIso8601String(),
        if (_catalogLang != null) 'lang': _catalogLang,
      });

  bool get canPrice => cashier?.can(Perm.prices) ?? false;

  /// Цена продажи товару без цены — сразу на сервере (документ цен магазина)
  /// и в каталоге кассы. Нет связи — цена в каталоге кассы и в очереди: уйдёт
  /// раньше чека, где товар продан (очередь идёт по порядку), и только если
  /// цену за это время не поставили в панели. Возвращает товар с ценой;
  /// ошибка — [PriceError].
  Future<Product> setProductPrice(Product p, int price) async {
    if (!canPrice) throw PriceError(tr('Цену ставит владелец или сотрудник с правом «Установка цен»', 'Narxni egasi yoki «Narxlarni belgilash» huquqiga ega xodim qoʻyadi'));
    Product priced;
    try {
      final res = await api.send('PUT', '/pos/products/${p.id}/price', body: {'price': moneyApi(price)}, cashier: cashier?.id)
          as Map<String, dynamic>;
      priced = Product.fromJson({...p.toJson(), 'price': res['price']});
      online = true;
    } on ApiError catch (e) {
      _netError(e);
      if (!e.isNetwork) throw PriceError(e.message);
      await outbox.add('price', {'product_id': p.id, 'price': price, 'name': p.name, 'product': p.toJson()}, cashier!.id, at: _now());
      priced = Product.fromJson({...p.toJson(), 'price': moneyApi(price)});
    }
    catalog.put(priced);
    await _keepCatalog();
    notifyListeners();
    return priced;
  }

  /// Цены, поставленные без связи, ещё в очереди — каталог с сервера их не
  /// знает (или загружен заново целиком): вернуть их товарам без цены.
  void _applyQueuedPrices() {
    for (final i in outbox.pendingItems) {
      if (i.kind != 'price') continue;
      final price = (i.body['price'] as num?)?.toInt() ?? 0;
      final cur = catalog.byId(i.body['product_id'] as String? ?? '');
      if (price <= 0 || (cur != null && cur.price > 0)) continue;
      final src = cur?.toJson() ?? (i.body['product'] as Map?)?.cast<String, dynamic>();
      if (src != null) catalog.put(Product.fromJson({...src, 'price': moneyApi(price)}));
    }
  }

  /// Товар Super Market по штрихкоду, которого нет в каталоге кассы (у него
  /// нет цены в магазине). null — такого штрихкода нет нигде; без связи —
  /// [ApiError] со статусом 0.
  Future<Product?> lookupBarcode(String code) async {
    try {
      final res = await api.get('/pos/products/lookup', query: {'barcode': code}, cashier: cashier?.id, wait: const Duration(seconds: 4))
          as Map<String, dynamic>;
      online = true;
      return Product.fromJson({
        ...res,
        'fractional': res['is_fractional'] == true,
        'marked': res['is_marked'] == true,
        'barcodes': [res['barcode'] ?? code],
      });
    } on ApiError catch (e) {
      if (e.status == 404) return null;
      _netError(e);
      rethrow;
    }
  }

  bool get canTakeDebtPayment => catalog.settings.debtEnabled || catalog.debtors.isNotEmpty;

  /// Долг по номеру из чеков и погашений в очереди (ещё не на сервере).
  int _pendingDebt(String phone) {
    var sum = 0;
    for (final i in outbox.pendingItems) {
      if (i.kind == 'sale') {
        final d = i.body['debt'];
        if (d is Map && d['phone'] == phone) sum += (d['amount'] as int?) ?? 0;
      } else if (i.kind == 'debt_payment' && i.body['phone'] == phone) {
        sum -= (i.body['amount'] as int?) ?? 0;
      }
    }
    return sum;
  }

  /// Покупатель из каталога кассы — когда нет связи. К долгу из каталога
  /// добавляем чеки и погашения этой смены после его загрузки.
  DebtorView localDebtor(String phone, {String qrId = ''}) {
    final d = catalog.debtors[phone];
    var debt = d?.debt ?? 0;
    final since = catalogAt;
    for (final e in journal) {
      if (e is SaleRecord && e.debt?.phone == phone && (since == null || e.soldAt.isAfter(since))) debt += e.debt!.amount;
      if (e is DebtPaymentRecord && e.phone == phone && (since == null || e.at.isAfter(since))) debt -= e.amount;
    }
    if (d == null) {
      return DebtorView(phone: phone, debt: debt, limit: 10000000, unverifiedLimit: 10000000, qrId: qrId);
    }
    return DebtorView(
      phone: phone,
      found: true,
      name: d.fullName,
      debt: debt,
      limit: d.limit,
      blocked: d.blocked,
      verified: d.verified,
      qrId: qrId,
    );
  }

  /// Покупатель по номеру: с сервера, без связи — из каталога.
  Future<DebtorView> lookupDebtor(String phone) async {
    try {
      final res = await api.get('/pos/debtors', query: {'phone': phone}, cashier: cashier?.id) as Map<String, dynamic>;
      online = true;
      return DebtorView.fromLookup(res, pending: _pendingDebt(phone));
    } on ApiError catch (e) {
      if (e.status != 0) rethrow;
      _netError(e);
      return localDebtor(phone);
    }
  }

  /// Покупатель по QR из приложения (Figma «ДQ1–ДQ3»): QR проверяет сервер,
  /// номер подтверждён входом в приложение. Без связи — ищем номер QR в
  /// каталоге кассы (код проверить нельзя).
  Future<DebtorView> lookupDebtorQr(String code) async {
    final qr = parseClientQr(code);
    if (qr == null) throw CartError(tr('Это не QR покупателя Super Market', 'Bu Super Market xaridorining QR kodi emas'));
    try {
      final res = await api.get('/pos/debtors/qr', query: {'code': qr.payload}, cashier: cashier?.id) as Map<String, dynamic>;
      online = true;
      return DebtorView.fromLookup(res, pending: _pendingDebt(res['phone'] as String? ?? ''));
    } on ApiError catch (e) {
      if (e.status != 0) rethrow;
      _netError(e);
      for (final d in catalog.debtors.values) {
        if (d.qrId == qr.qrId) return localDebtor(d.phone, qrId: qr.qrId);
      }
      throw CartError(tr('Нет связи, а этого покупателя ещё нет в каталоге кассы — введите номер телефона (F2)',
          'Aloqa yoʻq, bu xaridor esa hali kassa katalogida yoʻq — telefon raqamini kiriting (F2)'));
    }
  }

  /// Отправить покупателю код подтверждения номера (нужен интернет).
  /// Возвращает канал: push, sms или dev.
  Future<String> sendDebtCode(String phone) async {
    final res = await api.post('/pos/debtors/code', {'phone': phone}, cashier: cashier?.id) as Map<String, dynamic>;
    return res['channel'] as String? ?? '';
  }

  /// Проверить код и подтвердить номер; заводит покупателя с именем.
  Future<DebtorView> verifyDebtCode(String phone, String code, String name) async {
    final res = await api.post('/pos/debtors/verify', {'phone': phone, 'code': code, 'full_name': name}, cashier: cashier?.id)
        as Map<String, dynamic>;
    return DebtorView.fromLookup(res, pending: _pendingDebt(phone));
  }

  /// Погашение долга на кассе: журнал смены, очередь, квитанция. Без сервера.
  Future<DebtPaymentRecord> recordDebtPayment({required DebtorView who, required int amount, required PayMethod method}) async {
    if (shiftLimit?.state == LimitState.blocked) throw CartError(tr('Смена идёт больше 24 часов — закройте смену (Z-отчёт)', 'Smena 24 soatdan beri davom etmoqda — smenani yoping (Z-hisobot)'));
    if (amount <= 0) throw CartError(tr('Наберите сумму', 'Summani tering'));
    if (amount > who.debt) throw CartError(tr('Сумма больше долга ${fmtMoney(who.debt)}', 'Summa qarzdan (${fmtMoney(who.debt)}) koʻp'));
    final r = DebtPaymentRecord(
      uid: _uuid.v4(),
      shiftUid: shift!.uid,
      phone: who.phone,
      name: who.name,
      amount: amount,
      kind: method.kind,
      methodId: method.id,
      methodName: method.name,
      at: _now(),
      cashierId: cashier!.id,
      balance: who.debt - amount,
    );
    await store.append(_journalName(r.shiftUid), r.toJson());
    await outbox.add('debt_payment', r.toJson(), r.cashierId, at: r.at);
    journal.add(r);
    notifyListeners();
    unawaited(sync());
    final by = cashier!.name;
    unawaited(_print(() => debtPaymentReceipt(
          s: catalog.settings,
          r: r,
          shiftLabel: _shiftLabel,
          cashier: by,
          paperMm: printer.paperMm,
          codePage: printer.codePage,
          openDrawer: printer.drawer,
        )));
    return r;
  }

  // ----------------------------------------------------------- возврат

  /// Найти чек для возврата: номер с чека или QR (client_uid). Нужен интернет.
  Future<Map<String, dynamic>> findSale(String q) async {
    q = q.trim().replaceFirst('№', '');
    // Чек этой кассы, который ещё не дошёл до сервера.
    final pendingSale = outbox.failed.any((i) => i.body['uid'] == q);
    if (pendingSale) throw ApiError(400, 'not_sent', tr('Этот чек не принят сервером — возврат невозможен', 'Bu chek server tomonidan qabul qilinmagan — qaytarib boʻlmaydi'));
    await sync();
    final res = await api.get('/pos/sales', query: {'q': q}, cashier: cashier!.id) as Map<String, dynamic>;
    final items = (res['items'] as List?) ?? const [];
    if (items.isEmpty) {
      throw ApiError(404, 'not_found', online ? tr('Чек $q не найден', '$q chek topilmadi') : tr('Нет связи — возврат проводится только онлайн', 'Aloqa yoʻq — qaytarish faqat onlayn amalga oshiriladi'));
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
    final blocked = shiftLimit?.state == LimitState.blocked ? tr('Смена идёт больше 24 часов — закройте смену (Z-отчёт)', 'Smena 24 soatdan beri davom etmoqda — smenani yoping (Z-hisobot)') : null;
    if (blocked != null) throw ApiError(409, 'shift_expired', blocked);
    final shiftId = shift!.serverId ?? outbox.shiftIds[shift!.uid];
    if (shiftId == null) throw ApiError(0, 'network', tr('Смена ещё не дошла до сервера — нужен интернет', 'Smena hali serverga yetib bormadi — internet kerak'));
    final saleSign = '${sale['fiscal_sign'] ?? ''}';
    if (fiscalMode && saleSign.isEmpty) {
      throw ApiError(409, 'not_fiscal', tr('Исходный чек не фискальный — возврат через фискальный модуль невозможен', 'Asl chek fiskal emas — fiskal modul orqali qaytarib boʻlmaydi'));
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
        fiscalError = tr('Возврат проведён, но фискальный модуль не пробил чек: ${e.message}', 'Qaytarish bajarildi, lekin fiskal modul chek chiqarmadi: ${e.message}');
      } on ApiError catch (e) {
        fiscalError = tr('Чек возврата пробит, но сервер не сохранил признак: ${e.message}', 'Qaytarish cheki chiqarildi, lekin server fiskal belgini saqlamadi: ${e.message}');
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
      debtAmount: parseMoney(res['debt_amount']),
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
          debtAmount: rec.debtAmount,
        )));
    if (fiscalError != null) {
      printError = fiscalError;
      notifyListeners();
    }
    return rec;
  }
}

/// Цену не удалось поставить: текст — для окна цены.
class PriceError implements Exception {
  PriceError(this.message);
  final String message;

  @override
  String toString() => message;
}
