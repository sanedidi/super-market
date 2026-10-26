import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

// Общие детали кассы V1 («Красная шапка»): размер экрана, текст без обрезания,
// список без полосы прокрутки, кнопка-плитка. Правила из Figma
// («V1 · Красная шапка — маленькие экраны»): экран не прокручивается, слова не
// обрезаются «…», длинный чек листается по целым строкам.

/// Размер экрана кассы: S — до 1200 px (1024×768), M — 1280–1366×768,
/// L — 1440×900 и больше.
enum Density { s, m, l }

Density densityOf(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  if (size.width < 1200) return Density.s;
  if (size.width >= 1400 && size.height >= 860) return Density.l;
  return Density.m;
}

/// Текст, который не обрезается: если не влезает в [maxLines] строк,
/// шрифт уменьшается до [minSize]. Многоточие — только если и так не влезло.
class FitText extends StatelessWidget {
  const FitText(this.text, {super.key, required this.style, this.maxLines = 1, this.minSize = 11, this.textAlign = TextAlign.start});

  final String text;
  final TextStyle style;
  final int maxLines;
  final double minSize;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        var size = style.fontSize ?? 14;
        if (c.maxWidth.isFinite) {
          final base = DefaultTextStyle.of(context).style;
          final dir = Directionality.of(context);
          final scaler = MediaQuery.textScalerOf(context);
          while (size > minSize) {
            final tp = TextPainter(
              text: TextSpan(text: text, style: base.merge(style.copyWith(fontSize: size))),
              maxLines: maxLines,
              textDirection: dir,
              textScaler: scaler,
            )..layout(maxWidth: c.maxWidth);
            final fits = !tp.didExceedMaxLines && (!c.maxHeight.isFinite || tp.height <= c.maxHeight + 0.5);
            tp.dispose();
            if (fits) break;
            size -= 1;
          }
        }
        return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, textAlign: textAlign, style: style.copyWith(fontSize: size));
      });
}

/// Прокрутка без полосы и без «резинки»; пальцем, мышью и колесом.
class NoBarScroll extends MaterialScrollBehavior {
  const NoBarScroll();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) => child;

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

/// Листание, которое всегда останавливается на целой строке высотой [extent].
class SnapPhysics extends ScrollPhysics {
  const SnapPhysics({required this.extent, super.parent});

  final double extent;

  @override
  SnapPhysics applyTo(ScrollPhysics? ancestor) => SnapPhysics(extent: extent, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    final tolerance = toleranceFor(position);
    final projected = position.pixels + velocity * 0.2;
    final target = ((projected / extent).round() * extent).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if ((target - position.pixels).abs() < tolerance.distance && velocity.abs() < tolerance.velocity) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity, tolerance: tolerance);
  }

  @override
  bool get allowImplicitScrolling => false;
}

/// Список строк одной высоты без полосы прокрутки (Figma «Длинный чек»).
/// Если строки не помещаются — сверху «▲ Ещё N выше», снизу «▼ Ещё N ниже»;
/// нажатие на полосу листает на экран. Строка [focus] всегда видна: новый
/// товар со сканера показывает низ списка.
class SnapList extends StatefulWidget {
  const SnapList({
    super.key,
    required this.count,
    required this.extent,
    required this.itemBuilder,
    required this.above,
    required this.below,
    this.focus,
    this.startLabel = '',
    this.endLabel = '',
  });

  final int count;
  final double extent;
  final IndexedWidgetBuilder itemBuilder;
  final int? focus;

  /// Подписи полос: «Ещё 14 позиций выше».
  final String Function(int n) above;
  final String Function(int n) below;

  /// Подписи, когда листать дальше некуда: «Начало чека», «Конец чека».
  final String startLabel;
  final String endLabel;

  @override
  State<SnapList> createState() => _SnapListState();
}

class _SnapListState extends State<SnapList> {
  static const _bar = 32.0;
  final _ctrl = ScrollController();
  int? _lastFocus;
  int _lastCount = -1;
  int _visible = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onScroll);
    _ctrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  int get _first => _ctrl.hasClients ? (_ctrl.offset / widget.extent).round() : 0;

  int get _maxFirst => math.max(0, widget.count - _visible);

  void _go(int first) {
    if (!_ctrl.hasClients) return;
    final to = (first.clamp(0, _maxFirst) * widget.extent).toDouble();
    if ((to - _ctrl.offset).abs() < 0.5) return;
    _ctrl.animateTo(to, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  /// После прокрутки колесом мыши — доводим до целой строки.
  bool _onEnd(ScrollEndNotification n) {
    if (!_ctrl.hasClients) return false;
    final rem = _ctrl.offset % widget.extent;
    if (rem > 0.5 && widget.extent - rem > 0.5) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _go(_first));
    }
    return false;
  }

  void _keepFocusVisible(bool overflow) {
    final f = widget.focus;
    final changed = f != _lastFocus || widget.count != _lastCount;
    _lastFocus = f;
    _lastCount = widget.count;
    if (!changed || f == null || !overflow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ctrl.hasClients) return;
      final first = _first;
      if (f < first) {
        _go(f);
      } else if (f >= first + _visible) {
        _go(f - _visible + 1);
      }
    });
  }

  Widget _barWidget(String text, IconData icon, bool active, VoidCallback onTap) => Material(
        color: active ? C.brandSoft : C.subtle,
        child: InkWell(
          onTap: active ? onTap : null,
          child: SizedBox(
            height: _bar,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Icon(icon, size: 16, color: active ? C.brand : C.td),
                const SizedBox(width: 8),
                Expanded(child: FitText(text, style: t(13, w: FontWeight.w600, c: active ? C.brand : C.td))),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final ext = widget.extent;
        final avail = c.maxHeight;
        final overflow = widget.count * ext > avail + 0.5;
        if (!overflow) {
          _visible = widget.count;
          _keepFocusVisible(false);
          if (_ctrl.hasClients && _ctrl.offset != 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_ctrl.hasClients) _ctrl.jumpTo(0);
            });
          }
          return ListView.builder(
            controller: _ctrl,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemExtent: ext,
            itemCount: widget.count,
            itemBuilder: widget.itemBuilder,
          );
        }
        _visible = math.max(1, ((avail - 2 * _bar) / ext).floor());
        _keepFocusVisible(true);
        final first = _first.clamp(0, _maxFirst);
        final above = first;
        final below = math.max(0, widget.count - first - _visible);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _barWidget(above > 0 ? widget.above(above) : widget.startLabel, Icons.keyboard_double_arrow_up_rounded, above > 0,
              () => _go(first - _visible)),
          SizedBox(
            height: _visible * ext,
            child: ScrollConfiguration(
              behavior: const NoBarScroll(),
              child: NotificationListener<ScrollEndNotification>(
                onNotification: _onEnd,
                child: ListView.builder(
                  controller: _ctrl,
                  physics: SnapPhysics(extent: ext, parent: const ClampingScrollPhysics()),
                  padding: EdgeInsets.zero,
                  itemExtent: ext,
                  itemCount: widget.count,
                  itemBuilder: widget.itemBuilder,
                ),
              ),
            ),
          ),
          const Spacer(),
          _barWidget(below > 0 ? widget.below(below) : widget.endLabel, Icons.keyboard_double_arrow_down_rounded, below > 0,
              () => _go(first + _visible)),
        ]);
      });
}

/// Кнопка-плитка: название и подсказка (клавиша), как в REGOS.
class PosButton extends StatelessWidget {
  const PosButton({
    super.key,
    required this.label,
    this.hint = '',
    this.onTap,
    this.enabled = true,
    this.bg = C.surface,
    this.fg = C.tp,
    this.hintColor = C.td,
    this.border = C.borderStrong,
    this.icon,
    this.iconColor,
    this.height,
    this.center = false,
    this.labelSize = 14,
  });

  final String label;
  final String hint;
  final VoidCallback? onTap;
  final bool enabled;
  final Color bg;
  final Color fg;
  final Color hintColor;
  final Color? border;
  final IconData? icon;
  final Color? iconColor;
  final double? height;
  final bool center;
  final double labelSize;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FitText(label, style: t(labelSize, w: FontWeight.w600, c: fg), textAlign: center ? TextAlign.center : TextAlign.start),
        if (hint.isNotEmpty) FitText(hint, style: t(11.5, w: FontWeight.w500, c: hintColor), textAlign: center ? TextAlign.center : TextAlign.start),
      ],
    );
    final body = icon == null
        ? text
        : center
            ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 22, color: iconColor ?? fg),
                const SizedBox(height: 2),
                text,
              ])
            : Row(children: [
                Icon(icon, size: 20, color: iconColor ?? fg),
                const SizedBox(width: 10),
                Expanded(child: text),
              ]);
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: border == null ? null : Border.all(color: border!),
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// Логотип-надпись «Super Market» шрифтом логотипа.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 18, this.color = Colors.white});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Text('Super Market', maxLines: 1, softWrap: false, style: tb(size, c: color, h: 1));
}

/// Кнопки «−» N «+» прямо в строке чека (Figma «Касса · Кол-во в строке чека»).
/// Кнопки [size]×[size] с зазором под число между ними — палец не перескакивает
/// на соседнюю. Нажатая — красная; `null` в [onMinus]/[onPlus] — неактивна.
/// Удержание ≥ 400 мс — автоповтор каждые 150 мс.
class QtyStepper extends StatelessWidget {
  const QtyStepper({
    super.key,
    required this.value,
    required this.onMinus,
    required this.onPlus,
    this.size = 44,
    this.width = 150,
    this.fontSize = 18,
  });

  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final double size;
  final double width;
  final double fontSize;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: size,
        child: Row(children: [
          _StepButton('−', size: size, onTap: onMinus),
          Expanded(child: FitText(value, textAlign: TextAlign.center, style: t(fontSize, w: FontWeight.w600))),
          _StepButton('+', size: size, onTap: onPlus),
        ]),
      );
}

class _StepButton extends StatefulWidget {
  const _StepButton(this.symbol, {required this.size, required this.onTap});

  final String symbol;
  final double size;
  final VoidCallback? onTap;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  bool _pressed = false;
  Timer? _repeat;

  void _down(TapDownDetails _) => setState(() => _pressed = true);

  void _up() {
    _repeat?.cancel();
    _repeat = null;
    if (mounted && _pressed) setState(() => _pressed = false);
  }

  void _hold(LongPressStartDetails _) {
    // Долгое нажатие отменяет обычный tap — срабатываем сами и повторяем.
    setState(() => _pressed = true);
    widget.onTap?.call();
    _repeat?.cancel();
    _repeat = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (widget.onTap == null) {
        _up();
        return;
      }
      widget.onTap!();
    });
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final bg = _pressed && enabled ? C.brand : C.surface;
    final fg = !enabled
        ? C.border
        : _pressed
            ? Colors.white
            : C.tp;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? _down : null,
      onTapUp: enabled ? (_) => _up() : null,
      onTapCancel: enabled ? _up : null,
      onTap: widget.onTap,
      onLongPressStart: enabled ? _hold : null,
      onLongPressEnd: enabled ? (_) => _up() : null,
      onLongPressCancel: enabled ? _up : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: widget.size,
        height: widget.size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: enabled ? (_pressed ? C.brand : C.border) : C.subtle),
        ),
        child: Text(widget.symbol, style: t(widget.size * 0.5, w: FontWeight.w600, c: fg, h: 1)),
      ),
    );
  }
}
