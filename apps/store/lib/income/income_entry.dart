import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../receipt/capture_screen.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'income_screen.dart';

/// Последний черновик прихода магазина (null — нет).
Future<Map<String, dynamic>?> incomeDraft(BuildContext context) async {
  final st = context.read<StoreState>();
  if (st.storeId == null || !st.can('inventory.manage')) return null;
  try {
    final l = await context.read<Api>().list('/store/inventory/documents', {'type': 'income', 'status': 'draft', 'store_id': st.storeId, 'limit': 1});
    return l.isEmpty ? null : l.first;
  } catch (_) {
    return null;
  }
}

/// Открыть ручной приход: новый или черновик [id]. true — что-то изменилось.
Future<bool> openIncome(BuildContext context, {String? id}) async {
  final r = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => IncomeScreen(id: id)));
  return r == true;
}

/// Р2 · «Приход» на главной: сканером или вручную / по фото накладной;
/// есть черновик — первая строка «продолжить».
Future<void> openIncomeChooser(BuildContext context) async {
  final draft = await incomeDraft(context);
  if (!context.mounted) return;
  final pick = await showSheet<String>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Приход товара', 'Mahsulot kirimi'), style: AppText.h3),
      const SizedBox(height: 14),
      IncomeWayCard(
        dark: true,
        icon: Icons.qr_code_scanner_rounded,
        title: tr('Сканером или вручную', 'Skaner yoki qoʻlda'),
        text: tr('Штрихкод или поиск по названию. Нет товара — создадите по фото', 'Shtrix-kod yoki nomi boʻyicha qidiruv. Mahsulot yoʻq — rasm orqali yaratasiz'),
        onTap: () => Navigator.pop(ctx, 'manual'),
      ),
      const SizedBox(height: 10),
      IncomeWayCard(
        icon: Icons.document_scanner_rounded,
        title: tr('По фото накладной', 'Yuk xati rasmi orqali'),
        text: tr('Super Market прочитает поставщика и товары', 'Super Market yetkazib beruvchi va mahsulotlarni oʻqiydi'),
        onTap: () => Navigator.pop(ctx, 'photo'),
      ),
      if (draft != null) ...[
        const SizedBox(height: 10),
        IncomeDraftTile(draft: draft, onTap: () => Navigator.pop(ctx, 'draft')),
      ],
    ]),
  );
  if (pick == null || !context.mounted) return;
  switch (pick) {
    case 'manual':
      await openIncome(context);
    case 'draft':
      await openIncome(context, id: '${draft!['id']}');
    case 'photo':
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CaptureScreen()));
  }
}

/// Карточка способа прихода (Р1 на складе, Р2 на главной).
class IncomeWayCard extends StatelessWidget {
  const IncomeWayCard({super.key, required this.icon, required this.title, required this.text, required this.onTap, this.dark = false});

  final IconData icon;
  final String title;
  final String text;
  final VoidCallback? onTap;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      color: dark ? AppColors.ink : AppColors.white,
      border: dark ? null : AppColors.line,
      onTap: onTap,
      child: Row(children: [
        IconBox(icon, bg: dark ? AppColors.primary : AppColors.primarySoft, fg: dark ? AppColors.white : AppColors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong.copyWith(color: dark ? AppColors.white : AppColors.ink, fontSize: 16)),
            Text(text, style: AppText.small.copyWith(color: dark ? AppColors.muted : AppColors.text2)),
          ]),
        ),
        Icon(Icons.chevron_right_rounded, color: dark ? AppColors.white : AppColors.muted),
      ]),
    );
  }
}

/// «Черновик прихода № 50 · 4 позиции — продолжить».
class IncomeDraftTile extends StatelessWidget {
  const IncomeDraftTile({super.key, required this.draft, required this.onTap});

  final Map<String, dynamic> draft;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = (draft['items_count'] as num?)?.toInt() ?? 0;
    final who = (draft['counterparty_name'] as String?) ?? '';
    return AppCard(
      color: AppColors.soft,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onTap,
      child: Row(children: [
        const Icon(Icons.edit_note_rounded, color: AppColors.text2),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            [
              tr('Черновик прихода № ${draft['number']}', 'Kirim qoralamasi № ${draft['number']}'),
              if (who.isNotEmpty) who,
              tr('$n поз.', '$n ta'),
              money(draft['total'] ?? 0),
            ].join(' · '),
            style: AppText.small.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500),
          ),
        ),
        Text(tr('продолжить', 'davom etish'), style: AppText.caption.copyWith(color: AppColors.primary)),
      ]),
    );
  }
}
