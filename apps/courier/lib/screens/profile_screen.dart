import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show Lang, confirmSheet, formatPhone, infoSheet, pickLanguage, promptSheet, tr;

import '../logic.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import 'orders_screen.dart';

/// Профиль курьера: сеть, транспорт, геопозиция, звонок в магазин, выход (Figma К8).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CourierState>();
    final me = st.me ?? const {};
    final name = '${me['full_name'] ?? ''}';
    final initials = name.split(' ').where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();
    final stores = ((me['stores'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: ListView(padding: EdgeInsets.fromLTRB(20, top + 12, 20, 24), children: [
        Text(tr('Профиль', 'Profil'), style: AppText.h1),
        const SizedBox(height: 18),
        Row(children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
            child: Center(child: Text(initials, style: AppText.h3.copyWith(color: AppColors.primary, fontSize: 22))),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: AppText.h3),
              Text(
                [if ('${me['login'] ?? ''}'.isNotEmpty) tr('Логин ${me['login']}', 'Login: ${me['login']}'), formatPhone(me['phone'])].where((x) => x.isNotEmpty).join(' · '),
                style: AppText.body.copyWith(color: const Color(0xFF8E8E93)),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        _Group(children: [
          _Item(icon: Icons.storefront_rounded, title: '${me['network_name'] ?? ''}', trailing: Text(tr('сеть', 'tarmoq'), style: _gray)),
          _Item(icon: vehicleIcons[st.vehicle] ?? Icons.directions_walk_rounded, title: tr('Транспорт', 'Transport'), trailing: Text(vehicleTitles[st.vehicle] ?? st.vehicle, style: _gray)),
          _Item(
            icon: Icons.my_location_rounded,
            title: tr('Геопозиция', 'Joylashuv'),
            trailing: Text(
              !st.onShift
                  ? tr('только на смене', 'faqat smenada')
                  : (st.locationProblem == null ? tr('передаётся', 'uzatilmoqda') : tr('не передаётся', 'uzatilmayapti')),
              style: _gray.copyWith(color: st.onShift && st.locationProblem != null ? AppColors.error : null),
            ),
            onTap: st.onShift && st.locationProblem != null ? st.openLocationSettings : null,
          ),
          for (final s in stores)
            _Item(
              icon: Icons.call_rounded,
              title: tr('Позвонить: ${s['name']}', 'Qoʻngʻiroq: ${s['name']}'),
              trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF8E8E93)),
              onTap: '${s['phone'] ?? ''}'.isEmpty ? null : () => call(context, '${s['phone']}'),
            ),
          // Figma К8а: политика и запрос на удаление аккаунта.
          _Item(
            icon: Icons.policy_rounded,
            title: tr('Политика конфиденциальности', 'Maxfiylik siyosati'),
            trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF8E8E93)),
            onTap: () => openLink(context, privacyUrl),
          ),
          _Item(icon: Icons.person_remove_rounded, title: tr('Удалить аккаунт', 'Akkauntni oʻchirish'), color: AppColors.primary, onTap: () => _requestDeletion(context, st)),
        ]),
        const SizedBox(height: 18),
        _Group(children: [
          _Item(
            icon: Icons.language_rounded,
            title: tr('Язык', 'Til'),
            trailing: Text(Lang.names[Lang.instance.code]!, style: _gray),
            onTap: () async {
              final code = await pickLanguage(context);
              if (code == null || !st.api.loggedIn) return;
              try {
                await st.api.put('/me/language', {'language': code});
              } catch (_) {
                // Не сохранилось на сервере — уведомления придут на прежнем языке.
              }
            },
          ),
          _Item(icon: Icons.lock_reset_rounded, title: tr('Сменить пароль', 'Parolni almashtirish'), trailing: Text(tr('у менеджера', 'menejerda'), style: _gray)),
          _Item(
            icon: Icons.logout_rounded,
            title: tr('Выйти', 'Chiqish'),
            color: AppColors.primary,
            onTap: () async {
              final ok = await confirmSheet(
                context,
                icon: Icons.logout_rounded,
                title: tr('Выйти из приложения?', 'Ilovadan chiqasizmi?'),
                text: st.onShift
                    ? tr('Смена завершится, магазин перестанет назначать вам заказы.', 'Smena yakunlanadi, doʻkon sizga buyurtma biriktirishni toʻxtatadi.')
                    : tr('Чтобы войти снова, понадобятся логин и пароль.', 'Qayta kirish uchun login va parol kerak boʻladi.'),
                confirm: tr('Выйти', 'Chiqish'),
              );
              if (ok) await st.logout();
            },
          ),
        ]),
        const SizedBox(height: 18),
        Text(tr('Super Market Курьер · версия $appVersion', 'Super Market Kuryer · versiya $appVersion'), textAlign: TextAlign.center, style: AppText.small.copyWith(color: AppColors.muted)),
      ]),
    );
  }
}

/// Аккаунт штатного курьера создаёт магазин — удаляем по запросу (Figma К8а).
Future<void> _requestDeletion(BuildContext context, CourierState st) async {
  final reason = await promptSheet(
    context,
    title: tr('Удалить аккаунт?', 'Akkauntni oʻchirasizmi?'),
    text: tr('Ваш аккаунт создал магазин, поэтому удаляем по запросу — в течение 30 дней. Магазин и поддержка получат уведомление.',
        'Akkauntingizni doʻkon yaratgan, shuning uchun uni soʻrov boʻyicha 30 kun ichida oʻchiramiz. Doʻkon va qoʻllab-quvvatlash xizmati xabardor qilinadi.'),
    confirm: tr('Отправить запрос', 'Soʻrov yuborish'),
    options: deletionReasons,
    hint: tr('Комментарий (необязательно)', 'Izoh (ixtiyoriy)'),
    requireValue: false,
    maxLength: 500,
  );
  if (reason == null || !context.mounted) return;
  try {
    await st.requestDeletion(reason);
    if (!context.mounted) return;
    await infoSheet(
      context,
      icon: Icons.mark_email_read_rounded,
      title: tr('Запрос отправлен', 'Soʻrov yuborildi'),
      text: tr('Удалим аккаунт в течение 30 дней. Магазин и поддержка получили уведомление.',
          'Akkauntni 30 kun ichida oʻchiramiz. Doʻkon va qoʻllab-quvvatlash xizmati xabardor qilindi.'),
    );
  } catch (e) {
    if (context.mounted) showMessage(context, e);
  }
}

const _gray = TextStyle(fontFamily: 'Inter', fontSize: 15, color: Color(0xFF8E8E93));

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 56, color: Color(0xFFE0E0E3)),
          children[i],
        ],
      ]),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.icon, required this.title, this.trailing, this.onTap, this.color});
  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(children: [
          Icon(icon, size: 24, color: color ?? AppColors.dark),
          const SizedBox(width: 14),
          Expanded(child: Text(title, style: AppText.body.copyWith(fontSize: 17, color: color))),
          if (trailing != null) trailing!,
        ]),
      ),
    );
  }
}
