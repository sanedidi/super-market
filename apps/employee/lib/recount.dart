import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'scanner.dart';
import 'ui.dart';

/// Строка пересчёта: товар, сколько в системе и сколько на полке.
class RecountLine {
  RecountLine({required this.productId, required this.name, this.image, this.unit = '', this.fractional = false, this.system, this.fact});

  factory RecountLine.fromGlance(Map<String, dynamic> g) => RecountLine(
        productId: '${g['product_id']}',
        name: '${g['name']}',
        image: g['image'] as String?,
        unit: '${g['unit_short'] ?? ''}',
        fractional: g['is_fractional'] == true,
        system: g['uncounted'] == true ? null : n(g['qty']) - n(g['short']),
      );

  final String productId;
  final String name;
  final String? image;
  final String unit;
  final bool fractional;

  /// В системе (null — остаток ни разу не вводили; минус — продали больше, чем было).
  final num? system;

  /// Посчитано на полке (null — ещё не посчитан).
  num? fact;
}

/// С10 · Пересчёт полки — факт против системы. Остатки меняются сразу, как
/// только сотрудник записал пересчёт (инвентаризация основного склада,
/// POST /store/start/count); товары уходят из задач «В минусе» / «Не посчитаны».
class RecountScreen extends StatefulWidget {
  const RecountScreen({super.key, this.preset = const [], this.title});

  final List<RecountLine> preset;
  final String? title;

  @override
  State<RecountScreen> createState() => _RecountScreenState();
}

class _RecountScreenState extends State<RecountScreen> {
  late final List<RecountLine> _lines = [...widget.preset];
  final _started = DateTime.now();
  bool _busy = false;

  int get _counted => _lines.where((l) => l.fact != null).length;

  int get _diffs => _lines.where((l) => l.fact != null && l.system != null && l.fact != l.system).length;

  RecountLine? _byId(String id) {
    for (final l in _lines) {
      if (l.productId == id) return l;
    }
    return null;
  }

  Future<void> _ask(RecountLine l) async {
    final v = await askQty(
      context,
      title: tr('Сколько на полке?', 'Javonda qancha?'),
      text: '${l.name}${l.system == null ? '' : ' · ${tr('в системе', 'tizimda')} ${qty(l.system, l.unit)}'}',
      initial: l.fact,
      fractional: l.fractional,
    );
    if (v != null && mounted) setState(() => l.fact = v);
  }

  Future<void> _scan() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CodeScanner(
        title: tr('Пересчёт · наведите на штрихкод', 'Qayta sanash · shtrix-kodga qarating'),
        hint: tr('Снизу откроется «Сколько на полке?»', 'Pastdan «Javonda qancha?» ochiladi'),
        doneLabel: tr('Готово', 'Tayyor'),
        status: () => _counted == 0 ? null : tr('Посчитано: $_counted', 'Sanaldi: $_counted'),
        onCode: (ctx, code) async {
          final g = await fetchGlance(ctx, code: code);
          if (g == null || !mounted) return;
          final found = _byId('${g['product_id']}');
          final line = found ?? RecountLine.fromGlance(g);
          if (found == null) setState(() => _lines.insert(0, line));
          // Весовой с наклейки — сразу её вес; штучный — +1 к посчитанному.
          final suggested = g['weight'] != null ? n(g['weight']) : (line.fractional ? null : (line.fact ?? 0) + 1);
          if (!ctx.mounted) return;
          final v = await askQty(
            ctx,
            title: tr('Сколько на полке?', 'Javonda qancha?'),
            text: '${line.name}${line.system == null ? '' : ' · ${tr('в системе', 'tizimda')} ${qty(line.system, line.unit)}'}',
            initial: suggested,
            fractional: line.fractional,
          );
          if (v != null && mounted) setState(() => line.fact = v);
        },
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    final items = [
      for (final l in _lines)
        if (l.fact != null) {'product_id': l.productId, 'qty': qtyBody(l.fact!, l.fractional)},
    ];
    if (items.isEmpty) return;
    if (_counted < _lines.length) {
      final ok = await confirmSheet(context,
          title: tr('Записать посчитанные?', 'Sanalganlarni yozamizmi?'),
          text: tr('Ещё не посчитаны: ${goods(_lines.length - _counted)}. Они останутся в задаче.', 'Hali sanalmagan: ${goods(_lines.length - _counted)}. Ular vazifada qoladi.'),
          confirm: tr('Записать $_counted', '$_counted tasini yozish'));
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final api = context.read<Api>();
      final store = context.read<StoreState>().storeId;
      for (var i = 0; i < items.length; i += 500) {
        await api.post('/store/start/count', {'store_id': store, 'items': items.sublist(i, i + 500 > items.length ? items.length : i + 500)});
      }
      if (!mounted) return;
      toast(context, tr('Пересчёт записан — остатки обновлены', 'Qayta sanash yozildi — qoldiqlar yangilandi'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Пересчёт', 'Qayta sanash')),
          Text('${widget.title == null ? '' : '${widget.title} · '}${tr('начат в ${hm(_started)}', '${hm(_started)} da boshlandi')}', style: AppText.small),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 160), children: [
        InfoNote(tr('Остатки поменяются сразу, как только запишете пересчёт. Владелец увидит его в журнале.',
            'Qayta sanashni yozishingiz bilan qoldiqlar oʻzgaradi. Egasi uni jurnalda koʻradi.')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _Kpi(tr('Посчитано', 'Sanaldi'), tr('$_counted из ${_lines.length}', '${_lines.length} dan $_counted'))),
          const SizedBox(width: 8),
          Expanded(child: _Kpi(tr('Расхождений', 'Farqlar'), '$_diffs', color: _diffs > 0 ? AppColors.primary : null)),
        ]),
        const SizedBox(height: 12),
        if (_lines.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: EmptyState(
              icon: Icons.qr_code_scanner_rounded,
              title: tr('Сканируйте товары на полке', 'Javondagi mahsulotlarni skanerlang'),
              text: tr('Каждый товар — штрихкод, потом сколько на полке.', 'Har bir mahsulot — shtrix-kod, keyin javonda qanchaligi.'),
            ),
          ),
        for (final l in _lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              padding: const EdgeInsets.all(12),
              onTap: () => _ask(l),
              child: Row(children: [
                ProductThumb(image: l.image, size: 44, fractional: l.fractional),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.name, style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(
                      l.fact == null
                          ? tr('Ещё не посчитан — сканируйте или нажмите', 'Hali sanalmagan — skanerlang yoki bosing')
                          : l.system == null
                              ? tr('Не было в системе · факт ${qty(l.fact, l.unit)}', 'Tizimda yoʻq edi · fakt ${qty(l.fact, l.unit)}')
                              : tr('В системе ${qty(l.system, l.unit)} · факт ${qty(l.fact, l.unit)}', 'Tizimda ${qty(l.system, l.unit)} · fakt ${qty(l.fact, l.unit)}'),
                      style: AppText.small,
                    ),
                  ]),
                ),
                if (l.fact == null)
                  const Icon(Icons.qr_code_scanner_rounded, color: AppColors.muted)
                else if (l.system != null && l.fact != l.system)
                  StatusChip(diffLabel(l.system!, l.fact!), tone: l.fact! < l.system! ? ChipTone.red : ChipTone.amber)
                else
                  const Icon(Icons.check_circle_rounded, color: AppColors.success),
              ]),
            ),
          ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BigButton(label: tr('Сканировать товар', 'Mahsulotni skanerlash'), icon: Icons.qr_code_scanner_rounded, color: AppColors.ink, onPressed: _busy ? null : _scan),
            const SizedBox(height: 8),
            BigButton(label: tr('Записать пересчёт', 'Qayta sanashni yozish'), icon: Icons.check_rounded, busy: _busy, onPressed: _counted == 0 ? null : _submit),
          ]),
        ),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppText.small.copyWith(fontSize: 12)),
          Text(value, style: AppText.title.copyWith(color: color)),
        ]),
      );
}
