import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'ui.dart';

// «Цена закупки» в шторке сканера (Figma С5б/С5в, право «Склад»): ставится
// только там, где её нет — остатку без цены и чекам, проданным без
// себестоимости; прибыль пересчитывается. Заданную цену меняет приход.

/// Строка «Цена закупки · не задана» + «Поставить» (С5б).
class NoCostRow extends StatelessWidget {
  const NoCostRow({super.key, required this.onSet});

  final VoidCallback onSet;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = StatusChip.colors(ChipTone.amber);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Цена закупки', 'Xarid narxi'), style: AppText.small.copyWith(fontSize: 12)),
            Text(tr('не задана', 'belgilanmagan'), style: AppText.bodyStrong.copyWith(color: fg)),
            Text(tr('прибыль по товару не считается', 'mahsulot foydasi hisoblanmaydi'), style: AppText.small.copyWith(fontSize: 12)),
          ]),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: onSet,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.ink,
            foregroundColor: AppColors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(tr('Поставить', 'Qoʻyish'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
        ),
      ]),
    );
  }
}

/// Шторка «Цена закупки» (С5в). true — сохранили.
Future<bool> setCost(BuildContext context, Map<String, dynamic> g) async {
  final ok = await showSheet<bool>(context, (_) => _CostSheet(g: g));
  return ok == true;
}

class _CostSheet extends StatefulWidget {
  const _CostSheet({required this.g});

  final Map<String, dynamic> g;

  @override
  State<_CostSheet> createState() => _CostSheetState();
}

class _CostSheetState extends State<_CostSheet> {
  final _c = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = parseInput(_c.text);
    if (v == null || v <= 0) {
      setState(() => _error = tr('Введите цену больше нуля', 'Noldan katta narx kiriting'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Api>().post('/store/staff/cost', {
        'store_id': context.read<StoreState>().storeId,
        'product_id': widget.g['product_id'],
        'cost': v.toString(),
      });
      if (!mounted) return;
      toast(context, tr('Цена закупки ${money(v)} сохранена — прибыль пересчитана', 'Xarid narxi ${money(v)} saqlandi — foyda qayta hisoblandi'));
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.g;
    final unit = '${g['unit_short'] ?? ''}';
    final nc = (g['no_cost'] as Map?) ?? const {};
    final info = [
      '${g['name']}',
      if (n(nc['stock']) > 0) tr('остаток ${qty(nc['stock'], unit)}', 'qoldiq ${qty(nc['stock'], unit)}'),
      if (n(nc['sold']) > 0) tr('продано без цены закупки: ${qty(nc['sold'], unit)}', 'xarid narxisiz sotilgan: ${qty(nc['sold'], unit)}'),
    ].join(' · ');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Цена закупки', 'Xarid narxi'), style: AppText.h3),
      const SizedBox(height: 4),
      Text(info, style: AppText.small),
      const SizedBox(height: 14),
      TextField(
        controller: _c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: AppText.h2,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          hintText: '9 500',
          suffixText: tr('сум', 'soʻm'),
          suffixStyle: AppText.body.copyWith(color: AppColors.text2),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 6),
        Text(_error!, style: AppText.small.copyWith(color: AppColors.error, fontWeight: FontWeight.w600)),
      ],
      const SizedBox(height: 10),
      Text(
          tr('Сохранится для остатка и уже проданных чеков — прибыль пересчитается. Если цена закупки уже есть, её меняет только приход.',
              'Qoldiq va sotilgan cheklar uchun saqlanadi — foyda qayta hisoblanadi. Xarid narxi bor boʻlsa, uni faqat kirim oʻzgartiradi.'),
          style: AppText.small),
      const SizedBox(height: 16),
      BigButton(label: tr('Сохранить', 'Saqlash'), icon: Icons.check_rounded, busy: _busy, onPressed: _busy ? null : _save),
    ]);
  }
}
