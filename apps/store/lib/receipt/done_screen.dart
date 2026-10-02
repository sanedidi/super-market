import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'receipt_logic.dart';

/// П5 · Приход создан (проведён или черновик).
class DoneScreen extends StatelessWidget {
  const DoneScreen({super.key, required this.scan});

  final Map<String, dynamic> scan;

  @override
  Widget build(BuildContext context) {
    final posted = scan['document_status'] == 'posted';
    final lines = ((scan['lines'] as List?) ?? const []).where((l) => (l as Map)['skipped'] != true).length;
    final changed = ((scan['lines'] as List?) ?? const []).where((l) {
      final c = ((l as Map)['price_change'] as num?)?.abs() ?? 0;
      return c > 5;
    }).length;
    Widget row(String l, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Text(l, style: AppText.small),
            const SizedBox(width: 12),
            Expanded(child: Text(v, style: AppText.bodyStrong.copyWith(color: color), textAlign: TextAlign.right)),
          ]),
        );
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 64, 16, 24), children: [
          Center(
            child: IconBox(posted ? Icons.check_rounded : Icons.edit_note_rounded,
                bg: posted ? AppColors.successSoft : AppColors.soft, fg: posted ? AppColors.success : AppColors.ink, size: 96, iconSize: 52, radius: 48),
          ),
          const SizedBox(height: 16),
          Text(posted ? 'Приход проведён' : 'Черновик прихода сохранён', style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text('№ ${scan['document_number'] ?? '—'} · ${scanTitle(scan)}', style: AppText.small, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          AppCard(
            child: Column(children: [
              row('Позиций', '$lines'),
              row('Сумма', money(scan['lines_total'])),
              if (posted) row('Долг поставщику', '+ ${money(scan['lines_total'])}'),
              if (changed > 0) row('Цена закупки изменилась', '$changed — проверьте цены продажи', color: AppColors.primary),
              row('Фото накладной', 'сохранено'),
            ]),
          ),
          if (!posted) ...[
            const SizedBox(height: 12),
            const Text('Провести черновик можно в панели магазина: Закупки → Приход товара.', style: AppText.small, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 24),
          BigButton(label: 'Готово', onPressed: () => Navigator.of(context).pop()),
        ]),
      ),
    );
  }
}
