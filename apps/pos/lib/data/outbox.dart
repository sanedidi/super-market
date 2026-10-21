import 'dart:io';

import 'package:sm_core/sm_core.dart' show tr;

import '../core/journal.dart';
import '../core/money.dart';
import 'api.dart';
import 'store.dart';

/// Что касса должна отправить на сервер. Всё, что случилось на кассе
/// (смена, продажа, изъятие), сначала пишется сюда, а потом уходит по порядку.
/// Повтор безопасен: сервер узнаёт события по client_uid.
class OutboxItem {
  OutboxItem({required this.seq, required this.kind, required this.body, required this.cashier, this.error, this.errorCode, DateTime? at})
      : at = at ?? DateTime.now();

  final int seq;

  /// Когда событие случилось на кассе — для правила «не больше 24 часов без связи».
  final DateTime at;

  /// shift_open, cash_move, sale, shift_close.
  final String kind;
  final Map<String, dynamic> body;
  final String cashier;
  String? error;

  /// Код ошибки сервера (текст [error] — на языке кассы, код — нет).
  String? errorCode;

  String get fileName => '${seq.toString().padLeft(10, '0')}.json';

  Map<String, dynamic> toJson() =>
      {'seq': seq, 'kind': kind, 'body': body, 'cashier': cashier, 'error': error, 'error_code': errorCode, 'at': at.toUtc().toIso8601String()};

  factory OutboxItem.fromJson(Map<String, dynamic> j) => OutboxItem(
        seq: j['seq'] as int,
        kind: j['kind'] as String,
        body: j['body'] as Map<String, dynamic>,
        cashier: j['cashier'] as String? ?? '',
        error: j['error'] as String?,
        errorCode: j['error_code'] as String?,
        at: DateTime.tryParse(j['at'] as String? ?? '')?.toLocal(),
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

  /// Самое старое неотправленное событие; null — очередь пуста.
  DateTime? get oldestPendingAt => _pending.isEmpty ? null : _pending.first.at;
  List<OutboxItem> get failed => List.unmodifiable(_failed);

  /// События в очереди (ещё не на сервере).
  List<OutboxItem> get pendingItems => List.unmodifiable(_pending);

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

  Future<void> add(String kind, Map<String, dynamic> body, String cashier, {DateTime? at}) async {
    _seq++;
    await store.writeJson('outbox_seq.json', {'seq': _seq});
    final item = OutboxItem(seq: _seq, kind: kind, body: body, cashier: cashier, at: at);
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
          _pending.remove(item);
        } on _Wait {
          break;
        } on ApiError catch (e) {
          if (e.status == 0 || e.status >= 500 || e.status == 429) {
            r.offline = e.status == 0;
            break;
          }
          if (deviceRejected(e)) {
            r.revoked = true;
            break;
          }
          // Сервер не принял событие — откладываем в «ошибки», очередь идёт дальше.
          item.error = e.message;
          item.errorCode = e.code;
          await store.writeJson('$_failedDir${Platform.pathSeparator}${item.fileName}', item.toJson());
          await store.delete('$_dir${Platform.pathSeparator}${item.fileName}');
          _pending.remove(item);
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
    throw ApiError(400, 'shift_not_sent', tr('Смена не дошла до сервера', 'Smena serverga yetib bormadi'));
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
      case 'debt_payment': {
        final rec = DebtPaymentRecord.fromJson(b);
        final id = _shiftId(rec.shiftUid);
        await api.post('/pos/debt-payments', rec.apiBody(id), cashier: item.cashier);
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
        throw ApiError(400, 'unknown', tr('Неизвестное событие ${item.kind}', 'Nomaʼlum hodisa: ${item.kind}'));
      }
    }
  }

  /// Вернуть событие из ошибок в очередь (после исправления в панели).
  Future<void> retry(OutboxItem item) async {
    _failed.remove(item);
    item.error = null;
    item.errorCode = null;
    // Сначала в очередь, потом из ошибок: сбой между ними даст дубль, а не потерю
    // (сервер узнаёт повтор по client_uid).
    await store.writeJson('$_dir${Platform.pathSeparator}${item.fileName}', item.toJson());
    await store.delete('$_failedDir${Platform.pathSeparator}${item.fileName}');
    _pending
      ..add(item)
      ..sort((a, b) => a.seq.compareTo(b.seq));
  }

  /// Вернуть в очередь все события, которые сервер не принял («Повторить все»,
  /// или после того как закрыли зависшую смену). Порядок — исходный.
  Future<int> retryAll() async {
    // Не вставлять в очередь посреди отправки — дождаться её конца.
    while (_flushing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final items = List.of(_failed);
    for (final i in items) {
      i.error = null;
      i.errorCode = null;
      await store.writeJson('$_dir${Platform.pathSeparator}${i.fileName}', i.toJson());
      await store.delete('$_failedDir${Platform.pathSeparator}${i.fileName}');
    }
    // В очередь — разом и по порядку, чтобы отправка не взяла их вразнобой.
    _failed.removeWhere(items.contains);
    _pending
      ..addAll(items)
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return items.length;
  }
}

class _Wait implements Exception {}

/// Сервер не принимает токен кассы: касса отключена в панели или подключена
/// заново другим кодом. Ошибки кассира (401 cashier_*) сюда не относятся.
bool deviceRejected(ApiError e) => e.status == 401 && e.code != 'cashier_invalid' && e.code != 'cashier_required';
