import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/lock/pin_screens.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/start/start_screen.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'main.dart' show appVersion;
import 'requests_screen.dart';

/// Ещё: ввод товаров («Начало работы» как у магазина), условия для
/// магазинов, запросы, язык, код-замок, выход.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    void open(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Text(tr('Ещё', 'Yana'), style: AppText.h1),
        const SizedBox(height: 12),
        AppCard(
          child: Row(children: [
            const IconBox(Icons.local_shipping_rounded, bg: AppColors.primarySoft, fg: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st.networkName, style: AppText.bodyStrong),
                Text('${st.me?['full_name'] ?? ''} · ${st.me?['role_name'] ?? ''}', style: AppText.small),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            _Item(icon: Icons.add_box_rounded, title: tr('Мои товары · Начало работы', 'Mahsulotlarim · Ishni boshlash'),
                sub: tr('Ввод товаров как в «SM Магазин»: база, штрихкод, фото', '«SM Doʻkon»dagidek: baza, shtrix-kod, foto'), onTap: () => open(const StartScreen())),
            const Divider(height: 1),
            _Item(icon: Icons.person_add_alt_rounded, title: tr('Запросы от магазинов', 'Doʻkonlardan soʻrovlar'), onTap: () => open(const RequestsScreen())),
            if (st.me?['is_owner'] == true) ...[
              const Divider(height: 1),
              _Item(icon: Icons.handshake_rounded, title: tr('Условия для магазинов', 'Doʻkonlar uchun shartlar'),
                  sub: tr('Доставка, минимальный заказ, срок поставки', 'Yetkazish, minimal buyurtma, muddat'), onTap: () => open(const SupplySettingsScreen())),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            const LanguageTile(),
            const Divider(height: 1),
            _Item(icon: Icons.lock_outline_rounded, title: tr('Код и Face ID', 'Kod va Face ID'), onTap: () => open(const LockSettingsScreen())),
            const Divider(height: 1),
            _Item(
              icon: Icons.logout_rounded,
              title: tr('Выйти', 'Chiqish'),
              danger: true,
              onTap: () async {
                final ok = await confirmSheet(context, title: tr('Выйти из аккаунта?', 'Akkauntdan chiqasizmi?'), confirm: tr('Выйти', 'Chiqish'));
                if (ok && context.mounted) await signOut(context);
              },
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Center(child: Text('SM Дистрибьютор $appVersion', style: AppText.small)),
      ]),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.icon, required this.title, this.sub, required this.onTap, this.danger = false});

  final IconData icon;
  final String title;
  final String? sub;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: IconBox(icon, size: 40, iconSize: 20, radius: 12, fg: danger ? AppColors.primary : AppColors.ink),
      title: Text(title, style: AppText.bodyStrong.copyWith(color: danger ? AppColors.primary : AppColors.ink)),
      subtitle: sub == null ? null : Text(sub!, style: AppText.small),
      trailing: danger ? null : const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
    );
  }
}

/// Условия, которые магазины видят в карточке поставщика.
class SupplySettingsScreen extends StatefulWidget {
  const SupplySettingsScreen({super.key});

  @override
  State<SupplySettingsScreen> createState() => _SupplySettingsScreenState();
}

class _SupplySettingsScreenState extends State<SupplySettingsScreen> {
  final _terms = TextEditingController();
  int _lead = 2;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _terms.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Api>().get('/store/supply/settings') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _terms.text = '${s['supply_terms'] ?? ''}';
        _lead = (s['lead_days'] as num?)?.toInt() ?? 2;
        _loaded = true;
      });
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await context.read<Api>().patch('/store/supply/settings', {'supply_terms': _terms.text.trim(), 'lead_days': _lead});
      if (!mounted) return;
      showMessage(context, tr('Сохранено', 'Saqlandi'));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Условия для магазинов', 'Doʻkonlar uchun shartlar'))),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BigButton(label: tr('Сохранить', 'Saqlash'), icon: Icons.check_rounded, busy: _busy, onPressed: _loaded ? _save : null),
        ),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              TextField(
                controller: _terms,
                maxLength: 500,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: tr('Условия', 'Shartlar'),
                  hintText: tr('Доставка на следующий день, минимальный заказ 300 000 сум, отсрочка 7 дней', 'Ertasi kuni yetkazish, minimal buyurtma 300 000 soʻm, 7 kun muddat'),
                ),
              ),
              const SizedBox(height: 16),
              Text(tr('Срок поставки, дней', 'Yetkazish muddati, kun'), style: AppText.bodyStrong),
              Text(tr('По нему считаем «мало» и сколько рекомендовать магазину', 'Shu boʻyicha «kam» va doʻkonga qancha tavsiya qilish hisoblanadi'), style: AppText.small),
              const SizedBox(height: 8),
              Row(children: [
                IconButton.filledTonal(onPressed: _lead > 1 ? () => setState(() => _lead--) : null, icon: const Icon(Icons.remove_rounded)),
                Expanded(child: Text('$_lead', textAlign: TextAlign.center, style: AppText.h2)),
                IconButton.filledTonal(onPressed: _lead < 30 ? () => setState(() => _lead++) : null, icon: const Icon(Icons.add_rounded)),
              ]),
            ]),
    );
  }
}
