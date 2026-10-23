import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../start/stock_count.dart' show askShelfCounts, receivedOf;
import '../state.dart';
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

  /// Н1 · «Новый по фото» прямо из строки.
  Future<void> _photo(Map<String, dynamic> l) async {
    if (!_editable) return;
    final s = await findForLine(context, widget.id, _s!, l);
    if (s != null && mounted) setState(() => _s = s);
  }

  /// Н1 · Быстрый ответ «12 штук» / «12 блоков по 6».
  Future<void> _answerPack(Map<String, dynamic> l, num pack) async {
    if (!_editable) return;
    setState(() => _busy = true);
    try {
      final s = await context.read<Api>().put('/store/invoice-scans/${widget.id}/lines/${l['line']}', {
        'pack': '$pack',
        'remember': _s!['counterparty_id'] != null,
      }) as Map<String, dynamic>;
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _post({required bool post}) async {
    setState(() => _busy = true);
    try {
      final s = await context.read<Api>().post('/store/invoice-scans/${widget.id}/document', {'post': post}) as Map<String, dynamic>;
      if (!mounted) return;
      // Н6 · приход проведён: у непосчитанных товаров спросить «Сколько на полке?».
      final storeId = context.read<StoreState>().storeId;
      if (post && s['document_status'] == 'posted' && storeId != null) {
        await askShelfCounts(context, storeId, receivedOf((s['lines'] as List?) ?? const []));
        if (!mounted) return;
      }
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
        title: Text(s == null
            ? tr('Накладная', 'Yuk xati')
            : ((s['invoice_number'] as String?)?.isNotEmpty == true ? '${tr('Накладная', 'Yuk xati')} № ${s['invoice_number']}' : tr('Накладная', 'Yuk xati'))),
        actions: [
          if (_editable)
            PopupMenuButton<String>(
              onSelected: (_) => _post(post: false),
              itemBuilder: (_) => [PopupMenuItem(value: 'draft', child: Text(tr('Сохранить как черновик прихода', 'Kirim qoralamasi sifatida saqlash')))],
            ),
        ],
      ),
      body: _error != null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: _error.toString(), action: tr('Повторить', 'Qayta urinish'), onAction: _load)
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
          title: tr('Накладная ещё распознаётся', 'Yuk xati hali tanib olinmoqda'),
          action: tr('Ждать', 'Kutish'),
          onAction: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ProcessingScreen(id: widget.id))),
        ),
      ]);
    }
    if (status == 'failed') {
      return ListView(children: [
        EmptyState(
          icon: Icons.error_outline_rounded,
          title: tr('Не удалось распознать', 'Tanib olib boʻlmadi'),
          text: '${s['error'] ?? ''}',
          action: _busy ? null : tr('Распознать заново', 'Qayta tanib olish'),
          onAction: _retry,
        ),
      ]);
    }
    final lines = ((s['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final date = s['invoice_date'] as String?;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      if (date != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(
                  tr('от ${date.split('-').reversed.join('.')} · распознано ИИ', '${date.split('-').reversed.join('.')} sanali · sunʼiy intellekt tanib oldi'),
                  style: AppText.small)),
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
                    (s['counterparty_name'] as String?) ??
                        ((s['supplier_name'] as String?)?.isNotEmpty == true ? '${s['supplier_name']}' : tr('Поставщик не распознан', 'Yetkazib beruvchi aniqlanmadi')),
                    style: AppText.bodyStrong,
                  ),
                  Text(
                    s['counterparty_id'] != null
                        ? '${tr('найден в поставщиках', 'yetkazib beruvchilarda topildi')}${(s['supplier_inn'] as String?)?.isNotEmpty == true ? ' · ${tr('ИНН', 'STIR')} ${s['supplier_inn']}' : ''}'
                        : tr('нет в поставщиках — нажмите, чтобы выбрать', 'yetkazib beruvchilarda yoʻq — tanlash uchun bosing'),
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
            StatusChip('${_count('ok')} ${tr('готово', 'tayyor')}', icon: Icons.check_circle_rounded, tone: ChipTone.green),
            if (_count('check') > 0) StatusChip('${_count('check')} ${tr('проверить', 'tekshirish kerak')}', icon: Icons.error_rounded, tone: ChipTone.amber),
            if (_count('pack') > 0) StatusChip('${_count('pack')} ${tr('блоки или штуки?', 'blokmi yoki donami?')}', icon: Icons.help_rounded, tone: ChipTone.amber),
            if (_count('missing') > 0) StatusChip('${_count('missing')} ${tr('не найдено', 'topilmadi')}', icon: Icons.help_rounded, tone: ChipTone.red),
            if (_count('skipped') > 0) StatusChip('${_count('skipped')} ${tr('пропущено', 'oʻtkazib yuborildi')}', tone: ChipTone.gray),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      AppCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          for (final l in lines)
            _LineRow(
              line: l,
              onTap: _editable ? () => _line(l) : null,
              onPhoto: _editable && !_busy ? () => _photo(l) : null,
              onPack: _editable && !_busy ? (n) => _answerPack(l, n) : null,
            ),
        ]),
      ),
    ]);
  }

  Widget _bottom(Map<String, dynamic> s) {
    final missing = _count('missing') + _count('pack');
    final noSupplier = s['counterparty_id'] == null;
    final lines = ((s['lines'] as List?) ?? const []).where((l) => (l as Map)['skipped'] != true).length;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(color: AppColors.white, boxShadow: [BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, -4))]),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Text('${tr('Позиций', 'Pozitsiyalar')}: $lines', style: AppText.small),
          const Spacer(),
          Text(money(s['lines_total']), style: AppText.h3),
        ]),
        const SizedBox(height: 10),
        BigButton(
          label: tr('Провести', 'Oʻtkazish'),
          icon: Icons.done_all_rounded,
          busy: _busy,
          onPressed: missing > 0 || noSupplier ? null : () => _post(post: true),
        ),
        if (missing > 0 || noSupplier) ...[
          const SizedBox(height: 6),
          Text(
              noSupplier
                  ? tr('Выберите поставщика', 'Yetkazib beruvchini tanlang')
                  : _count('missing') > 0
                      ? tr('Сопоставьте или пропустите строки без товара', 'Mahsulotsiz qatorlarni moslang yoki oʻtkazib yuboring')
                      : tr('Ответьте в строках: блоки или штуки?', 'Qatorlarda javob bering: bloklarmi yoki donami?'),
              style: AppText.small),
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
            Text(ok ? tr('Итог совпадает: ${money(invoice)}', 'Jami mos keladi: ${money(invoice)}') : tr('Итог не совпадает', 'Jami mos kelmaydi'),
                style: AppText.bodyStrong.copyWith(color: fg)),
            Text(
                ok
                    ? tr('сумма строк = «Итого» в накладной', 'qatorlar summasi = yuk xatidagi «Jami»')
                    : tr('в накладной ${money(invoice)}, по строкам ${money(lines)} — проверьте строки',
                        'yuk xatida ${money(invoice)}, qatorlar boʻyicha ${money(lines)} — qatorlarni tekshiring'),
                style: AppText.small.copyWith(color: fg)),
          ]),
        ),
      ]),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.onTap, this.onPhoto, this.onPack});

  final Map<String, dynamic> line;
  final VoidCallback? onTap;

  /// Товар не найден — «Новый по фото».
  final VoidCallback? onPhoto;

  /// «Блоки или штуки?» — быстрый ответ: 1 (штуки) или N в блоке.
  final ValueChanged<num>? onPack;

  @override
  Widget build(BuildContext context) {
    final state = line['state'] as String? ?? 'missing';
    final (icon, color) = switch (state) {
      'ok' => (Icons.check_circle_rounded, AppColors.success),
      'check' || 'pack' => (state == 'pack' ? Icons.help_rounded : Icons.error_rounded, AppColors.warningInk),
      'skipped' => (Icons.remove_circle_outline_rounded, AppColors.muted),
      _ => (Icons.help_rounded, AppColors.primary),
    };
    final change = (line['price_change'] as num?)?.toInt();
    final productName = line['product_name'] as String?;
    final qty = numText(line['qty']);
    final pack = num.tryParse('${line['pack'] ?? ''}') ?? 1;
    var sub = state == 'pack'
        ? tr('$qty × ${numText(line['price'])} — $qty блоков или $qty штук?', '$qty × ${numText(line['price'])} — $qty blokmi yoki $qty donami?')
        : lineQty(line);
    if (change != null && change != 0 && state != 'pack') {
      sub += tr(' · ${change > 0 ? 'дороже' : 'дешевле'} прошлого на ${change.abs()}%', ' · oldingisidan ${change.abs()}% ${change > 0 ? 'qimmat' : 'arzon'}');
    }
    final note = state == 'skipped' ? null : packNote(line);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: color, size: 22)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  state == 'skipped' ? tr('Пропущена', 'Oʻtkazib yuborilgan') : (productName ?? tr('Не найден в каталоге', 'Katalogda topilmadi')),
                  style: AppText.bodyStrong.copyWith(color: state == 'missing' ? AppColors.primary : (state == 'skipped' ? AppColors.muted : AppColors.ink)),
                ),
                Text('«${line['name']}»', style: AppText.small.copyWith(color: AppColors.muted, fontSize: 12)),
                Text(sub,
                    style: AppText.small.copyWith(
                        fontSize: 12, color: state == 'pack' || (change != null && change.abs() > 5) ? AppColors.warningInk : AppColors.text2)),
                if (note != null) ...[
                  const SizedBox(height: 4),
                  StatusChip(note, icon: Icons.auto_fix_high_rounded),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money(line['sum'], suffix: false), style: AppText.bodyStrong.copyWith(color: state == 'skipped' ? AppColors.muted : AppColors.ink)),
              if (state == 'check') Text(tr('Проверить', 'Tekshirish'), style: AppText.caption.copyWith(color: color)),
            ]),
          ]),
          if (state == 'missing' && onTap != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: SmallButton(label: tr('Выбрать', 'Tanlash'), icon: Icons.search_rounded, onPressed: onTap)),
              const SizedBox(width: 8),
              Expanded(child: SmallButton(label: tr('Новый по фото', 'Yangi rasm bilan'), icon: Icons.photo_camera_rounded, primary: true, onPressed: onPhoto)),
            ]),
          ],
          if (state == 'pack' && onTap != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: SmallButton(label: tr('$qty штук', '$qty dona'), icon: Icons.looks_one_rounded, onPressed: onPack == null ? null : () => onPack!(1))),
              const SizedBox(width: 8),
              Expanded(
                child: SmallButton(
                  label: pack > 1 ? tr('$qty блоков по ${numText(pack)}', '$qty blok ${numText(pack)} tadan') : tr('$qty блоков…', '$qty blok…'),
                  icon: Icons.inventory_2_rounded,
                  primary: true,
                  // Сколько в блоке не знаем — шторка строки (Н4).
                  onPressed: pack > 1 ? (onPack == null ? null : () => onPack!(pack)) : onTap,
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
