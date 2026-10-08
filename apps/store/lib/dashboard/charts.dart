import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';

/// Цвета графиков — те же, что на главной веб-панели (проверены на
/// различимость при дальтонизме). Значения всегда подписаны, не только цветом.
abstract final class ChartColors {
  static const pos = Color(0xFF2A78D6);
  static const online = Color(0xFF93C1EF);
  static const profit = Color(0xFF1BAF7A);
  static const prev = Color(0xFFA1A1AA);
  static const orange = Color(0xFFEB6834);
  static const grid = Color(0xFFF4F4F5);
  static const axis = Color(0xFFE4E4E7);
  static const now = AppColors.primary;
  static const cats = [Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), Color(0xFFEDA100), Color(0xFFE87BA4), Color(0xFF008300), Color(0xFF4A3AA7), Color(0xFFE34948)];
  static const heat = [Color(0xFFEEF4FC), Color(0xFFC9DCF5), Color(0xFF94BBEC), Color(0xFF5F97E0), Color(0xFF2A78D6), Color(0xFF1B4F91)];
}

/// 4 860 000 → «4,86 млн» / «4,86 mln», 820 000 → «820 тыс» / «820 ming».
String shortMoney(num v) {
  final a = v.abs();
  String f(num x, int d) {
    var s = x.toStringAsFixed(d);
    if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s.replaceAll('.', ',');
  }
  if (a >= 1e6) return '${f(v / 1e6, a >= 1e8 ? 0 : 2)} ${tr('млн', 'mln')}';
  if (a >= 1e3) return '${(v / 1e3).round()} ${tr('тыс', 'ming')}';
  return '${v.round()}';
}

/// Удобный верх шкалы: 1, 2, 2.5, 5 × 10^n.
double niceMax(double v) {
  if (v <= 0) return 1;
  final p = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  for (final m in [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * p >= v) return m * p;
  }
  return 10 * p;
}

const _axisText = TextStyle(fontFamily: 'Inter', fontSize: 9, color: AppColors.muted);

void _text(Canvas c, String s, Offset at, {TextStyle style = _axisText, TextAlign align = TextAlign.left}) {
  final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout();
  var dx = at.dx;
  if (align == TextAlign.center) dx -= tp.width / 2;
  if (align == TextAlign.right) dx -= tp.width;
  tp.paint(c, Offset(dx, at.dy));
}

// ---------------------------------------------------------------- мини-график

class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, required this.color, this.bars = false, this.height = 30});

  final List<double> values;
  final Color color;
  final bool bars;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(height: height, width: double.infinity, child: CustomPaint(painter: _SparkPainter(values, color, bars)));
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.v, this.color, this.bars);
  final List<double> v;
  final Color color;
  final bool bars;

  @override
  void paint(Canvas c, Size s) {
    if (v.isEmpty) return;
    final mx = v.reduce(math.max);
    final mn = bars ? 0.0 : v.reduce(math.min);
    final span = (mx - mn) == 0 ? 1.0 : mx - mn;
    if (bars) {
      final step = s.width / v.length;
      for (var i = 0; i < v.length; i++) {
        final h = math.max(2.0, (mx == 0 ? 0.0 : v[i] / mx) * s.height);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * step, s.height - h, math.max(2.0, step - 3), h), const Radius.circular(2)),
            Paint()..color = i == v.length - 1 ? ChartColors.pos : const Color(0xFFD4D4D8));
      }
      return;
    }
    Offset p(int i) => Offset(v.length == 1 ? s.width / 2 : 2 + i * (s.width - 6) / (v.length - 1), 3 + (s.height - 6) * (1 - (v[i] - mn) / span));
    final line = Path()..moveTo(p(0).dx, p(0).dy);
    for (var i = 1; i < v.length; i++) {
      line.lineTo(p(i).dx, p(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(p(v.length - 1).dx, s.height)
      ..lineTo(p(0).dx, s.height)
      ..close();
    c.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)])
              .createShader(Offset.zero & s));
    c.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
    final e = p(v.length - 1);
    c.drawCircle(e, 4, Paint()..color = Colors.white);
    c.drawCircle(e, 2.8, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter o) => o.v != v || o.color != color;
}

// ---------------------------------------------------------------- столбики касса + онлайн

class BarPoint {
  const BarPoint({required this.label, required this.pos, required this.online, this.prev});
  final String? label; // подпись под осью (null — без подписи)
  final double pos;
  final double online;
  final double? prev; // прошлый отрезок, для пунктира
}

/// Столбики касса + онлайн, пунктир — прошлый отрезок, красная линия — «сейчас».
/// Нажатие на столбец выделяет его — подробности показывает родитель.
class StackedBars extends StatelessWidget {
  const StackedBars({super.key, required this.points, this.nowIndex, this.selected, this.onSelect, this.height = 120});

  final List<BarPoint> points;
  final int? nowIndex;
  final int? selected;
  final ValueChanged<int?>? onSelect;
  final double height;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      int? hit(Offset o) {
        if (points.isEmpty) return null;
        final i = (o.dx / (w / points.length)).floor();
        return math.min(math.max(i, 0), points.length - 1);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => onSelect?.call(hit(d.localPosition)),
        onHorizontalDragUpdate: (d) {
          final i = hit(d.localPosition);
          if (i != selected) onSelect?.call(i);
        },
        child: SizedBox(height: height + 16, width: w, child: CustomPaint(painter: _BarsPainter(points, nowIndex, selected))),
      );
    });
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.p, this.now, this.sel);
  final List<BarPoint> p;
  final int? now;
  final int? sel;

  @override
  void paint(Canvas c, Size s) {
    final h = s.height - 16;
    final n = p.length;
    if (n == 0) return;
    var mx = 1.0;
    for (final x in p) {
      mx = math.max(mx, math.max(x.pos + x.online, x.prev ?? 0.0));
    }
    mx = niceMax(mx);
    double y(double v) => 4 + (h - 4) * (1 - math.max(0.0, v) / mx);
    for (final t in [0.0, 0.5, 1.0]) {
      c.drawLine(Offset(0, y(t * mx)), Offset(s.width, y(t * mx)), Paint()..color = t == 0 ? ChartColors.axis : ChartColors.grid);
    }
    final slot = s.width / n;
    final bw = math.max(3.0, math.min(14.0, slot * 0.62));
    for (var i = 0; i < n; i++) {
      final cx = slot * i + slot / 2;
      final dim = sel != null && sel != i;
      final pos = math.max(0.0, p[i].pos);
      final on = math.max(0.0, p[i].online);
      if (pos > 0) c.drawRect(Rect.fromLTRB(cx - bw / 2, y(pos), cx + bw / 2, h), Paint()..color = ChartColors.pos.withValues(alpha: dim ? 0.4 : 1.0));
      if (on > 0) {
        c.drawRRect(
            RRect.fromRectAndCorners(Rect.fromLTRB(cx - bw / 2, y(pos + on), cx + bw / 2, y(pos) - 1),
                topLeft: const Radius.circular(3), topRight: const Radius.circular(3)),
            Paint()..color = ChartColors.online.withValues(alpha: dim ? 0.4 : 1.0));
      }
      final l = p[i].label;
      if (l != null) _text(c, l, Offset(cx, h + 4), align: TextAlign.center);
    }
    // Пунктир прошлого отрезка.
    final pts = <Offset>[];
    for (var i = 0; i < n; i++) {
      final v = p[i].prev;
      if (v != null) pts.add(Offset(slot * i + slot / 2, y(v)));
    }
    if (pts.length > 1) {
      final paint = Paint()
        ..color = ChartColors.prev
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      for (var i = 1; i < pts.length; i++) {
        _dashed(c, pts[i - 1], pts[i], paint);
      }
    }
    if (now != null && now! >= 0 && now! < n) {
      final x = slot * now! + slot / 2 + bw / 2 + 2;
      c.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = ChartColors.now);
    }
    _text(c, shortMoney(mx), const Offset(0, -2));
  }

  void _dashed(Canvas c, Offset a, Offset b, Paint paint) {
    const dash = 4.0, gap = 3.0;
    final d = (b - a).distance;
    if (d == 0) return;
    final dir = (b - a) / d;
    var t = 0.0;
    while (t < d) {
      final e = math.min(t + dash, d);
      c.drawLine(a + dir * t, a + dir * e, paint);
      t = e + gap;
    }
  }

  @override
  bool shouldRepaint(_BarsPainter o) => o.p != p || o.now != now || o.sel != sel;
}

// ---------------------------------------------------------------- линии по дням

class DayLines extends StatelessWidget {
  const DayLines({super.key, required this.revenue, required this.profit, required this.prev, required this.labels, this.height = 120});

  final List<double> revenue;
  final List<double> profit;
  final List<double> prev;
  final List<String> labels; // подписи первой, средней и последней точки
  final double height;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: height + 16, width: double.infinity, child: CustomPaint(painter: _LinesPainter(revenue, profit, prev, labels)));
}

class _LinesPainter extends CustomPainter {
  _LinesPainter(this.rev, this.prof, this.prev, this.labels);
  final List<double> rev, prof, prev;
  final List<String> labels;

  @override
  void paint(Canvas c, Size s) {
    final h = s.height - 16;
    final n = math.max(rev.length, prev.length);
    if (n < 2) return;
    final mx = niceMax([...rev, ...prof, ...prev, 1.0].reduce(math.max));
    double x(int i) => 2 + i * (s.width - 6) / (n - 1);
    double y(double v) => 4 + (h - 4) * (1 - math.max(0.0, v) / mx);
    for (final t in [0.0, 1 / 3, 2 / 3, 1.0]) {
      c.drawLine(Offset(0, y(t * mx)), Offset(s.width, y(t * mx)), Paint()..color = t == 0 ? ChartColors.axis : ChartColors.grid);
      if (t > 0) _text(c, shortMoney(t * mx), Offset(0, y(t * mx) - 12));
    }
    Path path(List<double> v) {
      final p = Path()..moveTo(x(0), y(v[0]));
      for (var i = 1; i < v.length; i++) {
        p.lineTo(x(i), y(v[i]));
      }
      return p;
    }

    void area(List<double> v, Color col, double a) {
      if (v.length < 2) return;
      final p = path(v)
        ..lineTo(x(v.length - 1), h)
        ..lineTo(x(0), h)
        ..close();
      c.drawPath(
          p,
          Paint()
            ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [col.withValues(alpha: a), col.withValues(alpha: 0.02)])
                .createShader(Offset.zero & s));
    }

    Paint stroke(Color col, double w) => Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeJoin = StrokeJoin.round;

    area(rev, ChartColors.pos, 0.18);
    area(prof, ChartColors.profit, 0.22);
    if (prev.length > 1) {
      final pp = stroke(ChartColors.prev, 1.5);
      for (var i = 1; i < prev.length; i++) {
        final a = Offset(x(i - 1), y(prev[i - 1]));
        final b = Offset(x(i), y(prev[i]));
        final d = (b - a).distance;
        final dir = (b - a) / d;
        var t = 0.0;
        while (t < d) {
          final e = math.min(t + 4, d);
          c.drawLine(a + dir * t, a + dir * e, pp);
          t = e + 3;
        }
      }
    }
    if (rev.length > 1) c.drawPath(path(rev), stroke(ChartColors.pos, 2));
    if (prof.length > 1) c.drawPath(path(prof), stroke(ChartColors.profit, 2));
    if (rev.isNotEmpty) {
      final e = Offset(x(rev.length - 1), y(rev.last));
      c.drawCircle(e, 4.5, Paint()..color = Colors.white);
      c.drawCircle(e, 3, Paint()..color = ChartColors.pos);
    }
    if (labels.isNotEmpty) _text(c, labels.first, Offset(0, h + 4));
    if (labels.length > 2) _text(c, labels[labels.length ~/ 2], Offset(s.width / 2, h + 4), align: TextAlign.center);
    if (labels.length > 1) _text(c, labels.last, Offset(s.width, h + 4), align: TextAlign.right);
  }

  @override
  bool shouldRepaint(_LinesPainter o) => o.rev != rev || o.prev != prev || o.prof != prof;
}

// ---------------------------------------------------------------- кольцо

class Donut extends StatelessWidget {
  const Donut({super.key, required this.values, required this.colors, required this.center, this.size = 120});

  final List<double> values;
  final List<Color> colors;
  final Widget center;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          CustomPaint(size: Size.square(size), painter: _DonutPainter(values, colors)),
          center,
        ]),
      );
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.v, this.colors);
  final List<double> v;
  final List<Color> colors;

  @override
  void paint(Canvas c, Size s) {
    final total = v.fold<double>(0.0, (a, b) => a + math.max(0.0, b));
    final r = s.width / 2;
    final w = r * 0.34;
    final rect = Rect.fromCircle(center: Offset(r, r), radius: r - w / 2);
    if (total <= 0) {
      c.drawArc(rect, 0, math.pi * 2, false, Paint()
        ..color = ChartColors.grid
        ..style = PaintingStyle.stroke
        ..strokeWidth = w);
      return;
    }
    var a = -math.pi / 2;
    final gap = v.where((x) => x > 0).length > 1 ? 0.03 : 0.0;
    for (var i = 0; i < v.length; i++) {
      final sweep = math.max(0.0, v[i]) / total * math.pi * 2;
      if (sweep > gap) {
        c.drawArc(rect, a + gap / 2, sweep - gap, false, Paint()
          ..color = colors[i % colors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = w);
      }
      a += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter o) => o.v != v;
}

// ---------------------------------------------------------------- кривая Парето

/// Кривая Парето по группам ABC: доля товаров → доля выручки (точки — границы групп).
class Pareto extends StatelessWidget {
  const Pareto({super.key, required this.counts, required this.shares, this.height = 96});

  final List<int> counts; // A, B, C
  final List<double> shares; // доля выручки групп, %
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(height: height + 14, width: double.infinity, child: CustomPaint(painter: _ParetoPainter(counts, shares)));
}

class _ParetoPainter extends CustomPainter {
  _ParetoPainter(this.counts, this.shares);
  final List<int> counts;
  final List<double> shares;

  @override
  void paint(Canvas c, Size s) {
    final h = s.height - 14;
    final total = counts.fold<int>(0, (a, b) => a + b);
    double x(double p) => s.width * p;
    double y(double p) => 4 + (h - 4) * (1 - p);
    final pts = <Offset>[Offset(x(0), y(0))];
    final xs = <double>[0];
    var cc = 0.0, ss = 0.0;
    for (var i = 0; i < counts.length; i++) {
      cc += total == 0 ? 0.0 : counts[i] / total;
      ss += shares[i] / 100;
      xs.add(math.min(1.0, cc));
      pts.add(Offset(x(math.min(1.0, cc)), y(math.min(1.0, ss))));
    }
    const zones = [(Color(0xFFE8F7EE), Color(0xFF067647), 'A'), (Color(0xFFFFF6E5), Color(0xFFB54708), 'B'), (Color(0xFFF4F4F5), Color(0xFF52525B), 'C')];
    for (var i = 0; i < 3 && i + 1 < xs.length; i++) {
      final l = x(xs[i]), r = x(xs[i + 1]);
      if (r - l < 1) continue;
      c.drawRect(Rect.fromLTRB(l, 4, r - 1, h), Paint()..color = zones[i].$1);
      _text(c, zones[i].$3, Offset(l + 4, h - 14), style: TextStyle(fontFamily: 'Inter', fontSize: 10, fontWeight: FontWeight.w700, color: zones[i].$2));
    }
    c.drawLine(Offset(0, h), Offset(s.width, h), Paint()..color = ChartColors.axis);
    if (total == 0) return;
    // Плавная кривая через границы групп (Катмулл—Ром без выбросов за 100%).
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = i == 0 ? pts[i] : pts[i - 1];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
      final c1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, math.max(4.0, p1.dy + (p2.dy - p0.dy) / 6));
      final c2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, math.max(4.0, p2.dy - (p3.dy - p1.dy) / 6));
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    c.drawPath(
        path,
        Paint()
          ..color = ChartColors.pos
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    final a = pts[1];
    c.drawCircle(a, 4.5, Paint()..color = Colors.white);
    c.drawCircle(a, 3, Paint()..color = ChartColors.pos);
    _text(c, '0%', Offset(0, h + 2));
    _text(c, tr('100% товаров', '100% mahsulot'), Offset(s.width, h + 2), align: TextAlign.right);
  }

  @override
  bool shouldRepaint(_ParetoPainter o) => o.counts != counts || o.shares != shares;
}

// ---------------------------------------------------------------- тепловая карта

class HeatCell {
  const HeatCell(this.weekday, this.hour, this.checks);
  final int weekday; // 1 — пн … 7 — вс
  final int hour;
  final double checks;
}

/// «Когда покупают»: дни недели × двухчасовые отрезки.
class Heatmap extends StatelessWidget {
  const Heatmap({super.key, required this.cells, required this.slots, this.peak});

  final List<HeatCell> cells;
  final List<int> slots; // начало двухчасовых отрезков: 8, 10, …
  final HeatCell? peak;

  static List<String> get days => tr('Пн Вт Ср Чт Пт Сб Вс', 'Du Se Ch Pa Ju Sh Ya').split(' ');

  double _sum(int d, int from) => cells.where((c) => c.weekday == d && c.hour >= from && c.hour < from + 2).fold(0.0, (a, c) => a + c.checks);

  @override
  Widget build(BuildContext context) {
    var mx = 1.0;
    for (var d = 1; d <= 7; d++) {
      for (final s in slots) {
        mx = math.max(mx, _sum(d, s));
      }
    }
    Widget row(int d) => Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(children: [
            SizedBox(width: 22, child: Text(days[d - 1], style: AppText.caption.copyWith(fontSize: 10, fontWeight: FontWeight.w500))),
            for (final s in slots)
              Expanded(
                child: Container(
                  height: 22,
                  margin: const EdgeInsets.only(right: 3),
                  decoration: BoxDecoration(
                    color: ChartColors.heat[math.min(5, (_sum(d, s) / mx * 5.999).floor())],
                    borderRadius: BorderRadius.circular(4),
                    border: peak != null && peak!.weekday == d && peak!.hour >= s && peak!.hour < s + 2 ? Border.all(color: AppColors.ink, width: 2) : null,
                  ),
                ),
              ),
          ]),
        );
    return Column(children: [
      for (var d = 1; d <= 7; d++) row(d),
      Row(children: [
        const SizedBox(width: 22),
        for (final s in slots) Expanded(child: Text('$s', textAlign: TextAlign.center, style: _axisText)),
      ]),
    ]);
  }
}
