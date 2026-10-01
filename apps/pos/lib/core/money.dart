// Деньги и количество на кассе — только целые числа, без double:
// деньги в тийинах (1 сум = 100 тийин), количество в тысячных (1 кг = 1000).

/// "15000.00", "15 000", "15000,5" → тийины. Пусто или мусор → 0.
int parseMoney(Object? v) => _parseFixed(v, 2);

/// "1.245", "1,245", "2" → тысячные.
int parseQty(Object? v) => _parseFixed(v, 3);

int _parseFixed(Object? v, int digits) {
  var s = '${v ?? ''}'.trim().replaceAll(' ', '').replaceAll(' ', '').replaceAll(',', '.');
  if (s.isEmpty) return 0;
  final neg = s.startsWith('-');
  if (neg) s = s.substring(1);
  final dot = s.indexOf('.');
  final whole = dot < 0 ? s : s.substring(0, dot);
  var frac = dot < 0 ? '' : s.substring(dot + 1);
  if (frac.length > digits) frac = frac.substring(0, digits);
  frac = frac.padRight(digits, '0');
  final w = whole.isEmpty ? 0 : int.tryParse(whole);
  final f = int.tryParse(frac);
  if (w == null || f == null) return 0;
  var scale = 1;
  for (var i = 0; i < digits; i++) {
    scale *= 10;
  }
  final r = w * scale + f;
  return neg ? -r : r;
}

/// Тийины → строка для API: 1500050 → "15000.50".
String moneyApi(int t) {
  final a = t.abs();
  final s = '${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
  return t < 0 ? '-$s' : s;
}

/// Тысячные → строка для API: 1245 → "1.245", 2000 → "2".
String qtyApi(int q) {
  final a = q.abs();
  final frac = a % 1000;
  var s = '${a ~/ 1000}';
  if (frac != 0) s += '.${frac.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '')}';
  return q < 0 ? '-$s' : s;
}

/// Тийины для экрана: 13468000 → "134 680", 1500050 → "15 000,50".
String fmtMoney(int t) {
  final a = t.abs();
  var s = _group(a ~/ 100);
  final frac = a % 100;
  if (frac != 0) s += ',${frac.toString().padLeft(2, '0')}';
  return t < 0 ? '−$s' : s;
}

/// Тысячные для экрана: 1245 → "1,245", 2000 → "2".
String fmtQty(int q) => qtyApi(q).replaceAll('.', ',');

String _group(int n) {
  final s = '$n';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return b.toString();
}

/// Сумма строки: цена × количество, округление до тийина (половина — вверх),
/// как на сервере.
int lineSum(int price, int qty) {
  final p = price * qty;
  return p >= 0 ? (p + 500) ~/ 1000 : -((-p + 500) ~/ 1000);
}

/// Доля [part] из [of] в процентах с сотыми (1000 = 10%): round(value × bp / 10000).
int percentOf(int value, int basisPoints) => (value * basisPoints + 5000) ~/ 10000;

/// НДС, включённый в сумму: total × rate / (100 + rate). Ставка в сотых процента.
int vatIncluded(int total, int rateBp) {
  if (rateBp <= 0 || total <= 0) return 0;
  final d = 10000 + rateBp;
  return (total * rateBp + d ~/ 2) ~/ d;
}

/// Подсказки купюр в окне «Наличные»: ближайшие круглые суммы больше итога
/// (до 1 000, 5 000, 10 000, 50 000, 100 000, 200 000 сумов), не больше 4.
List<int> cashSuggestions(int due) {
  if (due <= 0) return const [];
  final out = <int>{};
  for (final step in const [1000, 5000, 10000, 50000, 100000, 200000]) {
    final s = step * 100;
    var v = (due + s - 1) ~/ s * s;
    if (v == due) v += s;
    out.add(v);
  }
  final list = out.where((v) => v > due).toList()..sort();
  return list.take(4).toList();
}
