import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import 'theme.dart';

/// Данные покупателя: имя, фамилия, дата рождения, пол.
class PersonData {
  PersonData({this.firstName = '', this.lastName = '', this.birthDate, this.gender = ''});

  /// Из ответа /client/me.
  factory PersonData.fromProfile(Map<String, dynamic>? p) => PersonData(
        firstName: '${p?['first_name'] ?? ''}',
        lastName: '${p?['last_name'] ?? ''}',
        birthDate: DateTime.tryParse('${p?['birth_date'] ?? ''}'),
        gender: '${p?['gender'] ?? ''}',
      );

  String firstName;
  String lastName;
  DateTime? birthDate;

  /// '', 'male' или 'female'.
  String gender;

  /// Тело PATCH /client/me.
  Map<String, dynamic> toPatch() => {
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'birth_date': birthDate == null ? '' : isoDate(birthDate!),
        'gender': gender,
      };
}

/// 2001-03-07.
String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 07.03.2001.
String ruDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

/// Подпись над полем.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: AppText.smallStrong.copyWith(fontSize: 14)),
      );
}

/// Поле с рамкой по макету регистрации (радиус 16).
InputDecoration outlinedField(String hint, {Widget? suffix}) {
  OutlineInputBorder b(Color c, [double w = 1.5]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.lg), borderSide: BorderSide(color: c, width: w));
  return InputDecoration(
    hintText: hint,
    hintStyle: AppText.body.copyWith(color: AppColors.muted, fontSize: 16),
    filled: true,
    fillColor: AppColors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    suffixIcon: suffix,
    counterText: '',
    border: b(AppColors.line),
    enabledBorder: b(AppColors.line),
    focusedBorder: b(AppColors.ink, 1.8),
    errorBorder: b(AppColors.primary),
    focusedErrorBorder: b(AppColors.primary, 1.8),
  );
}

/// Форма «Имя, Фамилия, Дата рождения, Пол». Меняет [data] на месте.
class PersonForm extends StatefulWidget {
  const PersonForm({super.key, required this.data, this.onChanged, this.autofocus = false});
  final PersonData data;
  final VoidCallback? onChanged;
  final bool autofocus;

  @override
  State<PersonForm> createState() => _PersonFormState();
}

class _PersonFormState extends State<PersonForm> {
  late final _first = TextEditingController(text: widget.data.firstName);
  late final _last = TextEditingController(text: widget.data.lastName);

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _pickDate() async {
    FocusScope.of(context).unfocus();
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: widget.data.birthDate ?? DateTime(now.year - 25, 1, 1),
      firstDate: DateTime(1900),
      lastDate: now,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: tr('Дата рождения', 'Tugʻilgan sana'),
    );
    if (d == null) return;
    widget.data.birthDate = d;
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FieldLabel(tr('Имя', 'Ism')),
      TextField(
        controller: _first,
        autofocus: widget.autofocus,
        maxLength: 60,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        style: AppText.body.copyWith(fontSize: 16),
        decoration: outlinedField(tr('Например, Азиз', 'Masalan, Aziz')),
        onChanged: (v) {
          d.firstName = v;
          _changed();
        },
      ),
      const SizedBox(height: 16),
      FieldLabel(tr('Фамилия', 'Familiya')),
      TextField(
        controller: _last,
        maxLength: 60,
        textCapitalization: TextCapitalization.words,
        style: AppText.body.copyWith(fontSize: 16),
        decoration: outlinedField(tr('Например, Каримов', 'Masalan, Karimov')),
        onChanged: (v) {
          d.lastName = v;
          _changed();
        },
      ),
      const SizedBox(height: 16),
      FieldLabel(tr('Дата рождения', 'Tugʻilgan sana')),
      InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: _pickDate,
        child: InputDecorator(
          decoration: outlinedField(tr('ДД.ММ.ГГГГ', 'KK.OO.YYYY'),
              suffix: d.birthDate == null
                  ? const Icon(Icons.calendar_today_outlined, color: AppColors.text2)
                  : IconButton(
                      tooltip: tr('Очистить', 'Tozalash'),
                      icon: const Icon(Icons.close_rounded, color: AppColors.text2),
                      onPressed: () {
                        d.birthDate = null;
                        _changed();
                      },
                    )),
          isEmpty: d.birthDate == null,
          child: d.birthDate == null ? null : Text(ruDate(d.birthDate!), style: AppText.body.copyWith(fontSize: 16)),
        ),
      ),
      const SizedBox(height: 16),
      FieldLabel(tr('Пол', 'Jins')),
      GenderSwitch(
        value: d.gender,
        onChanged: (v) {
          d.gender = v;
          _changed();
        },
      ),
    ]);
  }
}

/// «Мужской / Женский» на сером фоне; повторное нажатие снимает выбор.
class GenderSwitch extends StatelessWidget {
  const GenderSwitch({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(String key, String label) {
      final on = value == key;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(on ? '' : key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? AppColors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.md),
              boxShadow: on ? const [BoxShadow(color: Color(0x1A000000), blurRadius: 6, offset: Offset(0, 2))] : null,
            ),
            child: Text(label, style: AppText.bodyMedium.copyWith(fontSize: 16, color: on ? AppColors.ink : AppColors.text2)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: Row(children: [option('male', tr('Мужской', 'Erkak')), option('female', tr('Женский', 'Ayol'))]),
    );
  }
}

/// Большая кнопка шагов регистрации: красная, серая, пока нельзя нажать.
class StepButton extends StatelessWidget {
  const StepButton({super.key, required this.label, required this.onPressed, this.busy = false, this.arrow = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool arrow;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final fg = enabled ? AppColors.white : AppColors.muted;
    return SizedBox(
      height: 58,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          disabledBackgroundColor: AppColors.soft,
          foregroundColor: AppColors.white,
          disabledForegroundColor: AppColors.muted,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
          textStyle: AppText.bodyStrong.copyWith(fontSize: 17),
        ),
        onPressed: enabled ? onPressed : null,
        child: busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.muted))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label),
                if (arrow) ...[const SizedBox(width: 8), Icon(Icons.arrow_forward_rounded, size: 22, color: fg)],
              ]),
      ),
    );
  }
}
