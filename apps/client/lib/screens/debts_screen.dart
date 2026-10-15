import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

// Мои долги (Figma К1–К4, К6): сколько и какому магазину покупатель должен,
// история по магазину с позициями чека и «Это не я». Признак «магазин даёт
// в долг» покупателю не показываем — только долги, которые уже есть.

List<String> get _monthsGen => Lang.instance.isUz
    ? const ['yanvar', 'fevral', 'mart', 'aprel', 'may', 'iyun', 'iyul', 'avgust', 'sentabr', 'oktabr', 'noyabr', 'dekabr']
    : const ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
List<String> get _monthsShort => Lang.instance.isUz
    ? const ['yan', 'fev', 'mar', 'apr', 'may', 'iyun', 'iyul', 'avg', 'sen', 'okt', 'noy', 'dek']
    : const ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];

DateTime? _date(Object? v) => DateTime.tryParse('${v ?? ''}');

/// «2026-11-05» → «5 ноября» / «5-noyabr».
String debtDay(Object? v) {
  final d = _date(v);
  return d == null ? '' : tr('${d.day} ${_monthsGen[d.month - 1]}', '${d.day}-${_monthsGen[d.month - 1]}');
}

String _short(DateTime d) {
  final l = d.toLocal();
  return '${l.day} ${_monthsShort[l.month - 1]} · ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String _days(int n) {
  final m10 = n % 10, m100 = n % 100;
  final ru = m10 == 1 && m100 != 11
      ? '$n день'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? '$n дня'
          : '$n дней';
  return tr(ru, '$n kun');
}

/// «2 магазина», «5 магазинов»; «2 ta doʻkon».
String _stores(int n) {
  final m10 = n % 10, m100 = n % 100;
  final ru = (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
      ? '$n магазина'
      : (m10 == 1 && m100 != 11)
          ? '$n магазин'
          : '$n магазинов';
  return tr(ru, '$n ta doʻkon');
}

/// «вернуть до 5 ноября · осталось 31 день» / «просрочено 3 дня · срок был 2 октября».
String debtDue(Map<String, dynamic> d, {bool left = false}) {
  final overdue = (d['overdue_days'] as num?)?.toInt() ?? 0;
  if (overdue > 0) {
    return tr('просрочено ${_days(overdue)} · срок был ${debtDay(d['due_date'])}', '${_days(overdue)} kechikdi · muddat ${debtDay(d['due_date'])} edi');
  }
  final due = _date(d['due_date']);
  if (due == null) return '';
  final now = DateTime.now();
  final daysLeft = DateTime(due.year, due.month, due.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (daysLeft == 0) return tr('сегодня день оплаты', 'bugun toʻlov kuni');
  return tr('вернуть до ${debtDay(d['due_date'])}${left ? ' · осталось ${_days(daysLeft)}' : ''}',
      '${debtDay(d['due_date'])} gacha qaytarish${left ? ' · ${_days(daysLeft)} qoldi' : ''}');
}

Future<void> openDebts(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyDebtsScreen()));

Future<void> openStoreDebt(BuildContext context, String storeId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoreDebtScreen(storeId: storeId)));

/// К1 · карточка в профиле. Нет долгов — ничего.
class DebtsProfileCard extends StatelessWidget {
  const DebtsProfileCard({super.key});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppState>().debts;
    final stores = ((d?['stores'] as List?) ?? const []).cast<Map<String, dynamic>>();
    if (stores.isEmpty) return const SizedBox.shrink();
    final overdue = stores.any((s) => ((s['overdue_days'] as num?)?.toInt() ?? 0) > 0);
    final sub = [
      stores.length == 1 ? '${stores.first['name']}' : _stores(stores.length),
      if (overdue)
        tr('есть просрочка', 'muddati oʻtgan qarz bor')
      else if (d?['next_due'] != null)
        tr('ближайший срок ${debtDay(d!['next_due'])}', 'eng yaqin muddat ${debtDay(d['next_due'])}'),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Material(
        color: overdue ? AppColors.errorSoft : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () => openDebts(context),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Icon(Icons.account_balance_wallet_rounded, size: 28, color: overdue ? AppColors.error : AppColors.warningInk),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Мои долги · ${money(d!['total'])}', 'Mening qarzlarim · ${money(d['total'])}'), style: AppText.bodyStrong.copyWith(fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(sub, style: AppText.small.copyWith(color: overdue ? AppColors.error : AppColors.text2)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
            ]),
          ),
        ),
      ),
    );
  }
}

/// К6 · плашка под шапкой магазина, если покупатель там должен.
Widget? debtBannerSliver(BuildContext context, AppState state, String storeId) {
  final d = state.debtAt(storeId);
  if (d == null) return null;
  final overdue = ((d['overdue_days'] as num?)?.toInt() ?? 0) > 0;
  return SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: overdue ? AppColors.errorSoft : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () => openStoreDebt(context, storeId),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(Icons.account_balance_wallet_rounded, color: overdue ? AppColors.error : AppColors.warningInk),
              const SizedBox(width: 10),
              Expanded(child: Text(tr('Ваш долг здесь: ${money(d['amount'])}', 'Bu yerdagi qarzingiz: ${money(d['amount'])}'), style: AppText.bodyStrong)),
              Text(tr('История', 'Tarix'), style: AppText.smallStrong.copyWith(color: AppColors.text2)),
              const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
            ]),
          ),
        ),
      ),
    ),
  );
}

/// К2 · Мои долги: итог и магазины.
class MyDebtsScreen extends StatefulWidget {
  const MyDebtsScreen({super.key});

  @override
  State<MyDebtsScreen> createState() => _MyDebtsScreenState();
}

class _MyDebtsScreenState extends State<MyDebtsScreen> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      await context.read<AppState>().loadDebts();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppState>().debts;
    final stores = ((d?['stores'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(children: [
          PageHeader(title: tr('Мои долги', 'Mening qarzlarim')),
          Expanded(
            child: d == null
                ? (_error == null
                    ? const Center(child: CircularProgressIndicator())
                    : EmptyState(
                        icon: Icons.wifi_off_rounded,
                        title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
                        text: '$_error',
                        action: tr('Повторить', 'Qayta urinish'),
                        onAction: _load))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                      if (stores.isEmpty)
                        EmptyState(
                            icon: Icons.check_circle_outline_rounded,
                            title: tr('Долгов нет', 'Qarzlar yoʻq'),
                            text: tr('Вы ничего не должны магазинам', 'Doʻkonlardan hech qanday qarzingiz yoʻq'))
                      else ...[
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.xl)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(tr('Всего вы должны', 'Umumiy qarzingiz'), style: AppText.small.copyWith(color: AppColors.muted)),
                            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                              Text(money(d['total'], suffix: false), style: AppText.h1.copyWith(color: AppColors.white)),
                              const SizedBox(width: 6),
                              Text(tr('сум', 'soʻm'), style: AppText.bodyStrong.copyWith(color: AppColors.muted)),
                            ]),
                            Text(
                              [
                                tr('в ${stores.length} ${stores.length == 1 ? 'магазине' : 'магазинах'}', '${stores.length} ta doʻkonda'),
                                if (d['next_due'] != null) tr('ближайший срок ${debtDay(d['next_due'])}', 'eng yaqin muddat ${debtDay(d['next_due'])}'),
                              ].join(' · '),
                              style: AppText.small.copyWith(color: AppColors.muted),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 16),
                        for (final s in stores) ...[
                          _StoreRow(s: s, onTap: () async {
                            await openStoreDebt(context, s['store_id'] as String);
                            if (mounted) _load();
                          }),
                          const SizedBox(height: 10),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          tr('Долг записывает магазин, когда вы берёте товар без оплаты. Если запись неверная — откройте её и нажмите «Это не я».',
                              'Mahsulotni toʻlovsiz olganingizda doʻkon qarzni yozib qoʻyadi. Yozuv notoʻgʻri boʻlsa — uni oching va «Bu men emasman» ni bosing.'),
                          style: AppText.small,
                        ),
                      ],
                    ]),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _StoreRow extends StatelessWidget {
  const _StoreRow({required this.s, required this.onTap});

  final Map<String, dynamic> s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final overdue = ((s['overdue_days'] as num?)?.toInt() ?? 0) > 0;
    final logo = '${s['logo_url'] ?? ''}';
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              StoreLogo(name: '${s['name']}', url: logo.isEmpty ? null : logo, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${s['name']}', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if ('${s['address'] ?? ''}'.isNotEmpty) Text('${s['address']}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              Text(money(s['amount'], suffix: false), style: AppText.price),
              const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Icon(overdue ? Icons.error_rounded : Icons.schedule_rounded, size: 16, color: overdue ? AppColors.error : AppColors.text2),
              const SizedBox(width: 6),
              Expanded(child: Text(debtDue(s), style: AppText.small.copyWith(color: overdue ? AppColors.error : AppColors.text2))),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// К3 · Долг в магазине: сумма, срок, позвонить, маршрут, история.
class StoreDebtScreen extends StatefulWidget {
  const StoreDebtScreen({super.key, required this.storeId});

  final String storeId;

  @override
  State<StoreDebtScreen> createState() => _StoreDebtScreenState();
}

class _StoreDebtScreenState extends State<StoreDebtScreen> {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _all = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<AppState>().api.get('/client/debts/${widget.storeId}') as Map<String, dynamic>;
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

  Future<void> _dispute(Map<String, dynamic> e) async {
    final sent = await showDebtDispute(context, e, '${_d?['name'] ?? ''}');
    if (sent) {
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Отправили владельцу магазина — он проверит запись', 'Doʻkon egasiga yuborildi — u yozuvni tekshiradi'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final entries = ((d?['entries'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final shown = _all ? entries : entries.take(5).toList();
    final phone = '${d?['phone'] ?? ''}';
    final lat = d?['lat'], lng = d?['lng'];
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(children: [
          PageHeader(title: '${d?['name'] ?? tr('Долг', 'Qarz')}'),
          Expanded(
            child: d == null
                ? (_error == null
                    ? const Center(child: CircularProgressIndicator())
                    : EmptyState(
                        icon: Icons.wifi_off_rounded,
                        title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
                        text: '$_error',
                        action: tr('Повторить', 'Qayta urinish'),
                        onAction: _load))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
                      if ('${d['address'] ?? ''}'.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text('${d['address']}', textAlign: TextAlign.center, style: AppText.small),
                        ),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.xl)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(tr('Ваш долг здесь', 'Bu yerdagi qarzingiz'), style: AppText.small.copyWith(color: AppColors.muted)),
                          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                            Text(money(d['amount'], suffix: false), style: AppText.h1.copyWith(color: AppColors.white)),
                            const SizedBox(width: 6),
                            Text(tr('сум', 'soʻm'), style: AppText.bodyStrong.copyWith(color: AppColors.muted)),
                          ]),
                          if ((num.tryParse('${d['amount']}') ?? 0) > 0)
                            Text(debtDue(d, left: true),
                                style: AppText.small.copyWith(color: ((d['overdue_days'] as num?) ?? 0) > 0 ? AppColors.primaryLine : AppColors.muted))
                          else
                            Text(tr('долг погашен', 'qarz uzildi'), style: AppText.small.copyWith(color: AppColors.muted)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      Row(children: [
                        if (phone.isNotEmpty)
                          Expanded(
                            child: AppButton(label: tr('Позвонить', 'Qoʻngʻiroq qilish'), icon: Icons.call_rounded, type: AppButtonType.secondary, small: true, onPressed: () => openUrl('tel:$phone')),
                          ),
                        if (phone.isNotEmpty && lat != null) const SizedBox(width: 10),
                        if (lat != null && lng != null)
                          Expanded(
                            child: AppButton(
                              label: tr('Маршрут', 'Yoʻnalish'),
                              icon: Icons.directions_rounded,
                              type: AppButtonType.secondary,
                              small: true,
                              onPressed: () => openUrl('https://yandex.uz/maps/?rtext=~$lat,$lng&rtt=auto'),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 20),
                      Text(tr('История', 'Tarix'), style: AppText.title),
                      const SizedBox(height: 10),
                      if (entries.isEmpty)
                        Text(tr('Записей нет', 'Yozuvlar yoʻq'), style: AppText.small)
                      else
                        AppCard(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          child: Column(children: [
                            for (var i = 0; i < shown.length; i++) ...[
                              if (i > 0) const Divider(height: 1),
                              _EntryTile(e: shown[i], onDispute: () => _dispute(shown[i])),
                            ],
                          ]),
                        ),
                      if (!_all && entries.length > 5)
                        TextButton(onPressed: () => setState(() => _all = true), child: Text(tr('Показать всю историю', 'Butun tarixni koʻrsatish'))),
                    ]),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.e, required this.onDispute});

  final Map<String, dynamic> e;
  final VoidCallback onDispute;

  @override
  Widget build(BuildContext context) {
    final amount = num.tryParse('${e['amount']}') ?? 0;
    final at = _date(e['created_at']);
    final no = e['number'];
    final (IconData icon, String title) = switch (e['doc_type']) {
      'sale' => (Icons.shopping_basket_rounded, tr('Покупка в долг', 'Qarzga xarid')),
      'payment' => (
          Icons.payments_rounded,
          '${tr('Оплата', 'Toʻlov')}${'${e['detail'] ?? ''}'.isNotEmpty ? ' · ${'${e['detail']}'.toLowerCase()}' : ''}'
        ),
      'return' => (Icons.assignment_return_rounded, tr('Возврат товара', 'Mahsulot qaytarildi')),
      _ => (Icons.remove_circle_outline_rounded, tr('Долг списан магазином', 'Doʻkon qarzni hisobdan chiqardi')),
    };
    final sub = [
      if (at != null) _short(at),
      if (e['doc_type'] == 'sale' && no != null) tr('чек № $no', 'chek № $no'),
    ].join(' · ');
    final sale = e['sale'] as Map<String, dynamic>?;
    final items = ((sale?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final dispute = '${e['dispute_status'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 24, color: amount > 0 ? AppColors.primary : AppColors.successInk),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong),
              if (sub.isNotEmpty) Text(sub, style: AppText.small),
            ]),
          ),
          Text('${amount > 0 ? '+ ' : '− '}${money(amount.abs(), suffix: false)}',
              style: AppText.bodyStrong.copyWith(color: amount > 0 ? AppColors.ink : AppColors.successInk)),
        ]),
        if (items.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.md)),
            child: Column(children: [
              for (final it in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(child: Text('${it['name']} · ${qty(it['qty'], '${it['unit'] ?? ''}')}', style: AppText.small.copyWith(color: AppColors.ink))),
                    Text(money(it['total'], suffix: false), style: AppText.small.copyWith(color: AppColors.ink)),
                  ]),
                ),
              const Divider(height: 14),
              Row(children: [
                Expanded(
                  child: Text(
                      tr('Чек ${money(sale!['total'], suffix: false)} · оплачено ${money(sale['paid'], suffix: false)} · в долг',
                          'Chek ${money(sale['total'], suffix: false)} · toʻlandi ${money(sale['paid'], suffix: false)} · qarzga'),
                      style: AppText.small),
                ),
                Text(money(sale['debt'], suffix: false), style: AppText.smallStrong),
              ]),
            ]),
          ),
        ],
        if (e['doc_type'] == 'sale') ...[
          const SizedBox(height: 6),
          if (dispute.isEmpty)
            TextButton.icon(
              onPressed: onDispute,
              icon: const Icon(Icons.report_rounded, size: 18),
              label: Text(tr('Это не я', 'Bu men emasman')),
              style: TextButton.styleFrom(foregroundColor: AppColors.text2, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            )
          else
            Text(
              switch (dispute) {
                'open' => tr('Жалоба у владельца — пока идёт проверка, напоминаний по ней нет',
                    'Shikoyat egasida — tekshiruv davomida bu yozuv boʻyicha eslatmalar kelmaydi'),
                'accepted' => tr('Владелец согласился — запись списана', 'Egasi rozi boʻldi — yozuv hisobdan chiqarildi'),
                _ => tr('Владелец проверил запись — она верна', 'Egasi yozuvni tekshirdi — u toʻgʻri'),
              },
              style: AppText.small.copyWith(color: dispute == 'accepted' ? AppColors.successInk : AppColors.warningInk),
            ),
        ],
      ]),
    );
  }
}

/// К4 · «Это не я»: шторка жалобы на запись [entry] ({id, number, created_at,
/// amount}). true — отправили.
Future<bool> showDebtDispute(BuildContext context, Map<String, dynamic> entry, String storeName) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (_) => _DisputeSheet(entry: entry, storeName: storeName),
  );
  return sent == true;
}

/// К4 · «Это не я»: жалоба владельцу магазина.
class _DisputeSheet extends StatefulWidget {
  const _DisputeSheet({required this.entry, required this.storeName});

  final Map<String, dynamic> entry;
  final String storeName;

  @override
  State<_DisputeSheet> createState() => _DisputeSheetState();
}

class _DisputeSheetState extends State<_DisputeSheet> {
  final _comment = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.post('/client/debts/entries/${widget.entry['id']}/dispute', {'comment': _comment.text.trim()});
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final at = _date(e['created_at']);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Это не ваша покупка?', 'Bu sizning xaridingiz emasmi?'), style: AppText.h3),
          const SizedBox(height: 6),
          Text(
            tr(
                '${e['number'] != null ? 'Чек № ${e['number']} · ' : ''}${at != null ? '${debtDay(at.toIso8601String())} · ' : ''}${money(e['amount'])} в долг. '
                    'Передадим владельцу ${widget.storeName} — он проверит запись. Пока идёт проверка, напоминаний по ней не будет.',
                '${e['number'] != null ? 'Chek № ${e['number']} · ' : ''}${at != null ? '${debtDay(at.toIso8601String())} · ' : ''}${money(e['amount'])} qarzga. '
                    '${widget.storeName} egasiga yuboramiz — u yozuvni tekshiradi. Tekshiruv davomida bu yozuv boʻyicha eslatmalar kelmaydi.'),
            style: AppText.small.copyWith(fontSize: 15),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _comment,
            maxLength: 500,
            maxLines: 3,
            minLines: 2,
            decoration: InputDecoration(labelText: tr('Что не так?', 'Nima notoʻgʻri?'), hintText: tr('В этот день я не был в магазине', 'Bu kuni men doʻkonda boʻlmaganman')),
          ),
          const SizedBox(height: 10),
          AppButton(label: tr('Отправить владельцу', 'Egasiga yuborish'), loading: _busy, onPressed: _busy ? null : _send),
          const SizedBox(height: 8),
          AppButton(label: tr('Отмена', 'Bekor qilish'), type: AppButtonType.ghost, onPressed: () => Navigator.of(context).pop(false)),
        ]),
      ),
    );
  }
}
