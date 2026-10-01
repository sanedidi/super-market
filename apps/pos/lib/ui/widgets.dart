import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/pos.dart';
import 'theme.dart';

/// Белая карточка-панель.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20), this.color = C.surface, this.border});

  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
          border: border == null ? null : Border.all(color: border!, width: 2),
        ),
        child: child,
      );
}

/// Клавиша на карточке: «Enter», «*», «F5».
class KeyBadge extends StatelessWidget {
  const KeyBadge(this.label, {super.key, this.dark = false, this.size = 56});

  final String label;
  final bool dark;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size * 0.8,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: dark ? Colors.white.withValues(alpha: 0.18) : C.keyBg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: t(label.length > 2 ? 15 : 18, w: FontWeight.w700, c: dark ? Colors.white : C.tp)),
      );
}

enum KeyCardStyle { normal, primary, active, dim }

/// Действие с клавишей: клавиша, название, подсказка. Нажимается и мышкой/пальцем.
class KeyCard extends StatelessWidget {
  const KeyCard({
    super.key,
    required this.keyLabel,
    required this.title,
    this.subtitle = '',
    this.style = KeyCardStyle.normal,
    this.onTap,
  });

  final String keyLabel;
  final String title;
  final String subtitle;
  final KeyCardStyle style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final primary = style == KeyCardStyle.primary;
    final (bg, border) = switch (style) {
      KeyCardStyle.primary => (C.brand, C.brand),
      KeyCardStyle.active => (C.brandSoft, C.brand),
      KeyCardStyle.dim => (C.surface, C.surface),
      KeyCardStyle.normal => (C.surface, C.border),
    };
    final card = Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border, width: style == KeyCardStyle.active ? 2 : 1),
          ),
          child: Row(children: [
            KeyBadge(keyLabel, dark: primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: t(17, w: FontWeight.w700, c: primary ? Colors.white : C.tp)),
                if (subtitle.isNotEmpty)
                  Text(subtitle, style: t(12, c: primary ? Colors.white.withValues(alpha: 0.9) : C.ts)),
              ]),
            ),
          ]),
        ),
      ),
    );
    return style == KeyCardStyle.dim ? Opacity(opacity: 0.4, child: card) : card;
  }
}

/// Верхняя строка: касса, смена, кассир, связь, фискальный модуль, очередь.
class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    final s = pos.catalog.settings;
    final shift = pos.shift;
    final shiftText = [
      if (shift != null) 'Смена ${shift.number ?? '·'}',
      if (pos.cashier != null) pos.cashier!.name,
    ].join(' · ');
    return Container(
      height: 48,
      color: C.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        Text('${s.deviceName} · ${s.storeName}', style: t(15, w: FontWeight.w700)),
        const SizedBox(width: 16),
        Text(shiftText, style: t(13, c: C.ts)),
        const Spacer(),
        if (pos.revoked) const _Dot('Касса отключена в панели', C.error),
        _Dot(pos.online ? 'Онлайн' : 'Нет связи', pos.online ? C.success : C.warning),
        const SizedBox(width: 16),
        _Dot(pos.fiscalMode ? 'ФМ' : 'Тестовый режим', pos.fiscalMode ? C.success : C.warning),
        const SizedBox(width: 16),
        _Dot('Очередь ${pos.queue}', pos.queue == 0 ? C.td : C.warning),
        if (pos.failed > 0) ...[
          const SizedBox(width: 16),
          _Dot('Не принято ${pos.failed}', C.error),
        ],
      ]),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: t(13, w: FontWeight.w500, c: color == C.td ? C.ts : color)),
      ]);
}

/// Ловит клавиатуру и сканер для всего экрана. [onKey] получает событие
/// нажатия (и автоповтора) и возвращает true, если обработал.
class KeyCatcher extends StatelessWidget {
  const KeyCatcher({super.key, required this.onKey, required this.child, this.focusNode});

  final bool Function(KeyEvent e) onKey;
  final Widget child;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: focusNode,
        autofocus: true,
        onKeyEvent: (node, e) {
          if (e is KeyUpEvent) return KeyEventResult.ignored;
          return onKey(e) ? KeyEventResult.handled : KeyEventResult.ignored;
        },
        child: child,
      );
}

/// Печатаемый символ события (цифры, буквы, знаки) или null.
String? printable(KeyEvent e) {
  final ch = e.character;
  if (ch == null || ch.isEmpty) return null;
  final code = ch.codeUnitAt(0);
  if (code < 32 && code != 0x1d) return null; // управляющие, кроме GS из DataMatrix
  if (code == 127) return null;
  return ch;
}

bool isEnter(KeyEvent e) => e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter;

/// Цифровая клавиатура на экране — для планшета и мышки.
class NumPad extends StatelessWidget {
  const NumPad({super.key, required this.onDigit, required this.onBackspace, this.extra});

  final void Function(String d) onDigit;
  final VoidCallback onBackspace;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.all(6),
          child: Material(
            color: C.surface,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: SizedBox(width: 76, height: 52, child: Center(child: Text(label, style: t(22, w: FontWeight.w500)))),
            ),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
      ])
        Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d, () => onDigit(d))]),
      Row(mainAxisSize: MainAxisSize.min, children: [
        extra ?? const SizedBox(width: 88),
        key('0', () => onDigit('0')),
        key('⌫', onBackspace),
      ]),
    ]);
  }
}
