import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/lock/pin_screens.dart' show signOut;
import 'package:sm_store/screens/store_picker.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'ui.dart';
import 'version.dart';

/// С13 · Профиль — мой день, магазин, язык, пароль, права.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.refresh});

  final ValueNotifier<int> refresh;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _day;

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_load);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final store = context.read<StoreState>().storeId;
    try {
      final d = await context.read<Api>().get('/store/staff/day', {'store_id': store}) as Map<String, dynamic>;
      if (mounted) setState(() => _day = d);
    } catch (_) {
      // «Мой день» без данных не показывается
    }
  }

  Future<void> _logout() async {
    final ok = await confirmSheet(context,
        icon: Icons.logout_rounded, title: tr('Выйти из приложения?', 'Ilovadan chiqasizmi?'), text: tr('Войти снова можно тем же логином и паролем.', 'Xuddi shu login va parol bilan qayta kirish mumkin.'), confirm: tr('Выйти', 'Chiqish'));
    if (ok && mounted) await signOut(context);
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final me = st.me ?? const <String, dynamic>{};
    final name = '${me['full_name'] ?? ''}';
    final role = '${me['role_name'] ?? ''}'.isNotEmpty ? '${me['role_name']}' : (me['is_owner'] == true ? tr('Владелец', 'Egasi') : tr('Сотрудник', 'Xodim'));
    final perms = ((me['permissions'] as List?) ?? const []).map((e) => '$e').toList();
    final d = _day;
    Widget row(IconData icon, String title, {String? value, VoidCallback? onTap, Color? color}) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: IconBox(icon, size: 40, iconSize: 22, fg: color ?? AppColors.ink),
          title: Text(title, style: AppText.bodyStrong.copyWith(color: color)),
          subtitle: value == null ? null : Text(value, style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: onTap == null || color != null ? null : const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          onTap: onTap,
        );
    Widget kpi(String label, String value) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small.copyWith(fontSize: 12)),
              Text(value, style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        );
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
          Center(child: Avatar(name, size: 72, dark: true)),
          const SizedBox(height: 10),
          Text(name, style: AppText.h3, textAlign: TextAlign.center),
          Text(tr('$role · Магазин «${st.store?['name'] ?? ''}»', '$role · «${st.store?['name'] ?? ''}» doʻkoni'), style: AppText.small, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (d != null)
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Мой день', 'Mening kunim'), style: AppText.title),
                const SizedBox(height: 10),
                Row(children: [
                  kpi(tr('Продажи', 'Sotuvlar'), money(d['sales'])),
                  const SizedBox(width: 8),
                  kpi(tr('Чеков', 'Cheklar'), '${d['receipts'] ?? 0}'),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  kpi(tr('Собрано заказов', 'Yigʻilgan buyurtmalar'), '${d['orders_picked'] ?? 0}'),
                  const SizedBox(width: 8),
                  kpi(tr('Списаний', 'Hisobdan chiqarish'), '${d['write_offs'] ?? 0}'),
                ]),
              ]),
            ),
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(children: [
              row(Icons.storefront_rounded, tr('Магазин', 'Doʻkon'), value: '${st.store?['name'] ?? ''}', onTap: st.stores.length > 1 ? () => pickStore(context) : null),
              ListenableBuilder(
                listenable: Lang.instance,
                builder: (context, _) => row(Icons.translate_rounded, tr('Язык', 'Til'), value: Lang.names[Lang.instance.code], onTap: () async {
                  final v = await pickLanguage(context);
                  if (v == null || !context.mounted) return;
                  try {
                    await context.read<Api>().put('/me/language', {'language': v});
                  } catch (_) {
                    // язык пушей — не страшно, если не сохранился
                  }
                }),
              ),
              row(Icons.lock_rounded, tr('Сменить пароль', 'Parolni oʻzgartirish'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NewPasswordScreen()))),
              row(Icons.verified_user_rounded, tr('Мои права', 'Huquqlarim'),
                  value: perms.take(3).map(permissionTitle).join(', ') + (perms.length > 3 ? '…' : ''),
                  onTap: () => infoSheet(context,
                      icon: Icons.verified_user_rounded,
                      title: tr('Мои права', 'Huquqlarim'),
                      text: '${perms.map((p) => '• ${permissionTitle(p)}').join('\n')}\n\n${tr('Права меняет владелец: Сотрудники → Роли.', 'Huquqlarni egasi oʻzgartiradi: Xodimlar → Rollar.')}')),
              row(Icons.logout_rounded, tr('Выйти', 'Chiqish'), onTap: _logout, color: AppColors.primary),
            ]),
          ),
          const SizedBox(height: 16),
          Text('SM Сотрудник $appVersion', style: AppText.small, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

/// «Сменить пароль»: текущий и новый (8+ символов, буквы и цифры).
class NewPasswordScreen extends StatefulWidget {
  const NewPasswordScreen({super.key});

  @override
  State<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends State<NewPasswordScreen> {
  final _current = TextEditingController();
  final _pw = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _pw.dispose();
    _repeat.dispose();
    super.dispose();
  }

  List<(bool, String)> get _checks {
    final p = _pw.text;
    return [
      (p.length >= 8 && p.length <= 72, tr('8 символов и больше', '8 ta belgi va undan koʻp')),
      (RegExp(r'\p{L}', unicode: true).hasMatch(p) && RegExp(r'\d').hasMatch(p), tr('Есть буквы и цифры', 'Harflar va raqamlar bor')),
      (p.isNotEmpty && p == _repeat.text, tr('Пароли совпадают', 'Parollar mos keladi')),
    ];
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Api>().post('/auth/store/password', {'current_password': _current.text, 'new_password': _pw.text});
      if (!mounted) return;
      toast(context, tr('Пароль изменён', 'Parol oʻzgartirildi'));
      Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.code == 'wrong_password' ? tr('Текущий пароль неверный', 'Joriy parol notoʻgʻri') : e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _current.text.isNotEmpty && _checks.every((c) => c.$1);
    Widget field(TextEditingController c, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(controller: c, obscureText: true, onChanged: (_) => setState(() {}), decoration: InputDecoration(hintText: label)),
        );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Сменить пароль', 'Parolni oʻzgartirish'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        field(_current, tr('Текущий пароль', 'Joriy parol')),
        field(_pw, tr('Новый пароль', 'Yangi parol')),
        field(_repeat, tr('Повторите пароль', 'Parolni takrorlang')),
        for (final (ok, label) in _checks)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              Icon(Icons.check_circle_rounded, size: 18, color: ok ? AppColors.success : AppColors.muted),
              const SizedBox(width: 8),
              Text(label, style: AppText.small.copyWith(color: ok ? AppColors.successInk : AppColors.text2)),
            ]),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: AppText.small.copyWith(color: AppColors.error, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 16),
        BigButton(label: tr('Сохранить', 'Saqlash'), icon: Icons.check_rounded, busy: _busy, onPressed: ready ? _save : null),
        const SizedBox(height: 8),
        Text(tr('Другие ваши входы (на других телефонах) закроются.', 'Boshqa kirishlaringiz (boshqa telefonlarda) yopiladi.'), style: AppText.small, textAlign: TextAlign.center),
      ]),
    );
  }
}
