import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'ui.dart';

// Оплаты магазинов агенту (Figma «Оплаты поставщику»): деньги вносит
// магазин, агент подтверждает «Получил», «Другая сумма» или «Не получал».

String payMethod(Object? m) => switch ('$m') {
      'transfer' => tr('Перевод', 'Oʻtkazma'),
      'card' => tr('Карта', 'Karta'),
      _ => tr('Наличные', 'Naqd'),
    };

ChipTone payTone(Object? s) => switch ('$s') {
      'confirmed' => ChipTone.green,
      'disputed' => ChipTone.red,
      _ => ChipTone.amber,
    };

String payStatus(Object? s) => switch ('$s') {
      'confirmed' => tr('Получено', 'Olindi'),
      'disputed' => tr('Расхождение', 'Farq bor'),
      _ => tr('Ждёт вас', 'Sizni kutmoqda'),
    };

/// Оплата магазина: сумма, способ, кто отдал; у ждущей — кнопки ответа.
class PaymentCard extends StatefulWidget {
  const PaymentCard({super.key, required this.payment, required this.onChanged, this.showStore = true});

  final Map<String, dynamic> payment;
  final VoidCallback onChanged;
  final bool showStore;

  @override
  State<PaymentCard> createState() => _PaymentCardState();
}

class _PaymentCardState extends State<PaymentCard> {
  bool _busy = false;

  Future<void> _post(String action, [Map<String, dynamic>? body]) async {
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/supply/payments/${widget.payment['id']}/$action', body);
      widget.onChanged();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _other() async {
    final r = await showSheet<Map<String, dynamic>>(context, (ctx) => _OtherAmountSheet(payment: widget.payment));
    if (r != null && mounted) await _post('dispute', r);
  }

  Future<void> _notReceived() async {
    final ok = await confirmSheet(context,
        icon: Icons.money_off_rounded,
        title: tr('Не получали деньги?', 'Pulni olmadingizmi?'),
        text: tr('Магазин увидит «Не получал» и сможет исправить сумму или позвонить вам.', 'Doʻkon «Olinmadi»ni koʻradi va summani tuzatishi yoki sizga qoʻngʻiroq qilishi mumkin.'),
        confirm: tr('Не получал', 'Olmadim'));
    if (ok && mounted) await _post('dispute', {'received': '0'});
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    final pending = p['status'] == 'pending';
    final sub = [
      payMethod(p['method']),
      dateTime(p['created_at']),
      if ('${p['created_by'] ?? ''}'.isNotEmpty) '${p['created_by']}',
    ].join(' · ');
    return AppCard(
      color: pending ? AppColors.warningSoft : AppColors.white,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBox(pending ? Icons.payments_rounded : Icons.receipt_long_rounded,
              bg: pending ? AppColors.white : AppColors.soft, fg: pending ? AppColors.warningInk : AppColors.text2, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (widget.showStore) Text('${p['store_name']}', style: AppText.small.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600)),
              Text(tr('Магазин отдал ${money(p['amount'])}', 'Doʻkon ${money(p['amount'])} berdi'), style: AppText.bodyStrong),
              Text(sub, style: AppText.small),
              if ('${p['note'] ?? ''}'.isNotEmpty) Text('«${p['note']}»', style: AppText.small),
              if (p['status'] == 'disputed')
                Text(
                  tr('Вы получили ${money(p['received'])} — ждём магазин', 'Siz ${money(p['received'])} oldingiz — doʻkonni kutyapmiz'),
                  style: AppText.small.copyWith(color: AppColors.error),
                ),
            ]),
          ),
          StatusChip(payStatus(p['status']), tone: payTone(p['status'])),
        ]),
        if (pending) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: BigButton(
                label: tr('Получил', 'Oldim'),
                icon: Icons.check_rounded,
                color: AppColors.success,
                height: 44,
                busy: _busy,
                onPressed: () => _post('confirm'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: BigButton(
                label: tr('Другая сумма', 'Boshqa summa'),
                color: AppColors.white,
                foreground: AppColors.ink,
                height: 44,
                onPressed: _busy ? null : _other,
              ),
            ),
          ]),
          Center(
            child: TextButton(
              onPressed: _busy ? null : _notReceived,
              child: Text(tr('Не получал', 'Olmadim'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
            ),
          ),
        ],
      ]),
    );
  }
}

/// «Сколько вы получили?» — другая сумма и комментарий магазину.
class _OtherAmountSheet extends StatefulWidget {
  const _OtherAmountSheet({required this.payment});

  final Map<String, dynamic> payment;

  @override
  State<_OtherAmountSheet> createState() => _OtherAmountSheetState();
}

class _OtherAmountSheetState extends State<_OtherAmountSheet> {
  final _amount = TextEditingController();
  final _comment = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title: tr('Сколько вы получили?', 'Qancha oldingiz?')),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
        child: Text(
          tr('Магазин указал ${money(p['amount'])} · ${payMethod(p['method'])}, ${dateTime(p['created_at'])}',
              'Doʻkon ${money(p['amount'])} · ${payMethod(p['method'])}, ${dateTime(p['created_at'])} koʻrsatdi'),
          style: AppText.small.copyWith(color: AppColors.warningInk),
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _amount,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: AppText.h3,
        decoration: InputDecoration(labelText: tr('Получил на самом деле', 'Aslida oldim'), suffixText: tr('сум', 'soʻm')),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _comment,
        minLines: 2,
        maxLines: 3,
        decoration: InputDecoration(labelText: tr('Комментарий магазину · необязательно', 'Doʻkonga izoh · ixtiyoriy')),
      ),
      const SizedBox(height: 8),
      Text(tr('Магазин получит уведомление и увидит обе суммы: исправит оплату или согласится с вашей', 'Doʻkon xabarnoma oladi va ikkala summani koʻradi: toʻlovni tuzatadi yoki sizniki bilan rozi boʻladi'),
          style: AppText.small),
      const SizedBox(height: 16),
      ListenableBuilder(
        listenable: _amount,
        builder: (context, _) => SheetButton(
          label: tr('Отправить магазину', 'Doʻkonga yuborish'),
          onPressed: _amount.text.isEmpty ? null : () => Navigator.pop(context, {'received': _amount.text, 'comment': _comment.text.trim()}),
        ),
      ),
    ]);
  }
}

/// Оплаты от магазинов: ждут подтверждения · с расхождением · все.
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  String _status = 'pending';
  List<Map<String, dynamic>>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await context.read<Api>().list('/store/supply/payments', {'status': _status, 'limit': 100});
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    Widget chip(String status, String label) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label),
            selected: _status == status,
            onSelected: (_) {
              setState(() {
                _status = status;
                _items = null;
              });
              _load();
            },
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Оплаты от магазинов', 'Doʻkonlardan toʻlovlar'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              chip('pending', tr('Ждут вас', 'Sizni kutmoqda')),
              chip('disputed', tr('Расхождение', 'Farq bor')),
              chip('', tr('Все', 'Hammasi')),
            ]),
          ),
          const SizedBox(height: 12),
          if (_error != null && items == null)
            LoadError(_error!, onRetry: _load)
          else if (items == null)
            const Padding(padding: EdgeInsets.only(top: 60), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            EmptyState(
              icon: Icons.payments_outlined,
              title: _status == 'pending' ? tr('Нечего подтверждать', 'Tasdiqlash uchun hech narsa yoʻq') : tr('Оплат нет', 'Toʻlovlar yoʻq'),
              text: tr('Когда магазин отдаст вам деньги и отметит это в «SM Магазин», оплата появится здесь.',
                  'Doʻkon sizga pul berib, buni «SM Doʻkon»da belgilaganda, toʻlov shu yerda chiqadi.'),
            )
          else
            for (final p in items) ...[
              PaymentCard(payment: p, onChanged: _load),
              const SizedBox(height: 10),
            ],
        ]),
      ),
    );
  }
}

/// Акт сверки агента с магазином: отгрузки и подтверждённые оплаты, долг
/// после каждой операции; оплаты, которые ждут ответа, — сверху.
class StatementScreen extends StatefulWidget {
  const StatementScreen({super.key, required this.storeId, required this.storeName});

  final String storeId;
  final String storeName;

  @override
  State<StatementScreen> createState() => _StatementScreenState();
}

class _StatementScreenState extends State<StatementScreen> {
  Map<String, dynamic>? _s;
  Object? _error;

  /// Период: этот месяц (0), прошлый (1), с начала года (2).
  int _period = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  (DateTime, DateTime?) _range() {
    final now = DateTime.now();
    return switch (_period) {
      1 => (DateTime(now.year, now.month - 1), DateTime(now.year, now.month)),
      2 => (DateTime(now.year), null),
      _ => (DateTime(now.year, now.month), null),
    };
  }

  String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final (from, to) = _range();
    try {
      final s = await context.read<Api>().get('/store/supply/stores/${widget.storeId}/statement', {
        'from': _d(from),
        if (to != null) 'to': _d(to),
      }) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _s = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final st = s?['statement'] as Map<String, dynamic>?;
    final items = (st?['items'] as List? ?? const []).cast<Map<String, dynamic>>();
    final open = (s?['open'] as List? ?? const []).cast<Map<String, dynamic>>();
    var shipped = 0.0, paid = 0.0;
    for (final l in items) {
      final a = double.tryParse('${l['amount']}') ?? 0;
      if (a < 0) {
        shipped -= a;
      } else {
        paid += a;
      }
    }
    Widget chip(int p, String label) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label),
            selected: _period == p,
            onSelected: (_) {
              setState(() {
                _period = p;
                _s = null;
              });
              _load();
            },
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Акт сверки', 'Solishtirma dalolatnoma'), style: AppText.title),
          Text(widget.storeName, style: AppText.small),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              chip(0, tr('Этот месяц', 'Shu oy')),
              chip(1, tr('Прошлый месяц', 'Oʻtgan oy')),
              chip(2, tr('С начала года', 'Yil boshidan')),
            ]),
          ),
          const SizedBox(height: 12),
          if (_error != null && s == null)
            LoadError(_error!, onRetry: _load)
          else if (s == null)
            const Padding(padding: EdgeInsets.only(top: 60), child: Center(child: CircularProgressIndicator()))
          else ...[
            Row(children: [
              Expanded(child: StatTile(label: tr('Отгрузки', 'Joʻnatmalar'), value: money(shipped.toStringAsFixed(2), suffix: false), bg: AppColors.white)),
              const SizedBox(width: 8),
              Expanded(child: StatTile(label: tr('Оплаты', 'Toʻlovlar'), value: money(paid.toStringAsFixed(2), suffix: false), bg: AppColors.white, fg: AppColors.successInk)),
              const SizedBox(width: 8),
              Expanded(child: StatTile(label: tr('Долг', 'Qarz'), value: money(s['debt'], suffix: false), bg: AppColors.white, fg: AppColors.primary)),
            ]),
            if (open.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(tr('Ждут вашего ответа', 'Javobingizni kutmoqda'), style: AppText.title),
              const SizedBox(height: 8),
              for (final p in open) ...[
                PaymentCard(payment: p, onChanged: _load, showStore: false),
                const SizedBox(height: 10),
              ],
            ],
            const SizedBox(height: 16),
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Column(children: [
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(tr('За период операций нет', 'Davr uchun operatsiyalar yoʻq'), style: AppText.small),
                  ),
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _StatementRow(line: items[i]),
                ],
              ]),
            ),
            const SizedBox(height: 10),
            Text(
                tr('Неподтверждённая оплата в долг не входит, пока вы не нажмёте «Получил». Тот же акт видит магазин в «SM Магазин» → «Поставщики».',
                    '«Oldim» bosilmaguncha tasdiqlanmagan toʻlov qarzga kirmaydi. Xuddi shu dalolatnomani doʻkon «SM Doʻkon» → «Yetkazib beruvchilar»da koʻradi.'),
                style: AppText.small),
          ],
        ]),
      ),
    );
  }
}

class _StatementRow extends StatelessWidget {
  const _StatementRow({required this.line});

  final Map<String, dynamic> line;

  @override
  Widget build(BuildContext context) {
    final amount = double.tryParse('${line['amount']}') ?? 0;
    // В журнале агента минус — магазин должен больше (отгрузка), плюс — оплата.
    final shipment = amount < 0;
    final at = DateTime.tryParse('${line['at']}')?.toLocal();
    final debt = -(double.tryParse('${line['balance']}') ?? 0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 36,
          child: Column(children: [
            Text(at == null ? '' : at.day.toString().padLeft(2, '0'), style: AppText.bodyStrong),
            Text(at == null ? '' : _month(at.month), style: AppText.small.copyWith(fontSize: 11)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${line['title']}', style: AppText.bodyStrong),
            if ('${line['note'] ?? ''}'.isNotEmpty) Text('${line['note']}', style: AppText.small),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${shipment ? '+' : '−'}${money(amount.abs().toStringAsFixed(2), suffix: false)}',
              style: AppText.bodyStrong.copyWith(color: shipment ? AppColors.ink : AppColors.successInk)),
          Text(tr('долг ${money(debt.toStringAsFixed(2), suffix: false)}', 'qarz ${money(debt.toStringAsFixed(2), suffix: false)}'), style: AppText.small.copyWith(fontSize: 11)),
        ]),
      ]),
    );
  }

  static String _month(int m) {
    const ru = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
    const uz = ['yan', 'fev', 'mar', 'apr', 'may', 'iyn', 'iyl', 'avg', 'sen', 'okt', 'noy', 'dek'];
    return tr(ru[m - 1], uz[m - 1]);
  }
}
