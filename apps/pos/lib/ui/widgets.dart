import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/limits.dart';
import '../state/pos.dart';
import 'theme.dart';

/// Логотип Super Market (тот же, что у приложения покупателя).
class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.asset('assets/logo.png', width: size, height: size, filterQuality: FilterQuality.medium),
      );
}

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
      if (shift != null) tr('Смена ${shift.number ?? '·'}', 'Smena ${shift.number ?? '·'}'),
      if (pos.cashier != null) pos.cashier!.name,
    ].join(' · ');
    return Container(
      height: 48,
      color: C.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        const Logo(size: 28),
        const SizedBox(width: 12),
        Text('${s.deviceName} · ${s.storeName}', style: t(15, w: FontWeight.w700)),
        const SizedBox(width: 16),
        Text(shiftText, style: t(13, c: C.ts)),
        const Spacer(),
        if (pos.revoked) _Dot(tr('Касса отключена в панели', 'Kassa panelda oʻchirilgan'), C.error),
        if (pos.printError != null) ...[
          Tooltip(message: pos.printError!, child: _Dot(tr('Принтер', 'Printer'), C.error)),
          const SizedBox(width: 16),
        ],
        _connection(pos),
        const SizedBox(width: 16),
        _Dot(pos.fiscalMode ? tr('ФМ', 'FM') : tr('Тестовый режим', 'Test rejimi'), pos.fiscalMode ? C.success : C.warning),
        const SizedBox(width: 16),
        _Dot(tr('Очередь ${pos.queue}', 'Navbat ${pos.queue}'), pos.queue == 0 ? C.td : C.warning),
        if (pos.failed > 0) ...[
          const SizedBox(width: 16),
          _Dot(tr('Не принято ${pos.failed}', 'Qabul qilinmagan ${pos.failed}'), C.error),
        ],
      ]),
    );
  }
}

Widget _connection(PosController pos) {
  final off = pos.offlineLimit;
  if (pos.online && off.state != LimitState.warn) return _Dot(tr('Онлайн', 'Onlayn'), C.success);
  if (off.state == LimitState.ok) return _Dot(tr('Нет связи', 'Aloqa yoʻq'), C.warning);
  return _Dot(tr('Нет связи ${fmtDuration(off.age)}', 'Aloqa yoʻq ${fmtDuration(off.age)}'), C.error);
}

/// Полоса под верхней строкой: смена скоро 24 часа или касса давно без связи
/// (Figma «POS · Смена скоро 24 часа», «POS · Нет связи 3 часа»).
class LimitBanner extends StatelessWidget {
  const LimitBanner({super.key, this.onCloseShift});

  final VoidCallback? onCloseShift;

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    final sh = pos.shiftLimit;
    if (sh != null && sh.state == LimitState.warn) {
      return _Banner(
        icon: Icons.schedule_rounded,
        bg: C.warningSoft,
        fg: C.warning,
        title: tr('Смена идёт ${fmtDuration(sh.age)}.', 'Smena ${fmtDuration(sh.age)} davom etmoqda.'),
        text: tr('Через ${fmtDuration(sh.left)} касса перестанет продавать — закройте смену и напечатайте Z-отчёт.',
            '${fmtDuration(sh.left)} dan keyin kassa sotishni toʻxtatadi — smenani yoping va Z-hisobotni chop eting.'),
        action: tr('Закрыть смену · F11', 'Smenani yopish · F11'),
        onAction: onCloseShift,
      );
    }
    final off = pos.offlineLimit;
    if (off.state == LimitState.warn) {
      return _Banner(
        icon: Icons.wifi_off_rounded,
        bg: const Color(0xFFEFF8FF),
        fg: const Color(0xFF175CD3),
        title: tr('Нет связи ${fmtDuration(off.age)}.', 'Aloqa yoʻq: ${fmtDuration(off.age)}.'),
        text: tr(
            'Продавать можно: ${off.queue} ${_plural(off.queue, 'чек сохранён', 'чека сохранены', 'чеков сохранены')} в кассе и уйдут сами. '
                'Без связи — ещё ${fmtDuration(off.left)}.',
            'Sotish mumkin: ${off.queue} ta chek kassada saqlangan va oʻzi yuboriladi. '
                'Aloqasiz yana ${fmtDuration(off.left)} ishlash mumkin.'),
        action: tr('Проверить связь', 'Aloqani tekshirish'),
        onAction: () => pos.sync(catalog: true),
      );
    }
    return const SizedBox.shrink();
  }
}

String _plural(int n, String one, String few, String many) {
  final m = n % 100;
  if (m >= 11 && m <= 14) return many;
  return switch (n % 10) { 1 => one, 2 || 3 || 4 => few, _ => many };
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.bg, required this.fg, required this.title, required this.text, this.action, this.onAction});

  final IconData icon;
  final Color bg;
  final Color fg;
  final String title;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(children: [
          Icon(icon, color: fg, size: 22),
          const SizedBox(width: 12),
          Text(title, style: t(15, w: FontWeight.w600, c: fg)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: t(14), maxLines: 2, overflow: TextOverflow.ellipsis)),
          if (action != null) ...[
            const SizedBox(width: 12),
            Material(
              color: C.surface,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onAction,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(action!, style: t(13, w: FontWeight.w600, c: fg)),
                ),
              ),
            ),
          ],
        ]),
      );
}

/// Окно поверх продажи, когда продавать нельзя: смена дольше 24 часов или
/// касса без связи больше суток (Figma «… — продажи остановлены»).
class LimitLock extends StatelessWidget {
  const LimitLock({super.key, required this.onCloseShift, required this.onChangeCashier});

  final VoidCallback onCloseShift;
  final VoidCallback onChangeCashier;

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    final sh = pos.shiftLimit;
    final off = pos.offlineLimit;
    final shiftBlocked = sh != null && sh.state == LimitState.blocked;
    if (!shiftBlocked && off.state != LimitState.blocked) return const SizedBox.shrink();
    String hm(DateTime d) {
      final l = d.toLocal();
      final now = DateTime.now();
      final day = l.year == now.year && l.month == now.month && l.day == now.day ? tr('сегодня', 'bugun') : tr('вчера', 'kecha');
      return '$day ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
    }

    final (icon, title, text, rows, primary, onPrimary, secondary) = shiftBlocked
        ? (
            Icons.lock_clock_rounded,
            tr('Смена идёт больше 24 часов', 'Smena 24 soatdan oshdi'),
            tr('По закону смена кассы не может длиться дольше 24 часов. Закройте смену — напечатается Z-отчёт, и следующий кассир откроет новую.',
                'Qonunga koʻra kassa smenasi 24 soatdan oshmasligi kerak. Smenani yoping — Z-hisobot chop etiladi va keyingi kassir yangisini ochadi.'),
            [
              (tr('Смена ${pos.shift!.number ?? ''} открыта', 'Smena ${pos.shift!.number ?? ''} ochilgan'), hm(pos.shift!.openedAt)),
              (tr('Чеков за смену', 'Smenadagi cheklar'), '${pos.report.salesCount}'),
              (tr('Отложенные чеки', 'Kechiktirilgan cheklar'), tr('сохранятся', 'saqlanib qoladi')),
            ],
            tr('Закрыть смену · Enter', 'Smenani yopish · Enter'),
            onCloseShift,
            tr('Сменить кассира', 'Kassirni almashtirish'),
          )
        : (
            Icons.cloud_off_rounded,
            tr('Касса без связи больше 24 часов', 'Kassa 24 soatdan ortiq aloqasiz'),
            tr('Чеки нельзя хранить в кассе дольше суток — их нужно отправить в ОФД. Подключите интернет: продажи откроются сами, как только очередь уйдёт.',
                'Cheklarni kassada bir sutkadan ortiq saqlab boʻlmaydi — ularni OFDga yuborish kerak. Internetga ulaning: navbat yuborilishi bilan sotuv oʻzi ochiladi.'),
            [
              (tr('Чеков ждут отправки', 'Yuborilishini kutayotgan cheklar'), '${off.queue}'),
              if (off.since != null) (tr('Самый старый', 'Eng eskisi'), hm(off.since!)),
            ],
            tr('Проверить связь · Enter', 'Aloqani tekshirish · Enter'),
            () {
              pos.sync(catalog: true);
            },
            null,
          );
    return Positioned.fill(
      child: Container(
        color: const Color(0x8C0F1729),
        alignment: Alignment.center,
        child: Container(
          width: 600,
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 28),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(24)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(color: C.errorSoft, shape: BoxShape.circle),
              child: Icon(icon, color: C.brand, size: 30),
            ),
            const SizedBox(height: 16),
            Text(title, style: t(26, w: FontWeight.w700)),
            const SizedBox(height: 16),
            Text(text, style: t(16, c: C.ts)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(color: C.page, borderRadius: BorderRadius.circular(14)),
              child: Column(children: [
                for (final (k, v) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(child: Text(k, style: t(15, c: C.ts))),
                      Text(v, style: t(15, w: FontWeight.w600)),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: _LockButton(label: primary, primary: true, onTap: onPrimary)),
              if (secondary != null) ...[
                const SizedBox(width: 12),
                _LockButton(label: secondary, primary: false, onTap: onChangeCashier),
              ],
            ]),
          ]),
        ),
      ),
    );
  }
}

class _LockButton extends StatelessWidget {
  const _LockButton({required this.label, required this.primary, required this.onTap});

  final String label;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: primary ? C.brand : C.page,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Center(child: Text(label, style: t(17, w: FontWeight.w600, c: primary ? Colors.white : C.tp))),
          ),
        ),
      );
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
