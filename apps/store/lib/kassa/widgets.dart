import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';

/// Фото товара или серая заглушка.
class ProductThumb extends StatelessWidget {
  const ProductThumb(this.url, {super.key, this.size = 44, this.color = AppColors.soft, this.radius = 12});

  final String? url;
  final double size;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final empty = Icon(Icons.image_rounded, size: size * 0.45, color: AppColors.muted);
    final u = url ?? '';
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(radius)),
      child: u.startsWith('http')
          ? Image.network(u, fit: BoxFit.cover, cacheWidth: (size * 3).round(), errorBuilder: (_, __, ___) => Center(child: empty))
          : Center(child: empty),
    );
  }
}

/// −  2  + в чеке.
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.label, required this.onMinus, required this.onPlus});

  final String label;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    Widget b(IconData icon, VoidCallback? on, Color c) => InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: on == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  on();
                },
          child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 18, color: on == null ? AppColors.muted : c)),
        );
    return Container(
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b(Icons.remove_rounded, onMinus, AppColors.ink),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 22),
          child: Text(label, textAlign: TextAlign.center, style: AppText.bodyStrong.copyWith(fontSize: 14)),
        ),
        b(Icons.add_rounded, onPlus, AppColors.primary),
      ]),
    );
  }
}

/// Цифровая клавиатура 3×4: последний ряд — [extra] (запятая или «00»), 0, ⌫.
class Keypad extends StatelessWidget {
  const Keypad({super.key, required this.onKey, this.extra = ',', this.keyHeight = 54});

  /// Цифра, [extra] или «⌫».
  final ValueChanged<String> onKey;
  final String extra;
  final double keyHeight;

  @override
  Widget build(BuildContext context) {
    Widget key(String k) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Material(
              color: AppColors.soft,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  HapticFeedback.selectionClick();
                  onKey(k);
                },
                child: SizedBox(
                  height: keyHeight,
                  child: Center(
                    child: k == '⌫' ? const Icon(Icons.backspace_rounded, size: 22, color: AppColors.ink) : Text(k, style: AppText.h3.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
          ),
        );
    return Column(children: [
      for (final row in [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
        [extra, '0', '⌫'],
      ])
        Row(children: [for (final k in row) key(k)]),
    ]);
  }
}

/// Чип выбора: обводка, выбранный — красный.
class PickChip extends StatelessWidget {
  const PickChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: selected ? 2 : 1),
          ),
          child: Center(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyStrong.copyWith(fontSize: 14, color: selected ? AppColors.primary : AppColors.ink)),
          ),
        ),
      ),
    );
  }
}

/// Набор числа с клавиатуры: цифры, одна запятая ([decimals] знаков после неё), ⌫.
String typeKey(String value, String key, {int decimals = 0, int maxDigits = 9}) {
  if (key == '⌫') return value.isEmpty ? value : value.substring(0, value.length - 1);
  if (key == ',') {
    if (decimals == 0 || value.contains(',')) return value;
    return value.isEmpty ? '0,' : '$value,';
  }
  final comma = value.indexOf(',');
  if (comma >= 0 && value.length - comma - 1 + key.length > decimals) return value;
  final digits = value.replaceAll(',', '').length;
  if (digits + key.length > maxDigits) return value;
  if (value == '0' && key != ',') return key == '00' ? value : key;
  if (value.isEmpty && key == '00') return value;
  return value + key;
}
