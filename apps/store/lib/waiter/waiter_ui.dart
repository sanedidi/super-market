import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

// Цвета и мелкие детали экранов официанта — как в Figma «Кафе» → страница
// «Официант · телефон» (О1–О12): светлая тема, серый фон, красный акцент,
// зелёный «готово», оранжевый «по команде / готовится».

abstract final class WC {
  static const bg = Color(0xFFF2F4F7); // gray-100
  static const gray50 = Color(0xFFF9FAFB);
  static const gray200 = Color(0xFFEAECF0);
  static const gray300 = Color(0xFFD0D5DD);
  static const gray400 = Color(0xFF98A2B3);
  static const gray500 = Color(0xFF667085);
  static const gray600 = Color(0xFF475467);
  static const gray700 = Color(0xFF344054);
  static const ink = Color(0xFF101828);
  static const white = Color(0xFFFFFFFF);
  static const red = Color(0xFFE11D2A);
  static const red50 = Color(0xFFFEF3F2);
  static const red100 = Color(0xFFFEE4E2);
  static const green = Color(0xFF039855);
  static const green50 = Color(0xFFECFDF3);
  static const green700 = Color(0xFF027A48);
  static const orange = Color(0xFFDC6803);
  static const orange50 = Color(0xFFFFFAEB);
  static const blue = Color(0xFF155EEF);
  static const blue50 = Color(0xFFEFF4FF);

  /// Цвета кружков официантов (О6, О8): по порядку в списке.
  static const avatars = [red, blue, green, orange, Color(0xFF7A5AF8), Color(0xFF0E9384), Color(0xFFDD2590)];

  /// Фон значка блюда без фото — тёплые оттенки, как в макете.
  static const dishTints = [Color(0xFFF6E7D3), Color(0xFFFCE9B8), Color(0xFFF7E3D0), Color(0xFFF3E0C4), Color(0xFFF2D3C9)];
}

/// Inter заданного размера и веса (цвет по умолчанию — ink).
TextStyle wt(double size, {FontWeight w = FontWeight.w500, Color c = WC.ink, double? height}) =>
    TextStyle(fontFamily: 'Inter', fontSize: size, fontWeight: w, color: c, height: height);

const w4 = FontWeight.w400;
const w5 = FontWeight.w500;
const w6 = FontWeight.w600;
const w7 = FontWeight.w700;
const w8 = FontWeight.w800;

/// «296 000» — деньги без «сум», как в макете.
String sum(Object? v) => money(v, suffix: false);

/// «22 мин», «1 ч 05 мин».
String elapsed(DateTime since, [DateTime? now]) {
  final m = (now ?? DateTime.now()).difference(since).inMinutes.clamp(0, 99999);
  if (m < 60) return tr('$m мин', '$m daq');
  final h = m ~/ 60, mm = (m % 60).toString().padLeft(2, '0');
  return tr('$h ч $mm мин', '$h soat $mm daq');
}

/// «12:05».
String hhmm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// «4 гостя» / «4 mehmon».
String guestsLabel(int n) {
  if (Lang.instance.code == Lang.uz) return '$n mehmon';
  final n10 = n % 10, n100 = n % 100;
  final w = n10 == 1 && n100 != 11
      ? 'гость'
      : (n10 >= 2 && n10 <= 4 && (n100 < 10 || n100 >= 20))
          ? 'гостя'
          : 'гостей';
  return '$n $w';
}

/// Гость Г1…Г9: «Г3» / «M3».
String guestTag(int g) => tr('Г$g', 'M$g');

/// Первая буква имени для кружка.
String initial(String name) {
  final s = name.trim();
  return s.isEmpty ? '—' : s.characters.first.toUpperCase();
}

/// Круглая белая кнопка 44 в шапке (назад, ⋯, колокольчик).
class WRoundButton extends StatelessWidget {
  const WRoundButton(this.icon, {super.key, this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final b = Material(
      color: WC.white,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 22, color: WC.ink)),
      ),
    );
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

/// Шапка экрана: кнопка слева, заголовок 19 и подзаголовок 12, кнопка справа.
class WHeader extends StatelessWidget {
  const WHeader({super.key, required this.title, this.subtitle, this.leading, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: wt(19, w: w7), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (subtitle != null && subtitle!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(subtitle!, style: wt(12, c: WC.gray500), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ]),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ]),
    );
  }
}

/// Кружок с буквой: официант, «стол будет вашим».
class WAvatar extends StatelessWidget {
  const WAvatar(this.name, {super.key, this.color = WC.red, this.size = 44, this.fontSize});

  final String name;
  final Color color;
  final double size;
  final double? fontSize;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Text(initial(name), style: wt(fontSize ?? size * 0.41, w: w7, c: WC.white)),
      );
}

/// Плашка-статус с иконкой: «готово — заберите», «готовится · 9 мин», «выдано».
class WPill extends StatelessWidget {
  const WPill(this.label, {super.key, this.icon, this.fg = WC.gray500, this.bg = WC.bg});

  final String label;
  final IconData? icon;
  final Color fg;
  final Color bg;

  factory WPill.ready(String label) => WPill(label, icon: Icons.room_service_rounded, fg: WC.green, bg: WC.green50);
  factory WPill.cooking(String label) => WPill(label, icon: Icons.timer_rounded, fg: WC.orange, bg: WC.orange50);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(7, 3, 8, 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(7)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 3)],
          Text(label, style: wt(11, w: w7, c: fg)),
        ]),
      );
}

/// Метка гостя под блюдом: «Г1», «Г3 × 2», «всем» (синяя).
class WGuestTag extends StatelessWidget {
  const WGuestTag(this.label, {super.key, this.active = false, this.all = false});

  final String label;
  final bool active;
  final bool all;

  @override
  Widget build(BuildContext context) {
    final bg = active ? WC.red : (all ? WC.blue50 : WC.bg);
    final fg = active ? WC.white : (all ? WC.blue : WC.gray600);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
      child: Text(label, style: wt(11, w: w7, c: fg)),
    );
  }
}

/// «2×» в сером квадратике слева от блюда.
class WQtyBox extends StatelessWidget {
  const WQtyBox(this.qty, {super.key});

  final String qty;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: WC.bg, borderRadius: BorderRadius.circular(6)),
        child: Text('$qty×', style: wt(12, w: w7)),
      );
}

/// − N + в белой рамке (новые блюда в счёте, меню, шторка).
class WStepper extends StatelessWidget {
  const WStepper({super.key, required this.value, required this.onMinus, required this.onPlus, this.big = false, this.border = WC.red100, this.iconColor = WC.red});

  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final bool big;
  final Color border;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final icon = big ? 22.0 : 18.0;
    Widget tap(IconData i, VoidCallback? f) => InkResponse(
          onTap: f,
          radius: 22,
          child: Padding(padding: const EdgeInsets.all(4), child: Icon(i, size: icon, color: f == null ? WC.gray300 : iconColor)),
        );
    return Container(
      height: big ? 54 : null,
      padding: EdgeInsets.symmetric(horizontal: big ? 6 : 2, vertical: big ? 0 : 0),
      decoration: BoxDecoration(color: WC.white, border: Border.all(color: border), borderRadius: BorderRadius.circular(big ? 14 : 10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        tap(Icons.remove_rounded, onMinus),
        SizedBox(width: big ? 6 : 2),
        Text(value, style: wt(big ? 18 : 14, w: w7)),
        SizedBox(width: big ? 6 : 2),
        tap(Icons.add_rounded, onPlus),
      ]),
    );
  }
}

/// Большая кнопка 54–56: красная, синяя, оранжевая или белая с рамкой.
class WButton extends StatelessWidget {
  const WButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.color = WC.red,
    this.fg = WC.white,
    this.outline = false,
    this.height = 54,
    this.busy = false,
    this.leading,
    this.trailing,
    this.fontSize = 16,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color color;
  final Color fg;
  final bool outline;
  final double height;
  final bool busy;
  final Widget? leading;
  final Widget? trailing;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    final bg = outline ? WC.white : (enabled || busy ? color : WC.gray200);
    final textColor = outline ? fg : (enabled || busy ? fg : WC.gray400);
    return SizedBox(
      height: height,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: outline ? const BorderSide(color: WC.gray300) : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: busy
                ? Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: textColor)))
                : LayoutBuilder(builder: (context, c) {
                    final text = Text(label, style: wt(fontSize, w: w7, c: textColor), maxLines: 1, overflow: TextOverflow.ellipsis);
                    // Без ширины (кнопка в строке рядом с Expanded) — по содержимому.
                    if (!c.hasBoundedWidth) {
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        if (icon != null) ...[Icon(icon, size: 22, color: textColor), const SizedBox(width: 8)],
                        text,
                      ]);
                    }
                    return Row(mainAxisAlignment: trailing == null ? MainAxisAlignment.center : MainAxisAlignment.start, children: [
                      if (leading != null) ...[leading!, const SizedBox(width: 10)],
                      if (icon != null) ...[Icon(icon, size: 22, color: textColor), const SizedBox(width: 8)],
                      Flexible(child: text),
                      if (trailing != null) ...[const Spacer(), trailing!],
                    ]);
                  }),
          ),
        ),
      ),
    );
  }
}

/// Белая карточка со скруглением 16 и необязательной рамкой.
class WCard extends StatelessWidget {
  const WCard({super.key, required this.child, this.color = WC.white, this.border, this.padding = const EdgeInsets.fromLTRB(14, 12, 14, 12), this.onTap, this.radius = 16, this.borderWidth = 1});

  final Widget child;
  final Color color;
  final Color? border;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final double radius;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: border == null ? BorderSide.none : BorderSide(color: border!, width: borderWidth),
    );
    return Material(
      color: color,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// Заголовок секции карточки: иконка + КАПС 11 («НА КУХНЕ», «НОВЫЕ · …»).
class WSectionTitle extends StatelessWidget {
  const WSectionTitle(this.label, {super.key, required this.icon, this.color = WC.gray500, this.trailing});

  final String label;
  final IconData icon;
  final Color color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(label, style: wt(11, w: w7, c: color), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (trailing != null) ...[const Spacer(), trailing!],
        ]),
      );
}

/// Подсказка с иконкой ⓘ.
class WHint extends StatelessWidget {
  const WHint(this.text, {super.key, this.icon = Icons.info_rounded, this.center = false, this.size = 11});

  final String text;
  final IconData icon;
  final bool center;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 14, color: WC.gray400)),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: wt(size, c: WC.gray500), textAlign: center ? TextAlign.center : TextAlign.start)),
        ],
      );
}

/// Белая нижняя панель с кнопками (над «домашней» полоской).
class WBottomBar extends StatelessWidget {
  const WBottomBar({super.key, required this.children, this.gap = 10});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Container(
        color: WC.white,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: gap), children[i]],
            ]),
          ),
        ),
      );
}

/// Чип-переключатель: «Всем», «Г3», группы меню, причины передачи.
class WChoiceChip extends StatelessWidget {
  const WChoiceChip({super.key, required this.label, required this.selected, required this.onTap, this.dark = false, this.check = false, this.height});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Выбранный — чёрный (группы меню), иначе красный.
  final bool dark;

  /// Выбранный — красная рамка с галочкой (причины, «без лука»).
  final bool check;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final Color bg, fg;
    Border? border;
    if (check) {
      bg = selected ? WC.red50 : WC.white;
      fg = selected ? WC.red : WC.gray700;
      border = Border.all(color: selected ? WC.red : WC.gray300);
    } else if (selected) {
      bg = dark ? WC.ink : WC.red;
      fg = WC.white;
    } else {
      bg = WC.white;
      fg = WC.gray700;
      if (!dark) border = Border.all(color: WC.gray200);
    }
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: height,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: height != null ? 6 : (check ? 12 : 14), vertical: height == null ? 8 : 0),
        decoration: BoxDecoration(color: bg, border: border, borderRadius: BorderRadius.circular(18)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (check && selected) ...[Icon(Icons.check_rounded, size: 16, color: fg), const SizedBox(width: 4)],
          // Чип гостя стоит в ячейке заданной ширины — подпись не вылезает;
          // группы меню — в горизонтальной прокрутке, там ширина не ограничена.
          if (height != null)
            Flexible(child: Text(label, style: wt(13, w: check ? w6 : w7, c: fg), maxLines: 1, softWrap: false, overflow: TextOverflow.fade))
          else
            Text(label, style: wt(13, w: check ? w6 : w7, c: fg)),
        ]),
      ),
    );
  }
}

/// Значок блюда: фото или вилка с ножом на тёплом фоне.
class WDishIcon extends StatelessWidget {
  const WDishIcon({super.key, required this.image, required this.seed, this.size = 46, this.radius = 10});

  final String image;
  final String seed;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tint = WC.dishTints[seed.hashCode.abs() % WC.dishTints.length];
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(radius)),
      child: Icon(Icons.restaurant_rounded, size: size * 0.48, color: WC.gray500),
    );
    if (image.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(image, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback),
    );
  }
}

/// Шторка в стиле макета: белая, скругление 24, ручка сверху.
Future<T?> showWaiterSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: WC.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 5, decoration: BoxDecoration(color: WC.gray300, borderRadius: BorderRadius.circular(3))),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
              child: builder(ctx),
            ),
          ),
        ]),
      ),
    ),
  );
}

/// Сообщение внизу экрана.
void wToast(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(e.toString())));
}
