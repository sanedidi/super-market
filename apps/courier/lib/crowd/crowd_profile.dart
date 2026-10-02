import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' hide LoginScreen;

import '../logic.dart';
import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'crowd_logic.dart';
import 'crowd_state.dart';

/// Профиль доверия курьера «по пути» (Figma Ц7).
class CrowdProfileScreen extends StatelessWidget {
  const CrowdProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CrowdState>();
    final me = st.me ?? const {};
    final name = '${me['full_name'] ?? ''}'.trim();
    final shown = name.isEmpty ? 'Курьер ${me['code'] ?? ''}' : name;
    final initials = name.isEmpty ? 'SM' : name.split(' ').where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();
    final level = (me['level'] as Map?) ?? const {};
    final stats = (me['stats'] as Map?) ?? const {};
    final ver = me['verification'] as Map?;
    final top = MediaQuery.paddingOf(context).top;
    final at = DateTime.tryParse('${ver?['at'] ?? ''}')?.toLocal();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: ListView(padding: EdgeInsets.fromLTRB(20, top + 12, 20, 24), children: [
        Row(children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
            child: Center(child: Text(initials, style: AppText.h3.copyWith(color: AppColors.white, fontSize: 22))),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(shown, style: AppText.h3),
              const SizedBox(height: 6),
              st.verified
                  ? const StatusChip('Личность подтверждена', icon: Icons.verified_rounded, tone: ChipTone.green)
                  : const StatusChip('Не верифицирован', icon: Icons.hourglass_top_rounded, tone: ChipTone.amber),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        if (st.verified) ...[
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${level['title'] ?? ''}', style: AppText.title)),
                if (level['next'] != null)
                  Text('${stats['delivered'] ?? 0} из ${(level['next'] as Map)['after']} доставок', style: AppText.small.copyWith(fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: levelProgress(me), minHeight: 8, color: AppColors.primary, backgroundColor: AppColors.soft),
              ),
              const SizedBox(height: 10),
              Text(levelHint(me, money), style: AppText.small.copyWith(fontSize: 14)),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            _Stat(value: '${stats['delivered'] ?? 0}', label: 'доставок', icon: Icons.local_shipping_rounded, fg: AppColors.primary, bg: AppColors.primarySoft),
            const SizedBox(width: 12),
            _Stat(value: '${stats['ontime_pct'] ?? 100}%', label: 'вовремя', icon: Icons.schedule_rounded, fg: AppColors.success, bg: AppColors.successSoft),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            _Stat(value: '${stats['cancels'] ?? 0}', label: 'отмен', icon: Icons.cancel_rounded, fg: AppColors.warningInk, bg: AppColors.warningSoft),
            const SizedBox(width: 12),
            _Stat(value: '${stats['violations'] ?? 0}', label: 'нарушений', icon: Icons.gpp_good_rounded, fg: AppColors.blue, bg: AppColors.blueSoft),
          ]),
          const SizedBox(height: 12),
          if (ver != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
              child: Row(children: [
                const Icon(Icons.storefront_rounded, color: AppColors.ink),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Проверен в ${ver['store_name']}', style: AppText.bodyStrong),
                    Text(
                      [if (at != null) '${at.day.toString().padLeft(2, '0')}.${at.month.toString().padLeft(2, '0')}.${at.year}', ver['doc_type'] == 'passport' ? 'паспорт' : 'ID-карта'].join(' · '),
                      style: AppText.small,
                    ),
                  ]),
                ),
              ]),
            ),
          const SizedBox(height: 18),
        ],
        Container(
          decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.directions_walk_rounded, color: AppColors.dark),
              title: const Text('Транспорт', style: AppText.body),
              trailing: Text(vehicleTitles[st.vehicle] ?? st.vehicle, style: AppText.body.copyWith(color: AppColors.text2)),
              onTap: () => _vehicle(context, st),
            ),
            const Divider(height: 1, indent: 56, color: AppColors.line),
            ListTile(
              leading: const Icon(Icons.phone_iphone_rounded, color: AppColors.dark),
              title: Text('${me['phone'] ?? ''}', style: AppText.body),
              trailing: Text('${me['code'] ?? ''}', style: AppText.body.copyWith(color: AppColors.text2)),
            ),
            const Divider(height: 1, indent: 56, color: AppColors.line),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppColors.primary),
              title: Text('Выйти', style: AppText.body.copyWith(color: AppColors.primary)),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Выйти из приложения?'),
                    content: const Text('Лента перестанет искать заказы. Войти снова можно по номеру телефона.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Выйти')),
                    ],
                  ),
                );
                if (ok == true) await st.logout();
              },
            ),
          ]),
        ),
        const SizedBox(height: 18),
        Text('Super Market Курьер · версия $appVersion', textAlign: TextAlign.center, style: AppText.small.copyWith(color: AppColors.muted)),
      ]),
    );
  }

  Future<void> _vehicle(BuildContext context, CrowdState st) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final e in vehicleTitles.entries)
            ListTile(
              title: Text(e.value, style: AppText.bodyStrong),
              trailing: e.key == st.vehicle ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
              onTap: () => Navigator.pop(ctx, e.key),
            ),
        ]),
      ),
    );
    if (v == null || v == st.vehicle) return;
    try {
      await st.setVehicle(v);
    } catch (e) {
      if (context.mounted) showMessage(context, e);
    }
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.icon, required this.fg, required this.bg});
  final String value, label;
  final IconData icon;
  final Color fg, bg;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(height: 8),
          Text(value, style: AppText.title.copyWith(fontSize: 22)),
          Text(label, style: AppText.small.copyWith(fontSize: 12)),
        ]),
      ),
    );
  }
}
