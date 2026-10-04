import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'camera_screen.dart';
import 'catalog_screen.dart';
import 'new_product_screen.dart';
import 'review_screen.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// Способы добавить товары (кнопки на главной и на экране «Начало работы»).
enum StartMethod { photo, barcode, catalog, search }

/// Открыть способ добавления.
Future<void> openStartMethod(BuildContext context, StartApi start, StartMethod m) async {
  final Widget screen = switch (m) {
    StartMethod.photo => StartCameraScreen(start: start),
    StartMethod.barcode => StartCameraScreen(start: start, mode: StartMode.barcode),
    StartMethod.catalog => CatalogSectionsScreen(start: start),
    StartMethod.search => StartSearchScreen(start: start),
  };
  await Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => screen));
}

/// Н2 · Начало работы: сколько добавлено, способы добавить, последние товары,
/// «Проверить и провести». Черновик общий с веб-панелью.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key, this.initial});

  /// Сразу открыть способ (нажали кнопку в блоке на главной).
  final StartMethod? initial;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  late final StartApi _start = StartApi(context.read<Api>(), context.read<StoreState>().storeId!);
  Map<String, dynamic>? _d;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
    final m = widget.initial;
    if (m != null) WidgetsBinding.instance.addPostFrameCallback((_) => _open(m));
  }

  Future<void> _load() async {
    try {
      final d = await _start.draft(limit: 5);
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(StartMethod m) async {
    await openStartMethod(context, _start, m);
    _load();
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final d = _d;
    final t = (d?['totals'] as Map<String, dynamic>?) ?? const {};
    final products = (t['products'] as num?)?.toInt() ?? 0;
    final lines = ((d?['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final stock = (d?['stock_products'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Начало работы'),
          if (d != null) Text('Склад «${d['warehouse_name']}» · ${st.store?['name'] ?? ''}', style: AppText.small),
        ]),
      ),
      body: _error != null && d == null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: _error.toString(), action: 'Повторить', onAction: _load)
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                    AppCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                          Text('$products', style: AppText.h1),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('${plural(products, 'товар', 'товара', 'товаров')} добавлено · ${plainQty(t['qty'] ?? 0)} шт', style: AppText.small),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(child: _Kpi('По закупке', money(t['cost_total'] ?? 0))),
                          const SizedBox(width: 8),
                          Expanded(child: _Kpi('По цене продажи', money(t['price_total'] ?? 0))),
                        ]),
                        const SizedBox(height: 10),
                        const Text('Черновик сохраняется: можно продолжить в веб-панели', style: AppText.small),
                      ]),
                    ),
                    if (stock > 0 && d['id'] == null) ...[
                      const SizedBox(height: 12),
                      AppCard(
                        color: AppColors.successSoft,
                        child: Text(
                          'На складе уже ${goods(stock)}. Нашлись ещё товары — добавьте их и проведите снова. Новые поставки — через «Приход по фото».',
                          style: AppText.small.copyWith(color: AppColors.successInk),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Text('Как добавить', style: AppText.h3),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: _Method(
                          icon: Icons.photo_camera_rounded,
                          bg: AppColors.primarySoft,
                          fg: AppColors.primary,
                          title: 'Фото товара или полки',
                          text: 'Super Market найдёт товары в каталоге',
                          onTap: () => _open(StartMethod.photo),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _Method(
                          icon: Icons.qr_code_scanner_rounded,
                          bg: AppColors.blueSoft,
                          fg: AppColors.blue,
                          title: 'Штрихкод',
                          text: 'Сканируйте камерой подряд',
                          onTap: () => _open(StartMethod.barcode),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: _Method(
                          icon: Icons.category_rounded,
                          bg: AppColors.successSoft,
                          fg: AppColors.success,
                          title: 'Каталог по разделам',
                          text: 'Отметьте галочками, что есть',
                          onTap: () => _open(StartMethod.catalog),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _Method(
                          icon: Icons.search_rounded,
                          bg: AppColors.warningSoft,
                          fg: AppColors.warningInk,
                          title: 'Поиск',
                          text: 'По названию или бренду',
                          onTap: () => _open(StartMethod.search),
                        ),
                      ),
                    ]),
                    if (st.can('catalog.manage')) ...[
                      const SizedBox(height: 4),
                      TextButton.icon(
                        onPressed: () => _push(NewProductScreen(start: _start)),
                        icon: const Icon(Icons.add_rounded, color: AppColors.primary),
                        label: Text('Нет в каталоге — новый товар', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(children: [
                      const Expanded(child: Text('Добавленные', style: AppText.h3)),
                      if (products > 0)
                        TextButton(
                          onPressed: () => _push(StartReviewScreen(start: _start)),
                          child: Text('Все $products', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                        ),
                    ]),
                    const SizedBox(height: 4),
                    if (lines.isEmpty)
                      const Text('Пока ничего — начните с фото полки или штрихкода.', style: AppText.small)
                    else
                      AppCard(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Column(children: [
                          for (final l in lines)
                            StartLineTile(
                              line: l,
                              onTap: () async {
                                if (await editLineSheet(context, _start, l)) _load();
                              },
                            ),
                        ]),
                      ),
                  ]),
                ),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  BigButton(
                    label: 'Проверить и провести',
                    icon: Icons.check_circle_outline_rounded,
                    onPressed: products == 0 ? null : () => _push(StartReviewScreen(start: _start)),
                  ),
                  const SizedBox(height: 6),
                  const Text('Товары с остатком сразу увидят покупатели', style: AppText.small),
                ]),
              ),
            ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.small.copyWith(fontSize: 12)),
        Text(value, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

class _Method extends StatelessWidget {
  const _Method({required this.icon, required this.bg, required this.fg, required this.title, required this.text, required this.onTap});

  final IconData icon;
  final Color bg;
  final Color fg;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: SizedBox(
        height: 128,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBox(icon, bg: bg, fg: fg, size: 40, iconSize: 22, radius: 12),
          const SizedBox(height: 10),
          Text(title, style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(text, style: AppText.small, maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

/// Н1 · Блок на главной: пока на складе нет товаров или список не проведён.
class StartHomeBlock extends StatefulWidget {
  const StartHomeBlock({super.key, required this.storeId});

  final String storeId;

  @override
  State<StartHomeBlock> createState() => _StartHomeBlockState();
}

class _StartHomeBlockState extends State<StartHomeBlock> {
  Map<String, dynamic>? _d;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StartHomeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId) _load();
  }

  Future<void> _load() async {
    try {
      final d = await StartApi(context.read<Api>(), widget.storeId).draft(limit: 1);
      if (mounted) setState(() => _d = d);
    } catch (_) {
      // блок просто не показывается
    }
  }

  Future<void> _open([StartMethod? m]) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => StartScreen(initial: m)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) return const SizedBox.shrink();
    final stock = (d['stock_products'] as num?)?.toInt() ?? 0;
    if (stock > 0 && d['id'] == null) return const SizedBox.shrink();
    final products = ((d['totals'] as Map<String, dynamic>?)?['products'] as num?)?.toInt() ?? 0;
    Widget btn(StartMethod m, IconData icon, String label, {bool primary = false}) => Expanded(
          child: Material(
            color: primary ? AppColors.primary : AppColors.soft,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _open(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(children: [
                  Icon(icon, color: primary ? AppColors.white : AppColors.ink, size: 22),
                  const SizedBox(height: 4),
                  Text(label, style: AppText.caption.copyWith(color: primary ? AppColors.white : AppColors.ink)),
                ]),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppCard(
        border: AppColors.primary,
        onTap: () => _open(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            IconBox(Icons.rocket_launch_rounded, bg: AppColors.primarySoft, fg: AppColors.primary),
            SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Начало работы', style: AppText.title),
                Text('Добавьте товары, которые уже есть в магазине', style: AppText.small),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text('Добавлено ${goods(products)}', style: AppText.bodyStrong.copyWith(fontSize: 14))),
            const Text('черновик сохраняется', style: AppText.small),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            btn(StartMethod.photo, Icons.photo_camera_rounded, 'Фото', primary: true),
            const SizedBox(width: 8),
            btn(StartMethod.barcode, Icons.qr_code_scanner_rounded, 'Штрихкод'),
            const SizedBox(width: 8),
            btn(StartMethod.catalog, Icons.category_rounded, 'Каталог'),
            const SizedBox(width: 8),
            btn(StartMethod.search, Icons.search_rounded, 'Поиск'),
          ]),
        ]),
      ),
    );
  }
}
