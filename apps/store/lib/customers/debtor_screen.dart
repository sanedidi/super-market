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
      if (mounted) _snack('Напоминание отправлено в приложение покупателя');
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
    await _patch({'credit_limit': res.$2}, res.$2 == null ? 'Лимит — по настройкам сети' : 'Лимит ${money(res.$2)}');
  }

  Future<void> _block() async {
    final blocked = _c!['blocked'] == true;
    final ok = await confirmSheet(
      context,
      icon: Icons.block_rounded,
      title: blocked ? 'Убрать из стоп-листа?' : 'В стоп-лист?',
      text: blocked
          ? 'Касса снова сможет продавать этому покупателю в долг.'
          : 'Касса не продаст в долг по этому номеру. Долг останется — его можно принимать.',
      confirm: blocked ? 'Убрать' : 'В стоп-лист',
    );
    if (ok) await _patch({'blocked': !blocked}, blocked ? 'Покупатель убран из стоп-листа' : 'Покупатель в стоп-листе');
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
      title: accept ? 'Запись ошибочна?' : 'Запись верна?',
      text: accept
          ? 'Долг ${money(d['amount'])} по этой записи спишется, покупатель получит уведомление.'
          : 'Долг останется, покупатель получит уведомление, что запись проверена.',
      confirm: accept ? 'Списать долг' : 'Запись верна',
    );
    if (!ok || !mounted) return;
    try {
      await context.read<Api>().post('/store/debt-disputes/${d['id']}/resolve', {'status': accept ? 'accepted' : 'rejected'});
      if (!mounted) return;
      _snack(accept ? 'Запись списана' : 'Спор закрыт');
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
        appBar: AppBar(title: const Text('Покупатель')),
        body: _error == null
            ? const Center(child: CircularProgressIndicator())
            : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load),
      );
    }
    final b = _bal;
    final debt = n(b?['amount']);
    final phone = '${c['phone']}';
    final name = '${c['full_name'] ?? ''}'.trim();
    final entries = ((c['entries'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final overdue = (b?['overdue_days'] as num?)?.toInt() ?? 0;
    final status = [
      c['verified'] == true ? 'подтверждён' : 'не подтверждён',
      if (c['blocked'] == true) 'стоп-лист',
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
                const PopupMenuItem(value: 'limit', child: Text('Лимит')),
                PopupMenuItem(value: 'block', child: Text(c['blocked'] == true ? 'Убрать из стоп-листа' : 'В стоп-лист')),
                if (debt > 0) const PopupMenuItem(value: 'writeoff', child: Text('Списать долг')),
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
              Text('Должен магазину', style: AppText.small.copyWith(color: AppColors.muted)),
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(money(debt, suffix: false), style: AppText.h1.copyWith(color: AppColors.white, fontSize: 30)),
                const SizedBox(width: 6),
                Text('сум', style: AppText.bodyStrong.copyWith(color: AppColors.muted)),
              ]),
              Text(
                [
                  if (debt > 0 && b?['due_date'] != null)
                    overdue > 0 ? 'просрочено $overdue дн. · срок был ${shortDate(b!['due_date'])}' : 'Вернуть до ${shortDate(b!['due_date'])}',
                  'свободно ${money(b?['available'], suffix: false)}',
                ].join(' · '),
                style: AppText.small.copyWith(color: overdue > 0 ? AppColors.primarySoft : AppColors.muted),
              ),
              if (manage) ...[
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: SmallButton(label: 'Принять оплату', icon: Icons.payments_outlined, primary: true, onPressed: debt > 0 ? _pay : null)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SmallButton(
                      label: _reminding ? 'Отправляем…' : 'Напомнить',
                      icon: Icons.notifications_none_rounded,
                      onPressed: debt > 0 && !_reminding ? _remind : null,
                    ),
                  ),
                ]),
                if (c['has_app'] != true && debt > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('У покупателя нет приложения — напоминание не дойдёт, позвоните.',
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
                    child: Text('«Это не я» · ${d['number'] != null ? 'чек № ${d['number']} · ' : ''}${money(d['amount'])}',
                        style: AppText.bodyStrong.copyWith(color: AppColors.warningInk)),
                  ),
                ]),
                const SizedBox(height: 4),
                Text(
                  [
                    shortDate(d['entry_at']),
                    if ('${d['cashier'] ?? ''}'.isNotEmpty) 'кассир ${d['cashier']}',
                    if ('${d['comment'] ?? ''}'.isNotEmpty) '«${d['comment']}»',
                  ].join(' · '),
                  style: AppText.small,
                ),
                if (manage) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: SmallButton(label: 'Запись верна', icon: Icons.check_rounded, onPressed: () => _resolve(d, false))),
                    const SizedBox(width: 10),
                    Expanded(child: SmallButton(label: 'Списать', icon: Icons.close_rounded, primary: true, onPressed: () => _resolve(d, true))),
                  ]),
                ],
              ]),
            ),
          ],
          const SizedBox(height: 18),
          const Text('История долга', style: AppText.title),
          const SizedBox(height: 10),
          if (entries.isEmpty)
            const EmptyState(icon: Icons.receipt_long_outlined, title: 'Записей пока нет')
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
      'sale' => (Icons.shopping_basket_outlined, 'В долг${no != null ? ' · чек № $no' : ''}'),
      'payment' => (Icons.payments_outlined, 'Оплата${'${e['detail'] ?? ''}'.isNotEmpty ? ' · ${e['detail']}' : ''}'),
      'return' => (Icons.assignment_return_outlined, 'Возврат${no != null ? ' № $no' : ''}'),
      _ => (Icons.remove_circle_outline_rounded, 'Списание'),
    };
    final sub = [
      dateTime(e['created_at']),
      if (e['doc_type'] == 'sale' || e['doc_type'] == 'return' || e['doc_type'] == 'writeoff')
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
                switch (dispute) { 'open' => 'оспаривает', 'accepted' => 'списано по спору', _ => 'спор отклонён' },
                tone: dispute == 'open' ? ChipTone.amber : ChipTone.gray,
              ),
            ],
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${amount > 0 ? '+ ' : '− '}${money(amount.abs(), suffix: false)}',
              style: AppText.bodyStrong.copyWith(color: amount > 0 ? AppColors.ink : AppColors.successInk)),
          Text('долг ${money(e['balance'], suffix: false)}', style: AppText.small),
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
      err = 'Введите сумму больше нуля';
    } else if (v > debt) {
      err = 'Больше долга ${money(debt)}';
    } else if (_methodId == null) {
      err = 'Выберите, как платит';
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
      messenger.showSnackBar(SnackBar(content: Text(left > 0 ? 'Оплата принята · осталось ${money(left)}' : 'Долг погашен полностью')));
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
            const Text('Принять оплату долга', style: AppText.h3),
            Text('${name.isEmpty ? formatPhone(widget.card['phone']) : name} · долг ${money(debt)}', style: AppText.small),
            const SizedBox(height: 14),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
              style: AppText.h2,
              decoration: const InputDecoration(labelText: 'Сумма', suffixText: 'сум'),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ActionChip(label: const Text('Весь долг'), onPressed: () => _quick(debt)),
              ActionChip(label: const Text('Половина'), onPressed: () => _quick((debt / 2).roundToDouble())),
              if (last != null && last > 0 && last < debt) ActionChip(label: const Text('Последняя покупка'), onPressed: () => _quick(last)),
            ]),
            const SizedBox(height: 16),
            const Text('КАК ПЛАТИТ', style: AppText.caption),
            const SizedBox(height: 8),
            if (ms == null)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
            else if (ms.isEmpty)
              const Text('В магазине нет способов оплаты «Наличные» или «Карта» — добавьте в панели', style: AppText.small)
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
                          Text(m['kind'] == 'cash' ? 'Наличными' : 'Картой', style: AppText.bodyStrong),
                          Text('${m['name']}', style: AppText.small),
                        ]),
                      ),
                      Icon(_methodId == m['id'] ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                          color: _methodId == m['id'] ? AppColors.primary : AppColors.muted),
                    ]),
                  ),
                ),
            const SizedBox(height: 4),
            TextField(controller: _note, decoration: const InputDecoration(hintText: 'Комментарий: кто принёс, если не сам покупатель')),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 16),
            ValueListenableBuilder(
              valueListenable: _amount,
              builder: (_, v, __) => BigButton(
                label: 'Принять ${money(plainAmount(v.text))}',
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
            const Text('Лимит покупателя', style: AppText.h3),
            Text(widget.own == null ? 'Сейчас — по настройкам сети: ${money(widget.current)}' : 'Свой лимит этого покупателя', style: AppText.small),
            const SizedBox(height: 14),
            TextField(
              controller: _v,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s]'))],
              style: AppText.h2,
              decoration: const InputDecoration(labelText: 'Сколько можно в долг', suffixText: 'сум'),
            ),
            const SizedBox(height: 16),
            BigButton(
              label: 'Сохранить',
              onPressed: () {
                final v = plainAmount(_v.text);
                if (num.tryParse(v) == null) return;
                Navigator.of(context).pop((true, v));
              },
            ),
            if (widget.own != null) ...[
              const SizedBox(height: 10),
              BigButton(
                label: 'Как в настройках сети',
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
      setState(() => _error = 'Сумма — больше нуля и не больше долга ${money(widget.debt)}');
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'Напишите причину — её увидит владелец в истории');
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
      messenger.showSnackBar(const SnackBar(content: Text('Долг списан')));
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
            const Text('Списать долг', style: AppText.h3),
            Text('Деньги не поступят — долг просто уменьшится. Долг ${money(widget.debt)}', style: AppText.small),
            const SizedBox(height: 14),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
              style: AppText.h2,
              decoration: const InputDecoration(labelText: 'Сумма', suffixText: 'сум'),
            ),
            const SizedBox(height: 10),
            TextField(controller: _reason, decoration: const InputDecoration(hintText: 'Причина: уехал, ошибка кассира, подарок…')),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 16),
            BigButton(label: 'Списать', busy: _busy, onPressed: _submit),
          ]),
        ),
      );
}
