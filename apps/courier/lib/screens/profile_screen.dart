import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show confirmSheet, formatPhone;

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
        const Text('Профиль', style: AppText.h1),
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
                [if ('${me['login'] ?? ''}'.isNotEmpty) 'Логин ${me['login']}', formatPhone(me['phone'])].where((x) => x.isNotEmpty).join(' · '),
                style: AppText.body.copyWith(color: const Color(0xFF8E8E93)),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        _Group(children: [
          _Item(icon: Icons.storefront_rounded, title: '${me['network_name'] ?? ''}', trailing: const Text('сеть', style: _gray)),
          _Item(icon: vehicleIcons[st.vehicle] ?? Icons.directions_walk_rounded, title: 'Транспорт', trailing: Text(vehicleTitles[st.vehicle] ?? st.vehicle, style: _gray)),
          _Item(
            icon: Icons.my_location_rounded,
            title: 'Геопозиция',
            trailing: Text(
              !st.onShift ? 'только на смене' : (st.locationProblem == null ? 'передаётся' : 'не передаётся'),
              style: _gray.copyWith(color: st.onShift && st.locationProblem != null ? AppColors.error : null),
            ),
            onTap: st.onShift && st.locationProblem != null ? st.openLocationSettings : null,
          ),
          for (final s in stores)
            _Item(
              icon: Icons.call_rounded,
              title: 'Позвонить: ${s['name']}',
              trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF8E8E93)),
              onTap: '${s['phone'] ?? ''}'.isEmpty ? null : () => call(context, '${s['phone']}'),
            ),
        ]),
        const SizedBox(height: 18),
        _Group(children: [
          const _Item(icon: Icons.lock_reset_rounded, title: 'Сменить пароль', trailing: Text('у менеджера', style: _gray)),
          _Item(
            icon: Icons.logout_rounded,
            title: 'Выйти',
            color: AppColors.primary,
            onTap: () async {
              final ok = await confirmSheet(
                context,
                icon: Icons.logout_rounded,
                title: 'Выйти из приложения?',
                text: st.onShift ? 'Смена завершится, магазин перестанет назначать вам заказы.' : 'Чтобы войти снова, понадобятся логин и пароль.',
                confirm: 'Выйти',
              );
              if (ok) await st.logout();
            },
          ),
        ]),
        const SizedBox(height: 18),
        Text('Super Market Курьер · версия $appVersion', textAlign: TextAlign.center, style: AppText.small.copyWith(color: AppColors.muted)),
      ]),
    );
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
