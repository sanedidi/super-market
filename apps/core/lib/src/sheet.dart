import 'package:flutter/material.dart';

import 'i18n.dart';

// Подтверждения и короткий ввод — шторкой снизу, а не окном по центру
// (Figma «Магазин · приложение» → Ш1, Ш2). Цвета берутся из темы приложения.

const _soft = Color(0xFFF3F3F4);
const _ink = Color(0xFF151515);
const _text2 = Color(0xFF6B6B70);

/// Открыть шторку снизу: ручка сверху, скругление 28, поднимается над клавиатурой.
Future<T?> showSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SafeArea(top: false, child: builder(ctx)),
      ),
    ),
  );
}

/// Кнопка шторки на всю ширину: основная (цвет бренда) или серая.
class SheetButton extends StatelessWidget {
  const SheetButton({super.key, required this.label, required this.onPressed, this.primary = true, this.busy = false});

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: primary ? color : _soft,
          foregroundColor: primary ? Colors.white : _ink,
          disabledBackgroundColor: _soft,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)) : Text(label),
      ),
    );
  }
}

/// Заголовок шторки: иконка в кружке (необязательно), вопрос и пояснение.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.title, this.text, this.icon});

  final String title;
  final String? text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (icon != null) ...[
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.08), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 28),
        ),
        const SizedBox(height: 16),
      ],
      Text(title, style: const TextStyle(fontSize: 22, height: 1.25, fontWeight: FontWeight.w700, color: _ink)),
      if (text != null && text!.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(text!, style: const TextStyle(fontSize: 15, height: 1.4, color: _text2)),
      ],
    ]);
  }
}

/// Подтверждение снизу: «Выйти из приложения?» → true, если нажали [confirm].
Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  String? text,
  required String confirm,
  String? cancel,
  IconData? icon,
}) async {
  final ok = await showSheet<bool>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title: title, text: text, icon: icon),
      const SizedBox(height: 20),
      SheetButton(label: confirm, onPressed: () => Navigator.pop(ctx, true)),
      const SizedBox(height: 10),
      SheetButton(label: cancel ?? tr('Отмена', 'Bekor qilish'), primary: false, onPressed: () => Navigator.pop(ctx, false)),
    ]),
  );
  return ok == true;
}

/// Сообщение снизу с одной кнопкой «Понятно» / «Tushunarli».
Future<void> infoSheet(BuildContext context, {required String title, String? text, String? button, IconData? icon}) {
  return showSheet<void>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title: title, text: text, icon: icon),
      const SizedBox(height: 20),
      SheetButton(label: button ?? tr('Понятно', 'Tushunarli'), onPressed: () => Navigator.pop(ctx)),
    ]),
  );
}

/// Шторка с вводом (Ш2): варианты-чипы и/или поле. Возвращает выбранный вариант,
/// текст поля или «вариант: текст»; null — передумали.
Future<String?> promptSheet(
  BuildContext context, {
  required String title,
  String? text,
  required String confirm,
  String? cancel,
  List<String> options = const [],
  String? hint,
  bool requireValue = true,
  TextInputType keyboardType = TextInputType.text,
  int? maxLength,
}) {
  return showSheet<String>(
    context,
    (ctx) => _Prompt(
      title: title,
      text: text,
      confirm: confirm,
      cancel: cancel ?? tr('Отмена', 'Bekor qilish'),
      options: options,
      hint: hint,
      requireValue: requireValue,
      keyboardType: keyboardType,
      maxLength: maxLength,
    ),
  );
}

class _Prompt extends StatefulWidget {
  const _Prompt({
    required this.title,
    required this.text,
    required this.confirm,
    required this.cancel,
    required this.options,
    required this.hint,
    required this.requireValue,
    required this.keyboardType,
    required this.maxLength,
  });

  final String title;
  final String? text;
  final String confirm;
  final String cancel;
  final List<String> options;
  final String? hint;
  final bool requireValue;
  final TextInputType keyboardType;
  final int? maxLength;

  @override
  State<_Prompt> createState() => _PromptState();
}

class _PromptState extends State<_Prompt> {
  final _ctrl = TextEditingController();
  String? _option;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _value {
    final t = _ctrl.text.trim();
    if (_option == null) return t;
    return t.isEmpty ? _option! : '${_option!}: $t';
  }

  @override
  Widget build(BuildContext context) {
    final ready = !widget.requireValue || _value.isNotEmpty;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title: widget.title, text: widget.text),
      if (widget.options.isNotEmpty) ...[
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final o in widget.options)
            ChoiceChip(
              label: Text(o),
              selected: _option == o,
              showCheckmark: false,
              selectedColor: _ink,
              backgroundColor: _soft,
              side: BorderSide.none,
              shape: const StadiumBorder(),
              labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _option == o ? Colors.white : _ink),
              onSelected: (v) => setState(() => _option = v ? o : null),
            ),
        ]),
      ],
      if (widget.hint != null) ...[
        const SizedBox(height: 16),
        TextField(
          controller: _ctrl,
          autofocus: widget.options.isEmpty,
          keyboardType: widget.keyboardType,
          maxLength: widget.maxLength,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (ready) Navigator.pop(context, _value);
          },
          decoration: InputDecoration(hintText: widget.hint, counterText: ''),
        ),
      ],
      const SizedBox(height: 20),
      SheetButton(label: widget.confirm, onPressed: ready ? () => Navigator.pop(context, _value) : null),
      const SizedBox(height: 10),
      SheetButton(label: widget.cancel, primary: false, onPressed: () => Navigator.pop(context)),
    ]);
  }
}
