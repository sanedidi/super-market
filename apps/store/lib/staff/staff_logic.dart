import 'package:sm_core/sm_core.dart';

// Сотрудники, роли и кассы в «SM Магазин» (Figma «SM Магазин · Сотрудники,
// роли и кассы», С1–С11): чистая логика без виджетов — её проверяют тесты.

/// Есть ли у сотрудника доступ к магазину.
bool worksIn(Map<String, dynamic> e, String? storeId) =>
    e['all_stores'] == true || e['is_owner'] == true || ((e['store_ids'] as List?) ?? const []).contains(storeId);

/// «ДЮ» — инициалы для кружка.
String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.take(2).map((p) => String.fromCharCode(p.runes.first).toUpperCase()).join();
}

/// Группы прав роли (С7) — коды как на сервере (identity.Permissions).
/// Права, которых нет в группах, показываются в «Другое».
const permissionGroups = <(String, String, List<String>)>[
  ('Касса', 'Kassa', ['sales.pos', 'sales.discount', 'sales.return', 'debts.give', 'prices.manage', 'pos.settings']),
  ('Товары и склад', 'Mahsulotlar va ombor', ['catalog.manage', 'inventory.manage', 'counterparties.manage']),
  ('Деньги и отчёты', 'Pul va hisobotlar', ['finance.manage', 'debts.manage', 'reports.view', 'payouts.manage']),
  ('Онлайн и доставка', 'Onlayn va yetkazish', ['orders.manage', 'orders.deliver', 'showcase.manage', 'cafe.waiter']),
  ('Управление', 'Boshqaruv', ['stores.manage', 'staff.manage']),
];

/// Права по группам: [(название группы, [права из [all] в порядке группы])].
/// [all] — список прав с сервера ({code, title}).
List<(String, List<Map<String, dynamic>>)> groupPermissions(List<Map<String, dynamic>> all) {
  final byCode = {for (final p in all) '${p['code']}': p};
  final used = <String>{};
  final out = <(String, List<Map<String, dynamic>>)>[];
  for (final (ru, uz, codes) in permissionGroups) {
    final items = [
      for (final c in codes)
        if (byCode[c] != null) byCode[c]!,
    ];
    used.addAll(codes);
    if (items.isNotEmpty) out.add((tr(ru, uz), items));
  }
  final rest = [
    for (final p in all)
      if (!used.contains('${p['code']}')) p,
  ];
  if (rest.isNotEmpty) out.add((tr('Другое', 'Boshqa'), rest));
  return out;
}

/// «3 права» / «1 право» / «5 прав».
String rightsCount(int n) {
  final ru = (n % 10 == 1 && n % 100 != 11)
      ? 'право'
      : (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14))
          ? 'права'
          : 'прав';
  return tr('$n $ru', '$n ta huquq');
}

/// «2 сотрудника» / «1 сотрудник» / «5 сотрудников».
String staffCount(int n) {
  final ru = (n % 10 == 1 && n % 100 != 11)
      ? 'сотрудник'
      : (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14))
          ? 'сотрудника'
          : 'сотрудников';
  return tr('$n $ru', '$n ta xodim');
}

/// «5831 2047» — пароль из 8 цифр парами по 4.
String spacedPassword(String p) => p.length == 8 && int.tryParse(p) != null ? '${p.substring(0, 4)} ${p.substring(4)}' : p;

/// Текст сотруднику: логин и временный пароль для «SM Сотрудник» (С4).
String employeeLoginMessage(String store, String login, String password) => tr(
      'Вход в «SM Сотрудник» ($store).\nЛогин: $login\nВременный пароль: $password\nПри первом входе придумайте свой пароль.',
      '«SM Xodim»ga kirish ($store).\nLogin: $login\nVaqtinchalik parol: $password\nBirinchi kirishda oʻz parolingizni oʻylab toping.',
    );

/// ПИН для кассы — строго 4 цифры.
bool validPin(String pin) => RegExp(r'^[0-9]{4}$').hasMatch(pin);

/// Статус кассы для С8: (текст, тон: green / amber / gray).
(String, String) registerStatus(Map<String, dynamic> d) => switch ('${d['status']}') {
      'active' => (tr('Подключена', 'Ulangan'), 'green'),
      'waiting' => (tr('Ждёт подключения', 'Ulanishni kutmoqda'), 'amber'),
      _ => (tr('Отключена', 'Oʻchirilgan'), 'gray'),
    };

/// Подпись кассы в списке С8: на связи / когда была, открыта ли смена.
String registerSubtitle(Map<String, dynamic> d) {
  final status = '${d['status']}';
  if (status == 'revoked') return tr('отключена · в лимите не считается', 'oʻchirilgan · limitda hisoblanmaydi');
  if (status == 'waiting') {
    final until = d['activation_expires'];
    return until == null
        ? tr('нужен код подключения — нажмите, чтобы получить', 'ulanish kodi kerak — olish uchun bosing')
        : tr('код действует до ${dateTime(until)}', 'kod ${dateTime(until)} gacha amal qiladi');
  }
  final parts = <String>[
    if (d['online'] == true) tr('на связи', 'aloqada') else if (d['last_seen_at'] != null) tr('была на связи ${dateTime(d['last_seen_at'])}', 'oxirgi aloqa: ${dateTime(d['last_seen_at'])}'),
    if (d['open_shift_id'] != null) tr('смена открыта', 'smena ochiq'),
  ];
  return parts.join(' · ');
}

/// «7MQX-2HTR» — код подключения кассы с дефисом посередине.
String formatActivationCode(String code) {
  final c = code.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
  return c.length == 8 ? '${c.substring(0, 4)}-${c.substring(4)}' : code;
}
