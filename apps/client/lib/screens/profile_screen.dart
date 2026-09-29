import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../state.dart';
import '../ui/brand.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';
import 'family_screen.dart';
import 'favorites_screen.dart';
import 'order_screen.dart';
import 'orders_screen.dart';

/// Версия приложения (совпадает с pubspec.yaml).
const appVersion = '0.5.0';

const _languages = {'ru': 'Русский', 'uz': 'O‘zbekcha'};
const _cities = ['Ташкент', 'Самарканд', 'Бухара', 'Андижан', 'Наманган', 'Фергана', 'Нукус', 'Карши', 'Навои', 'Ургенч', 'Джизак', 'Термез'];

/// Профиль по макету Figma: карточка покупателя, активный заказ, статистика,
/// покупки, настройки, помощь, выход и удаление аккаунта.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final state = context.read<AppState>();
      state.loadFamily().catchError((_) {});
      await state.loadProfile();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _update(Map<String, dynamic> patch) async {
    try {
      await context.read<AppState>().updateProfile(patch);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = state.profile;
    final st = state.stats;
    if (p == null) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: _error == null
              ? const Center(child: CircularProgressIndicator())
              : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить профиль', text: _error.toString(), action: 'Повторить', onAction: _load),
        ),
      );
    }
    final notif = (p['notifications'] as Map<String, dynamic>?) ?? const {};
    final active = st?['active_order'] as Map<String, dynamic>?;
    final name = '${p['full_name'] ?? ''}';
    final supportUrl = '${p['support_url'] ?? ''}';
    final privacyUrl = '${p['privacy_url'] ?? ''}';

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 180), children: [
            const Text('Профиль', style: AppText.h2),
            const SizedBox(height: 16),
            _UserCard(name: name, phone: '${p['phone']}', telegram: p['telegram_linked'] == true, onTap: () => _editName(name)),
            if (active != null) ...[
              const SizedBox(height: 12),
              _ActiveOrder(order: active, onTap: () => _push(OrderScreen(id: active['id'] as String))),
            ],
            if (st != null) ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _Stat(value: '${st['orders_count']}', label: _plural(st['orders_count'] as num? ?? 0, 'заказ', 'заказа', 'заказов'))),
                const SizedBox(width: 10),
                Expanded(child: _Stat(value: _short(st['saved']), label: 'сум сэкономлено', accent: true)),
                const SizedBox(width: 10),
                Expanded(child: _Stat(value: '${st['addresses_count']}', label: _plural(st['addresses_count'] as num? ?? 0, 'адрес', 'адреса', 'адресов'))),
              ]),
            ],
            const SizedBox(height: 24),
            const _GroupTitle('Покупки'),
            _Group(children: [
              AppListRow(
                icon: Icons.receipt_long_outlined,
                title: 'Мои заказы',
                trailing: _count(st?['orders_count']),
                onTap: () => _push(const OrdersScreen()),
              ),
              AppListRow(
                icon: Icons.location_on_outlined,
                title: 'Адреса доставки',
                trailing: _count(st?['addresses_count']),
                onTap: () => _push(const AddressesScreen()),
              ),
              AppListRow(
                icon: Icons.favorite_border_rounded,
                title: 'Избранное',
                trailing: _count(state.favorites.length),
                onTap: () => _push(const FavoritesScreen()),
              ),
              AppListRow(
                icon: Icons.family_restroom_rounded,
                title: 'Моя семья',
                subtitle: state.family == null ? 'Общий список покупок' : '${state.family!['name']}',
                trailing: state.familyForMe > 0 ? AppBadge(label: '${state.familyForMe}', kind: BadgeKind.discount) : null,
                divider: false,
                onTap: () => _push(const FamilyScreen()),
              ),
            ]),
            const SizedBox(height: 24),
            const _GroupTitle('Настройки'),
            _Group(children: [
              AppListRow(
                icon: Icons.notifications_none_rounded,
                title: 'Уведомления',
                subtitle: 'О статусе заказа',
                trailing: Switch(
                  value: notif['orders'] == true,
                  onChanged: (v) => _update({'notifications': {'orders': v}}),
                ),
                onTap: () => _notifications(notif),
              ),
              AppListRow(
                icon: Icons.language_rounded,
                title: 'Язык уведомлений',
                trailing: Text(_languages[p['language']] ?? 'Русский', style: AppText.small.copyWith(fontSize: 14)),
                onTap: () => _pick('Язык уведомлений', _languages, '${p['language']}', (v) => _update({'language': v})),
              ),
              AppListRow(
                icon: Icons.location_city_outlined,
                title: 'Город',
                trailing: Text('${p['city']}'.isEmpty ? 'Не выбран' : '${p['city']}', style: AppText.small.copyWith(fontSize: 14)),
                divider: false,
                onTap: () => _pick('Город', {for (final c in _cities) c: c}, '${p['city']}', (v) => _update({'city': v})),
              ),
            ]),
            const SizedBox(height: 24),
            const _GroupTitle('Помощь'),
            _Group(children: [
              if (supportUrl.isNotEmpty)
                AppListRow(icon: Icons.send_rounded, title: 'Поддержка в Telegram', onTap: () => _open(supportUrl)),
              if (privacyUrl.isNotEmpty)
                AppListRow(icon: Icons.shield_outlined, title: 'Конфиденциальность', onTap: () => _open(privacyUrl)),
              AppListRow(icon: Icons.info_outline_rounded, title: 'О приложении', divider: false, onTap: _about),
            ]),
            const SizedBox(height: 24),
            Material(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                onTap: _logout,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.logout_rounded, color: AppColors.error, size: 20),
                    SizedBox(width: 8),
                    Text('Выйти из аккаунта', style: TextStyle(fontFamily: 'Inter', fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.error)),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: AppColors.text2),
                onPressed: _deleteAccount,
                child: const Text('Удалить аккаунт'),
              ),
            ),
            const SizedBox(height: 4),
            Center(child: Text('Super Market · версия $appVersion', style: AppText.caption)),
          ]),
        ),
      ),
    );
  }

  Widget? _count(Object? n) {
    final v = n is num ? n : num.tryParse('${n ?? ''}');
    if (v == null || v == 0) return null;
    return Text('$v', style: AppText.small.copyWith(fontSize: 14));
  }

  Future<void> _open(String url) async {
    try {
      await openUrl(url);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _editName(String current) async {
    final ctrl = TextEditingController(text: current);
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Как к вам обращаться?', style: AppText.h3),
          const SizedBox(height: 16),
          TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 100,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Имя и фамилия', counterText: ''),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 16),
          AppButton(label: 'Сохранить', onPressed: () => Navigator.pop(ctx, ctrl.text)),
        ]),
      ),
    );
    ctrl.dispose();
    if (name != null && name.trim() != current) await _update({'full_name': name.trim()});
  }

  Future<void> _pick(String title, Map<String, String> options, String current, ValueChanged<String> onPick) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(title, style: AppText.h3)),
            for (final e in options.entries)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text(e.value, style: AppText.bodyMedium),
                trailing: Icon(
                  e.key == current ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: e.key == current ? AppColors.primary : AppColors.muted,
                ),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
    if (v != null && v != current) onPick(v);
  }

  Future<void> _notifications(Map<String, dynamic> current) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: Consumer<AppState>(builder: (ctx, state, _) {
          final n = (state.profile?['notifications'] as Map<String, dynamic>?) ?? current;
          Widget row(String key, String title, String subtitle) => SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text(title, style: AppText.bodyMedium),
                subtitle: Text(subtitle, style: AppText.small),
                value: n[key] == true,
                onChanged: (v) => _update({'notifications': {key: v}}),
              );
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Уведомления', style: AppText.h3)),
            row('orders', 'Статус заказа', 'Оплачен, собран, в пути, доставлен'),
            row('promos', 'Акции и скидки', 'Не чаще раза в неделю'),
            row('telegram', 'Дублировать в Telegram', 'Если push не дошёл — пришлём в бот'),
            const SizedBox(height: 12),
          ]);
        }),
      ),
    );
  }

  void _about() {
    showAboutDialog(
      context: context,
      applicationName: 'Super Market',
      applicationVersion: appVersion,
      applicationIcon: const BrandMark(size: 40),
      children: const [Text('Продукты из магазинов рядом с доставкой за 30–60 минут.')],
    );
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(style: TextButton.styleFrom(foregroundColor: AppColors.error), onPressed: () => Navigator.pop(ctx, true), child: const Text('Выйти')),
        ],
      ),
    );
    if (ok == true && mounted) await context.read<Api>().logout();
  }

  Future<void> _deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить аккаунт?'),
        content: const Text(
            'Удалим имя, адреса, избранное и настройки. История заказов останется у магазинов без вашего телефона и адреса — это нужно для учёта. Восстановить аккаунт будет нельзя.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(style: TextButton.styleFrom(foregroundColor: AppColors.error), onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<Api>();
    try {
      await api.delete('/client/me');
      await api.forget();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

/// «148 тыс», «1,2 млн».
String _short(Object? v) {
  final n = num.tryParse('${v ?? ''}') ?? 0;
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1).replaceAll('.', ',').replaceAll(',0', '')} млн';
  if (n >= 1000) return '${(n / 1000).round()} тыс';
  return money(n, suffix: false);
}

String _plural(num n, String one, String few, String many) {
  final i = n.toInt(), m10 = i % 10, m100 = i % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.name, required this.phone, required this.telegram, required this.onTap});
  final String name;
  final String phone;
  final bool telegram;
  final VoidCallback onTap;

  String get _initials {
    final parts = name.split(' ').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    return parts.take(2).map((s) => s[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 60,
              height: 60,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
              child: _initials.isEmpty
                  ? const Icon(Icons.person_rounded, color: AppColors.white, size: 30)
                  : Text(_initials, style: AppText.title.copyWith(color: AppColors.white, fontSize: 20)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name.isEmpty ? 'Добавьте имя' : name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppText.title.copyWith(color: name.isEmpty ? AppColors.primary : AppColors.ink)),
                const SizedBox(height: 2),
                Text(_phone(phone), style: AppText.small),
                if (telegram) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.send_rounded, size: 12, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text('Вход через Telegram', style: AppText.caption.copyWith(color: AppColors.primary)),
                    ]),
                  ),
                ],
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.ink),
          ]),
        ),
      ),
    );
  }
}

/// +998901234567 → +998 90 123-45-67.
String _phone(String p) {
  final m = RegExp(r'^\+998(\d{2})(\d{3})(\d{2})(\d{2})$').firstMatch(p);
  return m == null ? p : '+998 ${m[1]} ${m[2]}-${m[3]}-${m[4]}';
}

class _ActiveOrder extends StatelessWidget {
  const _ActiveOrder({required this.order, required this.onTap});
  final Map<String, dynamic> order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = '${order['status']}';
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            IconBox(status == 'delivering' ? Icons.local_shipping_outlined : Icons.shopping_bag_outlined,
                bg: const Color(0x2EFFFFFF), fg: AppColors.white, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Заказ № ${order['number']} · ${(statusTitles[status] ?? status).toLowerCase()}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                const SizedBox(height: 2),
                Text('${order['store_name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(color: const Color(0xCCFFFFFF))),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.white),
          ]),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.accent = false});
  final String value;
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FittedBox(child: Text(value, style: AppText.title.copyWith(color: accent ? AppColors.accent : AppColors.ink))),
        const SizedBox(height: 2),
        Text(label, maxLines: 2, style: AppText.caption),
      ]),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AppCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: children));
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(text.toUpperCase(), style: AppText.caption.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      );
}
