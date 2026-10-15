import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/start/start_screen.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'document_screen.dart';
import 'logic.dart';
import 'requests_screen.dart';
import 'store_screen.dart';
import 'ui.dart';

/// Д1 · Главная: заказы от магазинов, «Магазинам не хватает», склад за сегодня.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onTab});

  final void Function(int tab, {String filter}) onTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _sum;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Api>().get('/store/supply/summary') as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _sum = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  Future<void> _scan() async {
    final code = await ScanScreen.open(context);
    if (code == null || !mounted) return;
    final st = context.read<StoreState>();
    try {
      final items = await context.read<Api>().list('/store/products', {'store_id': st.storeId, 'barcode': code, 'limit': 1});
      if (!mounted) return;
      if (items.isEmpty) {
        final add = await confirmSheet(context,
            title: tr('Товара нет в ваших товарах', 'Mahsulot sizning mahsulotlaringizda yoʻq'),
            text: tr('Штрихкод $code. Добавить его через «Начало работы»?', 'Shtrix-kod $code. «Ishni boshlash» orqali qoʻshilsinmi?'),
            confirm: tr('Добавить товар', 'Mahsulot qoʻshish'));
        if (add && mounted) await _open(const StartScreen());
        return;
      }
      final p = items.first;
      final stock = await context.read<Api>().list('/store/inventory/stock', {'store_id': st.storeId, 'product_id': p['id']});
      if (!mounted) return;
      await infoSheet(context,
          icon: Icons.inventory_2_rounded,
          title: '${p['name']}',
          text: '${tr('На складе', 'Omborda')}: ${qty(stock.isEmpty ? 0 : stock.first['qty'], '${p['unit_short'] ?? ''}')}\n'
              '${tr('Отпускная цена', 'Ulgurji narx')}: ${p['price'] == null ? '—' : money(p['price'])}');
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final s = _sum;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st.networkName, style: AppText.small),
                Text('${st.store?['name'] ?? ''}', style: AppText.h2, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (s != null && (s['requests'] as num? ?? 0) > 0)
              Badge(
                label: Text('${s['requests']}'),
                child: RoundIcon(icon: Icons.person_add_alt_rounded, color: AppColors.white, onTap: () => _open(const RequestsScreen())),
              ),
          ]),
          const SizedBox(height: 16),
          if (_error != null && s == null)
            LoadError(_error!, onRetry: _load)
          else if (s == null)
            const Padding(padding: EdgeInsets.only(top: 60), child: Center(child: CircularProgressIndicator()))
          else ...[
            if ((s['new_orders'] as num? ?? 0) > 0) ...[
              _Banner(
                icon: Icons.receipt_long_rounded,
                title: tr('${s['new_orders']} новых заказов от магазинов', 'Doʻkonlardan ${s['new_orders']} ta yangi buyurtma'),
                text: tr('Примите или отклоните', 'Qabul qiling yoki rad eting'),
                onTap: () => widget.onTab(2),
              ),
              const SizedBox(height: 12),
            ],
            if ((s['requests'] as num? ?? 0) > 0) ...[
              _Banner(
                icon: Icons.person_add_alt_rounded,
                color: AppColors.blue,
                title: tr('Запросы от магазинов: ${s['requests']}', 'Doʻkonlardan soʻrovlar: ${s['requests']}'),
                text: tr('Магазины хотят заказывать у вас', 'Doʻkonlar sizdan buyurtma bermoqchi'),
                onTap: () => _open(const RequestsScreen()),
              ),
              const SizedBox(height: 12),
            ],
            _Lacking(sum: s, onTab: widget.onTab, onOpen: (id) => _open(StoreScreen(storeId: id))),
            const SizedBox(height: 12),
            _Today(sum: s),
            const SizedBox(height: 20),
            Text(tr('Быстрые действия', 'Tezkor amallar'), style: AppText.h3),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _Tile(icon: Icons.move_to_inbox_rounded, title: tr('Приход', 'Kirim'), text: tr('от производителя', 'ishlab chiqaruvchidan'), onTap: () => _open(const DocumentScreen.create(type: 'income')))),
              const SizedBox(width: 12),
              Expanded(child: _Tile(icon: Icons.local_shipping_rounded, title: tr('Расход', 'Chiqim'), text: tr('отгрузка магазину', 'doʻkonga joʻnatish'), onTap: () => _open(const DocumentScreen.create(type: 'shipment')))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _Tile(icon: Icons.qr_code_scanner_rounded, title: tr('Штрихкод', 'Shtrix-kod'), text: tr('найти товар', 'mahsulotni topish'), onTap: _scan)),
              const SizedBox(width: 12),
              Expanded(child: _Tile(icon: Icons.add_box_rounded, title: tr('Товар', 'Mahsulot'), text: tr('добавить в свой склад', 'omboringizga qoʻshish'), onTap: () => _open(const StartScreen()))),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.title, required this.text, required this.onTap, this.color = AppColors.primary});

  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            IconBox(icon, bg: AppColors.white.withValues(alpha: 0.18), fg: AppColors.white, size: 40, iconSize: 20, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                Text(text, style: AppText.small.copyWith(color: AppColors.white.withValues(alpha: 0.85))),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.white),
          ]),
        ),
      ),
    );
  }
}

class _Lacking extends StatelessWidget {
  const _Lacking({required this.sum, required this.onTab, required this.onOpen});

  final Map<String, dynamic> sum;
  final void Function(int tab, {String filter}) onTab;
  final void Function(String id) onOpen;

  @override
  Widget build(BuildContext context) {
    final top = (sum['top'] as List? ?? const []).cast<Map<String, dynamic>>();
    final linked = sum['linked_stores'] as num? ?? 0;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Магазинам не хватает', 'Doʻkonlarga yetishmayapti'), style: AppText.title),
        Text(tr('по остаткам и продажам подключённых магазинов', 'ulangan doʻkonlar qoldiqlari va sotuvlari boʻyicha'), style: AppText.small),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: () => onTab(1, filter: 'out'),
              child: StatTile(label: tr('Закончилось', 'Tugagan'), value: tr('${sum['out_stores']} магаз.', '${sum['out_stores']} ta'), bg: AppColors.primarySoft, fg: AppColors.primary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => onTab(1, filter: 'low'),
              child: StatTile(label: tr('Мало', 'Kam'), value: tr('${sum['low_stores']} магаз.', '${sum['low_stores']} ta'), bg: AppColors.warningSoft, fg: AppColors.warningInk),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => onTab(1, filter: 'no_brand'),
              child: StatTile(label: tr('Нет бренда', 'Brend yoʻq'), value: tr('${sum['no_brand_stores']} магаз.', '${sum['no_brand_stores']} ta'), bg: AppColors.soft, fg: AppColors.text2),
            ),
          ),
        ]),
        if (linked == 0) ...[
          const SizedBox(height: 12),
          Text(tr('Пока ни один магазин вас не подключил. Откройте «Магазины» — там магазины рядом со складом и кнопка «Договориться».',
              'Hozircha hech bir doʻkon sizni ulamagan. «Doʻkonlar»ni oching — u yerda ombor yonidagi doʻkonlar va «Kelishish» tugmasi.'), style: AppText.small),
        ],
        for (final c in top) ...[
          const Divider(height: 20),
          InkWell(
            onTap: () => onOpen('${c['id']}'),
            child: Row(children: [
              StoreIcon(stockStatus(c['status'])),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c['name']}', style: AppText.bodyStrong),
                  Text(
                    tr('Закончилось ${c['out_count']} · мало ${c['low_count']}', 'Tugagan ${c['out_count']} · kam ${c['low_count']}'),
                    style: AppText.small.copyWith(color: stockColors(stockStatus(c['status'])).$2),
                  ),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        BigButton(label: tr('Все магазины · $linked', 'Barcha doʻkonlar · $linked'), color: AppColors.ink, height: 44, onPressed: () => onTab(1)),
      ]),
    );
  }
}

class _Today extends StatelessWidget {
  const _Today({required this.sum});

  final Map<String, dynamic> sum;

  @override
  Widget build(BuildContext context) {
    final pct = changePct(sum['shipped_today'], sum['shipped_yesterday']);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Сегодня', 'Bugun'), style: AppText.bodyStrong),
        const SizedBox(height: 8),
        Text(tr('Отгружено', 'Joʻnatildi'), style: AppText.small),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(money(sum['shipped_today'], suffix: false), style: AppText.h2),
          const SizedBox(width: 6),
          Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(tr('сум', 'soʻm'), style: AppText.body.copyWith(color: AppColors.text2))),
          const SizedBox(width: 8),
          if (pct.isNotEmpty) StatusChip(pct, tone: pct.startsWith('▲') ? ChipTone.green : ChipTone.red),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: StatTile(label: tr('Расходов', 'Chiqimlar'), value: '${sum['shipments_today']}', note: tr('${sum['in_transit']} собрано', '${sum['in_transit']} yigʻilgan'))),
          const SizedBox(width: 8),
          Expanded(child: StatTile(label: tr('Приходов', 'Kirimlar'), value: '${sum['incomes_today']}', note: money(sum['incomes_today_sum']))),
          const SizedBox(width: 8),
          Expanded(child: StatTile(label: tr('Заказов', 'Buyurtmalar'), value: '${sum['new_orders']}', note: tr('новых', 'yangi'))),
        ]),
      ]),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.title, required this.text, required this.onTap});

  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBox(icon, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 20, radius: 12),
        const SizedBox(height: 10),
        Text(title, style: AppText.bodyStrong),
        Text(text, style: AppText.small),
      ]),
    );
  }
}
