// Весы с протоколом Dahua (大华) по TCP: Dahua TM и Rongta RLS1000/RLS1100
// (у Rongta этот протокол на порту 4001). Проверено на Rongta RLS1000C
// (прошивка V1.011, 3 ноября 2026).
//
// Товар (PLU) — одна строка ASCII, в конце байты CR LF ETX:
//   !0V <номер 4> A <код 7> <цена 6> <способ 1> 000000 <срок 3> <магазин 2>
//   <отдел 2> <код 13> <тара 5> <этикетка 2> <скидка 2> <4 периода скидок 24>
//   B <название> CDE
// Весы подтверждают тем же началом строчными буквами: «0v0099a».
//
// Цена — целые сумы (весы с 0 знаков после запятой: 024000 = 24 000 за кг).
// Код в штрихкоде — последние цифры кода (номер на весах).
// Название — коды GB2312 «зона·позиция», 4 цифры на символ. Латиница
// печатается (полноширинные символы, зона 03); кириллица GB2312 (зона 07)
// на Rongta с русской прошивкой не печатается — сервер шлёт латиницу.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Товар для весов (как присылает сервер).
class ScaleGood {
  ScaleGood({required this.productId, required this.plu, required this.name, required this.price, this.unit = 'kg'});

  final String productId;
  final int plu;
  final String name;

  /// Цена за кг, целые сумы.
  final int price;
  final String unit;

  factory ScaleGood.fromJson(Map<String, dynamic> j) => ScaleGood(
        productId: j['product_id'] as String,
        plu: (j['plu'] as num).toInt(),
        name: j['name'] as String? ?? '',
        price: (j['price'] as num).toInt(),
        unit: j['unit'] as String? ?? 'kg',
      );
}

class ScaleError implements Exception {
  ScaleError(this.message);
  final String message;
  @override
  String toString() => message;
}

const _etx = 0x03;
const _tail = [0x0D, 0x0A, _etx];

/// Название в коды GB2312 «зона·позиция» (4 цифры на символ). Печатные ASCII —
/// полноширинные (зона 03), пробел — 0101; прочее (сервер уже убрал) — пропуск.
String dahuaName(String name) {
  final b = StringBuffer();
  for (final c in name.runes) {
    if (c == 0x20) {
      b.write('0101');
    } else if (c > 0x20 && c < 0x7F) {
      b
        ..write('03')
        ..write((c - 0x20).toString().padLeft(2, '0'));
    }
  }
  return b.toString();
}

/// Команда записи товара. [unit]: kg — на развес (способ 0).
String dahuaPlu(ScaleGood g) {
  final plu = g.plu.toString().padLeft(4, '0');
  final code = g.plu.toString().padLeft(7, '0');
  final price = g.price.toString().padLeft(6, '0');
  final mode = g.unit == 'kg' ? '0' : '1';
  return '!0V${plu}A$code$price${mode}000000' // способ, особые сведения
      '999' // срок годности: не печатать
      '22' // код магазина
      '01' // отдел
      '0000000000000' // числовой код
      '00000' // тара
      '00' // этикетка
      '00' // скидка
      '000000000000000000000000' // периоды скидок
      'B${dahuaName(g.name)}CDE';
}

/// Очистить все товары (PLU) в весах. Настройки весов (IP, формат штрихкода,
/// шаблон наклейки) остаются — проверено на Rongta RLS1000C. Ответ «0ia».
///
/// Быстрые клавиши «!0L<страница>A + 36 номеров + B» (Dahua TM) Rongta
/// RLS1000C принимает, но не применяет — клавиши привязываются в весах.
const dahuaClear = '!0IA';

/// Подтверждение весов на команду записи товара [plu].
bool dahuaAck(String reply, int plu) => reply.toLowerCase().contains('0v${plu.toString().padLeft(4, '0')}a');

/// Соединение с весами: команда → ответ до ETX.
class DahuaScale {
  DahuaScale(this.host, this.port, {this.timeout = const Duration(seconds: 5)});

  final String host;
  final int port;
  final Duration timeout;

  Socket? _s;
  StreamSubscription<Uint8List>? _sub;
  final _buf = BytesBuilder();
  Completer<String>? _wait;

  Future<void> open() async {
    try {
      _s = await Socket.connect(host, port, timeout: timeout);
    } on SocketException catch (e) {
      throw ScaleError('$host:$port — ${e.osError?.message ?? e.message}');
    } on TimeoutException {
      throw ScaleError('$host:$port — нет ответа');
    }
    _sub = _s!.listen(_onData, onError: (_) => _fail('соединение прервано'), onDone: () => _fail('весы закрыли соединение'));
  }

  void _onData(Uint8List data) {
    for (final b in data) {
      if (b == _etx) {
        final line = latin1.decode(_buf.takeBytes(), allowInvalid: true);
        final w = _wait;
        _wait = null;
        if (w != null && !w.isCompleted) w.complete(line);
      } else {
        _buf.addByte(b);
      }
    }
  }

  void _fail(String why) {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.completeError(ScaleError(why));
  }

  /// Отправить команду и дождаться ответа весов.
  Future<String> command(String cmd) async {
    final s = _s;
    if (s == null) throw ScaleError('нет соединения с весами');
    final w = Completer<String>();
    _wait = w;
    s.add([...ascii.encode(cmd), ..._tail]);
    await s.flush();
    return w.future.timeout(timeout, onTimeout: () {
      _wait = null;
      throw ScaleError('весы не ответили');
    });
  }

  Future<void> close() async {
    await _sub?.cancel();
    try {
      await _s?.close();
    } catch (_) {}
    _s?.destroy();
    _s = null;
  }
}
