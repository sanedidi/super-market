import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// Подпись источника строки: общий каталог или новый товар на модерации.
(String, Color?) lineOrigin(Map<String, dynamic> l) {
  if (l['own'] != true) return (tr('общий каталог', 'umumiy katalog'), null);
  if (l['moderation'] == 'approved') return (tr('свой товар', 'oʻz mahsulotingiz'), null);
  if (l['moderation'] == 'rejected') return (tr('новый · отклонён', 'yangi · rad etildi'), AppColors.error);
  return (tr('новый · на модерации', 'yangi · moderatsiyada'), AppColors.warningInk);
}

/// Строка списка: фото, название, источник; справа — штуки и закупка → продажа.
class StartLineTile extends StatelessWidget {
  const StartLineTile({super.key, required this.line, this.onTap});

  final Map<String, dynamic> line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final (origin, color) = lineOrigin(l);
    final cost = l['cost'];
    final price = l['price'] ?? l['current_price'];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          ProductThumb(l['image'] as String?, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${l['name']}', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(origin, style: AppText.small.copyWith(color: color)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${plainQty(l['qty'])} ${l['unit_short'] ?? ''}', style: AppText.bodyStrong),
            Text.rich(TextSpan(style: AppText.small, children: [
              TextSpan(text: cost == null ? '—' : money(cost, suffix: false), style: cost == null ? const TextStyle(color: AppColors.warningInk) : null),
              TextSpan(text: ' → ${money(price, suffix: false)}', style: cost == null ? const TextStyle(color: AppColors.warningInk) : null),
            ])),
          ]),
        ]),
      ),
    );
  }
}

/// Н9 · Проверка: товары без закупки, строки, итоги → «Провести».
class StartReviewScreen extends StatefulWidget {
  const StartReviewScreen({super.key, required this.start});

  final StartApi start;

  @override
  State<StartReviewScreen> createState() => _StartReviewScreenState();
}

class _StartReviewScreenState extends State<StartReviewScreen> {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _onlyNoCost = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.start.draft(only: _onlyNoCost ? 'no_cost' : null, limit: 1000);
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

  Map<String, dynamic> get _t => (_d?['totals'] as Map<String, dynamic>?) ?? const {};
  int _n(String k) => (_t[k] as num?)?.toInt() ?? 0;

  Future<void> _edit(Map<String, dynamic> l) async {
    if (await editLineSheet(context, widget.start, l)) _load();
  }

  Future<void> _post() async {
    final d = _d!;
    final ok = await confirmSheet(
      context,
      title: tr('Провести ${goods(_n('products'))}?', '${goods(_n('products'))}ni oʻtkazasizmi?'),
      text: tr(
          'Товары встанут на склад «${d['warehouse_name']}» по закупочным ценам, цены продажи установятся в магазине.'
              '${_n('no_cost') > 0 ? ' Без закупки: ${goods(_n('no_cost'))} — их себестоимость будет 0.' : ''}',
          'Mahsulotlar «${d['warehouse_name']}» omboriga xarid narxlarida kirim qilinadi, sotuv narxlari doʻkonda belgilanadi.'
              '${_n('no_cost') > 0 ? ' Xarid narxisiz: ${goods(_n('no_cost'))} — ularning tannarxi 0 boʻladi.' : ''}'),
      confirm: tr('Провести', 'Oʻtkazish'),
      icon: Icons.check_circle_outline_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await widget.start.post();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => StartDoneScreen(result: r, warehouse: '${d['warehouse_name']}')));
    } catch (e) {
      if (mounted) showMessage(context, e);
      _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final lines = ((d?['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final priced = lines.where((l) => l['price'] != null).length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Проверка', 'Tekshirish')),
          if (d != null) Text(tr('${goods(_n('products'))} · ${plainQty(_t['qty'])} шт', '${goods(_n('products'))} · ${plainQty(_t['qty'])} dona'), style: AppText.small),
        ]),
      ),
      body: _error != null && d == null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: _error.toString(), action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                    if (_n('no_cost') > 0 || _onlyNoCost) ...[
                      AppCard(
                        color: const Color(0xFFFFF4ED),
                        child: Row(children: [
                          const Icon(Icons.warning_amber_rounded, color: AppColors.warningInk),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(tr('У ${goods(_n('no_cost'))} нет закупочной цены', '${goods(_n('no_cost'))}da xarid narxi yoʻq'), style: AppText.bodyStrong.copyWith(color: AppColors.warningInk)),
                              Text(tr('Без неё не посчитать прибыль. Можно провести и так', 'Usiz foydani hisoblab boʻlmaydi. Shunday ham oʻtkazish mumkin'), style: AppText.small.copyWith(color: AppColors.warningInk)),
                            ]),
                          ),
                          TextButton(
                            onPressed: () {
                              setState(() => _onlyNoCost = !_onlyNoCost);
                              _load();
                            },
                            child: Text(_onlyNoCost ? tr('Все', 'Hammasi') : tr('Показать', 'Koʻrsatish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_n('pending') > 0) ...[
                      Text(
                          tr('Новых товаров на модерации: ${_n('pending')} — встанут на склад сразу, покупатели увидят их после проверки.',
                              'Moderatsiyadagi yangi mahsulotlar: ${_n('pending')} — omborga darhol kiritiladi, xaridorlar ularni tekshiruvdan keyin koʻradi.'),
                          style: AppText.small),
                      const SizedBox(height: 12),
                    ],
                    AppCard(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Expanded(child: Text(tr('ТОВАР', 'MAHSULOT'), style: AppText.caption)),
                            Text(tr('КОЛ-ВО · ЗАКУПКА → ПРОДАЖА', 'MIQDOR · XARID → SOTUV'), style: AppText.caption),
                          ]),
                        ),
                        if (lines.isEmpty)
                          Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(tr('Список пуст', 'Roʻyxat boʻsh'), style: AppText.small)),
                        for (final l in lines) StartLineTile(line: l, onTap: () => _edit(l)),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    AppCard(
                      child: Column(children: [
                        _row(tr('Оприходование · склад «${d['warehouse_name']}»', 'Kirim · «${d['warehouse_name']}» ombori'), money(_t['cost_total'])),
                        _row(tr('Установка цен', 'Narxlarni belgilash'), priced == 0 ? tr('цены каталога', 'katalog narxlari') : tr('$priced ${plural(priced, 'цена', 'цены', 'цен')}', '$priced ta narx')),
                        _row(tr('Будут видны покупателям', 'Xaridorlarga koʻrinadi'), goods(_n('products') - _n('pending'))),
                      ]),
                    ),
                  ]),
                ),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: BigButton(
                  label: tr('Провести · ${money(_t['cost_total'])}', 'Oʻtkazish · ${money(_t['cost_total'])}'),
                  icon: Icons.check_circle_outline_rounded,
                  busy: _busy,
                  onPressed: _n('products') == 0 || d['status'] != 'open' ? null : _post,
                ),
              ),
            ),
    );
  }

  Widget _row(String l, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(l, style: AppText.small)),
          const SizedBox(width: 8),
          Text(v, style: AppText.bodyStrong),
        ]),
      );
}

/// Н10 · Магазин готов к работе.
class StartDoneScreen extends StatelessWidget {
  const StartDoneScreen({super.key, required this.result, required this.warehouse});

  final Map<String, dynamic> result;
  final String warehouse;

  @override
  Widget build(BuildContext context) {
    final r = result;
    int n(String k) => (r[k] as num?)?.toInt() ?? 0;
    final docs = ((r['documents'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final price = r['price_document'] as Map<String, dynamic>?;
    Widget row(String l, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(l, style: AppText.body)),
            Text(v, style: AppText.bodyStrong),
          ]),
        );
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 80, 24, 24), children: [
          const Center(child: IconBox(Icons.check_circle_rounded, bg: AppColors.successSoft, fg: AppColors.success, size: 96, iconSize: 56, radius: 48)),
          const SizedBox(height: 20),
          Text(tr('Магазин готов к работе', 'Doʻkon ishga tayyor'), style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            tr(
                '${goods(n('products'))} на складе «$warehouse». ${n('visible')} уже видят покупатели в приложении'
                    '${n('pending') > 0 ? ', ${n('pending')} новых — после модерации' : ''}.',
                '«$warehouse» omborida ${goods(n('products'))}. Ulardan ${n('visible')} tasini xaridorlar ilovada allaqachon koʻrmoqda'
                    '${n('pending') > 0 ? ', ${n('pending')} ta yangisi — moderatsiyadan keyin' : ''}.'),
            style: AppText.small,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              for (final doc in docs) row(tr('Оприходование № ${doc['number']}', 'Kirim № ${doc['number']}'), docs.length == 1 ? money(r['cost_total']) : ''),
              if (price != null) row(tr('Установка цен № ${price['number']}', 'Narx belgilash № ${price['number']}'), tr('проведена', 'oʻtkazildi')),
            ]),
          ),
          const SizedBox(height: 12),
          Text(tr('В приложении товары видны, когда магазин принимает онлайн-заказы и открыт.', 'Doʻkon ochiq va onlayn buyurtmalarni qabul qilayotganda mahsulotlar ilovada koʻrinadi.'), style: AppText.small, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          BigButton(label: tr('На главную', 'Bosh sahifaga'), onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst)),
          const SizedBox(height: 12),
          BigButton(label: tr('Добавить ещё товары', 'Yana mahsulot qoʻshish'), color: AppColors.soft, foreground: AppColors.ink, onPressed: () => Navigator.of(context).pop()),
        ]),
      ),
    );
  }
}
