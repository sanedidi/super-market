// Команды чекового принтера ESC/POS (Xprinter, Epson, Rongta и совместимые).
// Кириллица — кодовая страница PC866 (ESC t 17), её понимают почти все
// принтеры для СНГ. Узбекские «ўқғҳ» печатаются ближайшими русскими буквами.

import 'dart:typed_data';

enum PrintAlign { left, center, right }

/// Ширина строки в символах: 80 мм — 48 (шрифт A), 58 мм — 32.
int lineWidth(int paperMm) => paperMm >= 80 ? 48 : 32;

class EscPos {
  EscPos({this.paperMm = 80, this.codePage = 17});

  final int paperMm;

  /// Номер кодовой страницы PC866 в принтере (у большинства — 17).
  final int codePage;
  final BytesBuilder _b = BytesBuilder();

  int get width => lineWidth(paperMm);

  Uint8List bytes() => _b.toBytes();

  void _raw(List<int> v) => _b.add(v);

  EscPos init() {
    _raw([0x1B, 0x40]); // ESC @
    _raw([0x1B, 0x74, codePage]); // ESC t n
    return this;
  }

  EscPos align(PrintAlign a) {
    _raw([0x1B, 0x61, a.index]);
    return this;
  }

  EscPos bold(bool on) {
    _raw([0x1B, 0x45, on ? 1 : 0]);
    return this;
  }

  /// Размер: 1 — обычный, 2 — двойной (ширина и высота).
  EscPos size(int w, int h) {
    _raw([0x1D, 0x21, ((w - 1) << 4) | (h - 1)]);
    return this;
  }

  EscPos text(String s) {
    _raw(encode866(s));
    return this;
  }

  EscPos line([String s = '']) => text('$s\n');

  /// Строка «слева … справа» на всю ширину ([w] — ширина в символах для двойного шрифта).
  EscPos pair(String left, String right, {int? w}) {
    final width = w ?? this.width;
    final space = width - left.length - right.length;
    if (space >= 1) return line(left + ' ' * space + right);
    // Не влезает — левую часть переносим, правую прижимаем на следующей строке.
    for (final l in wrap(left, width)) {
      line(l);
    }
    return line(right.padLeft(width));
  }

  EscPos wrapped(String s) {
    for (final l in wrap(s, width)) {
      line(l);
    }
    return this;
  }

  EscPos dashes() => line('-' * width);

  EscPos feed(int lines) {
    _raw([0x1B, 0x64, lines]);
    return this;
  }

  /// QR-код (GS ( k): модель 2, размер модуля [module], коррекция M.
  EscPos qr(String data, {int module = 6}) {
    final d = encode866(data);
    final len = d.length + 3;
    _raw([0x1D, 0x28, 0x6B, 4, 0, 0x31, 0x41, 0x32, 0x00]); // модель 2
    _raw([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x43, module]); // размер
    _raw([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x45, 0x31]); // коррекция M
    _raw([0x1D, 0x28, 0x6B, len & 0xFF, len >> 8, 0x31, 0x50, 0x30]);
    _raw(d);
    _raw([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x51, 0x30]); // печать
    return this;
  }

  /// Отрезать бумагу (частичный отрез с подачей).
  EscPos cut() {
    _raw([0x1D, 0x56, 0x42, 3]);
    return this;
  }

  /// Открыть денежный ящик (импульс на разъём 1).
  EscPos drawer() {
    _raw([0x1B, 0x70, 0x00, 0x19, 0xFA]);
    return this;
  }
}

/// Перенос по словам на строки ширины [width].
List<String> wrap(String s, int width) {
  final out = <String>[];
  for (final para in s.split('\n')) {
    var cur = '';
    for (final word in para.split(' ')) {
      var w = word;
      while (w.length > width) {
        if (cur.isNotEmpty) {
          out.add(cur);
          cur = '';
        }
        out.add(w.substring(0, width));
        w = w.substring(width);
      }
      if (cur.isEmpty) {
        cur = w;
      } else if (cur.length + 1 + w.length <= width) {
        cur = '$cur $w';
      } else {
        out.add(cur);
        cur = w;
      }
    }
    out.add(cur);
  }
  return out;
}

/// Unicode → PC866. Неизвестные символы — «?».
List<int> encode866(String s) {
  final out = <int>[];
  for (final r in s.runes) {
    out.add(_cp866(r));
  }
  return out;
}

int _cp866(int r) {
  if (r < 0x80) return r;
  if (r >= 0x0410 && r <= 0x043F) return r - 0x0410 + 0x80; // А..п
  if (r >= 0x0440 && r <= 0x044F) return r - 0x0440 + 0xE0; // р..я
  switch (r) {
    case 0x0401: // Ё
      return 0xF0;
    case 0x0451: // ё
      return 0xF1;
    case 0x040E: // Ў
      return 0xF6;
    case 0x045E: // ў
      return 0xF7;
    case 0x0492: // Ғ
      return 0x83; // Г
    case 0x0493: // ғ
      return 0xA3; // г
    case 0x049A: // Қ
      return 0x8A; // К
    case 0x049B: // қ
      return 0xAA; // к
    case 0x04B2: // Ҳ
      return 0x95; // Х
    case 0x04B3: // ҳ
      return 0xE5; // х
    case 0x2116: // №
      return 0xFC;
    case 0x00B0: // °
      return 0xF8;
    case 0x00B7: // ·
      return 0xFA;
    case 0x2212: // −
    case 0x2013: // –
    case 0x2014: // —
      return 0x2D;
    case 0x00A0: // неразрывный пробел
    case 0x202F:
      return 0x20;
    case 0x00AB: // «
    case 0x00BB: // »
    case 0x201C:
    case 0x201D:
      return 0x22;
    case 0x2018:
    case 0x2019:
    case 0x02BB: // ʻ (oʻ, gʻ)
    case 0x02BC:
      return 0x27;
    case 0x00D7: // ×
      return 0x78;
  }
  return 0x3F;
}
