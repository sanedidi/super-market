import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';

// Общие виджеты «SM Сотрудник» (Figma «SM Сотрудник» → «Компоненты»).
// Цвета, шрифт и кнопки — из «SM Магазин» (sm_store/ui), тёмной темы нет.

/// Фото товара или иконка, если фото нет.
class ProductThumb extends StatelessWidget {
  const ProductThumb({super.key, this.image, this.size = 48, this.fractional = false});

  final String? image;
  final double size;
  final bool fractional;

  @override
  Widget build(BuildContext context) {
    final url = image ?? '';
    final icon = IconBox(fractional ? Icons.scale_rounded : Icons.inventory_2_outlined, size: size, iconSize: size * 0.5, radius: size * 0.28);
    if (url.isEmpty) return icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: Container(
        width: size,
        height: size,
        color: AppColors.soft,
        child: Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => icon),
      ),
    );
  }
}

/// Кружок с инициалами (С3, С13).
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 44, this.dark = false});

  final String name;
  final double size;

  /// Чёрный кружок с белыми буквами (профиль, С13).
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: dark ? AppColors.ink : AppColors.primarySoft, shape: BoxShape.circle),
      child: Text(initials(name), style: AppText.bodyStrong.copyWith(color: dark ? AppColors.white : AppColors.primary, fontSize: size * 0.36)),
    );
  }
}

/// «− 2 +» — количество (С9 пакеты, С11 списание).
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.value, required this.onChanged, this.min = 0, this.max, this.fractional = false, this.unit = '', this.onTapValue});

  final num value;
  final ValueChanged<num> onChanged;
  final num min;
  final num? max;
  final bool fractional;
  final String unit;

  /// Нажали на число — ввести вручную.
  final VoidCallback? onTapValue;

  @override
  Widget build(BuildContext context) {
    final step = stepFor(fractional);
    num clamp(num v) {
      if (v < min) return min;
      if (max != null && v > max!) return max!;
      return num.parse(v.toStringAsFixed(3));
    }

    Widget btn(IconData icon, VoidCallback? onTap) => Material(
          color: onTap == null ? AppColors.soft : AppColors.white,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: SizedBox(width: 52, height: 52, child: Icon(icon, color: onTap == null ? AppColors.muted : AppColors.ink)),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(18)),
      child: Row(children: [
        btn(Icons.remove_rounded, value - step >= min - 0.0001 ? () => onChanged(clamp(value - step)) : null),
        Expanded(
          child: InkWell(
            onTap: onTapValue,
            child: Column(children: [
              Text(qty(value), style: AppText.h2),
              if (unit.isNotEmpty) Text(unit, style: AppText.small),
            ]),
          ),
        ),
        btn(Icons.add_rounded, max == null || value + step <= max! + 0.0001 ? () => onChanged(clamp(value + step)) : null),
      ]),
    );
  }
}

/// Голубая плашка с пояснением (ⓘ).
class InfoNote extends StatelessWidget {
  const InfoNote(this.text, {super.key, this.icon = Icons.info_outline_rounded, this.tone = ChipTone.blue});

  final String text;
  final IconData icon;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = StatusChip.colors(tone);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: fg),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: AppText.small.copyWith(color: AppColors.ink))),
      ]),
    );
  }
}

/// Подпись секции капсом: «ОСТАЛОСЬ СОБРАТЬ».
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(text.toUpperCase(), style: AppText.caption.copyWith(letterSpacing: 0.4)),
      );
}

/// Загрузка / ошибка с «Повторить».
class LoadBox extends StatelessWidget {
  const LoadBox({super.key, this.error, required this.retry});

  final Object? error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
        child: error == null
            ? const CircularProgressIndicator()
            : EmptyState(
                icon: Icons.wifi_off_rounded,
                title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
                text: '$error',
                action: tr('Повторить', 'Qayta urinish'),
                onAction: retry,
              ),
      );
}

/// Сегменты-вкладки: «Новые 2 · Собираю 1 · Готовы 3».
class Segments extends StatelessWidget {
  const Segments({super.key, required this.labels, required this.counts, required this.index, required this.onChanged});

  final List<String> labels;
  final List<int?> counts;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(color: i == index ? AppColors.white : Colors.transparent, borderRadius: BorderRadius.circular(11)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(
                    child: Text(labels[i],
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStrong.copyWith(fontSize: 14, color: i == index ? AppColors.ink : AppColors.text2)),
                  ),
                  if ((counts[i] ?? 0) > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(color: i == index ? AppColors.primary : AppColors.line, borderRadius: BorderRadius.circular(10)),
                      child: Text('${counts[i]}', style: AppText.caption.copyWith(color: i == index ? AppColors.white : AppColors.dark)),
                    ),
                  ],
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Сообщение внизу экрана.
void toast(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(e.toString())));
}

/// Ввести количество в шторке (цифры, весовой — с запятой).
Future<num?> askQty(BuildContext context, {required String title, String? text, num? initial, bool fractional = false, String confirm = ''}) async {
  final v = await promptSheet(
    context,
    title: title,
    text: text,
    confirm: confirm.isEmpty ? tr('Готово', 'Tayyor') : confirm,
    hint: initial == null ? (fractional ? '0,5' : '0') : qty(initial),
    keyboardType: TextInputType.numberWithOptions(decimal: fractional),
  );
  if (v == null) return null;
  final x = parseInput(v);
  if (x == null || x < 0) return null;
  return fractional ? x : x.round();
}
