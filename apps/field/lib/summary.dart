import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import 'logic.dart';
import 'ui.dart';

/// П6 · Обход завершён — км, время, новые клетки, повтор чужого пути,
/// магазины по результатам и покрытие района до и после.
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key, required this.summary});

  final Map<String, dynamic> summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final results = (s['results'] as Map<String, dynamic>?) ?? const {};
    final total = (results['total'] as num?)?.toInt() ?? 0;
    final newCells = (s['new_cells'] as num?)?.toInt() ?? 0;
    final otherPct = (s['other_pct'] as num?)?.toInt() ?? 0;
    final district = s['district'] as String?;
    final before = s['coverage_before'], after = s['coverage_after'];
    final started = s['started_at'], ended = s['ended_at'];
    Widget tile(String value, String label, {bool red = false}) => Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: AppText.title.copyWith(fontSize: 18, color: red ? AppColors.errorInk : AppColors.ink)),
            Text(label, style: AppText.small.copyWith(fontSize: 12)),
          ]),
        );
    final chips = <Widget>[
      for (final code in ['lead', 'refused', 'closed', 'later', 'ours'])
        if (((results[code] as num?)?.toInt() ?? 0) > 0)
          Pill('${resultLabel(code)} · ${results[code]}', color: ResultStyle.of(code).color == AppColors.muted ? AppColors.dark : ResultStyle.of(code).color, bg: ResultStyle.of(code).bg),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 24, 16, 16), children: [
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: AppColors.success, size: 32),
                ),
              ),
              const SizedBox(height: 12),
              Text(tr('Обход завершён', 'Aylanish tugadi'), textAlign: TextAlign.center, style: AppText.h2),
              const SizedBox(height: 4),
              Text(
                [
                  '${hm(started)}–${hm(ended)}',
                  if (district != null) district,
                  if (s['end_reason'] == 'auto') tr('закрыт автоматически', 'avtomatik yopildi'),
                ].join(' · '),
                textAlign: TextAlign.center,
                style: AppText.small,
              ),
              const SizedBox(height: 18),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.4,
                children: [
                  tile(formatDistance(s['distance_m']), tr('пройдено', 'yurildi')),
                  tile(formatDuration((s['active_sec'] as num?)?.toInt() ?? 0), tr('в обходе', 'aylanishda')),
                  tile(tr('$newCells клеток', '$newCells katak'), tr('новых · ≈ ${(newCells / 100).toStringAsFixed(2).replaceAll('.', ',')} км²', 'yangi · ≈ ${(newCells / 100).toStringAsFixed(2)} km²')),
                  tile(formatDistance(s['other_m']), tr('по чужому пути · $otherPct%', 'boshqalar yoʻlidan · $otherPct%'), red: otherPct > 0),
                ],
              ),
              const SizedBox(height: 12),
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(tr('Магазины', 'Doʻkonlar'), style: AppText.bodyStrong),
                    const Spacer(),
                    Text('$total', style: AppText.bodyStrong),
                  ]),
                  if (chips.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: chips),
                  ] else ...[
                    const SizedBox(height: 4),
                    Text(tr('В этом обходе магазины не отмечены', 'Bu aylanishda doʻkonlar belgilanmadi'), style: AppText.small),
                  ],
                  if (district != null && after != null) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: Text(tr('$district обойдён', '$district aylanildi'), style: AppText.small)),
                      Text('${formatPct(before)} → ${formatPct(after)}', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                    ]),
                  ],
                ]),
              ),
              if (((s['mock_points'] as num?)?.toInt() ?? 0) > 0) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
                  child: Text(
                    tr('Телефон передавал поддельную геопозицию — эти точки не засчитаны. Отключите приложения для смены GPS.',
                        'Telefon soxta geojoylashuv yubordi — bu nuqtalar hisobga olinmadi. GPS ni oʻzgartiruvchi ilovalarni oʻchiring.'),
                    style: AppText.small.copyWith(color: AppColors.warningInk),
                  ),
                ),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: BigButton(label: tr('Готово', 'Tayyor'), onPressed: () => Navigator.of(context).pop()),
          ),
        ]),
      ),
    );
  }
}
