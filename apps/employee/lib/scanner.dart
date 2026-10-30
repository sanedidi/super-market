import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/start/scanner.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';
import 'package:sm_store/stock/my_products.dart' show ProductLink;

import 'cost.dart';
import 'logic.dart';
import 'price.dart';
import 'recount.dart';
import 'ui.dart';
import 'write_off.dart';

/// Камера на весь экран: штрихкоды подряд. Каждый код отдаётся [onCode] —
/// он открывает шторки поверх камеры (камера на это время выключена).
class CodeScanner extends StatefulWidget {
  const CodeScanner({super.key, required this.title, required this.onCode, this.hint, this.status, this.doneLabel});

  /// Подпись сверху: «Цена и остаток · наведите на штрихкод».
  final String title;
  final String? hint;

  /// Плашка над кнопками: «Собрано 5 из 8» (null — нет).
  final String? Function()? status;

  /// Кнопка «Готово» (null — только крестик).
  final String? doneLabel;

  final Future<void> Function(BuildContext context, String code) onCode;

  @override
  State<CodeScanner> createState() => _CodeScannerState();
}

class _CodeScannerState extends State<CodeScanner> {
  late final MobileScannerController _scanner = barcodeScanner(
    formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE, BarcodeFormat.code128, BarcodeFormat.code39, BarcodeFormat.dataMatrix],
  );
  bool _torch = false;
  bool _handling = false;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);

  @override
  void dispose() {
    disposeScanner(_scanner);
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handling || capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    if (code == _lastCode && DateTime.now().difference(_lastAt) < const Duration(seconds: 2)) return;
    _handle(code);
  }

  Future<void> _manual() async {
    final code = await whileScannerIdle(
        _scanner,
        () => promptSheet(context,
            title: tr('Штрихкод', 'Shtrix-kod'),
            text: tr('Введите цифры под штрихкодом', 'Shtrix-kod ostidagi raqamlarni kiriting'),
            confirm: tr('Найти', 'Topish'),
            hint: '4780012345678',
            keyboardType: TextInputType.number));
    if (code != null && code.trim().isNotEmpty) await _handle(code.trim());
  }

  Future<void> _handle(String code) async {
    _handling = true;
    await whileScannerIdle(_scanner, () async {
      try {
        await widget.onCode(context, code);
      } finally {
        _lastCode = code;
        _lastAt = DateTime.now();
        _handling = false;
      }
    });
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status?.call();
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(controller: _scanner, onDetect: _onDetect),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(children: [
                RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: () => Navigator.of(context).pop()),
                const Spacer(),
                RoundIcon(
                  icon: _torch ? Icons.flashlight_off_rounded : Icons.flash_on_rounded,
                  color: AppColors.white,
                  tooltip: tr('Фонарик', 'Chiroq'),
                  onTap: () {
                    _scanner.toggleTorch();
                    setState(() => _torch = !_torch);
                  },
                ),
              ]),
            ),
            const SizedBox(height: 16),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: AppColors.ink.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(20)),
              child: Text(widget.title, textAlign: TextAlign.center, style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
            ),
            const Spacer(),
            Container(
              width: 260,
              height: 150,
              decoration: BoxDecoration(border: Border.all(color: AppColors.white, width: 2.5), borderRadius: BorderRadius.circular(18)),
              child: Center(child: Container(height: 2, margin: const EdgeInsets.symmetric(horizontal: 14), color: AppColors.primary)),
            ),
            if (widget.hint != null) ...[
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(widget.hint!, textAlign: TextAlign.center, style: AppText.small.copyWith(color: AppColors.muted)),
              ),
            ],
            const Spacer(),
            if (status != null) ...[
              StatusChip(status, icon: Icons.check_circle_rounded, tone: ChipTone.green),
              const SizedBox(height: 12),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(children: [
                Expanded(child: SmallButton(label: tr('Ввести вручную', 'Qoʻlda kiritish'), icon: Icons.keyboard_rounded, onPressed: _manual)),
                if (widget.doneLabel != null) ...[
                  const SizedBox(width: 10),
                  Expanded(child: SmallButton(label: widget.doneLabel!, icon: Icons.check_rounded, primary: true, onPressed: () => Navigator.of(context).pop())),
                ],
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Цена и остаток товара по коду (GET /store/staff/glance). Не нашли — сообщение, null.
Future<Map<String, dynamic>?> fetchGlance(BuildContext context, {String? code, String? productId}) async {
  final api = context.read<Api>();
  final store = context.read<StoreState>().storeId;
  try {
    return await api.get('/store/staff/glance', {
      'store_id': store,
      if (code != null) 'code': code,
      if (productId != null) 'product_id': productId,
    }) as Map<String, dynamic>;
  } on ApiError catch (e) {
    if (context.mounted) {
      await infoSheet(context,
          icon: Icons.search_off_rounded,
          title: e.status == 404 ? tr('Товар не найден', 'Mahsulot topilmadi') : tr('Не получилось', 'Boʻlmadi'),
          text: e.status == 404 ? tr('Штрихкода $code нет в Super Market.', '$code shtrix-kodi Super Marketda yoʻq.') : e.message);
    }
  } catch (e) {
    if (context.mounted) toast(context, e);
  }
  return null;
}

/// С5 · Сканер (центральная кнопка таббара) → шторка «Цена и остаток».
Future<void> openGlanceScanner(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => CodeScanner(
      title: tr('Цена и остаток · наведите на штрихкод', 'Narx va qoldiq · shtrix-kodga qarating'),
      onCode: (ctx, code) async {
        final g = await fetchGlance(ctx, code: code);
        if (g != null && ctx.mounted) await showGlance(ctx, g);
      },
    ),
  ));
}

/// Шторка товара: цена продажи, остаток, продано за 7 дней, на сколько хватит;
/// кнопки Цена / Пересчитать / Списать / Ценник. Цену закупки сотрудник не видит —
/// кладовщик видит только «не задана» и может её поставить (С5б).
Future<void> showGlance(BuildContext context, Map<String, dynamic> g) async {
  final action = await showSheet<String>(context, (ctx) => _GlanceSheet(g: g));
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'price':
      final changed = await changePrice(context, g);
      if (changed && context.mounted) {
        final fresh = await fetchGlance(context, productId: '${g['product_id']}');
        if (fresh != null && context.mounted) await showGlance(context, fresh);
      }
    case 'count':
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RecountScreen(preset: [RecountLine.fromGlance(g)])));
    case 'write_off':
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WriteOffScreen(product: g)));
    case 'tag':
      await markPriceTag(context, g);
    case 'cost':
      final saved = await setCost(context, g);
      if (saved && context.mounted) {
        final fresh = await fetchGlance(context, productId: '${g['product_id']}');
        if (fresh != null && context.mounted) await showGlance(context, fresh);
      }
  }
}

class _GlanceSheet extends StatelessWidget {
  const _GlanceSheet({required this.g});

  final Map<String, dynamic> g;

  @override
  Widget build(BuildContext context) {
    final unit = '${g['unit_short'] ?? ''}';
    final uncounted = g['uncounted'] == true;
    final short = n(g['short']);
    final days = g['days_left'];
    final changed = DateTime.tryParse('${g['price_changed_at'] ?? ''}')?.toLocal();
    Widget kpi(String label, String value, {Color? color}) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small.copyWith(fontSize: 12)),
              const SizedBox(height: 2),
              Text(value, style: AppText.title.copyWith(color: color)),
            ]),
          ),
        );
    Widget act(IconData icon, String label, String value) => Expanded(
          child: AppCard(
            color: AppColors.soft,
            padding: const EdgeInsets.symmetric(vertical: 12),
            onTap: () => Navigator.of(context).pop(value),
            child: Column(children: [
              Icon(icon, color: AppColors.ink),
              const SizedBox(height: 4),
              Text(label, style: AppText.caption.copyWith(color: AppColors.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        );
    final stock = uncounted
        ? tr('не посчитан', 'sanalmagan')
        : (short > 0 ? '−${qty(short, unit)}' : qty(g['qty'], unit));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        ProductLink(productId: '${g['product_id']}', name: '${g['name']}', image: g['image'] as String?, child: ProductThumb(image: g['image'] as String?, size: 56, fractional: g['is_fractional'] == true)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${g['name']}', style: AppText.title),
            Text([if (g['barcode'] != null) '${g['barcode']}', '${g['category'] ?? ''}'].where((s) => s.isNotEmpty).join(' · '), style: AppText.small),
          ]),
        ),
      ]),
      if (g['in_store'] != true) ...[
        const SizedBox(height: 10),
        InfoNote(tr('Этого товара нет в товарах магазина.', 'Bu mahsulot doʻkon mahsulotlarida yoʻq.'), tone: ChipTone.amber),
      ],
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Цена продажи', 'Sotish narxi'), style: AppText.small),
              Text(g['price'] == null ? tr('не задана', 'belgilanmagan') : money(g['price']), style: AppText.h2.copyWith(color: AppColors.primary)),
              if (g['weight'] != null)
                Text(tr('На наклейке ${qty(g['weight'], unit)} · ${money(n(g['price']) * n(g['weight']))}', 'Yorliqda ${qty(g['weight'], unit)} · ${money(n(g['price']) * n(g['weight']))}'),
                    style: AppText.small),
            ]),
          ),
          if (changed != null)
            Row(children: [
              const Icon(Icons.history_rounded, size: 16, color: AppColors.text2),
              const SizedBox(width: 4),
              Text(tr('изменена ${changed.day.toString().padLeft(2, '0')}.${changed.month.toString().padLeft(2, '0')}',
                  '${changed.day.toString().padLeft(2, '0')}.${changed.month.toString().padLeft(2, '0')} da oʻzgargan'), style: AppText.small),
            ]),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        kpi(tr('Остаток', 'Qoldiq'), stock, color: short > 0 ? AppColors.primary : null),
        const SizedBox(width: 8),
        kpi(tr('Продано за 7 дн.', '7 kunda sotildi'), qty(g['sold_7d'], unit)),
        const SizedBox(width: 8),
        kpi(tr('Хватит на', 'Yetadi'), days == null ? '—' : tr('~$days дн.', '~$days kun')),
      ]),
      if (g['no_cost'] != null) ...[
        const SizedBox(height: 10),
        NoCostRow(onSet: () => Navigator.of(context).pop('cost')),
      ],
      const SizedBox(height: 14),
      Row(children: [
        if (g['can_price'] == true) ...[act(Icons.edit_rounded, tr('Цена', 'Narx'), 'price'), const SizedBox(width: 8)],
        if (g['can_count'] == true) ...[
          act(Icons.fact_check_rounded, tr('Пересчитать', 'Sanash'), 'count'),
          const SizedBox(width: 8),
          act(Icons.delete_sweep_rounded, tr('Списать', 'Chiqarish'), 'write_off'),
          const SizedBox(width: 8),
          act(Icons.local_offer_rounded, tr('Ценник', 'Yorliq'), 'tag'),
        ],
      ]),
      const SizedBox(height: 14),
      BigButton(label: tr('Сканировать дальше', 'Davom etish'), icon: Icons.qr_code_scanner_rounded, color: AppColors.ink, height: 52, onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}
