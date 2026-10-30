import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../finance/finance_logic.dart' show n, plainAmount;
import '../setup/setup_logic.dart' show spacedMoney;
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'customer_debts_screen.dart' show shortDate;

// «Добавить должника» — старый долг вручную (Figma «Приложения» →
// «SM Магазин · Долг вручную», Р2–Р5): номер, имя, сумма — и готово.
// Касса, остатки и прибыль не меняются. Номер уже есть — сумма прибавляется
// к его долгу. Лимит и стоп-лист не мешают записать — только предупреждаем.

/// Открывает шторку; результат — ответ POST /store/debtors или null.
Future<Map<String, dynamic>?> showAddDebtorSheet(BuildContext context, String storeId) => showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => AddDebtorSheet(storeId: storeId),
    );

/// Сумма с пробелами по мере ввода: «250 000».
class _MoneyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final d = newValue.text.replaceAll(RegExp(r'\D'), '');
    final t = d.isEmpty ? '' : spacedMoney(d.length > 10 ? d.substring(0, 10) : d);
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }
}

class AddDebtorSheet extends StatefulWidget {
  const AddDebtorSheet({super.key, required this.storeId});

  final String storeId;

  @override
  State<AddDebtorSheet> createState() => _AddDebtorSheetState();
}

class _AddDebtorSheetState extends State<AddDebtorSheet> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _amountFocus = FocusNode();

  /// Ответ GET /store/debtors/lookup для номера [_lookedUp].
  Map<String, dynamic>? _look;
  String? _lookedUp;
  bool _looking = false;
  int? _termDays;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _amount]) {
      c.addListener(_redraw);
    }
    _loadTerm();
  }

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _amount.dispose();
    _note.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() => _error = null);
  }

  Future<void> _loadTerm() async {
    try {
      final s = await context.read<Api>().get('/store/debt-settings') as Map<String, dynamic>;
      if (mounted) setState(() => _termDays = (s['term_days'] as num?)?.toInt());
    } catch (_) {}
  }

  /// Номер набран полностью — смотрим, есть ли он уже в должниках.
  Future<void> _onPhone(String _) async {
    final ph = normalizeUzPhone(_phone.text);
    setState(() => _error = null);
    if (ph == null) {
      if (_look != null) {
        setState(() {
          if (_existingName.isNotEmpty) _name.clear();
          _look = null;
          _lookedUp = null;
        });
      }
      return;
    }
    if (ph == _lookedUp) return;
    setState(() {
      if (_existingName.isNotEmpty) _name.clear();
      _look = null;
      _looking = true;
      _lookedUp = ph;
    });
    try {
      final res = await context.read<Api>().get('/store/debtors/lookup', {'store_id': widget.storeId, 'phone': ph}) as Map<String, dynamic>;
      if (!mounted || _lookedUp != ph) return;
      setState(() {
        _look = res;
        _looking = false;
      });
      final name = _existingName;
      if (name.isNotEmpty) {
        _name.text = name;
        _amountFocus.requestFocus();
      }
    } catch (e) {
      if (mounted && _lookedUp == ph) {
        setState(() {
          _error = e.toString();
          _lookedUp = null;
          _looking = false;
        });
      }
    }
  }

  Map<String, dynamic>? get _debtor => _look?['found'] == true ? _look!['debtor'] as Map<String, dynamic>? : null;
  String get _existingName => '${_debtor?['full_name'] ?? ''}'.trim();
  num get _sum => n(plainAmount(_amount.text));
  num get _debt => n(_debtor?['amount']);
  num get _limit => _debtor != null ? n(_debtor!['limit']) : n(_look?['unverified_limit']);
  bool get _blocked => _debtor?['blocked'] == true;
  bool get _verified => _debtor?['verified'] == true;
  bool get _ready => _look != null && normalizeUzPhone(_phone.text) == _lookedUp;
  bool get _over => _ready && _sum > 0 && (_blocked || _debt + _sum > _limit);
  bool get _canSubmit => _ready && !_looking && _sum > 0 && (_existingName.isNotEmpty || _name.text.trim().isNotEmpty);

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await context.read<Api>().post('/store/debtors', {
        'store_id': widget.storeId,
        'phone': _lookedUp,
        'full_name': _name.text.trim(),
        'amount': plainAmount(_amount.text),
        'note': _note.text.trim(),
      }) as Map<String, dynamic>;
      if (mounted) Navigator.of(context).pop(res);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _buttonLabel {
    final s = money(_sum);
    if (_sum <= 0) return tr('Записать в долг', 'Qarzga yozish');
    if (_over) return tr('Всё равно записать $s', 'Baribir $s yozish');
    if (_debt > 0) return tr('Добавить $s к долгу', 'Qarzga $s qoʻshish');
    return tr('Записать $s в долг', '$s qarzga yozish');
  }

  @override
  Widget build(BuildContext context) {
    final d = _debtor;
    final hasName = _existingName.isNotEmpty;
    final initials = hasName ? _existingName.split(RegExp(r'\s+')).take(2).map((w) => w.isEmpty ? '' : w[0]).join().toUpperCase() : '?';
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Новый должник', 'Yangi qarzdor'), style: AppText.h3),
            Text(tr('Старый долг — касса и остатки не меняются', 'Eski qarz — kassa va qoldiqlar oʻzgarmaydi'), style: AppText.small),
            const SizedBox(height: 14),
            PhoneField(
              controller: _phone,
              autofocus: true,
              label: tr('Номер телефона', 'Telefon raqami'),
              onChanged: _onPhone,
            ),
            if (_looking)
              const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator(minHeight: 2))
            else if (_ready && d == null)
              _Hint(Icons.person_add_alt_rounded, tr('Новый покупатель — в долгах магазина его ещё нет', 'Yangi xaridor — doʻkon qarzdorlari orasida hali yoʻq'))
            else if (_ready && d != null) ...[
              const SizedBox(height: 10),
              AppCard(
                border: AppColors.line,
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(12)),
                    child: Text(initials, style: AppText.bodyStrong.copyWith(color: AppColors.blue, fontSize: 14)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('Уже в долгах магазина', 'Doʻkon qarzdorlari orasida bor'), style: AppText.small.copyWith(fontSize: 12)),
                      Text(hasName ? _existingName : formatPhone(_lookedUp), style: AppText.bodyStrong),
                      Text(
                        _debt > 0
                            ? tr('должен ${money(_debt, suffix: false)}${d['due_date'] != null ? ' · вернуть до ${shortDate(d['due_date'])}' : ''}',
                                'qarzi ${money(_debt, suffix: false)}${d['due_date'] != null ? ' · ${shortDate(d['due_date'])} gacha' : ''}')
                            : tr('в этом магазине долга нет', 'bu doʻkonda qarzi yoʻq'),
                        style: AppText.small,
                      ),
                    ]),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              readOnly: hasName,
              textCapitalization: TextCapitalization.words,
              style: hasName ? AppText.body.copyWith(color: AppColors.text2) : null,
              decoration: InputDecoration(labelText: tr('Имя', 'Ism'), hintText: tr('Как записать покупателя', 'Xaridorni qanday yozish kerak')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              focusNode: _amountFocus,
              keyboardType: TextInputType.number,
              inputFormatters: [_MoneyFormatter()],
              style: AppText.h2,
              decoration: InputDecoration(labelText: tr('Сумма долга', 'Qarz summasi'), hintText: '0', suffixText: tr('сум', 'soʻm')),
            ),
            if (_ready && _debt > 0 && _sum > 0) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(children: [
                  Expanded(child: Text(tr('Станет долгом', 'Qarz boʻladi'), style: AppText.body.copyWith(color: AppColors.text2))),
                  Text(money(_debt + _sum), style: AppText.bodyStrong),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              maxLength: 300,
              decoration: InputDecoration(
                labelText: tr('Комментарий', 'Izoh'),
                hintText: tr('Необязательно: «из тетради»', 'Ixtiyoriy: «daftardan»'),
                counterText: '',
              ),
            ),
            if (_over) ...[
              const SizedBox(height: 12),
              _OverLimit(blocked: _blocked, verified: _verified, over: _debt + _sum - _limit, total: _debt + _sum, limit: _limit,
                  defaultLimit: n(_look?['default_limit'])),
            ] else if (_ready && _sum > 0)
              _Hint(
                Icons.event_outlined,
                _debt > 0 && d?['due_date'] != null
                    ? tr('Срок прежний: вернуть до ${shortDate(d!['due_date'])}', 'Muddat oʻsha: ${shortDate(d['due_date'])} gacha qaytarish')
                    : _termDays != null
                        ? tr('Вернуть до ${shortDate(DateTime.now().add(Duration(days: _termDays!)).toIso8601String())} — срок $_termDays дней из настроек долгов',
                            '${shortDate(DateTime.now().add(Duration(days: _termDays!)).toIso8601String())} gacha qaytarish — qarz sozlamalaridagi $_termDays kunlik muddat')
                        : tr('Срок возврата — из настроек долгов', 'Qaytarish muddati — qarz sozlamalaridan'),
              ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 16),
            BigButton(
              label: _buttonLabel,
              icon: _debt > 0 && !_over ? Icons.add_rounded : Icons.check_rounded,
              busy: _busy,
              onPressed: _canSubmit ? _submit : null,
            ),
          ]),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: AppColors.text2),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AppText.small)),
        ]),
      );
}

/// Р5 · сверх лимита или стоп-лист: запишем, но предупреждаем.
class _OverLimit extends StatelessWidget {
  const _OverLimit({required this.blocked, required this.verified, required this.over, required this.total, required this.limit, required this.defaultLimit});

  final bool blocked;
  final bool verified;
  final num over;
  final num total;
  final num limit;
  final num defaultLimit;

  @override
  Widget build(BuildContext context) {
    final String title;
    final String text;
    if (blocked) {
      title = tr('Покупатель в стоп-листе', 'Xaridor stop-roʻyxatda');
      text = tr('Долг запишется, но на кассе в долг ему не дадут.', 'Qarz yoziladi, lekin kassada unga qarzga berilmaydi.');
    } else {
      title = tr('Сверх лимита на ${money(over, suffix: false)} сум', 'Limitdan ${money(over, suffix: false)} soʻm ortiq');
      text = verified || defaultLimit <= limit
          ? tr('Станет ${money(total, suffix: false)} при лимите ${money(limit, suffix: false)}. Долг запишется, но на кассе в долг ему не дадут, пока не погасит часть.',
              '${money(limit, suffix: false)} limitda ${money(total, suffix: false)} boʻladi. Qarz yoziladi, lekin bir qismini toʻlamaguncha kassada unga qarzga berilmaydi.')
          : tr('Станет ${money(total, suffix: false)} при лимите ${money(limit, suffix: false)} для неподтверждённого номера. Долг запишется. Чтобы давать в долг на кассе — подтвердите номер кодом, лимит станет ${money(defaultLimit, suffix: false)}.',
              'Tasdiqlanmagan raqam uchun ${money(limit, suffix: false)} limitda ${money(total, suffix: false)} boʻladi. Qarz yoziladi. Kassada qarzga berish uchun raqamni kod bilan tasdiqlang — limit ${money(defaultLimit, suffix: false)} boʻladi.');
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.warningInk),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong.copyWith(fontSize: 14, color: AppColors.warningInk)),
            const SizedBox(height: 2),
            Text(text, style: AppText.small.copyWith(color: AppColors.warningInk)),
          ]),
        ),
      ]),
    );
  }
}
