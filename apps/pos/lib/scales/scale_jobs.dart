// Отправка товаров в весы (Figma «Панель магазина · Весы: отправка товаров в
// весы», Н3–Н4). Сервер весы не видит: панель создаёт задание, касса в той же
// сети забирает его при синхронизации, передаёт товары на весы и сообщает,
// что весы приняли. Без связи с сервером заданий нет — ничего не делаем.

import 'package:sm_core/sm_core.dart' show tr;

import '../data/api.dart';
import 'dahua.dart';

class ScaleJobs {
  ScaleJobs(this.api);

  final PosApi api;
  bool _busy = false;

  /// Раз в синхронизацию: взять задания и выполнить.
  Future<void> tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final res = await api.get('/pos/scales/jobs', wait: const Duration(seconds: 8));
      final items = res is Map ? (res['items'] as List?) ?? const [] : const [];
      for (final j in items.cast<Map<String, dynamic>>()) {
        await _run(j);
      }
    } on ApiError {
      // старый сервер или нет связи — в следующий раз
    } finally {
      _busy = false;
    }
  }

  Future<void> _run(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    final scale = job['scale'] as Map<String, dynamic>;
    final brand = scale['brand'] as String? ?? '';
    final host = scale['host'] as String? ?? '';
    final port = (scale['port'] as num?)?.toInt() ?? 4001;
    final goods = ((job['items'] as List?) ?? const []).cast<Map<String, dynamic>>().map(ScaleGood.fromJson).toList();
    Map<String, dynamic> result;
    if (brand != 'rongta' && brand != 'dahua') {
      result = {'done_ids': <String>[], 'error': tr('Касса не умеет отправлять в весы этого бренда — нужен файл', 'Kassa bu brend taroziga yubora olmaydi — fayl kerak')};
    } else if (job['kind'] == 'check') {
      result = await _check(host, port);
    } else {
      result = await sendGoods(host, port, goods, clear: job['mode'] == 'all');
    }
    try {
      await api.post('/pos/scales/jobs/$id', result);
    } on ApiError {
      // ответ потерялся — через 3 минуты задание вернётся, весы перезапишутся тем же
    }
  }

  Future<Map<String, dynamic>> _check(String host, int port) async {
    final s = DahuaScale(host, port);
    try {
      await s.open();
      return {'done_ids': <String>[], 'error': ''};
    } on ScaleError catch (e) {
      return {'done_ids': <String>[], 'error': _noLink(e)};
    } finally {
      await s.close();
    }
  }

  String _noLink(ScaleError e) => tr('Касса не видит весы: ${e.message}. Проверьте, включены ли весы, кабель и IP.',
      'Kassa tarozini koʻrmayapti: ${e.message}. Tarozi yoqilganini, kabel va IP ni tekshiring.');
}

/// Записать товары в весы по одному; оборвалось соединение — переподключиться
/// и продолжить. [clear] — сначала очистить весы («Все весовые»: в весах
/// останется только то, что есть в Super Market). Возвращает итог для сервера:
/// принятые, не принятые, очищены ли весы, ошибку.
Future<Map<String, dynamic>> sendGoods(String host, int port, List<ScaleGood> goods,
    {bool clear = false, Duration timeout = const Duration(seconds: 5)}) async {
  final done = <String>[];
  final failures = <Map<String, dynamic>>[];
  var s = DahuaScale(host, port, timeout: timeout);
  try {
    await s.open();
  } on ScaleError catch (e) {
    return {
      'done_ids': done,
      'error': tr('Касса не видит весы: ${e.message}. Проверьте, включены ли весы, кабель и IP.',
          'Kassa tarozini koʻrmayapti: ${e.message}. Tarozi yoqilganini, kabel va IP ni tekshiring.'),
    };
  }
  var reconnects = 0;
  var cleared = false;
  if (clear) {
    try {
      final reply = await s.command(dahuaClear);
      if (!reply.toLowerCase().contains('0ia')) throw ScaleError(tr('весы не ответили на очистку', 'tarozi tozalashga javob bermadi'));
      cleared = true;
    } on ScaleError catch (e) {
      await s.close();
      return {'done_ids': done, 'error': tr('Не удалось очистить весы: ${e.message}', 'Tarozini tozalab boʻlmadi: ${e.message}')};
    }
  }
  try {
    for (var i = 0; i < goods.length; i++) {
      final g = goods[i];
      try {
        final reply = await s.command(dahuaPlu(g));
        if (dahuaAck(reply, g.plu)) {
          done.add(g.productId);
        } else {
          failures.add({'product_id': g.productId, 'plu': g.plu, 'name': g.name, 'error': tr('весы не приняли товар', 'tarozi mahsulotni qabul qilmadi')});
        }
      } on ScaleError catch (e) {
        // Соединение оборвалось — переподключаемся и повторяем этот товар.
        await s.close();
        if (reconnects >= 3) {
          return {'done_ids': done, 'failures': failures, 'cleared': cleared, 'error': tr('Связь с весами оборвалась: ${e.message}', 'Tarozi bilan aloqa uzildi: ${e.message}')};
        }
        reconnects++;
        s = DahuaScale(host, port, timeout: timeout);
        try {
          await s.open();
        } on ScaleError catch (e2) {
          return {'done_ids': done, 'failures': failures, 'cleared': cleared, 'error': tr('Связь с весами оборвалась: ${e2.message}', 'Tarozi bilan aloqa uzildi: ${e2.message}')};
        }
        i--;
      }
    }
  } finally {
    await s.close();
  }
  return {'done_ids': done, 'failures': failures, 'cleared': cleared, 'error': ''};
}
