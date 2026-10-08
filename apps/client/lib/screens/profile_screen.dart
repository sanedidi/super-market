import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../guest.dart';
import '../main.dart';
import '../state.dart';
import '../ui/brand.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';
import 'debts_screen.dart';
import 'family_screen.dart';
import 'favorites_screen.dart';
import 'help_screen.dart';
import 'order_screen.dart';
import 'orders_screen.dart';
import 'profile_details_screen.dart';
import 'root_shell.dart';

/// Версия приложения (совпадает с pubspec.yaml).
const appVersion = '0.9.0';

/// Города: ключ — как хранится в профиле на сервере (по-русски), значение — подпись.
Map<String, String> get _cities => {
      'Ташкент': tr('Ташкент', 'Toshkent'),
      'Самарканд': tr('Самарканд', 'Samarqand'),
      'Бухара': tr('Бухара', 'Buxoro'),
      'Андижан': tr('Андижан', 'Andijon'),
      'Наманган': tr('Наманган', 'Namangan'),
      'Фергана': tr('Фергана', 'Fargʻona'),
      'Нукус': tr('Нукус', 'Nukus'),
      'Карши': tr('Карши', 'Qarshi'),
      'Навои': tr('Навои', 'Navoiy'),
      'Ургенч': tr('Ургенч', 'Urganch'),
      'Джизак': tr('Джизак', 'Jizzax'),
      'Термез': tr('Термез', 'Termiz'),
    };

/// Имя для показа: «Имя Фамилия», иначе full_name.
String profileName(Map<String, dynamic>? p) {
  if (p == null) return '';
  final parts = ['${p['first_name'] ?? ''}'.trim(), '${p['last_name'] ?? ''}'.trim()].where((s) => s.isNotEmpty);
  return parts.isNotEmpty ? parts.join(' ') : '${p['full_name'] ?? ''}'.trim();
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

  /// Раздел, которому нужен вход: гостю — шторка входа, потом раздел.
  Future<void> _gated(LoginReason reason, Widget screen) async {
    if (!await requireLogin(context, reason) || !mounted) return;
    _push(screen);
  }

  Future<void> _login() async {
    if (await openLogin(context) && mounted) _load();
  }

  /// Профиль гостя (Figma «Т5»): «Войдите в Super Market»; заказы, семья,
  /// избранное и адреса — после входа; помощь и настройки — сразу.
  Widget _guest() {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, tabBottomInset(context)), children: [
          Text(tr('Профиль', 'Profil'), style: AppText.h1),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: _login,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                const Avatar(name: '?', size: 64),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Войдите в Super Market', 'Super Marketga kiring'),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.h3.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(tr('Заказы, адреса и избранное', 'Buyurtmalar, manzillar va sevimlilar'), style: AppText.body.copyWith(color: AppColors.text2)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          SoftGroup(children: [
            AppListRow(
                icon: Icons.inventory_2_rounded,
                title: tr('История заказов', 'Buyurtmalar tarixi'),
                onTap: () => _gated(LoginReason.orders, const OrdersScreen())),
            AppListRow(
                icon: Icons.family_restroom_rounded,
                title: tr('Моя семья', 'Mening oilam'),
                onTap: () => _gated(LoginReason.family, const FamilyScreen())),
            AppListRow(
                icon: Icons.favorite_rounded,
                title: tr('Избранное', 'Sevimlilar'),
                onTap: () => _gated(LoginReason.favorite, const FavoritesScreen())),
            AppListRow(
              icon: Icons.location_on_rounded,
              title: tr('Мои адреса', 'Mening manzillarim'),
              divider: false,
              onTap: () => _gated(LoginReason.addresses, const AddressesScreen()),
            ),
          ]),
          const SizedBox(height: 16),
          SoftGroup(children: [
            AppListRow(icon: Icons.help_rounded, title: tr('Помощь', 'Yordam'), onTap: () => _push(const HelpScreen())),
            AppListRow(
                icon: Icons.settings_rounded, title: tr('Настройки', 'Sozlamalar'), divider: false, onTap: () => _push(const SettingsScreen())),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.isGuest) return _guest();
    final p = state.profile;
    if (p == null) {
      return Scaffold(
        body: SafeArea(
          child: _error == null
              ? const Center(child: CircularProgressIndicator())
              : EmptyState(
                  icon: Icons.wifi_off_rounded,
                  title: tr('Не удалось загрузить профиль', 'Profilni yuklab boʻlmadi'),
                  text: _error.toString(),
                  action: tr('Повторить', 'Qayta urinish'),
                  onAction: _load),
        ),
      );
    }
    final active = state.stats?['active_order'] as Map<String, dynamic>?;
    final name = profileName(p);
    final courierApp = '${p['courier_app_url'] ?? ''}';
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, tabBottomInset(context)), children: [
            Text(tr('Профиль', 'Profil'), style: AppText.h1),
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
                      Text(name.isEmpty ? tr('Добавьте имя', 'Ismingizni qoʻshing') : name,
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
            const DebtsProfileCard(),
            if (active != null) ...[
              const SizedBox(height: 16),
              ActiveOrderCard(order: active, onTap: () => _push(OrderScreen(id: active['id'] as String))),
            ],
            const SizedBox(height: 16),
            SoftGroup(children: [
              AppListRow(icon: Icons.inventory_2_rounded, title: tr('История заказов', 'Buyurtmalar tarixi'), onTap: () => _push(const OrdersScreen())),
              AppListRow(
                icon: Icons.family_restroom_rounded,
                title: tr('Моя семья', 'Mening oilam'),
                trailing: state.familyForMe > 0 ? AppBadge(label: '${state.familyForMe}', kind: BadgeKind.discount) : null,
                onTap: () => _push(const FamilyScreen()),
              ),
              AppListRow(icon: Icons.favorite_rounded, title: tr('Избранное', 'Sevimlilar'), onTap: () => _push(const FavoritesScreen())),
              AppListRow(
                  icon: Icons.location_on_rounded,
                  title: tr('Мои адреса', 'Mening manzillarim'),
                  divider: false,
                  onTap: () => _push(const AddressesScreen())),
            ]),
            if (courierApp.isNotEmpty) ...[
              const SizedBox(height: 16),
              CourierBanner(url: courierApp),
            ],
            const SizedBox(height: 16),
            SoftGroup(children: [
              AppListRow(icon: Icons.help_rounded, title: tr('Помощь', 'Yordam'), onTap: () => _push(const HelpScreen())),
              AppListRow(
                  icon: Icons.settings_rounded, title: tr('Настройки', 'Sozlamalar'), divider: false, onTap: () => _push(const SettingsScreen())),
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
      if (courier.isNotEmpty) tr('курьер $courier', 'kuryer $courier'),
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
                Text(
                    tr('Заказ № ${order['number']} · ${(statusTitles[status] ?? status).toLowerCase()}',
                        'Buyurtma № ${order['number']} · ${(statusTitles[status] ?? status).toLowerCase()}'),
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
  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadConfig();
  }

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

  /// Язык приложения: меняется сразу на устройстве; у вошедшего — сохраняется
  /// и в профиле (на нём приходят уведомления).
  Future<void> _setLanguage(String code) async {
    await Lang.instance.set(code);
    if (!mounted || context.read<AppState>().isGuest) return;
    await _update({'language': code});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // Гостю — только то, что не требует аккаунта: поддержка, политика, о приложении.
    final guest = state.isGuest;
    final p = state.profile ?? const <String, dynamic>{};
    final notif = (p['notifications'] as Map<String, dynamic>?) ?? const {};
    final supportUrl = state.link('support_url');
    final city = '${p['city'] ?? ''}';
    Widget value(String v) => Padding(padding: const EdgeInsets.only(right: 4), child: Text(v, style: AppText.small.copyWith(fontSize: 14)));
    // Гостю язык тоже можно сменить — строка в общей группе.
    Widget language({bool divider = true}) => AppListRow(
          icon: Icons.language_rounded,
          title: tr('Язык приложения', 'Ilova tili'),
          trailing: value(Lang.names[Lang.instance.code]!),
          divider: divider,
          onTap: () => _pick(tr('Язык приложения', 'Ilova tili'), Lang.names, Lang.instance.code, _setLanguage),
        );
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          PageHeader(title: tr('Настройки', 'Sozlamalar')),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
              if (!guest) ...[
                SoftGroup(children: [
                  AppListRow(
                    icon: Icons.account_circle_rounded,
                    title: tr('Личные данные', 'Shaxsiy maʼlumotlar'),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileDetailsScreen())),
                  ),
                  language(),
                  AppListRow(
                    icon: Icons.notifications_rounded,
                    title: tr('Уведомления', 'Bildirishnomalar'),
                    trailing: value(notif['orders'] == true ? tr('Вкл', 'Yoqilgan') : tr('Выкл', 'Oʻchirilgan')),
                    divider: false,
                    onTap: () => _notifications(notif),
                  ),
                ]),
                const SizedBox(height: 12),
              ],
              SoftGroup(children: [
                if (guest) language(),
                if (!guest)
                  AppListRow(
                    icon: Icons.location_city_rounded,
                    title: tr('Город', 'Shahar'),
                    trailing: value(city.isEmpty ? tr('Не выбран', 'Tanlanmagan') : (_cities[city] ?? city)),
                    onTap: () => _pick(tr('Город', 'Shahar'), _cities, city, (v) => _update({'city': v})),
                  ),
                if (supportUrl.isNotEmpty)
                  AppListRow(icon: Icons.headset_mic_rounded, title: tr('Служба поддержки', 'Qoʻllab-quvvatlash xizmati'), onTap: () => _open(supportUrl)),
                AppListRow(icon: Icons.privacy_tip_rounded, title: tr('Политика конфиденциальности', 'Maxfiylik siyosati'), onTap: () => _open(state.privacyUrl)),
                AppListRow(icon: Icons.info_rounded, title: tr('О приложении', 'Ilova haqida'), divider: false, onTap: _about),
              ]),
              if (!guest) ...[
                const SizedBox(height: 12),
                SoftGroup(children: [
                  AppListRow(icon: Icons.delete_rounded, title: tr('Удалить аккаунт', 'Akkauntni oʻchirish'), divider: false, onTap: _deleteAccount),
                ]),
              ],
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
                onPressed: guest ? _login : _logout,
                child: Text(guest ? tr('Войти', 'Kirish') : tr('Выйти', 'Chiqish')),
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
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(tr('Уведомления', 'Bildirishnomalar'), style: AppText.h3)),
            row('orders', tr('Статус заказа', 'Buyurtma holati'), tr('Оплачен, собран, в пути, доставлен', 'Toʻlandi, yigʻildi, yoʻlda, yetkazildi')),
            row('promos', tr('Акции и скидки', 'Aksiya va chegirmalar'), tr('Скидки, новые магазины и предложения', 'Chegirmalar, yangi doʻkonlar va takliflar')),
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
      children: [Text(tr('Продукты из магазинов рядом с доставкой за 30–60 минут.', 'Yaqindagi doʻkonlardan mahsulotlar — 30–60 daqiqada yetkazib beramiz.'))],
    );
  }

  Future<void> _login() => openLogin(context);

  Future<void> _logout() async {
    final ok = await confirmSheet(context,
        icon: Icons.logout_rounded,
        title: tr('Выйти из аккаунта?', 'Akkauntdan chiqilsinmi?'),
        text: tr('Войти снова можно по номеру телефона.', 'Telefon raqami orqali qayta kirish mumkin.'),
        confirm: tr('Выйти', 'Chiqish'));
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    await context.read<Api>().logout();
    nav.popUntil((r) => r.isFirst);
  }

  Future<void> _deleteAccount() async {
    final ok = await confirmSheet(
      context,
      icon: Icons.delete_outline_rounded,
      title: tr('Удалить аккаунт?', 'Akkaunt oʻchirilsinmi?'),
      text: tr(
          'Удалим имя, адреса, избранное и настройки. История заказов останется у магазинов без вашего телефона и адреса — это нужно для учёта. Восстановить аккаунт будет нельзя.',
          'Ism, manzillar, sevimlilar va sozlamalar oʻchiriladi. Buyurtmalar tarixi doʻkonlarda telefon raqamingiz va manzilingizsiz qoladi — bu hisob uchun kerak. Akkauntni tiklab boʻlmaydi.'),
      confirm: tr('Удалить аккаунт', 'Akkauntni oʻchirish'),
    );
    if (!ok || !mounted) return;
    final api = context.read<Api>();
    final nav = Navigator.of(context);
    try {
      await api.delete('/client/me');
      await api.forget();
      nav.popUntil((r) => r.isFirst);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'active_order') {
        // 409: есть незавершённый заказ — удалить можно после доставки или отмены.
        final n = e.details['order_number'];
        await infoSheet(
          context,
          icon: Icons.local_shipping_outlined,
          title: tr('Сначала дождитесь заказа', 'Avval buyurtmani kuting'),
          text: n == null
              ? e.message
              : tr('Заказ № $n ещё не завершён. Когда его доставят или отменят, аккаунт можно будет удалить.',
                  'Buyurtma № $n hali yakunlanmagan. U yetkazilgach yoki bekor qilingach, akkauntni oʻchirish mumkin boʻladi.'),
        );
      } else {
        showError(context, e);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

/// Баннер в профиле (Figma «П2»): «Зарабатывайте на доставке» — ссылка на приложение курьера.
/// Показывается, только если сервер отдал courier_app_url.
class CourierBanner extends StatelessWidget {
  const CourierBanner({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    Future<void> open() async {
      try {
        await openUrl(url);
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.directions_walk_rounded, color: AppColors.primary, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Зарабатывайте на доставке', 'Yetkazib berib daromad qiling'), style: AppText.bodyStrong.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(tr('Берите заказы из магазинов по пути', 'Yoʻlingizdagi doʻkonlardan buyurtma oling'), style: AppText.small),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
          ]),
        ),
      ),
    );
  }
}
