import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';
import 'package:sm_store/stock/my_products.dart' show ProductLink;
import 'package:url_launcher/url_launcher.dart';

import 'logic.dart';
import 'scanner.dart';
import 'ui.dart';

/// С7 · Сборка заказа — скан каждого товара, весовой — по наклейке весов,
/// без штрихкода — нажатием в списке; прогресс. С8 «Нет?» — убрать из
/// заказа. Готово → С9 пакеты и «Передал курьеру».
class PickingScreen extends StatefulWidget {
  const PickingScreen({super.key, required this.id});

  final String id;

  @override
  State<PickingScreen> createState() => _PickingScreenState();
}

class _PickingScreenState extends State<PickingScreen> {
  Map<String, dynamic>? _o;
  Object? _error;
  bool _showDone = false;
  bool _busy = false;

  String get _path => '/store/orders/${widget.id}';

  List<Map<String, dynamic>> get _items => ((_o?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final o = await context.read<Api>().get(_path) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _o = o;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  bool get _mineOrFree {
    final st = context.read<StoreState>();
    final picker = _o?['picker_id'];
    return picker == null || picker == st.me?['employee_id'] || st.me?['is_owner'] == true;
  }

  Future<void> _take() async {
    setState(() => _busy = true);
    try {
      final o = await context.read<Api>().post('$_path/take') as Map<String, dynamic>;
      if (mounted) setState(() => _o = o);
    } on ApiError catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Отметить, сколько собрано в строке.
  Future<bool> _pick(Map<String, dynamic> it, String qtyValue) async {
    try {
      final o = await context.read<Api>().post('$_path/lines/${it['line']}/pick', {'qty': qtyValue}) as Map<String, dynamic>;
      if (mounted) setState(() => _o = o);
      HapticFeedback.mediumImpact();
      return true;
    } on ApiError catch (e) {
      if (mounted) toast(context, e);
      return false;
    }
  }

  /// Нажали на товар без штрихкода — сколько собрано.
  Future<void> _tapLine(Map<String, dynamic> it) async {
    if (_o?['status'] != 'picking' || !_mineOrFree) return;
    final fractional = it['is_fractional'] == true;
    if (!fractional && n(it['qty']) == 1) {
      await _pick(it, linePicked(it) ? '0' : '1');
      return;
    }
    final v = await askQty(context,
        title: tr('Сколько собрали?', 'Qancha yigʻildi?'),
        text: tr('${it['product_name']} · в заказе ${qty(it['qty'], '${it['unit_short'] ?? ''}')}', '${it['product_name']} · buyurtmada ${qty(it['qty'], '${it['unit_short'] ?? ''}')}'),
        initial: n(it['qty']),
        fractional: fractional);
    if (v != null) await _pick(it, qtyBody(v, fractional));
  }

  Future<void> _scan() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CodeScanner(
        title: tr('Сборка № ${_o?['number']} · наведите на штрихкод', '№ ${_o?['number']} yigʻish · shtrix-kodga qarating'),
        hint: tr('Весовой товар — наклейка с весов', 'Tortiladigan mahsulot — tarozi yorligʻi'),
        doneLabel: tr('Готово', 'Tayyor'),
        status: () => tr('Собрано ${_o?['picked_count'] ?? 0} из ${_o?['items_count'] ?? 0}', '${_o?['items_count'] ?? 0} dan ${_o?['picked_count'] ?? 0} yigʻildi'),
        onCode: (ctx, code) async {
          var it = lineForCode(_items, code);
          String? weight;
          if (it == null) {
            // Наклейка весов или код маркировки — сервер найдёт товар.
            final g = await fetchGlance(ctx, code: code);
            if (g == null) return;
            weight = g['weight'] as String?;
            for (final x in _items) {
              if (x['product_id'] == g['product_id'] && (it == null || !linePicked(x))) it = x;
            }
            if (it == null) {
              if (ctx.mounted) {
                await infoSheet(ctx,
                    icon: Icons.remove_shopping_cart_rounded,
                    title: tr('Этого товара нет в заказе', 'Bu mahsulot buyurtmada yoʻq'),
                    text: '${g['name']}');
              }
              return;
            }
          }
          final line = it;
          if (linePicked(line)) {
            if (ctx.mounted) toast(ctx, tr('${line['product_name']} уже собран', '${line['product_name']} allaqachon yigʻilgan'));
            return;
          }
          await _pick(line, pickQtyAfterScan(line, weight: weight));
        },
      ),
    ));
  }

  /// С8 · «Нет на полке?» — убрать из заказа (замены нет: товаров без
  /// остатка покупатель в приложении не видит).
  Future<void> _missing(Map<String, dynamic> it) async {
    final canStock = context.read<StoreState>().can('inventory.manage');
    final after = n(_o?['total']) - n(it['total']);
    final res = await showSheet<bool>(context, (ctx) => _MissingSheet(item: it, newTotal: after, canStock: canStock));
    if (res == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await context.read<Api>().post('$_path/lines/${it['line']}/remove', {'zero_stock': res}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _o = r['order'] as Map<String, dynamic>);
      toast(
          context,
          r['zero_stocked'] == true
              ? tr('Убрали из заказа, остаток обнулён. Покупатель получит уведомление', 'Buyurtmadan olindi, qoldiq nolga tushirildi. Xaridorga xabar boradi')
              : tr('Убрали из заказа. Покупатель получит уведомление', 'Buyurtmadan olindi. Xaridorga xabar boradi'));
    } on ApiError catch (e) {
      if (mounted) {
        await infoSheet(context,
            icon: Icons.info_outline_rounded,
            title: e.code == 'last_line' ? tr('Это последний товар', 'Bu oxirgi mahsulot') : tr('Убрать нельзя', 'Olib tashlab boʻlmaydi'),
            text: e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _call() async {
    final phone = '${_o?['customer_phone'] ?? ''}';
    if (phone.isEmpty) return;
    await launchUrl(Uri.parse('tel:$phone'));
  }

  Future<void> _finish() async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PackScreen(order: _o!)));
    if (done == true && mounted) Navigator.of(context).pop();
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    if (o == null) {
      return Scaffold(appBar: AppBar(), body: LoadBox(error: _error, retry: _load));
    }
    final status = '${o['status']}';
    final items = _items;
    final left = items.where((it) => !linePicked(it)).toList();
    final done = items.where(linePicked).toList();
    final picking = status == 'picking';
    final canPick = picking && _mineOrFree;
    final all = items.isNotEmpty && left.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Сборка № ${o['number']}', '№ ${o['number']} yigʻish')),
          Text('${deliveryWhen(o)} · ${money(o['total'])}', style: AppText.small),
        ]),
        actions: [
          if ('${o['customer_phone'] ?? ''}'.isNotEmpty) IconButton(tooltip: tr('Позвонить покупателю', 'Xaridorga qoʻngʻiroq'), icon: const Icon(Icons.call_rounded), onPressed: _call),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 160), children: [
          // Прогресс.
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(tr('Собрано ${done.length} из ${items.length}', '${items.length} dan ${done.length} yigʻildi'), style: AppText.bodyStrong),
                const Spacer(),
                Text(left.isEmpty ? tr('всё собрано', 'hammasi yigʻildi') : tr('осталось ${left.length}', '${left.length} ta qoldi'), style: AppText.small),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: items.isEmpty ? 0 : done.length / items.length,
                  minHeight: 8,
                  backgroundColor: AppColors.soft,
                  color: AppColors.success,
                ),
              ),
            ]),
          ),
          if ('${o['comment'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 10),
            InfoNote(tr('Покупатель: ${o['comment']}', 'Xaridor: ${o['comment']}'), icon: Icons.chat_bubble_outline_rounded, tone: ChipTone.amber),
          ],
          if (!picking && (status == 'paid' || status == 'accepted')) ...[
            const SizedBox(height: 10),
            InfoNote(tr('Заказ ещё не в сборке. Нажмите «Взять в сборку».', 'Buyurtma hali yigʻilmayapti. «Yigʻishga olish» ni bosing.')),
          ],
          if (picking && !_mineOrFree) ...[
            const SizedBox(height: 10),
            InfoNote(tr('Заказ собирает ${o['picker_name'] ?? ''}', 'Buyurtmani ${o['picker_name'] ?? ''} yigʻyapti'), icon: Icons.person_rounded, tone: ChipTone.gray),
          ],
          if (left.isNotEmpty) ...[
            SectionLabel(tr('Осталось собрать', 'Yigʻish qoldi')),
            for (final it in left) ...[
              _LineRow(item: it, onTap: canPick ? () => _tapLine(it) : null, onMissing: canPick && !_busy ? () => _missing(it) : null),
              const SizedBox(height: 8),
            ],
          ],
          if (done.isNotEmpty) ...[
            SectionLabel(tr('Собрано · ${done.length}', 'Yigʻildi · ${done.length}')),
            for (final it in (_showDone || left.isEmpty ? done : done.take(1))) ...[
              _LineRow(item: it, onTap: canPick ? () => _tapLine(it) : null),
              const SizedBox(height: 8),
            ],
            if (!_showDone && left.isNotEmpty && done.length > 1)
              AppCard(
                padding: const EdgeInsets.all(12),
                onTap: () => setState(() => _showDone = true),
                child: Row(children: [
                  const Icon(Icons.check_circle_rounded, color: AppColors.success),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tr('Ещё ${goods(done.length - 1)} собраны', 'Yana ${goods(done.length - 1)} yigʻildi'), style: AppText.body)),
                  Text(tr('Показать', 'Koʻrsatish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                  const Icon(Icons.expand_more_rounded, color: AppColors.primary),
                ]),
              ),
          ],
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (status == 'paid' || status == 'accepted')
              BigButton(label: tr('Взять в сборку', 'Yigʻishga olish'), icon: Icons.inventory_rounded, color: AppColors.ink, busy: _busy, onPressed: _take)
            else if (canPick && !all) ...[
              BigButton(label: tr('Сканировать товар', 'Mahsulotni skanerlash'), icon: Icons.qr_code_scanner_rounded, color: AppColors.ink, onPressed: _busy ? null : _scan),
              const SizedBox(height: 6),
              Text(tr('Нет штрихкода — нажмите на товар в списке', 'Shtrix-kod yoʻq — roʻyxatdagi mahsulotni bosing'), style: AppText.small),
            ] else if (canPick && all)
              BigButton(label: tr('Заказ собран', 'Buyurtma yigʻildi'), icon: Icons.check_rounded, color: AppColors.success, onPressed: _finish)
            else if (status == 'picked' && o['handed_at'] == null)
              BigButton(label: tr('Передать курьеру', 'Kuryerga topshirish'), icon: Icons.handshake_rounded, onPressed: _finish),
          ]),
        ),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.item, this.onTap, this.onMissing});

  final Map<String, dynamic> item;
  final VoidCallback? onTap;
  final VoidCallback? onMissing;

  @override
  Widget build(BuildContext context) {
    final it = item;
    final unit = '${it['unit_short'] ?? ''}';
    final fractional = it['is_fractional'] == true;
    final picked = linePicked(it);
    final part = !picked && n(it['picked_qty']) > 0;
    return AppCard(
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      color: picked ? AppColors.successSoft : AppColors.white,
      child: Row(children: [
        ProductLink(productId: '${it['product_id']}', name: '${it['product_name']}', image: it['image'] as String?, child: ProductThumb(image: it['image'] as String?, size: 48, fractional: fractional)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['product_name']}', style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(
              fractional && !picked
                  ? tr('${qty(it['qty'], unit)} · весовой — наклейка с весов', '${qty(it['qty'], unit)} · tortiladigan — tarozi yorligʻi')
                  : part
                      ? tr('${qty(it['picked_qty'])} из ${qty(it['qty'], unit)} · ${money(it['price'])}', '${qty(it['qty'], unit)} dan ${qty(it['picked_qty'])} · ${money(it['price'])}')
                      : '${qty(it['qty'], unit)} · ${money(it['price'])}',
              style: AppText.small,
            ),
          ]),
        ),
        if (picked)
          const Icon(Icons.check_circle_rounded, color: AppColors.success)
        else if (onMissing != null)
          ChipButton(label: tr('Нет?', 'Yoʻqmi?'), onPressed: onMissing, color: AppColors.primarySoft, foreground: AppColors.primary)
        else
          const Icon(Icons.qr_code_scanner_rounded, color: AppColors.muted),
      ]),
    );
  }
}

/// С8 · шторка «Нет на полке?». Возвращает zero_stock (обнулить остаток) или null — передумали.
class _MissingSheet extends StatefulWidget {
  const _MissingSheet({required this.item, required this.newTotal, required this.canStock});

  final Map<String, dynamic> item;
  final num newTotal;
  final bool canStock;

  @override
  State<_MissingSheet> createState() => _MissingSheetState();
}

class _MissingSheetState extends State<_MissingSheet> {
  late bool _zero = widget.canStock;

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title: tr('Нет на полке?', 'Javonda yoʻqmi?')),
      const SizedBox(height: 14),
      Row(children: [
        ProductLink(productId: '${it['product_id']}', name: '${it['product_name']}', image: it['image'] as String?, child: ProductThumb(image: it['image'] as String?, size: 48, fractional: it['is_fractional'] == true)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['product_name']}', style: AppText.bodyStrong),
            Text('${qty(it['qty'], '${it['unit_short'] ?? ''}')} · ${money(it['total'])}', style: AppText.small),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      AppCard(
        color: AppColors.soft,
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.radio_button_checked_rounded, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Убрать из заказа', 'Buyurtmadan olib tashlash'), style: AppText.bodyStrong),
              Text(tr('Сумма станет ${money(widget.newTotal)}, покупатель получит уведомление', 'Summa ${money(widget.newTotal)} boʻladi, xaridorga xabar boradi'), style: AppText.small),
            ]),
          ),
        ]),
      ),
      if (widget.canStock) ...[
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _zero,
          onChanged: (v) => setState(() => _zero = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(tr('На складе тоже нет — обнулить остаток', 'Omborda ham yoʻq — qoldiqni nolga tushirish'), style: AppText.body),
          subtitle: Text(tr('Покупатели перестанут видеть товар, пока не придёт приход', 'Kirim kelguncha xaridorlar mahsulotni koʻrmaydi'), style: AppText.small),
        ),
      ],
      const SizedBox(height: 12),
      SheetButton(label: tr('Убрать из заказа', 'Buyurtmadan olib tashlash'), onPressed: () => Navigator.of(context).pop(_zero)),
      const SizedBox(height: 8),
      SheetButton(label: tr('Нашёл, отмена', 'Topdim, bekor qilish'), primary: false, onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}

/// С9 · Заказ собран → пакеты → «Передал курьеру». Курьер подтверждает в
/// своём приложении, что забрал заказ. true — заказ закрыт для сборщика.
class PackScreen extends StatefulWidget {
  const PackScreen({super.key, required this.order});

  final Map<String, dynamic> order;

  @override
  State<PackScreen> createState() => _PackScreenState();
}

class _PackScreenState extends State<PackScreen> {
  late num _bags = n(widget.order['bags'] ?? 1) < 1 ? 1 : n(widget.order['bags'] ?? 1);
  late Map<String, dynamic> _o = widget.order;
  bool _busy = false;

  String get _path => '/store/orders/${_o['id']}';

  Future<bool> _picked() async {
    if (_o['status'] != 'picking' && _o['status'] != 'accepted') return true;
    final o = await context.read<Api>().post('$_path/picked', {'bags': _bags.toInt()}) as Map<String, dynamic>;
    if (mounted) setState(() => _o = o);
    return true;
  }

  Future<void> _run(bool hand) async {
    setState(() => _busy = true);
    try {
      await _picked();
      if (hand) await context.read<Api>().post('$_path/handed');
      if (!mounted) return;
      toast(context, hand ? tr('Заказ передан курьеру', 'Buyurtma kuryerga topshirildi') : tr('Заказ собран — ждёт курьера', 'Buyurtma yigʻildi — kuryerni kutmoqda'));
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) {
        if (e.code == 'insufficient_stock') {
          await infoSheet(context,
              icon: Icons.inventory_2_outlined,
              title: tr('На складе меньше, чем в заказе', 'Omborda buyurtmadagidan kam'),
              text: tr('По учёту одного из товаров не хватает. Пересчитайте его на полке или уберите из заказа.',
                  'Hisob boʻyicha mahsulotlardan biri yetishmaydi. Uni javonda qayta sanang yoki buyurtmadan olib tashlang.'));
        } else {
          toast(context, e);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    final courier = o['courier_name'];
    final picked = o['status'] != 'picking' && o['status'] != 'accepted';
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Сборка № ${o['number']}', '№ ${o['number']} yigʻish')),
          Text(deliveryWhen(o), style: AppText.small),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 160), children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
            child: const Icon(Icons.check_rounded, color: AppColors.success, size: 40),
          ),
        ),
        const SizedBox(height: 12),
        Text(tr('Заказ собран', 'Buyurtma yigʻildi'), style: AppText.h2, textAlign: TextAlign.center),
        Text('${goods(n(o['items_count']).toInt())} · ${money(o['total'])}', style: AppText.small, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const IconBox(Icons.shopping_bag_rounded, size: 40, iconSize: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Пакетов', 'Paketlar'), style: AppText.bodyStrong),
                  Text(tr('Курьер увидит, сколько забрать', 'Kuryer qanchasini olishini koʻradi'), style: AppText.small),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            if (picked)
              Text(tr('${o['bags'] ?? 1} пак.', '${o['bags'] ?? 1} ta paket'), style: AppText.h3)
            else
              QtyStepper(value: _bags, min: 1, max: 99, onChanged: (v) => setState(() => _bags = v)),
          ]),
        ),
        const SizedBox(height: 10),
        AppCard(
          child: Row(children: [
            IconBox(courier == null ? Icons.person_off_rounded : Icons.two_wheeler_rounded, size: 40, iconSize: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(courier == null ? tr('Курьер ещё не назначен', 'Kuryer hali tayinlanmagan') : tr('Курьер · $courier', 'Kuryer · $courier'), style: AppText.bodyStrong),
                Text(
                  o['eta_at'] != null
                      ? tr('будет в ${hm(o['eta_at'])}', '${hm(o['eta_at'])} da keladi')
                      : (o['delivery_mode'] == 'crowd' ? tr('Курьер по пути', 'Yoʻl-yoʻlakay kuryer') : tr('Свой курьер магазина', 'Doʻkonning oʻz kuryeri')),
                  style: AppText.small,
                ),
              ]),
            ),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BigButton(label: tr('Передал курьеру', 'Kuryerga topshirdim'), icon: Icons.handshake_rounded, busy: _busy, onPressed: () => _run(true)),
            const SizedBox(height: 4),
            Text(tr('Курьер подтвердит в своём приложении, что забрал заказ', 'Kuryer buyurtmani olganini oʻz ilovasida tasdiqlaydi'), style: AppText.small, textAlign: TextAlign.center),
            if (!picked)
              TextButton(
                onPressed: _busy ? null : () => _run(false),
                child: Text(tr('Курьер ещё не пришёл — отметить собранным', 'Kuryer hali kelmadi — yigʻildi deb belgilash')),
              ),
          ]),
        ),
      ),
    );
  }
}
