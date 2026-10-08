import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../control/cashiers_screen.dart' show plural;
import '../finance/finance_logic.dart' show plainAmount;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Настройки долгов (Figma С4): «Даёт в долг» для магазина и правила сети.
/// Признак «даёт в долг» покупатели не видят — он только показывает или
/// прячет кнопку «В долг» на кассе.
class DebtSettingsScreen extends StatefulWidget {
  const DebtSettingsScreen({super.key});

  @override
  State<DebtSettingsScreen> createState() => _DebtSettingsScreenState();
}

class _DebtSettingsScreenState extends State<DebtSettingsScreen> {
  Map<String, dynamic>? _s;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Api>().get('/store/debt-settings') as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _s = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save(Future<dynamic> Function(Api api) call) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final s = await call(context.read<Api>()) as Map<String, dynamic>;
      if (mounted) setState(() => _s = s);
    } on ApiError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _number(String field, String title, String hint, {bool days = false}) async {
    final cur = '${_s?[field] ?? ''}';
    final ctl = TextEditingController(text: days || cur.isEmpty ? cur : money(cur, suffix: false));
    final v = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.h3),
            Text(hint, style: AppText.small),
            const SizedBox(height: 14),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s]'))],
              style: AppText.h2,
              decoration: InputDecoration(suffixText: days ? tr('дней', 'kun') : tr('сум', 'soʻm')),
            ),
            const SizedBox(height: 16),
            BigButton(label: tr('Сохранить', 'Saqlash'), onPressed: () => Navigator.of(ctx).pop(plainAmount(ctl.text))),
          ]),
        ),
      ),
    );
    ctl.dispose();
    if (v == null || v.isEmpty) return;
    await _save((api) => api.put('/store/debt-settings', {field: days ? int.tryParse(v) ?? 0 : v}));
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final s = _s;
    final stores = ((s?['stores'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final here = stores.where((x) => x['store_id'] == st.storeId).firstOrNull;
    final term = (s?['term_days'] as num?)?.toInt() ?? 30;
    Widget row(String title, String sub, String value, VoidCallback onTap) => ListTile(
          title: Text(title, style: AppText.bodyStrong),
          subtitle: Text(sub, style: AppText.small),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(value, style: AppText.bodyStrong),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ]),
          onTap: _busy ? null : onTap,
        );
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Настройки долгов', 'Qarz sozlamalari')),
          Text('${st.networkName} · ${st.store?['name'] ?? ''}', style: AppText.small),
        ]),
      ),
      body: s == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load))
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              Text(tr('ЭТОТ МАГАЗИН', 'USHBU DOʻKON'), style: AppText.caption),
              const SizedBox(height: 8),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SwitchListTile(
                  title: Text(tr('Даёт в долг', 'Qarzga beradi'), style: AppText.bodyStrong),
                  subtitle: Text(tr('кнопка «В долг» на кассе. Покупатели эту настройку не видят', 'kassadagi «Qarzga» tugmasi. Xaridorlar bu sozlamani koʻrmaydi'),
                      style: AppText.small),
                  value: here?['debt_enabled'] == true,
                  onChanged: _busy || st.storeId == null
                      ? null
                      : (v) => _save((api) => api.put('/store/debt-settings/stores/${st.storeId}', {'debt_enabled': v})),
                ),
              ),
              const SizedBox(height: 18),
              Text(tr('ДЛЯ ВСЕЙ СЕТИ', 'BUTUN TARMOQ UCHUN'), style: AppText.caption),
              const SizedBox(height: 8),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(children: [
                  row(tr('Лимит по умолчанию', 'Standart limit'), tr('на одного покупателя', 'bitta xaridor uchun'), money(s['default_limit'], suffix: false),
                      () => _number('default_limit', tr('Лимит по умолчанию', 'Standart limit'),
                          tr('Сколько можно в долг подтверждённому покупателю', 'Tasdiqlangan xaridorga qancha qarz berish mumkin'))),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  row(tr('Лимит без кода', 'Kodsiz limit'), tr('для «не подтверждённых»', '«tasdiqlanmaganlar» uchun'), money(s['unverified_limit'], suffix: false),
                      () => _number('unverified_limit', tr('Лимит без кода', 'Kodsiz limit'),
                          tr('Пока покупатель не подтвердил номер кодом', 'Xaridor raqamini kod bilan tasdiqlamaguncha'))),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  row(tr('Срок возврата', 'Qaytarish muddati'), tr('с первой неоплаченной покупки', 'birinchi toʻlanmagan xariddan'),
                      tr('$term ${plural(term, 'день', 'дня', 'дней')}', '$term kun'),
                      () => _number('term_days', tr('Срок возврата', 'Qaytarish muddati'), tr('Дней с первой неоплаченной покупки', 'Birinchi toʻlanmagan xariddan boshlab kunlar'),
                          days: true)),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: Text(tr('Код при первом долге', 'Birinchi qarzda kod'), style: AppText.bodyStrong),
                    subtitle: Text(tr('Telegram или приложение на номер покупателя', 'Xaridor raqamiga Telegram yoki ilova orqali'), style: AppText.small),
                    value: s['require_code'] == true,
                    onChanged: _busy ? null : (v) => _save((api) => api.put('/store/debt-settings', {'require_code': v})),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: Text(tr('Доп. напоминания', 'Qoʻshimcha eslatmalar'), style: AppText.bodyStrong),
                    subtitle: Text(tr('за 3 дня и после просрочки. В день оплаты — всегда, в 10:00', '3 kun oldin va muddat oʻtgach. Toʻlov kuni — doim, soat 10:00 da'),
                        style: AppText.small),
                    value: s['extra_reminders'] == true,
                    onChanged: _busy ? null : (v) => _save((api) => api.put('/store/debt-settings', {'extra_reminders': v})),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Text(
                tr('Выключите «Даёт в долг» — кнопка на кассе пропадёт. Старые долги останутся: их можно принимать и видеть в списке.',
                    '«Qarzga beradi»ni oʻchirsangiz, kassadagi tugma yoʻqoladi. Eski qarzlar qoladi: ularni qabul qilish va roʻyxatda koʻrish mumkin.'),
                style: AppText.small,
              ),
            ]),
    );
  }
}
