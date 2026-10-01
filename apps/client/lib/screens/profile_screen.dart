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
import 'help_screen.dart';
import 'order_screen.dart';
import 'orders_screen.dart';
import 'profile_details_screen.dart';
import 'root_shell.dart';

/// Версия приложения (совпадает с pubspec.yaml).
const appVersion = '0.6.0';

const _languages = {'ru': 'Русский', 'uz': 'O‘zbekcha'};
const _cities = ['Ташкент', 'Самарканд', 'Бухара', 'Андижан', 'Наманган', 'Фергана', 'Нукус', 'Карши', 'Навои', 'Ургенч', 'Джизак', 'Термез'];

/// Имя для показа: «Имя Фамилия», иначе full_name.
String profileName(Map<String, dynamic>? p) {
  if (p == null) return '';
  final parts = ['${p['first_name'] ?? ''}'.trim(), '${p['last_name'] ?? ''}'.trim()].where((s) => s.isNotEmpty);
  return parts.isNotEmpty ? parts.join(' ') : '${p['full_name'] ?? ''}'.trim();
}

/// +998901234567 → +998 90 123-45-67.
String formatPhone(String p) {
  final m = RegExp(r'^\+998(\d{2})(\d{3})(\d{2})(\d{2})$').firstMatch(p);
  return m == null ? p : '+998 ${m[1]} ${m[2]}-${m[3]}-${m[4]}';
}

/// Вкладка «Профиль» (Figma «10 Профиль»): покупатель, текущий заказ,
/// покупки, помощь и настройки.
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

  void _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = state.profile;
    if (p == null) {
      return Scaffold(
        body: SafeArea(
          child: _error == null
              ? const Center(child: CircularProgressIndicator())
              : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить профиль', text: _error.toString(), action: 'Повторить', onAction: _load),
        ),
      );
    }
    final active = state.stats?['active_order'] as Map<String, dynamic>?;
    final name = profileName(p);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, tabBottomInset(context)), children: [
            const Text('Профиль', style: AppText.h1),
            const SizedBox(height: 16),
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap: () => _push(const ProfileDetailsScreen()),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Avatar(name: name, size: 64),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name.isEmpty ? 'Добавьте имя' : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.h3.copyWith(fontWeight: FontWeight.w700, color: name.isEmpty ? AppColors.primary : AppColors.ink)),
                      const SizedBox(height: 2),
                      Text(formatPhone('${p['phone']}'), style: AppText.body.copyWith(color: AppColors.text2)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
                ]),
              ),
            ),
            if (active != null) ...[
              const SizedBox(height: 16),
              ActiveOrderCard(order: active, onTap: () => _push(OrderScreen(id: active['id'] as String))),
            ],
            const SizedBox(height: 16),
            SoftGroup(children: [
              AppListRow(icon: Icons.inventory_2_rounded, title: 'История заказов', onTap: () => _push(const OrdersScreen())),
              AppListRow(
                icon: Icons.family_restroom_rounded,
                title: 'Моя семья',
                trailing: state.familyForMe > 0 ? AppBadge(label: '${state.familyForMe}', kind: BadgeKind.discount) : null,
                onTap: () => _push(const FamilyScreen()),
              ),
              AppListRow(icon: Icons.favorite_rounded, title: 'Избранное', onTap: () => _push(const FavoritesScreen())),
              AppListRow(icon: Icons.location_on_rounded, title: 'Мои адреса', divider: false, onTap: () => _push(const AddressesScreen())),
            ]),
            const SizedBox(height: 16),
            SoftGroup(children: [
              AppListRow(icon: Icons.help_rounded, title: 'Помощь', onTap: () => _push(const HelpScreen())),
              AppListRow(icon: Icons.settings_rounded, title: 'Настройки', divider: false, onTap: () => _push(const SettingsScreen())),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Серая карточка-группа строк (как в макете профиля и настроек).
class SoftGroup extends StatelessWidget {
  const SoftGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.xl)),
        child: Column(children: children),
      );
}

/// Тёмная карточка текущего заказа: «Заказ № 1042 · в пути».
class ActiveOrderCard extends StatelessWidget {
  const ActiveOrderCard({super.key, required this.order, required this.onTap});
  final Map<String, dynamic> order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = '${order['status']}';
    final courier = '${order['courier_name'] ?? ''}';
    final sub = [
      '${order['store_name'] ?? ''}',
      if (courier.isNotEmpty) 'курьер $courier',
    ].where((s) => s.isNotEmpty).join(' · ');
    return Material(
      color: AppColors.dark,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(status == 'delivering' ? Icons.delivery_dining_rounded : Icons.shopping_bag_outlined, color: AppColors.white, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Заказ № ${order['number']} · ${(statusTitles[status] ?? status).toLowerCase()}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                if (sub.isNotEmpty)
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(color: const Color(0xCCFFFFFF))),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.white),
          ]),
        ),
      ),
    );
  }
}

/// «Настройки» (Figma «11 Настройки»): личные данные, язык, уведомления,
/// город, поддержка, о приложении, удаление аккаунта и выход.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _update(Map<String, dynamic> patch) async {
    try {
      await context.read<AppState>().updateProfile(patch);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _open(String url) async {
    try {
      await openUrl(url);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppState>().profile ?? const <String, dynamic>{};
    final notif = (p['notifications'] as Map<String, dynamic>?) ?? const {};
    final supportUrl = '${p['support_url'] ?? ''}';
    final city = '${p['city'] ?? ''}';
    Widget value(String v) => Padding(padding: const EdgeInsets.only(right: 4), child: Text(v, style: AppText.small.copyWith(fontSize: 14)));
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const PageHeader(title: 'Настройки'),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
              SoftGroup(children: [
                AppListRow(
                  icon: Icons.account_circle_rounded,
                  title: 'Личные данные',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileDetailsScreen())),
                ),
                AppListRow(
                  icon: Icons.language_rounded,
                  title: 'Язык приложения',
                  trailing: value(_languages[p['language']] ?? 'Русский'),
                  onTap: () => _pick('Язык приложения', _languages, '${p['language']}', (v) => _update({'language': v})),
                ),
                AppListRow(
                  icon: Icons.notifications_rounded,
                  title: 'Уведомления',
                  trailing: value(notif['orders'] == true ? 'Вкл' : 'Выкл'),
                  divider: false,
                  onTap: () => _notifications(notif),
                ),
              ]),
              const SizedBox(height: 12),
              SoftGroup(children: [
                AppListRow(
                  icon: Icons.location_city_rounded,
                  title: 'Город',
                  trailing: value(city.isEmpty ? 'Не выбран' : city),
                  onTap: () => _pick('Город', {for (final c in _cities) c: c}, city, (v) => _update({'city': v})),
                ),
                if (supportUrl.isNotEmpty) AppListRow(icon: Icons.headset_mic_rounded, title: 'Служба поддержки', onTap: () => _open(supportUrl)),
                AppListRow(icon: Icons.info_rounded, title: 'О приложении', divider: false, onTap: _about),
              ]),
              const SizedBox(height: 12),
              SoftGroup(children: [
                AppListRow(icon: Icons.delete_rounded, title: 'Удалить аккаунт', divider: false, onTap: _deleteAccount),
              ]),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: AppColors.primarySoft,
                  foregroundColor: AppColors.primary,
                  shape: const StadiumBorder(),
                  textStyle: AppText.bodyStrong.copyWith(fontSize: 17),
                ),
                onPressed: _logout,
                child: const Text('Выйти'),
              ),
            ),
          ),
        ]),
      ),
    );
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
            row('promos', 'Акции и скидки', 'Скидки, новые магазины и предложения'),
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
    if (ok != true || !mounted) return;
    final nav = Navigator.of(context);
    await context.read<Api>().logout();
    nav.popUntil((r) => r.isFirst);
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
    final nav = Navigator.of(context);
    try {
      await api.delete('/client/me');
      await api.forget();
      nav.popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}
