import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Номер телефона Узбекистана — одна маска во всех приложениях
// (Figma «Магазин · приложение» → «Маска телефона»): +998 99 999 99 99.
// «+998» стоит всегда, человек вводит 9 цифр, пробелы ставятся сами.

/// 9 цифр после +998 из того, что ввёл или вставил человек
/// («+998 90 123-45-67», «998901234567», «90 123 45 67»).
String uzLocalDigits(String raw) {
  var d = raw.replaceAll(RegExp(r'\D'), '');
  // Код страны срезаем только у полного номера (12 цифр): иначе лишняя цифра
  // после «99 8…» отрезала бы начало номера.
  if (d.length >= 12 && d.startsWith('998')) d = d.substring(3);
  return d.length > 9 ? d.substring(0, 9) : d;
}

/// «901234567» → «90 123 45 67» (по мере ввода — «90 12»).
String formatUzLocal(String raw) {
  final d = uzLocalDigits(raw);
  final b = StringBuffer();
  for (var i = 0; i < d.length; i++) {
    if (i == 2 || i == 5 || i == 7) b.write(' ');
    b.write(d[i]);
  }
  return b.toString();
}

/// Номер для сервера: +998XXXXXXXXX; null — номер неполный.
String? normalizeUzPhone(String raw) {
  final d = uzLocalDigits(raw);
  return d.length == 9 ? '+998$d' : null;
}

/// Для показа: «+998 90 123 45 67». Чужие номера — как есть.
String formatPhone(Object? v) {
  final s = '${v ?? ''}'.trim();
  final d = s.replaceAll(RegExp(r'\D'), '');
  if (d.length == 12 && d.startsWith('998')) return '+998 ${formatUzLocal(d.substring(3))}';
  if (d.length == 9 && !s.startsWith('+')) return '+998 ${formatUzLocal(d)}';
  return s;
}

/// Маска поля: только 9 цифр с пробелами «90 123 45 67»; вставка номера целиком
/// с +998 или 998 тоже работает.
class UzPhoneFormatter extends TextInputFormatter {
  static String format(String digits) => formatUzLocal(digits);

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final nonDigit = RegExp(r'\D');
    var digits = newValue.text.replaceAll(nonDigit, '');
    // Сколько цифр стоит до курсора — чтобы курсор оставался на месте при правке в середине.
    final sel = newValue.selection;
    final end = sel.isValid && sel.extentOffset <= newValue.text.length ? sel.extentOffset : newValue.text.length;
    var before = newValue.text.substring(0, end).replaceAll(nonDigit, '').length;
    // Стёрли пробел — стираем и цифру перед ним.
    final oldDigits = oldValue.text.replaceAll(nonDigit, '');
    if (newValue.text.length < oldValue.text.length && digits == oldDigits && before > 0) {
      digits = digits.substring(0, before - 1) + digits.substring(before);
      before--;
    }
    final text = formatUzLocal(digits);
    // Вставили номер целиком или лишние цифры — курсор в конец.
    var offset = text.length;
    if (digits.length <= 9) {
      var seen = 0;
      offset = 0;
      while (offset < text.length && seen < before) {
        if (text[offset] != ' ') seen++;
        offset++;
      }
    }
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset));
  }
}

/// Поле номера: «+998 | 99 999 99 99». В контроллере — только местная часть
/// («90 123 45 67»), полный номер — [normalizeUzPhone] от неё.
class PhoneField extends StatelessWidget {
  const PhoneField({
    super.key,
    required this.controller,
    this.label,
    this.errorText,
    this.autofocus = false,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.textStyle,
  });

  final TextEditingController controller;
  final String? label;
  final String? errorText;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = textStyle ?? theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w500, letterSpacing: 0.3);
    final hint = theme.inputDecorationTheme.hintStyle ?? TextStyle(color: theme.hintColor);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: enabled,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.telephoneNumberNational],
      inputFormatters: [UzPhoneFormatter()],
      style: style,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        hintText: '99 999 99 99',
        hintStyle: style?.merge(hint).copyWith(fontWeight: FontWeight.w400),
        errorText: errorText,
        errorMaxLines: 2,
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 16, right: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('+998', style: style?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            Container(width: 1, height: 24, color: theme.dividerColor),
          ]),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      ),
    );
  }
}
