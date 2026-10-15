import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

// «Мой QR-код» (Figma Q1–Q3): QR покупателя для продажи в долг.
//
// Сервер один раз выдаёт секрет (GET /client/qr), дальше QR считается в
// телефоне — без интернета. Код как в Google Authenticator (TOTP):
// HMAC-SHA256(секрет, номер 30-секундного шага), динамическое усечение,
// 8 цифр. Тот же расчёт — на сервере (backend/internal/debts/qr.go).

/// Ключ QR покупателя (ответ GET /client/qr), хранится на телефоне.
class QrKey {
  QrKey({required this.qrId, required this.secret, this.step = 30, this.digits = 8, this.prefix = clientQrPrefix, this.clockOffset = Duration.zero});

  final String qrId;
  final List<int> secret;
  final int step;
  final int digits;
  final String prefix;

  /// Насколько часы сервера впереди часов телефона.
  final Duration clockOffset;

  /// [receivedAt] — когда пришёл ответ (для поправки часов).
  factory QrKey.fromJson(Map<String, dynamic> j, {DateTime? receivedAt}) {
    final server = (j['server_time'] as num?)?.toInt();
    final offset = j['clock_offset_ms'] is num
        ? Duration(milliseconds: (j['clock_offset_ms'] as num).toInt())
        : server != null && receivedAt != null
            ? Duration(milliseconds: server - receivedAt.millisecondsSinceEpoch)
            : Duration.zero;
    return QrKey(
      qrId: '${j['qr_id']}',
      secret: _hex('${j['secret']}'),
      step: (j['step'] as num?)?.toInt() ?? 30,
      digits: (j['digits'] as num?)?.toInt() ?? 8,
      prefix: j['prefix'] as String? ?? clientQrPrefix,
      clockOffset: offset,
    );
  }

  Map<String, dynamic> toJson() => {
        'qr_id': qrId,
        'secret': _toHex(secret),
        'step': step,
        'digits': digits,
        'prefix': prefix,
        'clock_offset_ms': clockOffset.inMilliseconds,
      };

  DateTime _now(DateTime? at) => (at ?? DateTime.now()).add(clockOffset);

  int stepAt([DateTime? at]) => _now(at).millisecondsSinceEpoch ~/ 1000 ~/ step;

  /// Содержимое QR сейчас (или в момент [at]).
  String payload([DateTime? at]) => '$prefix$qrId${qrCode(secret, stepAt(at), digits: digits)}';

  /// Сколько секунд текущий QR ещё действует.
  int secondsLeft([DateTime? at]) => step - (_now(at).millisecondsSinceEpoch ~/ 1000) % step;
}

/// Одноразовый код для шага [step].
String qrCode(List<int> secret, int step, {int digits = 8}) {
  final msg = ByteData(8)..setUint64(0, step); // big-endian
  final mac = Hmac(sha256, secret).convert(msg.buffer.asUint8List()).bytes;
  final off = mac[mac.length - 1] & 0x0f;
  final bin = ((mac[off] & 0x7f) << 24) | (mac[off + 1] << 16) | (mac[off + 2] << 8) | mac[off + 3];
  var mod = 1;
  for (var i = 0; i < digits; i++) {
    mod *= 10;
  }
  return (bin % mod).toString().padLeft(digits, '0');
}

List<int> _hex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

const _prefsKey = 'sm_client_qr';

/// Ключ с телефона (QR работает без интернета).
Future<QrKey?> loadQrKey() async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
    if (raw == null) return null;
    return QrKey.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

/// Ключ с сервера; сохраняем на телефоне.
Future<QrKey> fetchQrKey(Api api) async {
  final j = await api.get('/client/qr') as Map<String, dynamic>;
  final key = QrKey.fromJson(j, receivedAt: DateTime.now());
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefsKey, jsonEncode(key.toJson()));
  return key;
}

/// Выход из аккаунта: ключ QR с телефона убираем.
Future<void> forgetQrKey() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_prefsKey);
}
