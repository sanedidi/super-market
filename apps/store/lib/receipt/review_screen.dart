import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'done_screen.dart';
import 'line_sheet.dart';
import 'processing_screen.dart';
import 'receipt_logic.dart';
import 'supplier_sheet.dart';

/// П3 · Проверка прихода: поставщик, итог, строки → «Провести».
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.id});

  final String id;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Map<String, dynamic>? _s;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Api>().get('/store/invoice-scans/${widget.id}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _s = s;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic> get _counts => (_s?['counts'] as Map<String, dynamic>?) ?? const {};
  int _count(String k) => (_counts[k] as num?)?.toInt() ?? 0;
  bool get _editable => _s?['status'] == 'ready';

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/invoice-scans/${widget.id}/retry');
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ProcessingScreen(id: widget.id)));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _supplier() async {
    if (!_editable) return;
    final s = await pickSupplier(context, widget.id, _s!);
    if (s != null && mounted) setState(() => _s = s);
  }

  Future<void> _line(Map<String, dynamic> l) async {
    if (!_editable) return;
    final s = await editLine(context, widget.id, _s!, l);
    if (s != null && mounted) setState(() => _s = s);
  }

  Future<void> _post({required bool post}) async {
    setState(() => _busy = true);
    try {
      final s = await context.read<Api>().post('/store/invoice-scans/${widget.id}/document', {'post': post}) as Map<String, dynamic>;
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => DoneScreen(scan: s)));
    } on ApiError catch (e) {
      if (!mounted) return;
      showMessage(context, e.message);
      _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(s == null ? 'Накладная' : ((s['invoice_number'] as String?)?.isNotEmpty == true ? 'Накладная № ${s['invoice_number']}' : 'Накладная')),
        actions: [
          if (_editable)
            PopupMenuButton<String>(
              onSelected: (_) => _post(post: false),
              itemBuilder: (_) => const [PopupMenuItem(value: 'draft', child: Text('Сохранить как черновик прихода'))],
            ),
        ],
      ),
      body: _error != null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: _error.toString(), action: 'Повторить', onAction: _load)
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(onRefresh: _load, child: _body(s)),
      bottomNavigationBar: s == null || !_editable ? null : _bottom(s),
    );
  }

  Widget _body(Map<String, dynamic> s) {
    final status = s['status'];
    if (status == 'processing') {
      return ListView(children: [
        EmptyState(
          icon: Icons.hourglass_top_rounded,
          title: 'Накладная ещё распознаётся',
          action: 'Ждать',
          onAction: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ProcessingScreen(id: widget.id))),
        ),
      ]);
    }
    if (status == 'failed') {
      return ListView(children: [
        EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Не удалось распознать',
          text: '${s['error'] ?? ''}',
          action: _busy ? null : 'Распознать заново',
          onAction: _retry,
        ),
      ]);
    }
    final lines = ((s['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final date = s['invoice_date'] as String?;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      if (date != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('от ${date.split('-').reversed.join('.')} · распознано ИИ', style: AppText.small)),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: _supplier,
            child: Row(children: [
              const IconBox(Icons.local_shipping_rounded, size: 40, iconSize: 22, radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    (s['counterparty_name'] as String?) ?? ((s['supplier_name'] as String?)?.isNotEmpty == true ? '${s['supplier_name']}' : 'Поставщик не распознан'),
                    style: AppText.bodyStrong,
                  ),
                  Text(
                    s['counterparty_id'] != null
                        ? 'найден в поставщиках${(s['supplier_inn'] as String?)?.isNotEmpty == true ? ' · ИНН ${s['supplier_inn']}' : ''}'
                        : 'нет в поставщиках — нажмите, чтобы выбрать',
                    style: AppText.small.copyWith(color: s['counterparty_id'] == null ? AppColors.primary : AppColors.text2),
                  ),
                ]),
              ),
              if (_editable) const Icon(Icons.edit_rounded, size: 20, color: AppColors.muted),
            ]),
          ),
          if (s['total_matches'] != null) ...[
            const SizedBox(height: 12),
            _TotalBanner(ok: s['total_matches'] == true, invoice: s['invoice_total'], lines: s['lines_total']),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            StatusChip('${_count('ok')} готово', icon: Icons.check_circle_rounded, tone: ChipTone.green),
            if (_count('check') > 0) StatusChip('${_count('check')} проверить', icon: Icons.error_rounded, tone: ChipTone.amber),
            if (_count('missing') > 0) StatusChip('${_count('missing')} не найдено', icon: Icons.help_rounded, tone: ChipTone.red),
            if (_count('skipped') > 0) StatusChip('${_count('skipped')} пропущено', tone: ChipTone.gray),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      AppCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [for (final l in lines) _LineRow(line: l, onTap: _editable ? () => _line(l) : null)]),
      ),
    ]);
  }

  Widget _bottom(Map<String, dynamic> s) {
    final missing = _count('missing');
    final noSupplier = s['counterparty_id'] == null;
    final lines = ((s['lines'] as List?) ?? const []).where((l) => (l as Map)['skipped'] != true).length;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(color: AppColors.white, boxShadow: [BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, -4))]),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Text('Позиций: $lines', style: AppText.small),
          const Spacer(),
          Text(money(s['lines_total']), style: AppText.h3),
        ]),
        const SizedBox(height: 10),
        BigButton(
          label: 'Провести',
          icon: Icons.done_all_rounded,
          busy: _busy,
          onPressed: missing > 0 || noSupplier ? null : () => _post(post: true),
        ),
        if (missing > 0 || noSupplier) ...[
          const SizedBox(height: 6),
          Text(noSupplier ? 'Выберите поставщика' : 'Сопоставьте или пропустите строки без товара', style: AppText.small),
        ],
      ]),
    );
  }
}

class _TotalBanner extends StatelessWidget {
  const _TotalBanner({required this.ok, required this.invoice, required this.lines});

  final bool ok;
  final Object? invoice;
  final Object? lines;

  @override
  Widget build(BuildContext context) {
    final fg = ok ? AppColors.successInk : AppColors.warningInk;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: ok ? AppColors.successSoft : AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(ok ? Icons.verified_rounded : Icons.warning_amber_rounded, color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ok ? 'Итог совпадает: ${money(invoice)}' : 'Итог не совпадает', style: AppText.bodyStrong.copyWith(color: fg)),
            Text(ok ? 'сумма строк = «Итого» в накладной' : 'в накладной ${money(invoice)}, по строкам ${money(lines)} — проверьте строки',
                style: AppText.small.copyWith(color: fg)),
          ]),
        ),
      ]),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.onTap});

  final Map<String, dynamic> line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final state = line['state'] as String? ?? 'missing';
    final (icon, color) = switch (state) {
      'ok' => (Icons.check_circle_rounded, AppColors.success),
      'check' => (Icons.error_rounded, AppColors.warningInk),
      'skipped' => (Icons.remove_circle_outline_rounded, AppColors.muted),
      _ => (Icons.help_rounded, AppColors.primary),
    };
    final change = (line['price_change'] as num?)?.toInt();
    final productName = line['product_name'] as String?;
    var sub = lineQty(line);
    if (change != null && change != 0) sub += ' · ${change > 0 ? 'дороже' : 'дешевле'} прошлого на ${change.abs()}%';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: color, size: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                state == 'skipped' ? 'Пропущена' : (productName ?? 'Не найден в каталоге'),
                style: AppText.bodyStrong.copyWith(color: state == 'missing' ? AppColors.primary : (state == 'skipped' ? AppColors.muted : AppColors.ink)),
              ),
              Text('«${line['name']}»', style: AppText.small.copyWith(color: AppColors.muted, fontSize: 12)),
              Text(sub, style: AppText.small.copyWith(fontSize: 12, color: change != null && change.abs() > 5 ? AppColors.warningInk : AppColors.text2)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(money(line['sum'], suffix: false), style: AppText.bodyStrong.copyWith(color: state == 'skipped' ? AppColors.muted : AppColors.ink)),
            if (state == 'missing' || state == 'check')
              Text(state == 'missing' ? 'Выбрать' : 'Проверить', style: AppText.caption.copyWith(color: color)),
          ]),
        ]),
      ),
    );
  }
}
