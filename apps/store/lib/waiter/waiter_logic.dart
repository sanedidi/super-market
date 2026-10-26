import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sm_core/sm_core.dart';

// Данные режима «Официант»: зал, открытые счета, меню точки и операции со
// счётом. Сервер — /store/cafe/waiter/* (этап 6 модуля «Кафе»): те же счета,
// что и у кассы, те же операции (id операции — повтор не применяется второй
// раз). Изменения других устройств приходят длинным запросом /waiter/wait.

String _s(Object? v) => v == null ? '' : '$v';
int _i(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
num _n(Object? v) => num.tryParse('${v ?? ''}') ?? 0;
DateTime? _d(Object? v) => v == null ? null : DateTime.tryParse('$v');

final _rnd = Random.secure();

/// uuid v4 — id счёта, позиции и операции выдаёт телефон.
String newUuid() {
  final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Деньги приходят строкой «35000.00»; в сумах без тийинов.
int moneyInt(Object? v) => _n(v).round();

class WHall {
  WHall(this.id, this.name);
  final String id;
  final String name;
}

class WTable {
  WTable.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        hallId = _s(j['hall_id']),
        number = _s(j['number']),
        seats = _i(j['seats']),
        shape = _s(j['shape']),
        x = _i(j['x']),
        y = _i(j['y']),
        w = _i(j['w']) < 1 ? 1 : _i(j['w']),
        h = _i(j['h']) < 1 ? 1 : _i(j['h']),
        waiterId = j['waiter_id'] as String?,
        waiterName = _s(j['waiter_name']);

  final String id, hallId, number, shape;
  final int seats, x, y, w, h;

  /// Официант стола на сегодня (зона на смену или постоянный).
  final String? waiterId;
  final String waiterName;
}

class WMod {
  WMod.fromJson(Map<String, dynamic> j)
      : optionId = _s(j['option_id']),
        name = _s(j['name']),
        qty = _i(j['qty']) < 1 ? 1 : _i(j['qty']),
        price = moneyInt(j['price']),
        action = _s(j['action']);

  WMod(this.optionId, this.name, this.price, this.action) : qty = 1;

  final String optionId, name, action;
  final int qty, price;
}

class WItem {
  WItem.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        seq = _i(j['seq']),
        productId = _s(j['product_id']),
        name = _s(j['name']),
        qty = _n(j['qty']),
        price = moneyInt(j['price']),
        mods = [for (final m in (j['mods'] as List? ?? const [])) WMod.fromJson(m as Map<String, dynamic>)],
        note = _s(j['note']),
        guest = j['guest'] == null ? null : _i(j['guest']),
        course = _s(j['course']).isEmpty ? 'now' : _s(j['course']),
        status = _s(j['status']),
        sentAt = _d(j['sent_at']),
        cancelledQty = _n(j['cancelled_qty']),
        kitchen = _s(j['kitchen']),
        servedAt = _d(j['served_at']);

  /// Новая позиция до ответа сервера (меню добавляет сразу).
  WItem.local({required this.id, required this.productId, required this.name, required this.qty, required this.price, required this.mods, required this.note, required this.guest, this.course = 'now'})
      : seq = 1 << 30,
        status = 'new',
        sentAt = null,
        cancelledQty = 0,
        kitchen = '',
        servedAt = null;

  final String id, productId, name, note, status, kitchen;
  final int seq, price;
  num qty;
  final List<WMod> mods;
  int? guest;
  String course;
  final DateTime? sentAt, servedAt;
  final num cancelledQty;

  bool get isNew => status == 'new';
  num get left => qty - cancelledQty;
  int get total => (left * price).round();

  /// Ключ для объединения одинаковых строк: блюдо, модификаторы, комментарий.
  String get sameKey => '$productId|${mods.map((m) => '${m.optionId}*${m.qty}').join(',')}|$note';

  /// «1 порция · + Казы · без лука».
  String get modsText => [
        for (final m in mods) m.action == 'remove' || m.action == 'factor' || m.action == 'none' ? m.name : '+ ${m.name}',
        if (note.isNotEmpty) '«$note»',
      ].join(' · ');
}

String qtyText(num q) => q == q.roundToDouble() ? '${q.toInt()}' : qty(q);

class WBill {
  WBill.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        tableId = j['table_id'] as String?,
        tableNumber = _s(j['table_number']),
        hallName = _s(j['hall_name']),
        waiterId = j['waiter_id'] as String?,
        waiterName = _s(j['waiter_name']),
        guests = _i(j['guests']) < 1 ? 1 : _i(j['guests']),
        comment = _s(j['comment']),
        status = _s(j['status']),
        servicePercent = _s(j['service_percent']),
        precheckAt = _d(j['precheck_at']),
        version = _i(j['version']),
        openedAt = _d(j['opened_at']) ?? DateTime.now(),
        items = [for (final x in (j['items'] as List? ?? const [])) WItem.fromJson(x as Map<String, dynamic>)],
        subtotal = _s(j['subtotal']),
        service = _s(j['service']),
        total = _s(j['total']),
        paid = _s(j['paid']),
        ready = _i(j['ready']),
        transferTo = j['transfer_to'] as String?,
        transferToName = _s(j['transfer_to_name']),
        transferFrom = j['transfer_from'] as String?,
        transferFromName = _s(j['transfer_from_name']),
        transferReason = _s(j['transfer_reason']),
        transferAt = _d(j['transfer_at']),
        mine = j['mine'] == true;

  final String id, tableNumber, hallName, waiterName, comment, status, servicePercent;
  final String? tableId, waiterId;
  int guests;
  final DateTime? precheckAt;
  final int version;
  final DateTime openedAt;
  final List<WItem> items;

  /// Суммы с сервера; у чужого стола (только свои столы) — пусто.
  final String subtotal, service, total, paid;
  final int ready;
  final String? transferTo, transferFrom;
  final String transferToName, transferFromName, transferReason;
  final DateTime? transferAt;
  final bool mine;

  bool get open => status == 'open';

  /// Чужой стол при «официант видит только свои столы» — сервер не отдал суммы.
  bool get hidden => total.isEmpty;

  List<WItem> get newItems => items.where((i) => i.isNew).toList();
  List<WItem> get sentItems => items.where((i) => !i.isNew && i.left > 0).toList();

  /// Готово на кухне и ещё не отнесено.
  List<WItem> get readyItems => items.where((i) => i.kitchen == 'ready' && i.left > 0).toList();

  /// «По команде» — на кухне ждут «Подать горячее».
  List<WItem> get waitingItems => sentItems.where((i) => i.kitchen == 'waiting').toList();

  /// Сумма новых (до ответа сервера считаем сами).
  int get newTotal => newItems.fold(0, (a, i) => a + i.total);
  num get newCount => newItems.fold<num>(0, (a, i) => a + i.qty);

  /// Позиции + обслуживание — пока сервер не пересчитал, считаем сами.
  int get localSubtotal => items.fold(0, (a, i) => a + i.total);
  int get localService => (localSubtotal * _n(servicePercent) / 100).round();
}

class WModOption {
  WModOption.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        price = moneyInt(j['price']),
        action = _s(j['action']),
        factor = _s(j['factor']);

  final String id, name, action, factor;
  final int price;
}

class WModGroup {
  WModGroup.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        min = _i(j['min_select']),
        max = _i(j['max_select']),
        options = [for (final o in (j['options'] as List? ?? const [])) WModOption.fromJson(o as Map<String, dynamic>)];

  final String id, name;
  final int min, max;
  final List<WModOption> options;

  bool get required => min > 0;
  bool get single => max == 1;

  /// «Убрать» — только бесплатные «без …»: чипами, а не списком.
  bool get removals => options.isNotEmpty && options.every((o) => o.action == 'remove' && o.price == 0);
}

class WDish {
  WDish({
    required this.id,
    required this.name,
    required this.nameRu,
    required this.nameUz,
    required this.price,
    required this.image,
    required this.code,
    required this.groupId,
    required this.modGroups,
    required this.portion,
    required this.cookMinutes,
    required this.workshopId,
  });

  final String id, name, nameRu, nameUz, image, portion;
  final int price;
  final int? code;
  final String? groupId, workshopId;
  final List<String> modGroups;
  final int? cookMinutes;
}

class WGroup {
  WGroup(this.id, this.name);
  final String id;
  final String name;
}

class WMenu {
  WMenu.fromJson(Map<String, dynamic> j) {
    for (final g in (j['groups'] as List? ?? const [])) {
      final m = g as Map<String, dynamic>;
      groups.add(WGroup(_s(m['id']), _s(m['name'])));
    }
    for (final w in (j['workshops'] as List? ?? const [])) {
      final m = w as Map<String, dynamic>;
      workshops[_s(m['id'])] = _s(m['name']);
    }
    for (final g in (j['modifier_groups'] as List? ?? const [])) {
      final mg = WModGroup.fromJson(g as Map<String, dynamic>);
      modGroups[mg.id] = mg;
    }
    final info = <String, Map<String, dynamic>>{
      for (final x in (j['items'] as List? ?? const [])) _s((x as Map<String, dynamic>)['product_id']): x,
    };
    for (final x in (j['dishes'] as List? ?? const [])) {
      final d = x as Map<String, dynamic>;
      if (d['on_sale'] == false) continue;
      final id = _s(d['product_id']);
      final it = info[id] ?? const {};
      dishes.add(WDish(
        id: id,
        name: _s(it['name']),
        nameRu: _s(it['name_ru']),
        nameUz: _s(it['name_uz']),
        price: moneyInt(it['price']),
        image: _s(it['image']),
        code: d['menu_code'] == null ? null : _i(d['menu_code']),
        groupId: d['group_id'] as String?,
        modGroups: [for (final g in (d['modifier_group_ids'] as List? ?? const [])) '$g'],
        portion: _s(d['portion']),
        cookMinutes: d['cook_minutes'] == null ? null : _i(d['cook_minutes']),
        workshopId: d['workshop_id'] as String?,
      ));
    }
    stop = {for (final s in (j['stop'] as List? ?? const [])) '$s'};
    // Группы без блюд не показываем.
    final used = {for (final d in dishes) d.groupId};
    groups.removeWhere((g) => !used.contains(g.id));
  }

  final List<WGroup> groups = [];
  final Map<String, String> workshops = {};
  final Map<String, WModGroup> modGroups = {};
  final List<WDish> dishes = [];
  Set<String> stop = {};

  WDish? dish(String id) {
    for (final d in dishes) {
      if (d.id == id) return d;
    }
    return null;
  }

  List<WModGroup> groupsOf(WDish d) => [for (final id in d.modGroups) if (modGroups[id] != null) modGroups[id]!];

  /// «от 20 000» — у блюда с обязательной порцией цена от самой дешёвой.
  int minPrice(WDish d) {
    var p = d.price;
    for (final g in groupsOf(d)) {
      if (g.required && g.single && g.options.isNotEmpty) {
        p += g.options.map((o) => o.price).reduce(min);
      }
    }
    return p < 0 ? 0 : p;
  }

  bool hasChoice(WDish d) => groupsOf(d).isNotEmpty;
}

// ---------------------------------------------------------------- поиск

const _lat2cyr = {
  'sh': 'ш', 'ch': 'ч', 'yo': 'ё', 'yu': 'ю', 'ya': 'я', 'ts': 'ц', 'zh': 'ж', 'kh': 'х', "o'": 'ў', "g'": 'ғ', 'oʻ': 'ў', 'gʻ': 'ғ',
  'a': 'а', 'b': 'б', 'v': 'в', 'g': 'г', 'd': 'д', 'e': 'е', 'z': 'з', 'i': 'и', 'j': 'ж', 'y': 'й', 'k': 'к', 'l': 'л', 'm': 'м',
  'n': 'н', 'o': 'о', 'p': 'п', 'r': 'р', 's': 'с', 't': 'т', 'u': 'у', 'f': 'ф', 'h': 'х', 'x': 'х', 'q': 'к', 'c': 'к', 'w': 'в',
};

/// Упростить для сравнения: латиница → кириллица, ё → е, ў → у, без знаков.
String foldText(String s) {
  var t = s.toLowerCase().replaceAll('ё', 'е').replaceAll('ʼ', "'").replaceAll('`', "'").replaceAll('‘', "'");
  final out = StringBuffer();
  var i = 0;
  while (i < t.length) {
    if (i + 1 < t.length && _lat2cyr.containsKey(t.substring(i, i + 2))) {
      out.write(_lat2cyr[t.substring(i, i + 2)]);
      i += 2;
      continue;
    }
    final c = t[i];
    out.write(_lat2cyr[c] ?? c);
    i++;
  }
  return out
      .toString()
      .replaceAll('ў', 'у')
      .replaceAll('ғ', 'г')
      .replaceAll('қ', 'к')
      .replaceAll('ҳ', 'х')
      .replaceAll('ы', 'и')
      .replaceAll('э', 'е')
      .replaceAll('ъ', '')
      .replaceAll('ь', '')
      .replaceAll(RegExp(r"[^0-9а-яa-z ]"), ' ')
      // «палов» ≈ «плов»: гласные внутри слова не различаем.
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _skeleton(String folded) => folded.replaceAll(RegExp('[аеиоуюяй]'), '');

/// Подходит ли блюдо под запрос: по коду, по-русски, по-узбекски, с ошибками.
bool dishMatches(WDish d, String query) {
  final q = query.trim();
  if (q.isEmpty) return true;
  if (RegExp(r'^\d+$').hasMatch(q)) return d.code != null && '${d.code}'.startsWith(q);
  final fq = foldText(q);
  if (fq.isEmpty) return true;
  for (final name in {d.name, d.nameRu, d.nameUz}) {
    if (name.isEmpty) continue;
    final fn = foldText(name);
    if (fn.contains(fq)) return true;
    // Ошибки в гласных: «палов» → «плв» есть в «плв чйхнскй».
    final sq = _skeleton(fq);
    if (sq.length >= 2 && _skeleton(fn).contains(sq)) return true;
  }
  return false;
}

/// Где в названии совпадение — подсветить в списке (начало, длина) или null.
(int, int)? matchRange(String name, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return null;
  final i = name.toLowerCase().indexOf(q);
  return i < 0 ? null : (i, q.length);
}

// ---------------------------------------------------------------- состояние

class WaiterInfo {
  WaiterInfo(this.id, this.name, this.tables, this.me);
  final String id, name;
  final int tables;
  final bool me;
}

class WaiterState extends ChangeNotifier {
  WaiterState(this.api, this.storeId);

  final Api api;
  final String storeId;

  bool loaded = false;
  Object? error;
  String me = '';
  bool senior = false;
  bool ownTables = false;
  String mode = '';
  String servicePercent = '0';
  int version = 0;
  List<WHall> halls = [];
  List<WTable> tables = [];
  List<WBill> bills = [];
  WMenu? menu;
  DateTime? _menuAt;
  bool _disposed = false;
  bool _polling = false;
  int _pollGen = 0;

  /// Операции идут по одной — порядок важен (добавить, потом изменить).
  Future<void> _queue = Future.value();
  int _pending = 0;

  Map<String, dynamic> get _q => {'store_id': storeId};

  Future<void> load() async {
    try {
      await Future.wait([refreshHall(), refreshMenu(force: true)]);
      loaded = true;
      error = null;
    } catch (e) {
      error = e;
    }
    _notify();
  }

  Future<void> refreshHall() async {
    final j = await api.get('/store/cafe/waiter/hall', _q) as Map<String, dynamic>;
    me = _s(j['me']);
    senior = j['senior'] == true;
    ownTables = j['waiter_own_tables'] == true;
    mode = _s(j['mode']);
    servicePercent = _s(j['service_percent']);
    version = _i(j['version']);
    halls = [for (final h in (j['halls'] as List? ?? const [])) WHall(_s((h as Map)['id']), _s(h['name']))];
    tables = [for (final t in (j['tables'] as List? ?? const [])) WTable.fromJson(t as Map<String, dynamic>)];
    // Пока свои операции в пути — не затираем то, что уже на экране.
    if (_pending == 0) {
      bills = [for (final b in (j['bills'] as List? ?? const [])) WBill.fromJson(b as Map<String, dynamic>)];
    }
    // Первая загрузка не удалась, а потом связь появилась — экран оживает сам.
    if (!loaded && menu == null) {
      try {
        await refreshMenu(force: true);
      } catch (_) {}
    }
    if (!loaded && menu != null) {
      loaded = true;
      error = null;
    }
    _notify();
  }

  /// Меню (стоп-лист меняется) — не чаще раза в 2 минуты, если не force.
  Future<void> refreshMenu({bool force = false}) async {
    if (!force && _menuAt != null && DateTime.now().difference(_menuAt!) < const Duration(minutes: 2)) return;
    final j = await api.get('/store/cafe/waiter/menu', _q) as Map<String, dynamic>;
    menu = WMenu.fromJson(j);
    _menuAt = DateTime.now();
    _notify();
  }

  /// Длинный запрос: как только в точке что-то изменилось — обновить зал.
  void startPolling() {
    if (_polling) return;
    _polling = true;
    final gen = ++_pollGen;
    () async {
      var fails = 0;
      while (_polling && gen == _pollGen && !_disposed) {
        try {
          final j = await api.get('/store/cafe/waiter/wait', {..._q, 'v': version}) as Map<String, dynamic>;
          final v = _i(j['version']);
          if (!_polling || gen != _pollGen || _disposed) break;
          if (v != version) await refreshHall();
          fails = 0;
        } catch (_) {
          fails++;
          await Future<void>.delayed(Duration(seconds: fails > 5 ? 15 : 3));
        }
      }
    }();
  }

  void stopPolling() {
    _polling = false;
    _pollGen++;
  }

  // ------------------------------------------------------------ выборки

  WBill? billOfTable(String tableId) {
    for (final b in bills) {
      if (b.tableId == tableId && b.open) return b;
    }
    return null;
  }

  WBill? bill(String id) {
    for (final b in bills) {
      if (b.id == id) return b;
    }
    return null;
  }

  WTable? table(String id) {
    for (final t in tables) {
      if (t.id == id) return t;
    }
    return null;
  }

  String hallName(String id) {
    for (final h in halls) {
      if (h.id == id) return h.name;
    }
    return '';
  }

  List<WBill> get myBills => bills.where((b) => b.open && b.mine).toList();

  /// Мне передают стол — показать «Принять / Отказаться».
  List<WBill> get incoming => bills.where((b) => b.open && b.transferTo == me && b.transferAt != null).toList();

  /// Готово на кухне по моим столам: (счёт, позиция).
  List<(WBill, WItem)> get readyForMe => [
        for (final b in myBills)
          for (final i in b.readyItems) (b, i),
      ];

  // ------------------------------------------------------------ операции

  /// Операция со счётом: локально сразу (если [local]), на сервер — по очереди.
  /// Ответ сервера — свежий счёт, он заменяет локальный.
  Future<WBill?> op(Map<String, dynamic> body, {void Function(WBill b)? local}) {
    final b = bill('${body['bill_id']}');
    if (local != null && b != null) {
      local(b);
      _notify();
    }
    final data = {'id': newUuid(), ...body};
    final done = Completer<WBill?>();
    _pending++;
    _queue = _queue.then((_) async {
      try {
        final j = await api.post('/store/cafe/waiter/ops?store_id=$storeId', data) as Map<String, dynamic>;
        final fresh = WBill.fromJson(j);
        _pending--;
        if (_pending == 0 || local == null) _put(fresh);
        done.complete(fresh);
      } catch (e) {
        _pending--;
        // Локальное изменение не прошло — вернуть, как на сервере.
        try {
          await refreshHall();
        } catch (_) {}
        done.completeError(e);
      }
      _notify();
    });
    return done.future;
  }

  void _put(WBill fresh) {
    final i = bills.indexWhere((b) => b.id == fresh.id);
    if (!fresh.open) {
      if (i >= 0) bills.removeAt(i);
    } else if (i >= 0) {
      bills[i] = fresh;
    } else {
      bills.add(fresh);
    }
  }

  /// Открыть свободный стол — счёт новый, стол мой.
  Future<WBill?> openTable(String tableId, int guests, String comment) async {
    final id = newUuid();
    final b = await op({'bill_id': id, 'kind': 'open', 'table_id': tableId, 'guests': guests, if (comment.trim().isNotEmpty) 'comment': comment.trim()});
    return b;
  }

  /// «+»: добавить блюдо гостю (или всем). Такая же новая строка — +1 к ней.
  Future<void> addDish(String billId, WDish d, {int? guest, List<WMod> mods = const [], String note = '', num qty = 1}) {
    final b = bill(billId);
    final unit = d.price + mods.fold<int>(0, (a, m) => a + m.price * m.qty);
    final price = unit < 0 ? 0 : unit;
    final probe = WItem.local(id: '', productId: d.id, name: d.name, qty: qty, price: price, mods: mods, note: note, guest: guest);
    WItem? same;
    if (b != null) {
      for (final i in b.newItems) {
        if (i.sameKey == probe.sameKey && i.guest == guest) same = i;
      }
    }
    if (same != null) return setQty(billId, same, same.qty + qty);
    final id = newUuid();
    return op({
      'bill_id': billId,
      'kind': 'add',
      'item': {
        'id': id,
        'product_id': d.id,
        'qty': qtyText(qty),
        'price': '$price',
        if (guest != null) 'guest': guest,
        if (note.isNotEmpty) 'note': note,
        'modifiers': [for (final m in mods) {'option_id': m.optionId, 'qty': m.qty}],
      },
    }, local: (b) {
      b.items.add(WItem.local(id: id, productId: d.id, name: d.name, qty: qty, price: price, mods: mods, note: note, guest: guest));
    });
  }

  /// Количество новой позиции; 0 — убрать.
  Future<void> setQty(String billId, WItem item, num qty) {
    if (qty <= 0) {
      return op({'bill_id': billId, 'kind': 'remove', 'item_id': item.id}, local: (b) => b.items.removeWhere((i) => i.id == item.id));
    }
    return op({'bill_id': billId, 'kind': 'update', 'item_id': item.id, 'qty': qtyText(qty)}, local: (b) {
      for (final i in b.items) {
        if (i.id == item.id) i.qty = qty;
      }
    });
  }

  /// «Сразу» или «по команде» для новой позиции.
  Future<void> setCourse(String billId, WItem item, String course) =>
      op({'bill_id': billId, 'kind': 'update', 'item_id': item.id, 'course': course}, local: (b) {
        for (final i in b.items) {
          if (i.id == item.id) i.course = course;
        }
      });

  Future<WBill?> send(String billId) => op({'bill_id': billId, 'kind': 'send'});
  Future<WBill?> fire(String billId) => op({'bill_id': billId, 'kind': 'fire'});
  Future<WBill?> precheck(String billId) => op({'bill_id': billId, 'kind': 'precheck'});
  Future<WBill?> setGuests(String billId, int n) => op({'bill_id': billId, 'kind': 'guests', 'guests': n}, local: (b) => b.guests = n);
  Future<WBill?> serve(String billId, String itemId) => op({'bill_id': billId, 'kind': 'serve', 'item_id': itemId});
  Future<WBill?> transfer(String billId, String to, String reason) => op({'bill_id': billId, 'kind': 'transfer', 'to_waiter_id': to, 'reason': reason});
  Future<WBill?> accept(String billId) => op({'bill_id': billId, 'kind': 'accept'});
  Future<WBill?> decline(String billId) => op({'bill_id': billId, 'kind': 'decline'});
  Future<WBill?> request(String billId) => op({'bill_id': billId, 'kind': 'request'});
  Future<WBill?> take(String billId) => op({'bill_id': billId, 'kind': 'take'});
  Future<WBill?> voidEmpty(String billId) => op({'bill_id': billId, 'kind': 'void'});

  /// «Несу» — все готовые позиции стола (или всех моих столов).
  Future<void> serveAll(List<(WBill, WItem)> list) async {
    for (final (b, i) in list) {
      await serve(b.id, i.id);
    }
  }

  Future<List<WaiterInfo>> waiters() async {
    final list = await api.list('/store/cafe/waiter/waiters', _q);
    return [for (final w in list) WaiterInfo(_s(w['id']), _s(w['full_name']), _i(w['tables']), w['me'] == true)];
  }

  Future<void> saveZones(Map<String, String> assignments) async {
    await api.put('/store/cafe/waiter/zones', {
      'store_id': storeId,
      'assignments': [for (final e in assignments.entries) {'table_id': e.key, 'waiter_id': e.value}],
    });
    await refreshHall();
  }

  Future<void> likeYesterday() async {
    await api.put('/store/cafe/waiter/zones', {'store_id': storeId, 'like_yesterday': true});
    await refreshHall();
  }

  Future<Map<String, dynamic>> mySales() async => await api.get('/store/cafe/waiter/my-sales', _q) as Map<String, dynamic>;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stopPolling();
    super.dispose();
  }
}
