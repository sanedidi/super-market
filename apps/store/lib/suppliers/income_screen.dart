// «SM Магазин» · приход от поставщика-агента (Figma М28, М31): пересчитать,
// поправить, «Принять товар»; можно сразу отметить, что отдали деньги агенту.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../finance/finance_logic.dart' show n, plainAmount;
import '../kassa/widgets.dart' show PickChip, ProductThumb, QtyStepper;
import '../main.dart' show showMessage;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

String _q(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// М28 · Приход № … от поставщика: проверить и принять (М31 — сразу оплатили).
class SupplyIncomeScreen extends StatefulWidget {
  const SupplyIncomeScreen({super.key, required this.id, required this.supplier});

  /// id прихода (stock_documents).
  final String id;

  /// Карточка поставщика (/store/suppliers/{id}).
  final Map<String, dynamic> supplier;

  @override
  State<SupplyIncomeScreen> createState() => _SupplyIncomeScreenState();
}

class _SupplyIncomeScreenState extends State<SupplyIncomeScreen> {
  Map<String, dynamic>? _doc;
  Object? _error;
  final _shipped = <int, num>{};
  final _qty = <int, num>{};
  bool _busy = false;

  bool _payNow = false;
  final _amount = TextEditingController();
  String _method = 'cash';
  bool _part = false;
  Map<String, dynamic>? _box;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<Api>().get('/store/inventory/documents/${widget.id}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _doc = d;
        _error = null;
        _shipped.clear();
        _qty.clear();
        for (final it in ((d['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
          final line = (it['line'] as num).toInt();
          _shipped[line] = n(it['qty']);
          _qty[line] = n(it['qty']);
        }
        _amount.text = money(_total, suffix: false);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<Map<String, dynamic>> get _items => ((_doc?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();

  num get _total {
    num t = 0;
    for (final it in _items) {
      t += (_qty[(it['line'] as num).toInt()] ?? 0) * n(it['price']);
    }
    return t;
  }

  Future<void> _loadBox() async {
    if (_box != null) return;
    final st = context.read<StoreState>();
    try {
      final all = await context.read<Api>().list('/store/finance/cashboxes');
      final boxes = [
        for (final c in all)
          if (c['is_active'] != false && c['currency'] == 'UZS' && (c['is_main'] == true || c['store_id'] == st.storeId)) c,
      ];
      // Касса магазина, где хватает денег; иначе основная.
      final box = boxes.where((b) => b['store_id'] == st.storeId && n(b['balance']) >= _total).firstOrNull ??
          boxes.where((b) => n(b['balance']) >= _total).firstOrNull ??
          boxes.firstOrNull;
      if (mounted) setState(() => _box = box);
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  Future<void> _accept() async {
    final doc = _doc;
    if (doc == null) return;
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    final pay = num.tryParse(plainAmount(_amount.text)) ?? 0;
    if (_payNow) {
      final box = _box;
      String? err;
      if (pay <= 0) {
        err = tr('Введите сумму оплаты', 'Toʻlov summasini kiriting');
      } else if (box == null) {
        err = tr('Нет кассы для оплаты', 'Toʻlov uchun kassa yoʻq');
      } else if (pay > n(box['balance'])) {
        err = tr('В кассе «${box['name']}» только ${money(box['balance'])}', '«${box['name']}» kassasida faqat ${money(box['balance'])}');
      }
      if (err != null) {
        showMessage(context, err);
        return;
      }
    }
    setState(() => _busy = true);
    try {
      final changed = _items.any((it) => _qty[(it['line'] as num).toInt()] != _shipped[(it['line'] as num).toInt()]);
      if (changed) {
        await api.patch('/store/inventory/documents/${widget.id}', {
          'items': [
            for (final it in _items)
              if ((_qty[(it['line'] as num).toInt()] ?? 0) > 0)
                {'product_id': it['product_id'], 'qty': _q(_qty[(it['line'] as num).toInt()]!), 'price': it['price']},
          ],
        });
      }
      await api.post('/store/inventory/documents/${widget.id}/post');
      if (_payNow && pay > 0) {
        await api.post('/store/suppliers/${widget.supplier['id']}/pay', {
          'amount': plainAmount(_amount.text),
          'cashbox_id': _box?['id'],
          'method': _method,
          'store_id': st.storeId,
          'note': tr('При приёме прихода № ${doc['number']}', '№ ${doc['number']} kirimni qabul qilishda'),
        });
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(
          content: Text(_payNow
              ? tr('Товар принят, оплата ждёт подтверждения агента', 'Tovar qabul qilindi, toʻlov agent tasdigʻini kutmoqda')
              : tr('Товар принят — встал на остатки', 'Tovar qabul qilindi — qoldiqqa qoʻshildi'))));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    final s = widget.supplier;
    final agent = '${s['agent_name'] ?? ''}';
    final draft = doc?['status'] == 'draft';
    num diff = 0;
    num pcs = 0;
    for (final e in _qty.entries) {
      diff += e.value - (_shipped[e.key] ?? 0);
      pcs += e.value;
    }
    final total = _total;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(doc == null ? tr('Приход', 'Kirim') : tr('Приход № ${doc['number']}', '№ ${doc['number']} kirim')),
          Text([tr('От ${s['name']}', '${s['name']} dan'), if (agent.isNotEmpty) tr('агент $agent', 'agent $agent')].join(' · '), style: AppText.small),
        ]),
      ),
      body: doc == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load),
            )
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              if (draft)
                AppCard(
                  color: AppColors.blueSoft,
                  padding: const EdgeInsets.all(14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.local_shipping_rounded, color: AppColors.blue),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(tr('Поставщик отгрузил товар. Пересчитайте и поправьте количество, если пришло меньше', 'Yetkazib beruvchi tovarni joʻnatdi. Sanab chiqing va kamroq kelgan boʻlsa, sonini tuzating'),
                          style: AppText.small.copyWith(color: AppColors.ink)),
                    ),
                  ]),
                )
              else
                AppCard(
                  color: AppColors.successSoft,
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    const Icon(Icons.done_all_rounded, color: AppColors.successInk),
                    const SizedBox(width: 10),
                    Expanded(child: Text(tr('Принят ${dateTime(doc['posted_at'])}', '${dateTime(doc['posted_at'])} da qabul qilingan'), style: AppText.bodyStrong.copyWith(color: AppColors.successInk))),
                  ]),
                ),
              const SizedBox(height: 12),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(children: [
                  for (final (i, it) in _items.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    _line(it, draft),
                  ],
                ]),
              ),
              if (draft && diff != 0) ...[
                const SizedBox(height: 12),
                AppCard(
                  color: AppColors.warningSoft,
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded, color: AppColors.warningInk),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(tr('Расхождение ${diff > 0 ? '+' : '−'}${_q(diff.abs())} шт — поставщик увидит его после приёма', 'Farq ${diff > 0 ? '+' : '−'}${_q(diff.abs())} dona — qabul qilingandan keyin yetkazib beruvchi koʻradi'),
                          style: AppText.small.copyWith(color: AppColors.warningInk)),
                    ),
                  ]),
                ),
              ],
              if (draft && context.watch<StoreState>().can('finance.manage')) ...[
                const SizedBox(height: 12),
                _payCard(total),
              ],
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Text(tr('${_items.length} поз. · ${_q(pcs)} шт', '${_items.length} ta · ${_q(pcs)} dona'), style: AppText.small)),
                Text(money(total), style: AppText.title),
              ]),
              if (draft) ...[
                const SizedBox(height: 12),
                BigButton(
                  label: _payNow ? tr('Принять товар и оплату', 'Tovar va toʻlovni qabul qilish') : tr('Принять товар', 'Tovarni qabul qilish'),
                  icon: Icons.done_all_rounded,
                  busy: _busy,
                  onPressed: pcs > 0 ? _accept : null,
                ),
              ],
            ]),
    );
  }

  Widget _line(Map<String, dynamic> it, bool draft) {
    final line = (it['line'] as num).toInt();
    final q = _qty[line] ?? 0;
    final shipped = _shipped[line] ?? 0;
    final unit = '${it['unit_short'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        const ProductThumb(null, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['product_name']}', style: AppText.bodyStrong),
            Text(
                [
                  '${qty(shipped, unit)} × ${money(it['price'], suffix: false)}',
                  if (q < shipped) tr('пришло меньше', 'kamroq keldi'),
                  if (q > shipped) tr('пришло больше', 'koʻproq keldi'),
                ].join(' · '),
                style: AppText.small.copyWith(color: q == shipped ? AppColors.text2 : AppColors.warningInk)),
          ]),
        ),
        if (draft)
          QtyStepper(
            label: _q(q),
            onMinus: q > 0 ? () => setState(() => _qty[line] = q - 1 < 0 ? 0 : q - 1) : null,
            onPlus: () => setState(() => _qty[line] = q + 1),
          )
        else
          Text(qty(q, unit), style: AppText.bodyStrong),
      ]),
    );
  }

  Widget _payCard(num total) {
    return AppCard(
      border: _payNow ? AppColors.primary : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Сразу оплатили агенту', 'Agentga darhol toʻlandi'), style: AppText.bodyStrong),
              Text(tr('Агент подтвердит, что получил', 'Agent olganini tasdiqlaydi'), style: AppText.small),
            ]),
          ),
          Switch(
            value: _payNow,
            onChanged: (v) {
              setState(() {
                _payNow = v;
                if (v && !_part) _amount.text = money(total, suffix: false);
              });
              if (v) _loadBox();
            },
          ),
        ]),
        if (_payNow) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            enabled: _part,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
            style: AppText.h3,
            decoration: InputDecoration(labelText: tr('Сколько отдали', 'Qancha berildi'), suffixText: tr('сум', 'soʻm')),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: PickChip(
                label: tr('Всю сумму', 'Butun summa'),
                selected: !_part,
                onTap: () => setState(() {
                  _part = false;
                  _amount.text = money(total, suffix: false);
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: PickChip(label: tr('Часть', 'Bir qismi'), selected: _part, onTap: () => setState(() => _part = true))),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            for (final (i, m) in ['cash', 'transfer', 'card'].indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: PickChip(
                  label: switch (m) { 'transfer' => tr('Перевод', 'Oʻtkazma'), 'card' => tr('Карта', 'Karta'), _ => tr('Наличные', 'Naqd') },
                  selected: _method == m,
                  onTap: () => setState(() => _method = m),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 10),
          Text(
              _box == null
                  ? tr('Ищем кассу…', 'Kassa qidirilmoqda…')
                  : tr('Из кассы «${_box!['name']}» · в ней ${money(_box!['balance'])}', '«${_box!['name']}» kassasidan · unda ${money(_box!['balance'])}'),
              style: AppText.small),
          const SizedBox(height: 6),
          Text(
              tr('Товар встанет на остатки, долг поставщику — ${money(total)}. Оплата уйдёт из кассы и вычтется из долга, агент подтвердит «Получил».',
                  'Tovar qoldiqqa qoʻshiladi, yetkazib beruvchiga qarz — ${money(total)}. Toʻlov kassadan chiqadi va qarzdan ayriladi, agent «Oldim»ni tasdiqlaydi.'),
              style: AppText.small),
        ],
      ]),
    );
  }
}
