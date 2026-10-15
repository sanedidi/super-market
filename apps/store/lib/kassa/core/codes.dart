// Копия apps/pos/lib/core/codes.dart — касса в телефоне («SM Магазин») считает
// так же, как POS. Меняете здесь — поменяйте и там.

// Разбор того, что пришло со сканера: обычный штрихкод, этикетка весов,
// код маркировки DataMatrix.

/// Этикетка весов: EAN-13 вида PP CCCCC WWWWW K — префикс, код товара (PLU),
/// вес в граммах, контрольная цифра.
class WeightCode {
  WeightCode(this.plu, this.grams);
  final int plu;
  final int grams;
}

WeightCode? parseWeight(String code, List<String> prefixes) {
  if (code.length != 13 || !_digits.hasMatch(code)) return null;
  if (!prefixes.contains(code.substring(0, 2))) return null;
  if (!validEan13(code)) return null;
  final grams = int.parse(code.substring(7, 12));
  if (grams == 0) return null;
  return WeightCode(int.parse(code.substring(2, 7)), grams);
}

final _digits = RegExp(r'^[0-9]+$');

bool validEan13(String c) {
  if (c.length != 13 || !_digits.hasMatch(c)) return false;
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    final d = c.codeUnitAt(i) - 48;
    sum += i.isOdd ? d * 3 : d;
  }
  return (10 - sum % 10) % 10 == c.codeUnitAt(12) - 48;
}

/// Код маркировки (GS1 DataMatrix): 01 + GTIN-14 + 21 + серийный номер + …
class MarkCode {
  MarkCode(this.gtin, this.raw);

  /// GTIN-14 из кода.
  final String gtin;

  /// Код целиком — уходит в чек.
  final String raw;

  /// Штрихкоды, под которыми товар может быть в каталоге: GTIN-14, EAN-13, EAN-8.
  List<String> get barcodes {
    final out = <String>[gtin];
    if (gtin.startsWith('0')) out.add(gtin.substring(1));
    if (gtin.startsWith('000000')) out.add(gtin.substring(6));
    return out;
  }
}

const _gs = '\u001d';

MarkCode? parseMark(String input) {
  var s = input.trim();
  // Префикс символики, который добавляют некоторые сканеры.
  for (final p in [']d2', ']C1', ']Q3']) {
    if (s.startsWith(p)) s = s.substring(p.length);
  }
  if (s.startsWith(_gs)) s = s.substring(1);
  if (s.length < 20 || !s.startsWith('01')) return null;
  final gtin = s.substring(2, 16);
  if (!_digits.hasMatch(gtin) || s.substring(16, 18) != '21') return null;
  return MarkCode(gtin, s);
}

/// Сканер в режиме клавиатуры при русской раскладке печатает кириллицу
/// вместо латиницы. Возвращаем символы, которые он имел в виду.
String fixLayout(String s) {
  if (!_cyr.hasMatch(s)) return s;
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    b.write(_ruToEn[ch] ?? ch);
  }
  return b.toString();
}

final _cyr = RegExp('[А-Яа-яЁё]');

const _ruLower = 'йцукенгшщзхъфывапролджэячсмитьбюё';
const _enLower = 'qwertyuiop[]asdfghjkl;\'zxcvbnm,.`';
final Map<String, String> _ruToEn = () {
  final m = <String, String>{};
  for (var i = 0; i < _ruLower.length; i++) {
    m[_ruLower[i]] = _enLower[i];
    final up = _ruLower[i].toUpperCase();
    final enUp = _enLower[i].toUpperCase();
    m[up] = enUp == _enLower[i] ? _shifted[_enLower[i]] ?? enUp : enUp;
  }
  return m;
}();

const _shifted = {'[': '{', ']': '}', ';': ':', '\'': '"', ',': '<', '.': '>', '`': '~'};

/// Отличает сканер от человека: сканер «печатает» код быстрее 50 мс на символ.
class ScanTimer {
  ScanTimer({this.maxGap = const Duration(milliseconds: 50), this.minLength = 6});

  final Duration maxGap;
  final int minLength;

  Duration? _last;
  int _fast = 0;
  int _chars = 0;

  /// Символ введён в момент [at] (время события клавиатуры).
  void char(Duration at) {
    if (_last != null && at - _last! <= maxGap) _fast++;
    _last = at;
    _chars++;
  }

  /// Ввод похож на сканер: длинный и почти без пауз.
  bool get scanned => _chars >= minLength && _fast >= _chars - 1;

  void reset() {
    _last = null;
    _fast = 0;
    _chars = 0;
  }
}
