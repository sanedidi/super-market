import 'package:sm_core/sm_core.dart';

// Чистая логика «SM Сотрудник» (без виджетов) — покрыта test/logic_test.dart.

/// «Дилшод Каримов» → «ДК»; одно слово — две первые буквы.
String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters2(2).toUpperCase();
  return (parts[0].characters2(1) + parts[1].characters2(1)).toUpperCase();
}

extension on String {
  String characters2(int n) => runes.take(n).map(String.fromCharCode).join();
}

/// Имя для приветствия: первое слово.
String firstName(String name) {
  final p = name.trim().split(RegExp(r'\s+'));
  return p.isEmpty ? '' : p.first;
}

num n(Object? v) => num.tryParse('${v ?? ''}') ?? 0;

/// Количество без лишних нулей: 2.000 → «2», 1.250 → «1,25».
String q(Object? v) => qty(v);

/// Время по Ташкенту телефона: «15:30».
String hm(Object? v) {
  final d = v is DateTime ? v : DateTime.tryParse('${v ?? ''}');
  if (d == null) return '';
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Сколько минут ждёт заказ (с оплаты, иначе с создания).
int waitingMinutes(Map<String, dynamic> o, DateTime now) {
  final from = DateTime.tryParse('${o['paid_at'] ?? o['created_at'] ?? ''}');
  if (from == null) return 0;
  final m = now.difference(from).inMinutes;
  return m < 0 ? 0 : m;
}

/// «доставка к 15:30» или «как можно скорее».
String deliveryWhen(Map<String, dynamic> o) {
  final to = o['delivery_to'];
  if (to == null) return tr('как можно скорее', 'imkon qadar tez');
  return tr('доставка к ${hm(to)}', '${hm(to)} gacha yetkazish');
}

/// «8 товаров» / «8 ta mahsulot».
String goods(int count) {
  if (Lang.instance.code == Lang.uz) return '$count ta mahsulot';
  final m10 = count % 10, m100 = count % 100;
  if (m10 == 1 && m100 != 11) return '$count товар';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return '$count товара';
  return '$count товаров';
}

/// «2 заказа» / «2 ta buyurtma».
String ordersWord(int count) {
  if (Lang.instance.code == Lang.uz) return '$count ta buyurtma';
  final m10 = count % 10, m100 = count % 100;
  if (m10 == 1 && m100 != 11) return '$count заказ';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return '$count заказа';
  return '$count заказов';
}

/// Разделы главной по правам роли (С3–С4). Нет права — плитки нет совсем.
enum Section { sell, income, glance, recount, writeOff, returns }

List<Section> sectionsFor(bool Function(String) can) => [
      if (can('sales.pos')) Section.sell,
      if (can('inventory.manage')) Section.income,
      Section.glance,
      if (can('inventory.manage')) Section.recount,
      if (can('inventory.manage')) Section.writeOff,
      if (can('sales.return')) Section.returns,
    ];

/// Только касса: без склада и сборки — подсказка «остальное включает владелец» (С4).
bool cashierOnly(bool Function(String) can) => !can('inventory.manage') && !can('orders.manage');

/// Строка заказа собрана целиком.
bool linePicked(Map<String, dynamic> it) => n(it['picked_qty']) >= n(it['qty']) && n(it['qty']) > 0;

/// Строка заказа, которую закрывает этот штрихкод (ещё не собранная — первой).
Map<String, dynamic>? lineForCode(List<Map<String, dynamic>> items, String code) {
  Map<String, dynamic>? done;
  for (final it in items) {
    final codes = ((it['barcodes'] as List?) ?? const []).map((e) => '$e');
    if (!codes.contains(code)) continue;
    if (!linePicked(it)) return it;
    done ??= it;
  }
  return done;
}

/// Сколько отметить собранным после скана: штучный — +1 (не больше заказанного),
/// весовой — весь заказанный вес (или вес с наклейки, если он известен).
String pickQtyAfterScan(Map<String, dynamic> it, {String? weight}) {
  final ordered = n(it['qty']);
  if (it['is_fractional'] == true) {
    final w = weight == null ? ordered : n(weight);
    return (w > ordered ? ordered : w).toString();
  }
  final next = n(it['picked_qty']) + 1;
  return (next > ordered ? ordered : next).toString();
}

/// Расхождение факта и учёта: «+2», «−2», '' — совпало.
String diffLabel(num system, num fact) {
  final d = fact - system;
  if (d == 0) return '';
  final s = qty(d.abs());
  return d > 0 ? '+$s' : '−$s';
}

/// Названия прав для «Мои права» (С13).
String permissionTitle(String p) => switch (p) {
      'sales.pos' => tr('Продажа на кассе', 'Kassada sotish'),
      'sales.discount' => tr('Скидки на кассе', 'Kassada chegirma'),
      'sales.return' => tr('Возврат от покупателя', 'Xaridordan qaytarish'),
      'inventory.manage' => tr('Склад: приход, пересчёт, списание', 'Ombor: kirim, qayta sanash, hisobdan chiqarish'),
      'orders.manage' => tr('Онлайн-заказы и сборка', 'Onlayn buyurtmalar va yigʻish'),
      'prices.manage' => tr('Цены', 'Narxlar'),
      'debts.give' => tr('Продажа в долг', 'Nasiyaga sotish'),
      'debts.manage' => tr('Долги покупателей', 'Xaridorlar qarzlari'),
      'catalog.manage' => tr('Свои товары', 'Oʻz mahsulotlari'),
      'finance.manage' => tr('Кассы и деньги', 'Kassalar va pul'),
      'reports.view' => tr('Отчёты', 'Hisobotlar'),
      'staff.manage' => tr('Сотрудники', 'Xodimlar'),
      'stores.manage' => tr('Магазины', 'Doʻkonlar'),
      'orders.deliver' => tr('Доставка заказов', 'Buyurtmalarni yetkazish'),
      'cafe.waiter' => tr('Официант', 'Ofitsiant'),
      'pos.settings' => tr('Настройка кассы', 'Kassa sozlamalari'),
      'counterparties.manage' => tr('Поставщики', 'Yetkazib beruvchilar'),
      'payouts.manage' => tr('Вывод денег', 'Pul yechish'),
      'showcase.manage' => tr('Витрина в приложении', 'Ilovadagi vitrina'),
      _ => p,
    };

/// Причины списания (С11) — коды сервера и подписи.
const writeOffReasons = ['expired', 'defect', 'broken', 'spoiled', 'other'];

String writeOffReasonTitle(String r) => switch (r) {
      'expired' => tr('Просрочка', 'Muddati oʻtgan'),
      'defect' => tr('Брак', 'Nuqsonli'),
      'broken' => tr('Разбилось', 'Sindi'),
      'spoiled' => tr('Испортился', 'Buzildi'),
      _ => tr('Другое', 'Boshqa'),
    };

/// Шаг количества: штучный — 1, весовой — 0,1.
num stepFor(bool fractional) => fractional ? 0.1 : 1;

/// Число для сервера: «1,5» → «1.5»; округление весового до граммов.
String qtyBody(num v, bool fractional) {
  if (!fractional) return v.round().toString();
  final s = v.toStringAsFixed(3);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Ввод количества: «1,5» → 1.5; пусто или не число — null.
num? parseInput(String s) {
  final t = s.trim().replaceAll(' ', '').replaceAll(',', '.');
  if (t.isEmpty) return null;
  return num.tryParse(t);
}
