import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'state.dart';
import 'tracker.dart';
import 'ui.dart';
import 'version.dart';

/// «Ещё» — профиль, язык, выход.
class MoreTab extends StatelessWidget {
  const MoreTab({super.key});

  Future<void> _logout(BuildContext context) async {
    final tracker = context.read<Tracker>();
    if (tracker.walkId != null) {
      await infoSheet(
        context,
        title: tr('Идёт обход', 'Aylanish davom etmoqda'),
        text: tr('Сначала закончите обход — потом можно выйти.', 'Avval aylanishni tugating — keyin chiqish mumkin.'),
        icon: Icons.directions_walk_rounded,
      );
      return;
    }
    final ok = await confirmSheet(
      context,
      title: tr('Выйти из приложения?', 'Ilovadan chiqasizmi?'),
      confirm: tr('Выйти', 'Chiqish'),
      icon: Icons.logout_rounded,
    );
    if (ok && context.mounted) await context.read<Api>().logout();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<FieldState>();
    final rep = st.rep ?? const {};
    final d = st.district;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Ещё', 'Yana'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        AppCard(
          child: Row(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
              child: Text(_initials('${rep['full_name'] ?? ''}'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${rep['full_name'] ?? ''}', style: AppText.title),
                Text(formatPhone(rep['phone']), style: AppText.small),
                Text(
                  [
                    '${tr('логин', 'login')}: ${rep['login'] ?? ''}',
                    if (d != null) '${tr('район', 'tuman')}: ${Lang.instance.isUz && '${d['name_uz'] ?? ''}'.isNotEmpty ? d['name_uz'] : d['name']}',
                  ].join(' · '),
                  style: AppText.small,
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.translate_rounded),
              title: Text(tr('Язык', 'Til'), style: AppText.bodyStrong),
              trailing: Text(Lang.names[Lang.instance.code] ?? '', style: AppText.small),
              onTap: () => pickLanguage(context),
            ),
            const Divider(height: 1, color: AppColors.line),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppColors.primary),
              title: Text(tr('Выйти', 'Chiqish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
              onTap: () => _logout(context),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Text('SM ${tr('Продажник', 'Savdo agenti')} $appVersion', textAlign: TextAlign.center, style: AppText.small),
      ]),
    );
  }

  static String _initials(String name) {
    final w = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (w.isEmpty) return '?';
    return (w.length == 1 ? w.first.substring(0, w.first.length < 2 ? w.first.length : 2) : '${w[0][0]}${w[1][0]}').toUpperCase();
  }
}
