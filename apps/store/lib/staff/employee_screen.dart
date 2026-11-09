import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'staff_logic.dart';
import 'staff_ui.dart';

/// С5 · Карточка сотрудника: роль и магазины, ПИН для кассы (сменить /
/// убрать), вход в «SM Сотрудник» (новый пароль / убрать), «Работает».
class EmployeeScreen extends StatefulWidget {
  const EmployeeScreen({super.key, required this.employee, required this.roles, required this.hasPin});

  final Map<String, dynamic> employee;
  final List<Map<String, dynamic>> roles;
  final bool hasPin;

  @override
  State<EmployeeScreen> createState() => _EmployeeScreenState();
}

class _EmployeeScreenState extends State<EmployeeScreen> {
  late Map<String, dynamic> _e = widget.employee;
  late bool _hasPin = widget.hasPin;
  // Вход: null — ещё не загрузили; {} — входа нет.
  Map<String, dynamic>? _login;
  String? _busy;

  String get _id => '${_e['id']}';
  bool get _owner => _e['is_owner'] == true;

  @override
  void initState() {
    super.initState();
    _loadLogin();
  }

  Future<void> _loadLogin() async {
    try {
      final l = await context.read<Api>().get('/store/employees/$_id/login') as Map<String, dynamic>;
      if (mounted) setState(() => _login = l);
    } on ApiError catch (e) {
      if (mounted) setState(() => _login = e.status == 404 ? const {} : null);
    } catch (_) {
      if (mounted) setState(() => _login = null);
    }
  }

  /// Выполнить действие с индикатором; ошибка — снэкбар.
  Future<T?> _run<T>(String what, Future<T> Function(Api api) f, {String? done}) async {
    setState(() => _busy = what);
    try {
      final r = await f(context.read<Api>());
      if (mounted && done != null) snack(context, done);
      return r;
    } on ApiError catch (e) {
      if (mounted) snack(context, e.message);
      return null;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _patch(Map<String, dynamic> body, {String? done}) async {
    final r = await _run('patch', (api) => api.patch('/store/employees/$_id', body), done: done);
    if (r is Map<String, dynamic> && mounted) setState(() => _e = r);
  }

  Future<void> _chooseRole() async {
    final roles = [
      for (final r in widget.roles)
        if (r['is_owner'] != true) r,
    ];
    final id = await showSheet<String>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Роль', 'Rol'), style: AppText.h3),
        const SizedBox(height: 8),
        for (final r in roles)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${r['name']}', style: AppText.bodyStrong),
            subtitle: Text(rightsCount(((r['permissions'] as List?) ?? const []).length), style: AppText.small),
            trailing: '${r['id']}' == '${_e['role_id']}' ? const Icon(Icons.check_circle_rounded, color: AppColors.primary) : null,
            onTap: () => Navigator.pop(ctx, '${r['id']}'),
          ),
      ]),
    );
    if (id != null && id != '${_e['role_id']}') await _patch({'role_id': id}, done: tr('Роль изменена', 'Rol oʻzgartirildi'));
  }

  Future<void> _chooseStores() async {
    final st = context.read<StoreState>();
    final picked = <String>{...((_e['store_ids'] as List?) ?? const []).map((e) => '$e')};
    var all = _e['all_stores'] == true;
    final ok = await showSheet<bool>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Где работает', 'Qayerda ishlaydi'), style: AppText.h3),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: all,
            onChanged: (v) => set(() => all = v),
            title: Text(tr('Все магазины', 'Barcha doʻkonlar'), style: AppText.bodyStrong),
          ),
          if (!all)
            for (final s in st.stores)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: picked.contains('${s['id']}'),
                onChanged: (v) => set(() => v == true ? picked.add('${s['id']}') : picked.remove('${s['id']}')),
                title: Text('${s['name']}', style: AppText.body),
              ),
          const SizedBox(height: 16),
          SheetButton(label: tr('Сохранить', 'Saqlash'), onPressed: all || picked.isNotEmpty ? () => Navigator.pop(ctx, true) : null),
        ]),
      ),
    );
    if (ok == true) await _patch({'all_stores': all, 'store_ids': all ? <String>[] : picked.toList()}, done: tr('Сохранено', 'Saqlandi'));
  }

  Future<void> _setPin() async {
    final pin = await askPin(context, name: '${_e['full_name']}');
    if (pin == null || !mounted) return;
    final r = await _run('pin', (api) => api.put('/store/pos/pins/$_id', {'pin': pin}), done: tr('ПИН сохранён — кассы получат его за минуту', 'PIN saqlandi — kassalar uni bir daqiqada oladi'));
    if (r != null && mounted) setState(() => _hasPin = true);
  }

  Future<void> _clearPin() async {
    final ok = await confirmSheet(
      context,
      title: tr('Убрать ПИН?', 'PIN olib tashlansinmi?'),
      text: tr('Сотрудник не сможет войти на кассе, пока не зададите новый.', 'Yangisini bermaguningizcha xodim kassaga kira olmaydi.'),
      confirm: tr('Убрать', 'Olib tashlash'),
      icon: Icons.dialpad_rounded,
    );
    if (!ok || !mounted) return;
    final r = await _run('pin', (api) => api.delete('/store/pos/pins/$_id'), done: tr('ПИН убран', 'PIN olib tashlandi'));
    if (r != null && mounted) setState(() => _hasPin = false);
  }

  Future<void> _newPassword({required bool first}) async {
    if (!first) {
      final ok = await confirmSheet(
        context,
        title: tr('Новый пароль?', 'Yangi parol?'),
        text: tr('Старый пароль сразу перестанет работать, сотрудник выйдет из приложения. Покажем новый временный пароль.',
            'Eski parol darhol ishlamay qoladi, xodim ilovadan chiqadi. Yangi vaqtinchalik parolni koʻrsatamiz.'),
        confirm: tr('Дать новый пароль', 'Yangi parol berish'),
        icon: Icons.lock_reset_rounded,
      );
      if (!ok || !mounted) return;
    }
    final r = await _run('login', (api) => api.put('/store/employees/$_id/login', {'generate_password': true}),
        done: first ? tr('Вход выдан', 'Kirish berildi') : tr('Новый пароль готов', 'Yangi parol tayyor'));
    if (r is Map<String, dynamic> && mounted) setState(() => _login = r);
  }

  Future<void> _removeLogin() async {
    final ok = await confirmSheet(
      context,
      title: tr('Убрать вход?', 'Kirish olib tashlansinmi?'),
      text: tr('Сотрудник сразу выйдет из «SM Сотрудник» и не сможет войти, пока не выдадите вход снова.',
          'Xodim «SM Xodim»dan darhol chiqadi va kirishni qayta bermaguningizcha kira olmaydi.'),
      confirm: tr('Убрать вход', 'Kirishni olib tashlash'),
      icon: Icons.no_accounts_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = 'login');
    try {
      await context.read<Api>().delete('/store/employees/$_id/login');
      if (!mounted) return;
      setState(() => _login = const {});
      snack(context, tr('Вход убран', 'Kirish olib tashlandi'));
    } on ApiError catch (e) {
      if (mounted) snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _card({required List<Widget> children, EdgeInsets padding = const EdgeInsets.all(16)}) =>
      AppCard(padding: padding, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children));

  Widget _head(IconData icon, String title, [Widget? chip]) => Row(children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: AppText.bodyStrong)),
        if (chip != null) chip,
      ]);

  Widget _btn(String label, IconData icon, VoidCallback? onTap, {bool danger = false}) => Expanded(
        child: SizedBox(
          height: 44,
          child: FilledButton.tonalIcon(
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.soft,
              foregroundColor: danger ? AppColors.primary : AppColors.ink,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final e = _e;
    final active = e['status'] == 'active';
    final storeNames = e['all_stores'] == true || _owner
        ? tr('Все магазины', 'Barcha doʻkonlar')
        : [
            for (final s in st.stores)
              if (((e['store_ids'] as List?) ?? const []).contains(s['id'])) '${s['name']}',
          ].join(', ');
    final login = _login;
    final hasLogin = login != null && '${login['login'] ?? ''}'.isNotEmpty;
    final temp = '${login?['temp_password'] ?? ''}';
    final store = '${st.store?['name'] ?? ''}';
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Сотрудник', 'Xodim')),
        actions: [
          IconButton(
            tooltip: tr('Позвонить', 'Qoʻngʻiroq'),
            icon: const Icon(Icons.call_rounded, color: AppColors.successInk),
            onPressed: () => launchUrl(Uri.parse('tel:${e['phone']}')),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        AppCard(
          child: Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: AppColors.successSoft,
              foregroundColor: AppColors.successInk,
              child: Text(initials('${e['full_name']}'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${e['full_name']}', style: AppText.title),
                Text(formatPhone(e['phone']), style: AppText.small),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text(tr('Роль', 'Rol'), style: AppText.body.copyWith(color: AppColors.text2)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_owner ? tr('Владелец', 'Egasi') : '${e['role_name']}', style: AppText.bodyStrong),
                if (!_owner) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ]),
              onTap: _owner || _busy != null ? null : _chooseRole,
            ),
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: Text(tr('Магазин', 'Doʻkon'), style: AppText.body.copyWith(color: AppColors.text2)),
              trailing: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Text(storeNames.isEmpty ? '—' : storeNames, style: AppText.bodyStrong, overflow: TextOverflow.ellipsis)),
                  if (!_owner && st.stores.length > 1) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                ]),
              ),
              onTap: _owner || st.stores.length < 2 || _busy != null ? null : _chooseStores,
            ),
          ]),
        ),
        const SizedBox(height: 12),
        _card(children: [
          _head(Icons.dialpad_rounded, tr('ПИН для кассы', 'Kassa uchun PIN'),
              _hasPin ? StatusChip(tr('Задан', 'Berilgan'), tone: ChipTone.green) : StatusChip(tr('Нет', 'Yoʻq'), tone: ChipTone.red)),
          const SizedBox(height: 6),
          Text(tr('Вводит его при входе на кассу. Забыл — задайте новый.', 'Uni kassaga kirishda kiritadi. Unutsa — yangisini bering.'), style: AppText.small),
          const SizedBox(height: 12),
          Row(children: [
            _btn(_hasPin ? tr('Сменить ПИН', 'PINni almashtirish') : tr('Задать ПИН', 'PIN berish'), Icons.edit_rounded, _busy != null || !active ? null : _setPin),
            if (_hasPin) ...[const SizedBox(width: 8), _btn(tr('Убрать', 'Olib tashlash'), Icons.close_rounded, _busy != null ? null : _clearPin, danger: true)],
          ]),
        ]),
        const SizedBox(height: 12),
        _card(children: [
          _head(
            Icons.smartphone_rounded,
            tr('Вход в «SM Сотрудник»', '«SM Xodim»ga kirish'),
            !hasLogin
                ? null
                : temp.isNotEmpty
                    ? StatusChip(tr('не входил(а)', 'kirmagan'), tone: ChipTone.amber)
                    : (login?['last_login_at'] != null ? StatusChip(tr('входил(а)', 'kirgan'), tone: ChipTone.green) : null),
          ),
          const SizedBox(height: 10),
          if (login == null)
            const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
          else if (_owner)
            Text(
              hasLogin
                  ? tr('Логин ${login['login']}. Логин и пароль владельца меняет Super Market — напишите в поддержку.',
                      'Login ${login['login']}. Ega login va parolini Super Market oʻzgartiradi — qoʻllab-quvvatlashga yozing.')
                  : tr('Логин владельцу выдаёт Super Market.', 'Egasiga loginni Super Market beradi.'),
              style: AppText.small,
            )
          else if (!hasLogin) ...[
            Text(tr('Входа нет. Выдадим логин и временный пароль — сотрудник сменит пароль при первом входе.',
                'Kirish yoʻq. Login va vaqtinchalik parol beramiz — xodim birinchi kirishda parolni almashtiradi.'), style: AppText.small),
            const SizedBox(height: 12),
            Row(children: [_btn(tr('Выдать вход', 'Kirish berish'), Icons.key_rounded, _busy != null || !active ? null : () => _newPassword(first: true))]),
          ] else ...[
            CredentialsBox(login: '${login['login']}', password: temp),
            if (temp.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => shareTelegram(context, employeeLoginMessage(store, '${login['login']}', temp)),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(tr('Отправить в Telegram', 'Telegram’da yuborish')),
              ),
            ],
            const SizedBox(height: 8),
            Row(children: [
              _btn(tr('Новый пароль', 'Yangi parol'), Icons.lock_reset_rounded, _busy != null || !active ? null : () => _newPassword(first: false)),
              const SizedBox(width: 8),
              _btn(tr('Убрать вход', 'Kirishni olib tashlash'), Icons.no_accounts_rounded, _busy != null ? null : _removeLogin, danger: true),
            ]),
          ],
        ]),
        if (!_owner) ...[
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SwitchListTile(
              value: active,
              onChanged: _busy != null
                  ? null
                  : (v) => _patch({'status': v ? 'active' : 'inactive'}, done: v ? tr('Сотрудник снова работает', 'Xodim yana ishlaydi') : tr('Сотрудник отключён', 'Xodim oʻchirildi')),
              title: Text(tr('Работает', 'Ishlaydi'), style: AppText.bodyStrong),
              subtitle: Text(tr('Выключите — сразу выйдет из приложения и с касс', 'Oʻchirsangiz — ilovadan va kassalardan darhol chiqadi'), style: AppText.small),
            ),
          ),
        ],
      ]),
    );
  }
}
