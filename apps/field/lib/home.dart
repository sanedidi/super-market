import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'flags.dart';
import 'logic.dart';
import 'permission.dart';
import 'places.dart';
import 'state.dart';
import 'tracker.dart';
import 'ui.dart';
import 'walk.dart';

/// Начать обход: разрешение геопозиции (П7), POST /field/walks, запись пути
/// и экран обхода (П2). Обход уже идёт — просто открыть его.
Future<void> openWalk(BuildContext context) async {
  final api = context.read<Api>();
  final tracker = context.read<Tracker>();
  final state = context.read<FieldState>();
  final nav = Navigator.of(context);
  final access = await locationAccess();
  if (access != LocationAccess.ok) {
    final ok = await nav.push<bool>(MaterialPageRoute(builder: (_) => PermissionScreen(access: access)));
    if (ok != true) return;
  }
  if (!tracker.running || tracker.walkId == null) {
    final pos = await currentPosition();
    final w = await api.post('/field/walks', {
      if (pos != null) 'lat': pos.latitude,
      if (pos != null) 'lng': pos.longitude,
    }) as Map<String, dynamic>;
    await tracker.start(w);
    await state.load();
  }
  await nav.push(MaterialPageRoute<void>(builder: (_) => const WalkScreen()));
}

/// П1 · Обход — район и сколько обойдено, итоги, «Сегодня прийти»,
/// последние обходы, «Начать обход».
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  bool _busy = false;
  final _flags = GlobalKey<FlagsNearbyState>();

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      await openWalk(context);
    } on ApiError catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
      // Вернулись с обхода — флажки могли появиться или закрыться.
      unawaited(_flags.currentState?.reload());
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<FieldState>();
    final tracker = context.watch<Tracker>();
    final me = st.me;
    if (me == null) {
      return Scaffold(
        body: Center(
          child: st.error == null
              ? const CircularProgressIndicator()
              : EmptyState(
                  icon: Icons.wifi_off_rounded,
                  title: tr('Не удалось загрузить данные', 'Maʼlumotlarni yuklab boʻlmadi'),
                  text: '${st.error}',
                  action: tr('Повторить', 'Qayta urinish'),
                  onAction: st.load,
                ),
        ),
      );
    }
    final rep = st.rep ?? const {};
    final district = st.district;
    final today = (me['today'] as Map<String, dynamic>?) ?? const {};
    final recent = ((me['recent'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final reminders = ((me['reminders'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final walking = tracker.walkId != null || st.openWalk != null;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => Future.wait([st.load(), _flags.currentState?.reload() ?? Future<void>.value()]),
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 20), children: [
                Text(tr('Обход', 'Aylanish'), style: AppText.h1),
                const SizedBox(height: 2),
                Text(
                  [
                    '${rep['full_name'] ?? ''}',
                    tr('продажник', 'savdo agenti'),
                    if (district != null) '${tr('район', 'tuman')} ${Lang.instance.isUz && '${district['name_uz'] ?? ''}'.isNotEmpty ? district['name_uz'] : district['name']}',
                  ].join(' · '),
                  style: AppText.small,
                ),
                const SizedBox(height: 14),
                _Coverage(district: district),
                const SizedBox(height: 12),
                Row(children: [
                  _Stat(value: formatDistance(today['distance_m']), label: tr('сегодня', 'bugun')),
                  const SizedBox(width: 8),
                  _Stat(value: formatDistance(me['week_m']), label: tr('за неделю', 'bir haftada')),
                  const SizedBox(width: 8),
                  _Stat(value: '${me['places'] ?? 0}', label: tr('магазинов · +${me['leads'] ?? 0}', 'doʻkon · +${me['leads'] ?? 0}')),
                ]),
                if (reminders.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(tr('Сегодня прийти', 'Bugun kelish'), style: AppText.title.copyWith(fontSize: 15)),
                  const SizedBox(height: 8),
                  for (final p in reminders) Padding(padding: const EdgeInsets.only(bottom: 8), child: PlaceTile(place: p)),
                ],
                FlagsNearby(key: _flags, onOpenMap: (at) => context.read<FieldState>().openMap(at)),
                const SizedBox(height: 18),
                Text(tr('Последние обходы', 'Oxirgi aylanishlar'), style: AppText.title.copyWith(fontSize: 15)),
                const SizedBox(height: 8),
                if (recent.isEmpty)
                  Text(tr('Пока не было — начните первый обход', 'Hali boʻlmagan — birinchi aylanishni boshlang'), style: AppText.small)
                else
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      for (var i = 0; i < recent.length; i++) ...[
                        if (i > 0) const Divider(height: 1, color: AppColors.line),
                        _WalkRow(w: recent[i]),
                      ],
                    ]),
                  ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Column(children: [
              BigButton(
                label: walking ? tr('Продолжить обход', 'Aylanishni davom ettirish') : tr('Начать обход', 'Aylanishni boshlash'),
                icon: walking ? Icons.map_rounded : Icons.directions_walk_rounded,
                busy: _busy,
                onPressed: _start,
              ),
              const SizedBox(height: 6),
              Text(
                tr('Путь пишется только во время обхода — даже с выключенным экраном', 'Yoʻl faqat aylanish vaqtida yoziladi — ekran oʻchiq boʻlsa ham'),
                textAlign: TextAlign.center,
                style: AppText.small.copyWith(fontSize: 12),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Coverage extends StatelessWidget {
  const _Coverage({required this.district});

  final Map<String, dynamic>? district;

  @override
  Widget build(BuildContext context) {
    final d = district;
    if (d == null) {
      return AppCard(
        child: Row(children: [
          const IconBox(icon: Icons.map_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Text(tr('Район вам ещё не назначен — ходите, где скажет менеджер. Путь всё равно записывается.',
                'Sizga hali tuman biriktirilmagan — menejer aytgan joyda yuring. Yoʻl baribir yoziladi.'),
                style: AppText.small),
          ),
        ]),
      );
    }
    final name = Lang.instance.isUz && '${d['name_uz'] ?? ''}'.isNotEmpty ? '${d['name_uz']}' : '${d['name']}';
    final pct = (d['coverage_pct'] as num?)?.toDouble();
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('$name обойдён', '$name aylanildi'), style: AppText.bodyStrong)),
          Text(pct == null ? '—' : formatPct(pct), style: AppText.h2.copyWith(color: AppColors.primary)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct == null ? 0 : (pct / 100).clamp(0, 1).toDouble(),
            minHeight: 8,
            backgroundColor: AppColors.line,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          pct == null
              ? tr('Граница района ещё не задана — процент появится, когда менеджер её нарисует', 'Tuman chegarasi hali belgilanmagan — foiz menejer uni chizganda chiqadi')
              : tr('Белых зон: ${formatPct(100 - pct)} — карта покажет, куда идти', 'Oq hududlar: ${formatPct(100 - pct)} — xarita qayerga borishni koʻrsatadi'),
          style: AppText.small,
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: AppText.title.copyWith(fontSize: 18), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(label, style: AppText.small.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      );
}

class _WalkRow extends StatelessWidget {
  const _WalkRow({required this.w});

  final Map<String, dynamic> w;

  @override
  Widget build(BuildContext context) {
    final results = (w['results'] as Map<String, dynamic>?) ?? const {};
    final total = (results['total'] as num?)?.toInt() ?? 0;
    final leads = (results['lead'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(children: [
        const IconBox(icon: Icons.route_rounded),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${shortDate(w['started_at'])}, ${hm(w['started_at'])}–${hm(w['ended_at'])}', style: AppText.bodyStrong.copyWith(fontSize: 14)),
            Text('${formatDistance(w['distance_m'])} · ${storesCount(total)}', style: AppText.small),
          ]),
        ),
        if (leads > 0) Pill(tr('+$leads заявок', '+$leads ariza'), color: AppColors.successInk, bg: AppColors.successSoft),
      ]),
    );
  }
}
