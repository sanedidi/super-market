import 'dart:io';

import '../core/journal.dart';
import '../core/money.dart';
import 'api.dart';
import 'store.dart';

/// Что касса должна отправить на сервер. Всё, что случилось на кассе
/// (смена, продажа, изъятие), сначала пишется сюда, а потом уходит по порядку.
/// Повтор безопасен: сервер узнаёт события по client_uid.
class OutboxItem {
  OutboxItem({required this.seq, required this.kind, required this.body, required this.cashier, this.error});

  final int seq;

  /// shift_open, cash_move, sale, shift_close.
  final String kind;
  final Map<String, dynamic> body;
  final String cashier;
  String? error;

  String get fileName => '${seq.toString().padLeft(10, '0')}.json';

  Map<String, dynamic> toJson() => {'seq': seq, 'kind': kind, 'body': body, 'cashier': cashier, 'error': error};

  factory OutboxItem.fromJson(Map<String, dynamic> j) => OutboxItem(
        seq: j['seq'] as int,
        kind: j['kind'] as String,
        body: j['body'] as Map<String, dynamic>,
        cashier: j['cashier'] as String? ?? '',
        error: j['error'] as String?,
      );
}

/// Итог отправки очереди.
class FlushResult {
  int sent = 0;
  int failed = 0;
  bool offline = false;

  /// Сервер не принимает токен — кассу отключили в панели.
  bool revoked = false;
}

class Outbox {
  Outbox(this.store, this.api);

  final FileStore store;
  final PosApi api;

  static const _dir = 'outbox';
  static const _failedDir = 'failed';

  /// local uid смены → id смены на сервере.
  final Map<String, String> shiftIds = {};
  int _seq = 0;
  final List<OutboxItem> _pending = [];
  final List<OutboxItem> _failed = [];
  bool _flushing = false;

  /// Сервер ответил на открытие смены — касса запоминает id и номер.
  Future<void> Function(String uid, String id, int number)? onShiftOpened;

  /// Продажа дошла до сервера: номер чека на сервере.
  Future<void> Function(String uid, String id, int number)? onSaleSent;

  int get pending => _pending.length;
  List<OutboxItem> get failed => List.unmodifiable(_failed);

  Future<void> load() async {
    final ids = await store.readJson('shift_ids.json');
    ids?.forEach((k, v) => shiftIds[k] = v as String);
    _pending
      ..clear()
      ..addAll(await _readDir(_dir));
    _failed
      ..clear()
      ..addAll(await _readDir(_failedDir));
    for (final i in [..._pending, ..._failed]) {
      if (i.seq > _seq) _seq = i.seq;
    }
    final s = await store.readJson('outbox_seq.json');
    final saved = (s?['seq'] as int?) ?? 0;
    if (saved > _seq) _seq = saved;
  }

  Future<List<OutboxItem>> _readDir(String name) async {
    final d = store.dir(name);
    if (!await d.exists()) return [];
    final out = <OutboxItem>[];
    await for (final f in d.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final j = await store.readJson('$name${Platform.pathSeparator}${f.uri.pathSegments.last}');
      if (j != null) out.add(OutboxItem.fromJson(j));
    }
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  Future<void> add(String kind, Map<String, dynamic> body, String cashier) async {
    _seq++;
    await store.writeJson('outbox_seq.json', {'seq': _seq});
    final item = OutboxItem(seq: _seq, kind: kind, body: body, cashier: cashier);
    await store.writeJson('$_dir${Platform.pathSeparator}${item.fileName}', item.toJson());
    _pending.add(item);
  }

  /// Смена, открытая на сервере раньше (например, после переустановки кассы).
  Future<void> knowShift(String uid, String id) async {
    shiftIds[uid] = id;
    await store.writeJson('shift_ids.json', shiftIds);
  }

  /// Отправить всё по порядку. Нет связи — остановиться и попробовать позже.
  Future<FlushResult> flush() async {
    final r = FlushResult();
    if (_flushing) return r;
    _flushing = true;
    try {
      while (_pending.isNotEmpty) {
        final item = _pending.first;
        try {
          await _send(item);
          r.sent++;
          await store.delete('$_dir${Platform.pathSeparator}${item.fileName}');
          _pending.removeAt(0);
        } on _Wait {
          break;
        } on ApiError catch (e) {
          if (e.status == 0 || e.status >= 500 || e.status == 429) {
            r.offline = e.status == 0;
            break;
          }
          if (e.status == 401 && e.code == 'unauthorized') {
            r.revoked = true;
            break;
          }
          // Сервер не принял событие — откладываем в «ошибки», очередь идёт дальше.
          item.error = e.message;
          await store.writeJson('$_failedDir${Platform.pathSeparator}${item.fileName}', item.toJson());
          await store.delete('$_dir${Platform.pathSeparator}${item.fileName}');
          _pending.removeAt(0);
          _failed.add(item);
          r.failed++;
        }
      }
    } finally {
      _flushing = false;
    }
    return r;
  }

  String _shiftId(String uid) {
    final id = shiftIds[uid];
    if (id != null) return id;
    // Открытие смены ещё в очереди впереди — ждём. Иначе оно не прошло.
    if (_pending.any((i) => i.kind == 'shift_open' && i.body['client_uid'] == uid)) throw _Wait();
    throw ApiError(400, 'shift_not_sent', 'Смена не дошла до сервера');
  }

  Future<void> _send(OutboxItem item) async {
    final b = item.body;
    switch (item.kind) {
      case 'shift_open': {
        final res = await api.post('/pos/shifts', b, cashier: item.cashier) as Map<String, dynamic>;
        final uid = b['client_uid'] as String;
        await knowShift(uid, res['id'] as String);
        await onShiftOpened?.call(uid, res['id'] as String, (res['number'] as num).toInt());
      }
      case 'cash_move': {
        final id = _shiftId(b['shift_uid'] as String);
        await api.post('/pos/shifts/$id/cash-moves', {
          'client_uid': b['uid'],
          'kind': b['kind'],
          'amount': moneyApi(b['amount'] as int),
          'reason': b['reason'],
          'at': b['at'],
        }, cashier: item.cashier);
      }
      case 'sale': {
        final sale = SaleRecord.fromJson(b);
        final id = _shiftId(sale.shiftUid);
        final res = await api.post('/pos/sales', sale.apiBody(id), cashier: item.cashier) as Map<String, dynamic>;
        await onSaleSent?.call(sale.uid, res['id'] as String, (res['number'] as num).toInt());
      }
      case 'shift_close': {
        final id = _shiftId(b['shift_uid'] as String);
        await api.post('/pos/shifts/$id/close', {
          'counted_cash': moneyApi(b['counted_cash'] as int),
          'diff_reason': b['diff_reason'] ?? '',
          'closed_at': b['closed_at'],
        }, cashier: item.cashier);
      }
      default: {
        throw ApiError(400, 'unknown', 'Неизвестное событие ${item.kind}');
      }
    }
  }

  /// Вернуть событие из ошибок в очередь (после исправления в панели).
  Future<void> retry(OutboxItem item) async {
    _failed.remove(item);
    item.error = null;
    await store.delete('$_failedDir${Platform.pathSeparator}${item.fileName}');
    await store.writeJson('$_dir${Platform.pathSeparator}${item.fileName}', item.toJson());
    _pending
      ..add(item)
      ..sort((a, b) => a.seq.compareTo(b.seq));
  }
}

class _Wait implements Exception {}
