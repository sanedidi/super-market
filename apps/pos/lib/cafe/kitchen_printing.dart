// Касса кафе печатает бегунки сама — и без интернета (Figma П7, «Логика кухни»):
// - номерок гостю — на принтер чеков кассы;
// - бегунок цеха — если цех так настроен: «всегда», «если экран кухни не в
//   сети» (или касса сама без связи) или «никогда»;
// - принтер цеха по сети (IP:9100) или принтер чеков кассы;
// - не напечаталось (принтер цеха не отвечает) — бегунок ждёт в очереди и
//   печатается, когда принтер появится; касса сообщает панели состояние;
// - «Тест печати» из панели — касса печатает тестовый бегунок.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/catalog.dart';
import '../core/journal.dart';
import '../data/api.dart';
import '../data/store.dart';
import '../printer/transport.dart';
import 'bills.dart';
import 'kitchen_board.dart' show KOrder;
import 'menu.dart';
import 'tickets.dart';

class _Pending {
  _Pending(this.workshopId, this.bytes, this.at);
  final String workshopId;
  final Uint8List bytes;
  final DateTime at;

  Map<String, dynamic> toJson() => {'workshop_id': workshopId, 'bytes': base64Encode(bytes), 'at': at.toUtc().toIso8601String()};

  static _Pending? fromJson(Map<String, dynamic> j) {
    try {
      return _Pending(j['workshop_id'] as String, base64Decode(j['bytes'] as String), DateTime.parse(j['at'] as String));
    } catch (_) {
      return null;
    }
  }
}

class KitchenPrinting {
  KitchenPrinting({required this.api, required this.store, required this.catalog, required this.printer});

  final PosApi api;
  final FileStore store;
  final Catalog Function() catalog;
  final PrinterConfig Function() printer;

  /// Экраны кухни в сети: id цеха → да; '*' — экран всех цехов. null — касса не
  /// знает (без связи): тогда печатаем бегунки, как будто экранов нет.
  Map<String, bool>? screens;

  final List<_Pending> _queue = [];

  /// Состояние принтеров цехов по сети, которое ещё не отправлено в панель.
  final Map<String, ({bool ok, int pending})> _report = {};

  /// Тесты печати, уже напечатанные: цех → время запроса.
  final Map<String, String> _testsDone = {};

  /// Бегунки с телефона официанта, уже напечатанные («id:send», «id:fire»):
  /// сервер узнаёт о них следующим запросом, если ответ «напечатано» потерялся.
  final List<String> _phoneDone = [];

  bool _busy = false;

  static const _file = 'kitchen_queue.json';
  static const _maxAge = Duration(hours: 3);

  Future<void> load() async {
    final j = await store.readJson(_file);
    for (final e in (j?['queue'] as List?) ?? const []) {
      final p = _Pending.fromJson(e as Map<String, dynamic>);
      if (p != null) _queue.add(p);
    }
    (j?['tests'] as Map<String, dynamic>?)?.forEach((k, v) => _testsDone[k] = '$v');
    for (final e in (j?['phone'] as List?) ?? const []) {
      _phoneDone.add('$e');
    }
  }

  Future<void> _save() => store.writeJson(_file, {
        'queue': [for (final p in _queue) p.toJson()],
        'tests': _testsDone,
        'phone': _phoneDone.length > 300 ? _phoneDone.sublist(_phoneDone.length - 300) : _phoneDone,
      });

  int pendingFor(String workshopId) => _queue.where((p) => p.workshopId == workshopId).length;

  bool _screenOnline(String workshopId) {
    final s = screens;
    if (s == null) return false;
    return s['*'] == true || s[workshopId] == true;
  }

  PrinterConfig _target(CafeWorkshop w) {
    if (!w.networkPrinter) return printer();
    final own = printer();
    return PrinterConfig(kind: 'network', host: w.printerHost, port: w.printerPort, paperMm: w.printerPaper, codePage: own.codePage, drawer: false);
  }

  /// Заказ оплачен: номерок гостю и бегунки цехов. Ошибка не мешает продаже.
  /// Возвращает текст ошибки принтера кассы (или null).
  Future<String?> printOrder(SaleRecord sale) async {
    final cat = catalog();
    final menu = cat.cafe;
    if (menu == null || sale.order == null) return null;
    final own = printer();
    String? error;
    final ownJob = BytesBuilder(copy: false);
    if (own.enabled) ownJob.add(guestSlip(s: cat.settings, sale: sale, paperMm: own.paperMm, codePage: own.codePage));
    for (final e in linesByWorkshop(sale, menu).entries) {
      final w = menu.workshop(e.key);
      if (w == null) continue;
      final needed = switch (w.ticketPrint) {
        'always' => true,
        'never' => false,
        _ => !_screenOnline(w.id),
      };
      if (!needed) continue;
      final target = _target(w);
      if (!target.enabled) continue;
      final bytes = workshopTicket(
          s: cat.settings, sale: sale, menu: menu, workshop: w, lines: e.value, paperMm: target.paperMm, codePage: target.codePage);
      if (w.networkPrinter) {
        await _sendNetwork(w, bytes);
      } else {
        ownJob.add(bytes);
      }
    }
    if (ownJob.isNotEmpty) {
      try {
        await sendToPrinter(own, ownJob.toBytes());
      } on PrintError catch (e) {
        error = e.message;
      } catch (e) {
        error = '$e';
      }
    }
    return error;
  }

  /// Счёт стола: бегунки цехов по тем же правилам, что у заказа у прилавка
  /// (номерка гостю нет). [lines] — позиция и сколько.
  Future<String?> printTable(Bill bill, List<(BillItem, int)> lines, {TableTicket kind = TableTicket.send, String reason = ''}) async {
    final cat = catalog();
    final menu = cat.cafe;
    if (menu == null || lines.isEmpty) return null;
    final own = printer();
    String? error;
    final ownJob = BytesBuilder(copy: false);
    final by = <String, List<(BillItem, int)>>{};
    for (final l in lines) {
      final d = menu.dish(l.$1.productId);
      if (d == null || !d.isDish) continue;
      final w = menu.workshop(d.workshopId);
      if (w == null) continue;
      by.putIfAbsent(w.id, () => []).add(l);
    }
    final at = DateTime.now();
    for (final e in by.entries) {
      final w = menu.workshop(e.key)!;
      final needed = switch (w.ticketPrint) {
        'always' => true,
        'never' => false,
        _ => !_screenOnline(w.id),
      };
      if (!needed) continue;
      final target = _target(w);
      if (!target.enabled) continue;
      final bytes = tableTicket(
          s: cat.settings, bill: bill, workshop: w, lines: e.value, at: at, kind: kind, reason: reason, paperMm: target.paperMm, codePage: target.codePage);
      if (w.networkPrinter) {
        await _sendNetwork(w, bytes);
      } else {
        ownJob.add(bytes);
      }
    }
    if (ownJob.isNotEmpty) {
      try {
        await sendToPrinter(own, ownJob.toBytes());
      } on PrintError catch (e) {
        error = e.message;
      } catch (e) {
        error = '$e';
      }
    }
    return error;
  }

  Future<void> _sendNetwork(CafeWorkshop w, Uint8List bytes) async {
    // Очередь цеха не пуста — новый бегунок встаёт за старыми, порядок важен.
    if (pendingFor(w.id) > 0) {
      _queue.add(_Pending(w.id, bytes, DateTime.now()));
      await _save();
      unawaited(retry());
      return;
    }
    try {
      await sendToPrinter(_target(w), bytes);
      _report[w.id] = (ok: true, pending: 0);
    } catch (_) {
      _queue.add(_Pending(w.id, bytes, DateTime.now()));
      _report[w.id] = (ok: false, pending: pendingFor(w.id));
      await _save();
    }
  }

  /// Повторить бегунки из очереди; старше 3 часов — уже не нужны кухне.
  Future<void> retry() async {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    try {
      final menu = catalog().cafe;
      _queue.removeWhere((p) => DateTime.now().difference(p.at) > _maxAge);
      final failed = <String>{};
      for (final p in List.of(_queue)) {
        if (failed.contains(p.workshopId)) continue;
        final w = menu?.workshop(p.workshopId);
        if (w == null || w.id != p.workshopId) {
          _queue.remove(p);
          continue;
        }
        try {
          await sendToPrinter(_target(w), p.bytes);
          _queue.remove(p);
          _report[w.id] = (ok: true, pending: pendingFor(w.id));
        } catch (_) {
          failed.add(w.id);
          _report[w.id] = (ok: false, pending: pendingFor(w.id));
        }
      }
      await _save();
    } finally {
      _busy = false;
    }
  }

  /// Бегунки, отправленные официантом с телефона в цех без экрана: печатаем
  /// и сообщаем серверу. Принтер кассы не ответил — повтор в следующий раз;
  /// принтер цеха по сети — в очередь цеха (как обычные бегунки).
  Future<void> _printPhone(Catalog cat, CafeMenu menu, List<Map<String, dynamic>> orders) async {
    if (orders.isEmpty) return;
    final own = printer();
    final done = <String>[];
    for (final o in orders) {
      final order = KOrder.fromJson(o);
      final raw = ((o['tickets'] as List?) ?? const []).cast<Map<String, dynamic>>();
      for (var k = 0; k < raw.length && k < order.tickets.length; k++) {
        final t = order.tickets[k];
        final fire = raw[k]['print_kind'] == 'fire';
        final key = '${t.id}:${fire ? 'fire' : 'send'}';
        if (_phoneDone.contains(key)) {
          done.add(t.id);
          continue;
        }
        final w = menu.workshop(t.workshopId);
        if (w == null || w.id != t.workshopId || w.ticketPrint == 'never') {
          done.add(t.id);
          continue;
        }
        final target = _target(w);
        if (!target.enabled) {
          done.add(t.id);
          continue;
        }
        final bytes = phoneTicket(s: cat.settings, order: order, ticket: t, workshop: w, at: DateTime.now(), fire: fire, paperMm: target.paperMm, codePage: target.codePage);
        if (w.networkPrinter) {
          await _sendNetwork(w, bytes);
        } else if (own.enabled) {
          try {
            await sendToPrinter(own, bytes);
          } catch (_) {
            continue; // принтер кассы не ответил — повторим следующим tick
          }
        }
        _phoneDone.add(key);
        done.add(t.id);
      }
    }
    await _save();
    if (done.isEmpty) return;
    try {
      await api.post('/pos/kitchen/printed', {'ticket_ids': done});
    } catch (_) {}
  }

  /// Раз в синхронизацию: экраны кухни, тесты печати из панели, очередь и
  /// отчёт о принтерах. Без связи — экраны неизвестны (печатаем бегунки).
  Future<void> tick() async {
    final cat = catalog();
    final menu = cat.cafe;
    if (menu == null || cat.settings.deviceKind != 'pos') return;
    Map<String, dynamic>? st;
    try {
      st = await api.get('/pos/kitchen/status') as Map<String, dynamic>;
    } catch (_) {
      screens = null;
    }
    if (st != null) {
      screens = {for (final e in ((st['screens'] as Map<String, dynamic>?) ?? const {}).entries) e.key: e.value == true};
      for (final t in ((st['print_tests'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final id = '${t['workshop_id']}';
        final at = '${t['at']}';
        if (_testsDone[id] == at) continue;
        _testsDone[id] = at;
        await _save();
        final w = menu.workshop(id);
        if (w == null || w.id != id) continue;
        final target = _target(w);
        if (!target.enabled) continue;
        try {
          await sendToPrinter(target, testTicket(s: cat.settings, workshop: w, at: DateTime.now(), paperMm: target.paperMm, codePage: target.codePage));
          _report[id] = (ok: true, pending: pendingFor(id));
        } catch (_) {
          _report[id] = (ok: false, pending: pendingFor(id));
        }
      }
    }
    if (st != null) await _printPhone(cat, menu, ((st['print'] as List?) ?? const []).cast<Map<String, dynamic>>());
    await retry();
    if (_report.isNotEmpty && st != null) {
      final body = [
        for (final e in _report.entries) {'workshop_id': e.key, 'ok': e.value.ok, 'pending': e.value.pending},
      ];
      try {
        await api.post('/pos/kitchen/printers', body);
        _report.clear();
      } catch (_) {}
    }
  }
}
