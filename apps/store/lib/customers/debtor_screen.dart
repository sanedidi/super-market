import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../finance/finance_logic.dart' show n, plainAmount;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'customer_debts_screen.dart' show shortDate;

// Покупатель — долг и история (Figma С2), принять оплату (С3), напомнить,
// лимит, стоп-лист, списание, споры «Это не я».

class DebtorScreen extends StatefulWidget {
  const DebtorScreen({super.key, required this.id});

  final String id;

  @override
  State<DebtorScreen> createState() => _DebtorScreenState();
}

class _DebtorScreenState extends State<DebtorScreen> {
  Map<String, dynamic>? _c;
  List<Map<String, dynamic>> _disputes = const [];
  Object? _error;
  bool _reminding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? get _storeId => context.read<StoreState>().storeId;

  Future<void> _load() async {
    final api = context.read<Api>();
    final store = _storeId;
    try {
      final c = await api.get('/store/debtors/${widget.id}', {'store_id': store}) as Map<String, dynamic>;
      List<Map<String, dynamic>> ds = const [];
      try {
        ds = [
          for (final d in await api.list('/store/debt-disputes', {'store_id': store, 'status': 'open'}))
            if (d['debtor_id'] == widget.id) d,
        ];
      } catch (_) {
        // споры видит только владелец/менеджер с правом — без них карточка работает
      }
      if (!mounted) return;
      setState(() {
        _c = c;
        _disputes = ds;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic>? get _bal {
    final list = ((_c?['stores'] as List?) ?? const []).cast<Map<String, dynamic>>();
    for (final b in list) {
      if (b['store_id'] == _storeId) return b;
    }
    return list.isEmpty ? null : list.first;
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _pay() async {
    final c = _c!;
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => _PaySheet(card: c, debt: '${_bal?['amount'] ?? '0'}', storeId: _storeId!),
    );
    if (done == true) await _load();
  }

  Future<void> _remind() async {
    if (_reminding) return;
    setState(() => _reminding = true);
    try {
      await context.read<Api>().post('/store/debtors/${widget.id}/remind', {'store_id': _storeId});
      if (mounted) _snack(tr('Напоминание отправлено в приложение покупателя', 'Eslatma xaridor ilovasiga yuborildi'));
    } on ApiError catch (e) {
      if (mounted) _snack(e.message);
    } finally {
      if (mounted) setState(() => _reminding = false);
    }
  }

  Future<void> _patch(Map<String, dynamic> body, String done) async {
    try {
      await context.read<Api>().patch('/store/debtors/${widget.id}', body);
      if (!mounted) return;
      _snack(done);
      await _load();
    } on ApiError catch (e) {
      if (mounted) _snack(e.message);
    }
  }

  Future<void> _limit() async {
    final c = _c!;
    final res = await showModalBottomSheet<(bool, String?)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => _LimitSheet(own: c['credit_limit'] as String?, current: '${_bal?['limit'] ?? ''}'),
    );
    if (res == null) return;
    await _patch({'credit_limit': res.$2}, res.$2 == null ? tr('Лимит — по настройкам сети', 'Limit — tarmoq sozlamalari boʻyicha') : '${tr('Лимит', 'Limit')} ${money(res.$2)}');
  }

  Future<void> _block() async {
    final blocked = _c!['blocked'] == true;
    final ok = await confirmSheet(
      context,
      icon: Icons.block_rounded,
      title: blocked ? tr('Убрать из стоп-листа?', 'Stop-listdan olib tashlansinmi?') : tr('В стоп-лист?', 'Stop-listga qoʻshilsinmi?'),
      text: blocked
          ? tr('Касса снова сможет продавать этому покупателю в долг.', 'Kassa bu xaridorga yana qarzga sota oladi.')
          : tr('Касса не продаст в долг по этому номеру. Долг останется — его можно принимать.',
              'Kassa bu raqamga qarzga sotmaydi. Qarz qoladi — uni qabul qilish mumkin.'),
      confirm: blocked ? tr('Убрать', 'Olib tashlash') : tr('В стоп-лист', 'Stop-listga'),
    );
    if (ok) {
      await _patch(
          {'blocked': !blocked}, blocked ? tr('Покупатель убран из стоп-листа', 'Xaridor stop-listdan olib tashlandi') : tr('Покупатель в стоп-листе', 'Xaridor stop-listda'));
    }
  }

  Future<void> _writeoff() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => _WriteoffSheet(card: _c!, debt: '${_bal?['amount'] ?? '0'}', storeId: _storeId!),
    );
    if (done == true) await _load();
  }

  Future<void> _resolve(Map<String, dynamic> d, bool accept) async {
    final ok = await confirmSheet(
      context,
      icon: Icons.report_outlined,
      title: accept ? tr('Запись ошибочна?', 'Yozuv notoʻgʻrimi?') : tr('Запись верна?', 'Yozuv toʻgʻrimi?'),
      text: accept
          ? tr('Долг ${money(d['amount'])} по этой записи спишется, покупатель получит уведомление.',
              'Bu yozuv boʻyicha ${money(d['amount'])} qarz hisobdan chiqariladi, xaridor bildirishnoma oladi.')
          : tr('Долг останется, покупатель получит уведомление, что запись проверена.', 'Qarz qoladi, xaridor yozuv tekshirilgani haqida bildirishnoma oladi.'),
      confirm: accept ? tr('Списать долг', 'Qarzni hisobdan chiqarish') : tr('Запись верна', 'Yozuv toʻgʻri'),
    );
    if (!ok || !mounted) return;
    try {
      await context.read<Api>().post('/store/debt-disputes/${d['id']}/resolve', {'status': accept ? 'accepted' : 'rejected'});
      if (!mounted) return;
      _snack(accept ? tr('Запись списана', 'Yozuv hisobdan chiqarildi') : tr('Спор закрыт', 'Nizo yopildi'));
      await _load();
    } on ApiError catch (e) {
      if (mounted) _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final st = context.watch<StoreState>();
    final manage = st.can('debts.manage');
    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Покупатель', 'Xaridor'))),
        body: _error == null
            ? const Center(child: CircularProgressIndicator())
            : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load),
      );
    }
    final b = _bal;
    final debt = n(b?['amount']);
    final phone = '${c['phone']}';
    final name = '${c['full_name'] ?? ''}'.trim();
    final entries = ((c['entries'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final overdue = (b?['overdue_days'] as num?)?.toInt() ?? 0;
    final status = [
      c['verified'] == true ? tr('подтверждён', 'tasdiqlangan') : tr('не подтверждён', 'tasdiqlanmagan'),
      if (c['blocked'] == true) tr('стоп-лист', 'stop-list'),
    ].join(' · ');
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name.isEmpty ? formatPhone(phone) : name),
          Text('${formatPhone(phone)} · $status', style: AppText.small),
        ]),
        actions: [
          IconButton(icon: const Icon(Icons.call_rounded), onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
          if (manage)
            PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'limit' => _limit(),
                'block' => _block(),
                'writeoff' => _writeoff(),
                _ => null,
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'limit', child: Text(tr('Лимит', 'Limit'))),
                PopupMenuItem(value: 'block', child: Text(c['blocked'] == true ? tr('Убрать из стоп-листа', 'Stop-listdan olib tashlash') : tr('В стоп-лист', 'Stop-listga'))),
                if (debt > 0) PopupMenuItem(value: 'writeoff', child: Text(tr('Списать долг', 'Qarzni hisobdan chiqarish'))),
              ],
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(20)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Должен магазину', 'Doʻkonga qarzi'), style: AppText.small.copyWith(color: AppColors.muted)),
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(money(debt, suffix: false), style: AppText.h1.copyWith(color: AppColors.white, fontSize: 30)),
                const SizedBox(width: 6),
                Text(tr('сум', 'soʻm'), style: AppText.bodyStrong.copyWith(color: AppColors.muted)),
              ]),
              Text(
                [
                  if (debt > 0 && b?['due_date'] != null)
                    overdue > 0
                        ? tr('просрочено $overdue дн. · срок был ${shortDate(b!['due_date'])}', 'muddati $overdue kun oʻtgan · muddat ${shortDate(b['due_date'])} edi')
                        : tr('Вернуть до ${shortDate(b!['due_date'])}', '${shortDate(b['due_date'])} gacha qaytarish'),
                  tr('свободно ${money(b?['available'], suffix: false)}', 'boʻsh limit ${money(b?['available'], suffix: false)}'),
                ].join(' · '),
                style: AppText.small.copyWith(color: overdue > 0 ? AppColors.primarySoft : AppColors.muted),
              ),
              if (manage) ...[
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: SmallButton(label: tr('Принять оплату', 'Toʻlovni qabul qilish'), icon: Icons.payments_outlined, primary: true, onPressed: debt > 0 ? _pay : null)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SmallButton(
                      label: _reminding ? tr('Отправляем…', 'Yuborilmoqda…') : tr('Напомнить', 'Eslatish'),
                      icon: Icons.notifications_none_rounded,
                      onPressed: debt > 0 && !_reminding ? _remind : null,
                    ),
                  ),
                ]),
                if (c['has_app'] != true && debt > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(tr('У покупателя нет приложения — напоминание не дойдёт, позвоните.', 'Xaridorda ilova yoʻq — eslatma yetib bormaydi, qoʻngʻiroq qiling.'),
                        style: AppText.small.copyWith(color: AppColors.muted)),
                  ),
              ],
            ]),
          ),
          for (final d in _disputes) ...[
            const SizedBox(height: 12),
            AppCard(
              color: AppColors.warningSoft,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.report_outlined, color: AppColors.warningInk),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${tr('«Это не я»', '«Bu men emasman»')} · ${d['number'] != null ? '${tr('чек', 'chek')} № ${d['number']} · ' : ''}${money(d['amount'])}',
                        style: AppText.bodyStrong.copyWith(color: AppColors.warningInk)),
                  ),
                ]),
                const SizedBox(height: 4),
                Text(
                  [
                    shortDate(d['entry_at']),
                    if ('${d['cashier'] ?? ''}'.isNotEmpty) '${tr('кассир', 'kassir')} ${d['cashier']}',
                    if ('${d['comment'] ?? ''}'.isNotEmpty) '«${d['comment']}»',
                  ].join(' · '),
                  style: AppText.small,
                ),
                if (manage) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: SmallButton(label: tr('Запись верна', 'Yozuv toʻgʻri'), icon: Icons.check_rounded, onPressed: () => _resolve(d, false))),
                    const SizedBox(width: 10),
                    Expanded(child: SmallButton(label: tr('Списать', 'Chiqarish'), icon: Icons.close_rounded, primary: true, onPressed: () => _resolve(d, true))),
                  ]),
                ],
              ]),
            ),
          ],
          const SizedBox(height: 18),
          Text(tr('История долга', 'Qarz tarixi'), style: AppText.title),
          const SizedBox(height: 10),
          if (entries.isEmpty)
            EmptyState(icon: Icons.receipt_long_outlined, title: tr('Записей пока нет', 'Hozircha yozuvlar yoʻq'))
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 12, endIndent: 12),
                  _EntryRow(e: entries[i]),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.e});

  final Map<String, dynamic> e;

  @override
  Widget build(BuildContext context) {
    final amount = n(e['amount']);
    final no = e['number'];
    final (IconData icon, String title) = switch (e['doc_type']) {
      'sale' => (Icons.shopping_basket_outlined, '${tr('В долг', 'Qarzga')}${no != null ? ' · ${tr('чек', 'chek')} № $no' : ''}'),
      'payment' => (Icons.payments_outlined, '${tr('Оплата', 'Toʻlov')}${'${e['detail'] ?? ''}'.isNotEmpty ? ' · ${e['detail']}' : ''}'),
      'return' => (Icons.assignment_return_outlined, '${tr('Возврат', 'Qaytarish')}${no != null ? ' № $no' : ''}'),
      'manual' => (Icons.edit_note_rounded, '${tr('Внесён вручную', 'Qoʻlda kiritilgan')}${no != null ? ' № $no' : ''}'),
      _ => (Icons.remove_circle_outline_rounded, tr('Списание', 'Hisobdan chiqarish')),
    };
    final sub = [
      dateTime(e['created_at']),
      if (e['doc_type'] == 'sale' || e['doc_type'] == 'return' || e['doc_type'] == 'writeoff' || e['doc_type'] == 'manual')
        if ('${e['detail'] ?? ''}'.isNotEmpty) '${e['detail']}',
      if ('${e['employee'] ?? ''}'.isNotEmpty) '${e['employee']}',
    ].join(' · ');
    final dispute = '${e['dispute_status'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBox(icon, bg: amount > 0 ? AppColors.primarySoft : AppColors.successSoft, fg: amount > 0 ? AppColors.primary : AppColors.successInk),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
            Text(sub, style: AppText.small),
            if (dispute.isNotEmpty) ...[
              const SizedBox(height: 4),
              StatusChip(
                switch (dispute) {
                  'open' => tr('оспаривает', 'eʼtiroz bildirgan'),
                  'accepted' => tr('списано по спору', 'nizo boʻyicha chiqarildi'),
                  _ => tr('спор отклонён', 'nizo rad etildi'),
                },
                tone: dispute == 'open' ? ChipTone.amber : ChipTone.gray,
              ),
            ],
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${amount > 0 ? '+ ' : '− '}${money(amount.abs(), suffix: false)}',
              style: AppText.bodyStrong.copyWith(color: amount > 0 ? AppColors.ink : AppColors.successInk)),
          Text('${tr('долг', 'qarz')} ${money(e['balance'], suffix: false)}', style: AppText.small),
        ]),
      ]),
    );
  }
}

// --------------------------------------------------------- С3 принять оплату

class _PaySheet extends StatefulWidget {
  const _PaySheet({required this.card, required this.debt, required this.storeId});

  final Map<String, dynamic> card;
  final String debt;
  final String storeId;

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  late final _amount = TextEditingController(text: money(widget.debt, suffix: false));
  final _note = TextEditingController();
  List<Map<String, dynamic>>? _methods;
  String? _methodId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadMethods();
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadMethods() async {
    try {
      final all = await context.read<Api>().list('/store/finance/payment-methods');
      final ms = [
        for (final m in all)
          if (m['is_active'] != false && m['store_id'] == widget.storeId && (m['kind'] == 'cash' || m['kind'] == 'card')) m,
      ]..sort((a, b) => (a['kind'] == 'cash' ? 0 : 1) - (b['kind'] == 'cash' ? 0 : 1));
      if (!mounted) return;
      setState(() {
        _methods = ms;
        _methodId = ms.firstOrNull?['id'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  num? _lastSale() {
    for (final e in ((widget.card['entries'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (e['doc_type'] == 'sale') return n(e['amount']);
    }
    return null;
  }

  void _quick(num v) => _amount.text = money(v, suffix: false);

  Future<void> _submit() async {
    final v = num.tryParse(plainAmount(_amount.text));
    final debt = n(widget.debt);
    String? err;
    if (v == null || v <= 0) {
      err = tr('Введите сумму больше нуля', 'Noldan katta summani kiriting');
    } else if (v > debt) {
      err = tr('Больше долга ${money(debt)}', 'Qarzdan (${money(debt)}) koʻp');
    } else if (_methodId == null) {
      err = tr('Выберите, как платит', 'Toʻlov usulini tanlang');
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await context.read<Api>().post('/store/debt-payments', {
        'debtor_id': widget.card['id'],
        'store_id': widget.storeId,
        'amount': plainAmount(_amount.text),
        'payment_method_id': _methodId,
        'note': _note.text.trim(),
      }) as Map<String, dynamic>;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      final left = n(res['balance']);
      messenger.showSnackBar(SnackBar(
          content: Text(left > 0
              ? tr('Оплата принята · осталось ${money(left)}', 'Toʻlov qabul qilindi · qoldi ${money(left)}')
              : tr('Долг погашен полностью', 'Qarz toʻliq uzildi'))));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final debt = n(widget.debt);
    final last = _lastSale();
    final ms = _methods;
    final name = '${widget.card['full_name'] ?? ''}'.trim();
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Принять оплату долга', 'Qarz toʻlovini qabul qilish'), style: AppText.h3),
            Text('${name.isEmpty ? formatPhone(widget.card['phone']) : name} · ${tr('долг', 'qarz')} ${money(debt)}', style: AppText.small),
            const SizedBox(height: 14),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
              style: AppText.h2,
              decoration: InputDecoration(labelText: tr('Сумма', 'Summa'), suffixText: tr('сум', 'soʻm')),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ActionChip(label: Text(tr('Весь долг', 'Butun qarz')), onPressed: () => _quick(debt)),
              ActionChip(label: Text(tr('Половина', 'Yarmi')), onPressed: () => _quick((debt / 2).roundToDouble())),
              if (last != null && last > 0 && last < debt) ActionChip(label: Text(tr('Последняя покупка', 'Oxirgi xarid')), onPressed: () => _quick(last)),
            ]),
            const SizedBox(height: 16),
            Text(tr('КАК ПЛАТИТ', 'TOʻLOV USULI'), style: AppText.caption),
            const SizedBox(height: 8),
            if (ms == null)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
            else if (ms.isEmpty)
              Text(tr('В магазине нет способов оплаты «Наличные» или «Карта» — добавьте в панели', 'Doʻkonda «Naqd pul» yoki «Karta» toʻlov usuli yoʻq — panelda qoʻshing'),
                  style: AppText.small)
            else
              for (final m in ms)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AppCard(
                    onTap: () => setState(() => _methodId = m['id'] as String),
                    border: _methodId == m['id'] ? AppColors.primary : AppColors.line,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(children: [
                      Icon(m['kind'] == 'cash' ? Icons.payments_outlined : Icons.credit_card_rounded),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(m['kind'] == 'cash' ? tr('Наличными', 'Naqd pul') : tr('Картой', 'Karta'), style: AppText.bodyStrong),
                          Text('${m['name']}', style: AppText.small),
                        ]),
                      ),
                      Icon(_methodId == m['id'] ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                          color: _methodId == m['id'] ? AppColors.primary : AppColors.muted),
                    ]),
                  ),
                ),
            const SizedBox(height: 4),
            TextField(controller: _note, decoration: InputDecoration(hintText: tr('Комментарий: кто принёс, если не сам покупатель', 'Izoh: xaridorning oʻzi boʻlmasa, kim olib keldi'))),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 16),
            ValueListenableBuilder(
              valueListenable: _amount,
              builder: (_, v, __) => BigButton(
                label: tr('Принять ${money(plainAmount(v.text))}', '${money(plainAmount(v.text))} qabul qilish'),
                icon: Icons.check_rounded,
                busy: _busy,
                onPressed: _submit,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- лимит

class _LimitSheet extends StatefulWidget {
  const _LimitSheet({required this.own, required this.current});

  /// Свой лимит покупателя; null — по настройкам сети.
  final String? own;
  final String current;

  @override
  State<_LimitSheet> createState() => _LimitSheetState();
}

class _LimitSheetState extends State<_LimitSheet> {
  late final _v = TextEditingController(text: money(widget.own ?? widget.current, suffix: false));

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Лимит покупателя', 'Xaridor limiti'), style: AppText.h3),
            Text(
                widget.own == null
                    ? tr('Сейчас — по настройкам сети: ${money(widget.current)}', 'Hozir — tarmoq sozlamalari boʻyicha: ${money(widget.current)}')
                    : tr('Свой лимит этого покупателя', 'Bu xaridorning oʻz limiti'),
                style: AppText.small),
            const SizedBox(height: 14),
            TextField(
              controller: _v,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s]'))],
              style: AppText.h2,
              decoration: InputDecoration(labelText: tr('Сколько можно в долг', 'Qancha qarz berish mumkin'), suffixText: tr('сум', 'soʻm')),
            ),
            const SizedBox(height: 16),
            BigButton(
              label: tr('Сохранить', 'Saqlash'),
              onPressed: () {
                final v = plainAmount(_v.text);
                if (num.tryParse(v) == null) return;
                Navigator.of(context).pop((true, v));
              },
            ),
            if (widget.own != null) ...[
              const SizedBox(height: 10),
              BigButton(
                label: tr('Как в настройках сети', 'Tarmoq sozlamalaridagidek'),
                color: AppColors.soft,
                foreground: AppColors.ink,
                onPressed: () => Navigator.of(context).pop((true, null)),
              ),
            ],
          ]),
        ),
      );
}

// ---------------------------------------------------------------- списание

class _WriteoffSheet extends StatefulWidget {
  const _WriteoffSheet({required this.card, required this.debt, required this.storeId});

  final Map<String, dynamic> card;
  final String debt;
  final String storeId;

  @override
  State<_WriteoffSheet> createState() => _WriteoffSheetState();
}

class _WriteoffSheetState extends State<_WriteoffSheet> {
  late final _amount = TextEditingController(text: money(widget.debt, suffix: false));
  final _reason = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final v = num.tryParse(plainAmount(_amount.text));
    if (v == null || v <= 0 || v > n(widget.debt)) {
      setState(() => _error = tr('Сумма — больше нуля и не больше долга ${money(widget.debt)}', 'Summa noldan katta va qarzdan (${money(widget.debt)}) koʻp boʻlmasin'));
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = tr('Напишите причину — её увидит владелец в истории', 'Sababini yozing — egasi uni tarixda koʻradi'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Api>().post('/store/debt-writeoffs', {
        'debtor_id': widget.card['id'],
        'store_id': widget.storeId,
        'amount': plainAmount(_amount.text),
        'reason': _reason.text.trim(),
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(tr('Долг списан', 'Qarz hisobdan chiqarildi'))));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Списать долг', 'Qarzni hisobdan chiqarish'), style: AppText.h3),
            Text(tr('Деньги не поступят — долг просто уменьшится. Долг ${money(widget.debt)}', 'Pul tushmaydi — qarz shunchaki kamayadi. Qarz ${money(widget.debt)}'),
                style: AppText.small),
            const SizedBox(height: 14),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
              style: AppText.h2,
              decoration: InputDecoration(labelText: tr('Сумма', 'Summa'), suffixText: tr('сум', 'soʻm')),
            ),
            const SizedBox(height: 10),
            TextField(controller: _reason, decoration: InputDecoration(hintText: tr('Причина: уехал, ошибка кассира, подарок…', 'Sabab: koʻchib ketgan, kassir xatosi, sovgʻa…'))),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 16),
            BigButton(label: tr('Списать', 'Hisobdan chiqarish'), busy: _busy, onPressed: _submit),
          ]),
        ),
      );
}
