/// Чистая логика «Политика конфиденциальности» и «Удалить аккаунт» (без Flutter) — покрыта тестами.
library;

import 'package:sm_core/sm_core.dart';

/// Политика конфиденциальности (открывается в браузере).
const privacyUrl = 'https://super-market.uz/privacy';

/// Причины удаления аккаунта (Figma Ш4) — выбирается одна.
/// На сервер уходят по-русски (запросы читает супер-админ), на экране — [deletionReasonLabel].
const deletionReasons = ['Больше здесь не работаю', 'Не пользуюсь приложением', 'Магазин закрыт', 'Другое'];

/// Подпись причины на языке интерфейса.
String deletionReasonLabel(String r) => switch (r) {
      'Больше здесь не работаю' => tr(r, 'Bu yerda endi ishlamayman'),
      'Не пользуюсь приложением' => tr(r, 'Ilovadan foydalanmayman'),
      'Магазин закрыт' => tr(r, 'Doʻkon yopilgan'),
      'Другое' => tr(r, 'Boshqa'),
      _ => r,
    };

/// Не длиннее, чем принимает сервер (POST /store/me/deletion-request).
const deletionReasonMax = 500;

/// Пояснение в шторке: сотруднику — удаление по запросу, владельцу — закрытие сети.
String deletionText({required bool isOwner}) => isOwner
    ? tr(
        'Вы — владелец сети. Удалить аккаунт владельца — значит закрыть сеть: магазины, сотрудники и витрина перестанут работать. '
            'Удаляем по запросу — в течение 30 дней, супер-админ свяжется с вами и всё уточнит.',
        'Siz — tarmoq egasisiz. Egasining akkauntini oʻchirish — tarmoqni yopish demakdir: doʻkonlar, xodimlar va vitrina ishlamay qoladi. '
            'Soʻrov boʻyicha 30 kun ichida oʻchiramiz, super-admin siz bilan bogʻlanib, hammasini aniqlashtiradi.',
      )
    : tr(
        'Аккаунт сотрудника создаёт владелец сети, поэтому удаляем по запросу — в течение 30 дней. '
            'Удалим ваш доступ и личные данные; чеки и документы магазина останутся у сети.',
        'Xodim akkauntini tarmoq egasi yaratadi, shuning uchun soʻrov boʻyicha 30 kun ichida oʻchiramiz. '
            'Kirish huquqingiz va shaxsiy maʼlumotlaringiz oʻchiriladi; doʻkon cheklari va hujjatlari tarmoqda qoladi.',
      );

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
    already
        ? tr('Запрос уже отправлен. Супер-админ свяжется с вами', 'Soʻrov allaqachon yuborilgan. Super-admin siz bilan bogʻlanadi')
        : tr('Запрос отправлен. Супер-админ свяжется с вами', 'Soʻrov yuborildi. Super-admin siz bilan bogʻlanadi');
