// QR покупателя для продажи в долг (Figma «Долги · QR-код покупателя вместо
// номера телефона»).
//
// Покупатель показывает в приложении «Мой QR-код», касса сканирует. В QR —
// только цифры (сканер кассы печатает их одинаково при любой раскладке):
//
//   «99» + номер QR (10 цифр) + одноразовый код (8 цифр, меняется раз в 30 с)
//
// Код проверяет сервер (GET /pos/debtors/qr). Без связи касса находит
// покупателя по номеру QR в своём каталоге.

/// Разобранный QR покупателя.
class ClientQr {
  const ClientQr(this.qrId, this.code);

  /// Номер QR покупателя (10 цифр) — постоянный.
  final String qrId;

  /// Одноразовый код (8 цифр).
  final String code;

  /// Содержимое QR целиком.
  String get payload => '$clientQrPrefix$qrId$code';
}

const clientQrPrefix = '99';
const clientQrLength = 20;

final _qrDigits = RegExp(r'^[0-9]+$');

/// Скан — QR покупателя? Пробелы и перевод строки по краям сканер иногда
/// добавляет. null — это не QR покупателя (штрихкод, марка, чужой QR).
ClientQr? parseClientQr(String raw) {
  final s = raw.trim();
  if (s.length != clientQrLength || !s.startsWith(clientQrPrefix) || !_qrDigits.hasMatch(s)) return null;
  return ClientQr(s.substring(2, 12), s.substring(12));
}
