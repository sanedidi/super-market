/// Чистая логика «Политика конфиденциальности» и «Удалить аккаунт» (без Flutter) — покрыта тестами.
library;

/// Политика конфиденциальности (открывается в браузере).
const privacyUrl = 'https://super-market.uz/privacy';

/// Причины удаления аккаунта (Figma Ш4) — выбирается одна.
const deletionReasons = ['Больше здесь не работаю', 'Не пользуюсь приложением', 'Магазин закрыт', 'Другое'];

/// Не длиннее, чем принимает сервер (POST /store/me/deletion-request).
const deletionReasonMax = 500;

/// Пояснение в шторке: сотруднику — удаление по запросу, владельцу — закрытие сети.
String deletionText({required bool isOwner}) => isOwner
    ? 'Вы — владелец сети. Удалить аккаунт владельца — значит закрыть сеть: магазины, сотрудники и витрина перестанут работать. '
        'Удаляем по запросу — в течение 30 дней, супер-админ свяжется с вами и всё уточнит.'
    : 'Аккаунт сотрудника создаёт владелец сети, поэтому удаляем по запросу — в течение 30 дней. '
        'Удалим ваш доступ и личные данные; чеки и документы магазина останутся у сети.';

/// Причина для сервера: «вариант», «комментарий» или «вариант: комментарий»,
/// не длиннее [deletionReasonMax] символов.
String deletionReason(String? option, String comment) {
  final c = comment.trim();
  final o = option?.trim() ?? '';
  final text = o.isEmpty ? c : (c.isEmpty ? o : '$o: $c');
  final runes = text.runes;
  return runes.length <= deletionReasonMax ? text : String.fromCharCodes(runes.take(deletionReasonMax)).trimRight();
}

/// Сервер отвечает 201 на новый запрос и 200 с прежним, если открытый уже есть.
/// Код ответа приложению не виден, поэтому смотрим на created_at: запрос,
/// созданный больше 2 минут назад, — отправленный раньше.
bool deletionAlreadySent(Map<String, dynamic> res, DateTime now) {
  final created = DateTime.tryParse('${res['created_at'] ?? ''}');
  if (created == null) return false;
  return now.difference(created) > const Duration(minutes: 2);
}

String deletionSentMessage({required bool already}) =>
    already ? 'Запрос уже отправлен. Супер-админ свяжется с вами' : 'Запрос отправлен. Супер-админ свяжется с вами';
