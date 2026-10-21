// Касса кафе со столами (Figma С1–С9): залы, столы и открытые счета.
//
// Состояние зала касса берёт с сервера (GET /pos/hall) и ждёт перемен так же,
// как экран кухни. Операции со счётом (открыть стол, дописать, «На кухню»,
// гости, пречек, перенос на свободный стол, закрыть без оплаты) касса пишет в
// очередь (kind bill_op) и сразу показывает у себя: то, что видно на экране, —
// состояние сервера плюс ещё не отправленные операции и оплаты из очереди.
// Повтор операции безопасен — у неё свой id.
//
// Отмена позиции с кухни, объединение счетов и перенос части блюд меняют
// чужие данные (кухня, другой стол) и проверяются сервером — только со связью.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sm_core/sm_core.dart' show tr;
import 'package:uuid/uuid.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/money.dart';
import '../data/api.dart';
import '../data/outbox.dart';
import '../state/pos.dart';
import 'kitchen_board.dart';
import 'menu.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// Процент с сервера («10», «12.5») → сотые доли процента (1000 = 10%).
int percentBp(Object? v) => parseMoney(v);

class HallRoom {
  HallRoom({required this.id, required this.name, required this.sort});
  final String id;
  final String name;
  final int sort;

  factory HallRoom.fromJson(Map<String, dynamic> j) =>
      HallRoom(id: j['id'] as String, name: j['name'] as String? ?? '', sort: (j['sort'] as num?)?.toInt() ?? 0);
}

class HallTable {
  HallTable({
    required this.id,
    required this.hallId,
    required this.number,
    this.seats = 4,
    this.shape = 'rect',
    this.x = 0,
    this.y = 0,
    this.w = 2,
    this.h = 2,
    this.waiterId,
    this.waiterName = '',
    this.service = true,
  });

  final String id;
  final String hallId;
  final String number;
  final int seats;

  /// rect · round · topchan.
  final String shape;
  final int x, y, w, h;

  /// Официант стола по умолчанию (зона).
  final String? waiterId;
  final String waiterName;

  /// Обслуживание % у этого стола.
  final bool service;

  factory HallTable.fromJson(Map<String, dynamic> j) => HallTable(
        id: j['id'] as String,
        hallId: j['hall_id'] as String? ?? '',
        number: j['number'] as String? ?? '',
        seats: (j['seats'] as num?)?.toInt() ?? 4,
        shape: j['shape'] as String? ?? 'rect',
        x: (j['x'] as num?)?.toInt() ?? 0,
        y: (j['y'] as num?)?.toInt() ?? 0,
        w: (j['w'] as num?)?.toInt() ?? 2,
        h: (j['h'] as num?)?.toInt() ?? 2,
        waiterId: j['waiter_id'] as String?,
        waiterName: j['waiter_name'] as String? ?? '',
        service: j['service'] != false,
      );
}

class BillMod {
  BillMod({required this.optionId, required this.name, this.qty = 1, this.price = 0, this.action = 'none'});
  final String optionId;
  final String name;
  final int qty;

  /// Доплата за порцию, тийины.
  final int price;
  final String action;

  factory BillMod.fromJson(Map<String, dynamic> j) => BillMod(
        optionId: j['option_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        qty: (j['qty'] as num?)?.toInt() ?? 1,
        price: j['price'] is int ? j['price'] as int : parseMoney(j['price']),
        action: j['action'] as String? ?? 'none',
      );

  LineMod toLine() => LineMod(optionId: optionId, name: name, qty: qty, price: price, action: action);
}

/// Позиция счёта. Количество — тысячные, цена — тийины (с модификаторами).
class BillItem {
  BillItem({
    required this.id,
    required this.seq,
    required this.productId,
    required this.name,
    required this.qty,
    required this.price,
    this.mods = const [],
    this.note = '',
    this.guest,
    this.course = 'now',
    this.status = 'new',
    this.sentAt,
    this.cancelled = 0,
    this.paid = 0,
    this.kitchen = '',
  });

  final String id;
  int seq;
  final String productId;
  final String name;
  int qty;
  final int price;
  final List<BillMod> mods;
  String note;
  int? guest;

  /// now — сразу на кухню; later — «по команде».
  String course;

  /// new — ещё не на кухне; sent — ушла на кухню.
  String status;
  DateTime? sentAt;
  int cancelled;
  int paid;

  /// Состояние на кухне: waiting · new · cooking · ready · served · cancelled; '' — не блюдо.
  String kitchen;

  bool get isNew => status == 'new';

  /// Сколько ещё к оплате.
  int get left => (qty - cancelled - paid).clamp(0, qty).toInt();

  /// Сколько на столе (без отменённого).
  int get live => (qty - cancelled).clamp(0, qty).toInt();

  factory BillItem.fromJson(Map<String, dynamic> j) => BillItem(
        id: j['id'] as String,
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        productId: j['product_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        qty: parseQty(j['qty']),
        price: parseMoney(j['price']),
        mods: [for (final m in (j['mods'] as List?) ?? const []) BillMod.fromJson(m as Map<String, dynamic>)],
        note: j['note'] as String? ?? '',
        guest: (j['guest'] as num?)?.toInt(),
        course: j['course'] as String? ?? 'now',
        status: j['status'] as String? ?? 'new',
        sentAt: _time(j['sent_at']),
        cancelled: parseQty(j['cancelled_qty']),
        paid: parseQty(j['paid_qty']),
        kitchen: j['kitchen'] as String? ?? '',
      );
}

class Bill {
  Bill({
    required this.id,
    this.tableId,
    this.tableNumber = '',
    this.hallName = '',
    this.waiterId,
    this.waiterName = '',
    this.guests = 1,
    this.serviceBp = 0,
    this.precheckAt,
    required this.openedAt,
    List<BillItem>? items,
  }) : items = items ?? [];

  final String id;
  String? tableId;
  String tableNumber;
  String hallName;
  String? waiterId;
  String waiterName;
  int guests;

  /// Обслуживание в сотых процента (1000 = 10%), 0 — без него.
  final int serviceBp;
  DateTime? precheckAt;
  final DateTime openedAt;
  final List<BillItem> items;

  /// Сумма блюд без отменённого.
  int get subtotal => items.fold(0, (s, i) => s + lineSum(i.price, i.live));
  int get service => percentOf(subtotal, serviceBp);
  int get total => subtotal + service;

  /// Ещё не оплачено (с обслуживанием).
  int get leftSum => items.fold(0, (s, i) => s + lineSum(i.price, i.left));
  int get leftTotal => leftSum + percentOf(leftSum, serviceBp);

  int get ready => items.where((i) => i.kitchen == 'ready' && i.live > 0).length;
  int get newCount => items.where((i) => i.isNew).length;
  bool get anyPaid => items.any((i) => i.paid > 0);
  bool get hasWaiting => items.any((i) => i.kitchen == 'waiting' && i.live > 0);
  bool get empty => items.every((i) => i.live == 0);

  factory Bill.fromJson(Map<String, dynamic> j) => Bill(
        id: j['id'] as String,
        tableId: j['table_id'] as String?,
        tableNumber: j['table_number'] as String? ?? '',
        hallName: j['hall_name'] as String? ?? '',
        waiterId: j['waiter_id'] as String?,
        waiterName: j['waiter_name'] as String? ?? '',
        guests: (j['guests'] as num?)?.toInt() ?? 1,
        serviceBp: percentBp(j['service_percent']),
        precheckAt: _time(j['precheck_at']),
        openedAt: _time(j['opened_at']) ?? DateTime.now(),
        items: [for (final i in (j['items'] as List?) ?? const []) BillItem.fromJson(i as Map<String, dynamic>)],
      );
}

/// Зал, как его видит касса сейчас.
class HallView {
  HallView({
    this.mode = 'tables',
    this.serviceBp = 0,
    this.waiterOwnTables = true,
    this.precheckRequired = false,
    this.voidSeniorOnly = true,
    this.serviceIkpu = '',
    this.halls = const [],
    this.tables = const [],
    List<Bill>? bills,
  }) : bills = bills ?? [];

  final String mode;
  final int serviceBp;
  final bool waiterOwnTables;
  final bool precheckRequired;
  final bool voidSeniorOnly;
  final String serviceIkpu;
  final List<HallRoom> halls;
  final List<HallTable> tables;
  final List<Bill> bills;

  HallTable? table(String? id) {
    for (final t in tables) {
      if (t.id == id) return t;
    }
    return null;
  }

  Bill? bill(String? id) {
    for (final b in bills) {
      if (b.id == id) return b;
    }
    return null;
  }

  Bill? billOn(String tableId) {
    for (final b in bills) {
      if (b.tableId == tableId) return b;
    }
    return null;
  }

  String hallName(String hallId) {
    for (final h in halls) {
      if (h.id == hallId) return h.name;
    }
    return '';
  }

  factory HallView.fromJson(Map<String, dynamic> j) {
    final halls = [for (final h in (j['halls'] as List?) ?? const []) HallRoom.fromJson(h as Map<String, dynamic>)]
      ..sort((a, b) => a.sort.compareTo(b.sort));
    return HallView(
      mode: j['mode'] as String? ?? 'tables',
      serviceBp: percentBp(j['service_percent']),
      waiterOwnTables: j['waiter_own_tables'] != false,
      precheckRequired: j['precheck_required'] == true,
      voidSeniorOnly: j['void_senior_only'] != false,
      serviceIkpu: j['service_ikpu'] as String? ?? '',
      halls: halls,
      tables: [for (final t in (j['tables'] as List?) ?? const []) HallTable.fromJson(t as Map<String, dynamic>)],
      bills: [for (final b in (j['bills'] as List?) ?? const []) Bill.fromJson(b as Map<String, dynamic>)],
    );
  }
}

/// Позиция для операции «add» из строки чека кассы.
Map<String, dynamic> itemBody(String id, CartLine l, {String course = 'now', int? guest}) => {
      'id': id,
      'product_id': l.product.id,
      'qty': qtyApi(l.qty),
      'price': moneyApi(l.price),
      if (l.mods.isNotEmpty) 'modifiers': [for (final m in l.mods) {'option_id': m.optionId, 'qty': m.qty}],
      if (l.comment.isNotEmpty) 'note': l.comment,
      'course': course,
      if (guest != null) 'guest': guest,
      // Для показа на кассе, пока операция в очереди (сервер возьмёт своё).
      '_name': l.product.name,
      '_mods': [for (final m in l.mods) m.toJson()],
    };

class BillsController extends ChangeNotifier {
  BillsController(this.pos) {
    feed = LiveFeed(baseUrl: pos.api.baseUrl, token: pos.api.token, load: _load)..addListener(_changed);
    pos.addListener(_changed);
    feed.start();
  }

  final PosController pos;
  late final LiveFeed feed;

  Map<String, dynamic>? _server;
  int _stamp = 0;
  String? _viewKey;
  HallView? _view;

  bool get loaded => _server != null;
  bool get online => feed.online;
  String? get error => feed.error;

  Future<int> _load(PosApi api) async {
    final res = await api.get('/pos/hall') as Map<String, dynamic>;
    _server = res;
    _stamp++;
    return (res['version'] as num?)?.toInt() ?? 0;
  }

  void _changed() {
    if (hasListeners) notifyListeners();
  }

  @override
  void dispose() {
    pos.removeListener(_changed);
    feed.removeListener(_changed);
    feed.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- вид

  /// Отправленные операции, которых ещё нет в состоянии сервера у кассы:
  /// показываем их, пока зал не перечитан (иначе позиция мигнёт).
  final List<OutboxItem> _carry = [];
  List<OutboxItem> _replayed = const [];
  int _carryStamp = -1;

  /// Зал сейчас: сервер + очередь кассы.
  HallView get view {
    if (_carryStamp != _stamp) {
      _carry.clear();
      _carryStamp = _stamp;
    }
    final pending = [for (final it in pos.outbox.pendingItems) if (it.kind == 'bill_op' || it.kind == 'sale') it];
    for (final it in _replayed) {
      if (!pending.contains(it) && !_carry.contains(it)) _carry.add(it);
    }
    _replayed = pending;
    final key = '$_stamp/${_carry.length}/${pending.length}/${pending.isEmpty ? 0 : pending.last.seq}';
    if (_view != null && _viewKey == key) return _view!;
    final v = _server == null ? HallView() : HallView.fromJson(_server!);
    for (final it in [..._carry, ...pending]) {
      if (it.kind == 'bill_op') {
        applyBillOp(v, it.body, menu: pos.catalog.cafe, waiterName: _waiterName);
      } else {
        applyBillSale(v, it.body);
      }
    }
    v.bills.removeWhere((b) => b.items.isNotEmpty && b.items.every((i) => i.left == 0 && !i.isNew) && b.items.any((i) => i.paid > 0));
    _view = v;
    _viewKey = key;
    return v;
  }

  String _waiterName(String? id) {
    if (id == null) return '';
    for (final c in pos.catalog.cashiers) {
      if (c.id == id) return c.name;
    }
    return '';
  }

  // ------------------------------------------------------------ операции

  String get _cashierId => pos.cashier?.id ?? '';

  /// Операция через очередь: сразу на экране, на сервер — когда будет связь.
  Future<void> op(String kind, String billId, [Map<String, dynamic> fields = const {}]) async {
    final now = DateTime.now();
    await pos.outbox.add('bill_op', {
      'id': newId(),
      'bill_id': billId,
      'kind': kind,
      'at': now.toUtc().toIso8601String(),
      ...fields,
    }, _cashierId, at: now);
    _view = null;
    notifyListeners();
    unawaited(pos.push());
  }

  /// Открыть стол: id счёта выдаёт касса.
  Future<String> open(HallTable t, {required int guests, String? waiterId}) async {
    final id = newId();
    await op('open', id, {'table_id': t.id, 'guests': guests, 'waiter_id': waiterId ?? ''});
    return id;
  }

  /// Новые блюда из чека — в счёт; [send] — сразу «На кухню».
  /// Возвращает id новых позиций.
  Future<List<String>> addLines(String billId, List<CartLine> lines, {bool send = true, String course = 'now'}) async {
    final ids = <String>[];
    for (final l in lines) {
      final id = newId();
      ids.add(id);
      await op('add', billId, {'item': itemBody(id, l, course: course)});
    }
    if (send) await op('send', billId);
    return ids;
  }

  /// Операция только со связью: сервер проверяет и отвечает. Ошибка — текст.
  Future<String?> direct(String kind, String billId, Map<String, dynamic> fields) async {
    await pos.push();
    final waiting = pos.outbox.pendingItems.any((i) => i.kind == 'bill_op' || (i.kind == 'sale' && i.body['order'] is Map && (i.body['order'] as Map)['bill'] != null));
    if (waiting) {
      return tr('Нет связи с сервером — дождитесь отправки очереди и повторите', 'Server bilan aloqa yoʻq — navbat yuborilishini kuting va qaytaring');
    }
    try {
      await pos.api.post('/pos/bills/ops', {
        'id': newId(),
        'bill_id': billId,
        'kind': kind,
        'at': DateTime.now().toUtc().toIso8601String(),
        ...fields,
      }, cashier: _cashierId);
      await feed.refresh();
      return null;
    } on ApiError catch (e) {
      if (e.status == 0) return tr('Нет связи с сервером — это действие только со связью', 'Server bilan aloqa yoʻq — bu amal faqat aloqa bilan');
      return e.message;
    }
  }

  /// Официанты на смене — кассиры с правом работать на кассе.
  List<Cashier> get waiters => [for (final c in pos.catalog.cashiers) if (c.can(Perm.pos)) c];

  /// Чей стол: официант видит только свои (настройка П10); старший — все.
  bool mine(Bill b) {
    final me = pos.cashier;
    if (me == null) return false;
    return b.waiterId == null || b.waiterId == me.id;
  }

  bool canOpen(Bill b) {
    final me = pos.cashier;
    if (me == null) return false;
    if (!view.waiterOwnTables || mine(b)) return true;
    return me.can(Perm.returns);
  }
}

/// Операция со счётом из очереди — на виде зала (как её применит сервер).
void applyBillOp(HallView v, Map<String, dynamic> op, {CafeMenu? menu, String Function(String? id)? waiterName}) {
  String name(String? id) => waiterName?.call(id) ?? '';
  final kind = op['kind'] as String?;
  final billId = op['bill_id'] as String?;
  if (kind == 'open') {
    if (v.bill(billId) != null) return;
    final t = v.table(op['table_id'] as String?);
    if (t == null || v.billOn(t.id) != null) return;
    final waiter = op.containsKey('waiter_id') ? op['waiter_id'] as String? : t.waiterId;
    v.bills.add(Bill(
      id: billId!,
      tableId: t.id,
      tableNumber: t.number,
      hallName: v.hallName(t.hallId),
      waiterId: waiter == '' ? null : waiter,
      waiterName: name(waiter),
      guests: (op['guests'] as num?)?.toInt() ?? 1,
      serviceBp: t.service ? v.serviceBp : 0,
      openedAt: _time(op['at']) ?? DateTime.now(),
    ));
    return;
  }
  final b = v.bill(billId);
  if (b == null) return;
  BillItem? item(String? id) {
    for (final i in b.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  switch (kind) {
    case 'add':
      final j = (op['item'] as Map).cast<String, dynamic>();
      if (item(j['id'] as String?) != null) return;
      b.items.add(BillItem(
        id: j['id'] as String,
        seq: b.items.fold(0, (m, i) => i.seq > m ? i.seq : m) + 1,
        productId: j['product_id'] as String,
        name: j['_name'] as String? ?? '',
        qty: parseQty(j['qty']),
        price: parseMoney(j['price']),
        mods: [
          for (final m in (j['_mods'] as List?) ?? const [])
            BillMod.fromJson((m as Map).cast<String, dynamic>()),
        ],
        note: j['note'] as String? ?? '',
        guest: (j['guest'] as num?)?.toInt(),
        course: j['course'] as String? ?? 'now',
      ));
    case 'update':
      final i = item(op['item_id'] as String?);
      if (i == null || !i.isNew) return;
      if (op['qty'] != null) i.qty = parseQty(op['qty']);
      if (op['note'] != null) i.note = op['note'] as String;
      if (op['course'] != null) i.course = op['course'] as String;
      if (op['guest'] != null) i.guest = (op['guest'] as num).toInt() == 0 ? null : (op['guest'] as num).toInt();
    case 'remove':
      b.items.removeWhere((i) => i.id == op['item_id'] && i.isNew);
    case 'send':
      for (final i in b.items) {
        if (!i.isNew) continue;
        i.status = 'sent';
        i.sentAt = _time(op['at']) ?? DateTime.now();
        final dish = menu?.dish(i.productId)?.isDish ?? false;
        i.kitchen = dish ? (i.course == 'later' ? 'waiting' : 'new') : '';
      }
    case 'fire':
      for (final i in b.items) {
        if (i.kitchen == 'waiting') {
          i.kitchen = 'new';
          i.course = 'now';
        }
      }
    case 'guests':
      b.guests = (op['guests'] as num?)?.toInt() ?? b.guests;
    case 'waiter':
      final w = op['waiter_id'] as String?;
      b.waiterId = w == null || w.isEmpty ? null : w;
      b.waiterName = name(b.waiterId);
    case 'precheck':
      b.precheckAt = _time(op['at']) ?? DateTime.now();
    case 'move':
      final t = v.table(op['to_table_id'] as String?);
      if (t == null) return;
      b.tableId = t.id;
      b.tableNumber = t.number;
      b.hallName = v.hallName(t.hallId);
    case 'void':
      v.bills.remove(b);
  }
}

/// Оплата счёта в очереди: позиции уже оплачены.
void applyBillSale(HallView v, Map<String, dynamic> sale) {
  final order = sale['order'];
  if (order is! Map || order['bill'] == null) return;
  final b = v.bill(order['bill'] as String?);
  if (b == null) return;
  for (final l in (sale['lines'] as List?) ?? const []) {
    final m = (l as Map).cast<String, dynamic>();
    final id = m['bill_item_id'];
    if (id == null) continue;
    for (final i in b.items) {
      if (i.id == id) i.paid = (i.paid + (m['qty'] as int)).clamp(0, i.qty - i.cancelled).toInt();
    }
  }
}
