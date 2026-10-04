import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../receipt/receipt_logic.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'camera_screen.dart';
import 'new_product_screen.dart';
import 'review_screen.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// Н4 · Super Market нашёл товары на фото: проверить, выбрать похожий или
/// создать новый, поправить штуки → в список. Цены — на следующем шаге.
class PhotoResultsScreen extends StatefulWidget {
  const PhotoResultsScreen({super.key, required this.start, required this.id});

  final StartApi start;
  final String id;

  @override
  State<PhotoResultsScreen> createState() => _PhotoResultsScreenState();
}

class _PhotoResultsScreenState extends State<PhotoResultsScreen> {
  Map<String, dynamic>? _ph;
  Object? _error;
  Timer? _poll;
  bool _busy = false;
  bool _inited = false;
  final _choice = <int, String?>{};
  final _qty = <int, num>{};
  final _refs = <int, ProductRef>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  List<Map<String, dynamic>> get _items => ((_ph?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();

  Future<void> _load() async {
    _poll?.cancel();
    try {
      final ph = await widget.start.photo(widget.id);
      if (!mounted) return;
      setState(() {
        _ph = ph;
        _error = null;
      });
      if (ph['status'] == 'processing') {
        _poll = Timer(const Duration(milliseconds: 1500), _load);
      } else if (ph['status'] == 'ready' && !_inited) {
        _inited = true;
        setState(() {
          for (final it in _items) {
            final n = (it['n'] as num).toInt();
            final p = it['product'] as Map<String, dynamic>?;
            if (it['state'] == 'found' && p != null) {
              _choice[n] = p['product_id'] as String;
              _refs[n] = ProductRef.fromItem(p);
            }
            _qty[n] = num.tryParse('${it['qty']}') ?? 1;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await widget.start.retryPhoto(widget.id);
      _inited = false;
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<ProductRef> _candidates(Map<String, dynamic> it) {
    final out = <ProductRef>[];
    final seen = <String>{};
    final p = it['product'] as Map<String, dynamic>?;
    for (final c in [if (p != null) p, ...((it['candidates'] as List?) ?? const []).cast<Map<String, dynamic>>()]) {
      if (seen.add('${c['product_id']}')) out.add(ProductRef.fromItem(c));
    }
    return out;
  }

  Future<void> _pick(Map<String, dynamic> it) async {
    final n = (it['n'] as num).toInt();
    final r = await pickProductSheet(
      context,
      widget.start,
      info: 'На фото: ${it['name']}',
      candidates: _candidates(it),
      query: _candidates(it).isEmpty ? '${it['name']}' : '',
      current: _choice[n],
    );
    if (!mounted || r == null) return;
    if (r.create) {
      final p = await Navigator.of(context).push<ProductRef>(MaterialPageRoute(
        builder: (_) => NewProductScreen(
          start: widget.start,
          name: '${it['name']}',
          barcode: (it['barcode'] as String?)?.isEmpty == true ? null : it['barcode'] as String?,
          brandId: it['brand_id'] as String?,
          categoryId: it['category_id'] as String?,
          fromPhoto: true,
          withLine: false,
        ),
      ));
      if (p != null && mounted) {
        setState(() {
          _choice[n] = p.id;
          _refs[n] = p;
        });
      }
    } else if (r.product != null) {
      setState(() {
        _choice[n] = r.product!.id;
        _refs[n] = r.product!;
      });
    }
  }

  Future<void> _editQty(Map<String, dynamic> it) async {
    final n = (it['n'] as num).toInt();
    final v = await promptSheet(context,
        title: 'Сколько штук?',
        text: '${it['name']} · 0 — не добавлять',
        confirm: 'Готово',
        hint: plainQty(_qty[n]),
        keyboardType: const TextInputType.numberWithOptions(decimal: true));
    final q = num.tryParse(parseNum(v ?? '') ?? '');
    if (q != null && mounted) setState(() => _qty[n] = q);
  }

  /// Выбранное — в список (штуки прибавляются к уже добавленным).
  Future<bool> _addChosen() async {
    final lines = photoLines(_items.map((it) {
      final n = (it['n'] as num).toInt();
      return PhotoPick(_choice[n], _qty[n] ?? 0);
    }));
    if (lines.isEmpty) return true;
    setState(() => _busy = true);
    try {
      await widget.start.setLines(lines);
      return true;
    } catch (e) {
      if (mounted) showMessage(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _more() async {
    if (!await _addChosen() || !mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => StartCameraScreen(start: widget.start)),
    );
  }

  Future<void> _next() async {
    if (!await _addChosen() || !mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => StartReviewScreen(start: widget.start)));
  }

  @override
  Widget build(BuildContext context) {
    final ph = _ph;
    final status = ph?['status'];
    final chosen = _items.where((it) => _choice[(it['n'] as num).toInt()] != null).length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(status == 'ready' ? 'Super Market нашёл ${goods(_items.length)}' : 'Фото полок'),
      ),
      body: _error != null && ph == null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: _error.toString(), action: 'Повторить', onAction: _load)
          : ph == null || status == 'processing'
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 20),
                      Text('Super Market ищет товары на фото…', style: AppText.title, textAlign: TextAlign.center),
                      SizedBox(height: 6),
                      Text('Обычно это 10–30 секунд. Можно не ждать — фото сохранено.', style: AppText.small, textAlign: TextAlign.center),
                    ]),
                  ),
                )
              : status == 'failed'
                  ? EmptyState(
                      icon: Icons.image_not_supported_outlined,
                      title: 'Не удалось найти товары',
                      text: '${ph['error']}',
                      action: 'Повторить',
                      onAction: _busy ? null : _retry,
                    )
                  : _list(ph),
      bottomNavigationBar: status != 'ready'
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Количество Super Market посчитал по фото — проверьте. Цены укажете на следующем шаге',
                      style: AppText.small, textAlign: TextAlign.center),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: SmallButton(label: 'Ещё фото', icon: Icons.photo_camera_rounded, onPressed: _busy ? null : _more)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SmallButton(
                        label: chosen == 0 ? 'Дальше' : 'Дальше: цены',
                        icon: Icons.arrow_forward_rounded,
                        primary: true,
                        onPressed: _busy ? null : _next,
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
    );
  }

  Widget _list(Map<String, dynamic> ph) {
    final counts = (ph['counts'] as Map<String, dynamic>?) ?? const {};
    int c(String k) => (counts[k] as num?)?.toInt() ?? 0;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        StatusChip('${c('found')} найдено', tone: ChipTone.green),
        if (c('choose') > 0) StatusChip('${c('choose')} выбрать', tone: ChipTone.amber),
        if (c('missing') > 0) StatusChip('${c('missing')} нет в каталоге', tone: ChipTone.red),
      ]),
      const SizedBox(height: 12),
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(children: [for (final it in _items) _row(it)]),
      ),
    ]);
  }

  Widget _row(Map<String, dynamic> it) {
    final n = (it['n'] as num).toInt();
    final ref = _choice[n] != null ? _refs[n] : null;
    final state = it['state'] as String?;
    final qty = _qty[n] ?? 0;
    final Widget icon;
    final String sub;
    Color? subColor;
    Widget trailing;
    if (ref != null) {
      icon = const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 22);
      sub = [
        if (ref.score != null && ref.score! > 0 && ref.score! < 100) 'совпадение ${ref.score}%',
        if (ref.score == 100) 'по штрихкоду',
        'на фото ${plainQty(it['qty'])} шт',
      ].join(' · ');
      trailing = InkWell(
        onTap: () => _editQty(it),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(qty <= 0 ? 'не добавлять' : '${plainQty(qty)} ${ref.unit}', style: AppText.bodyStrong.copyWith(color: qty <= 0 ? AppColors.muted : null)),
        ),
      );
    } else if (state == 'missing') {
      icon = const Icon(Icons.error_rounded, color: AppColors.error, size: 22);
      sub = '«${it['name']}» — на фото';
      subColor = AppColors.error;
      trailing = Text('Новый', style: AppText.bodyStrong.copyWith(color: AppColors.primary));
    } else {
      final k = ((it['candidates'] as List?) ?? const []).length;
      icon = const Icon(Icons.help_rounded, color: Color(0xFFF79009), size: 22);
      sub = k > 0 ? '$k ${plural(k, 'похожий товар', 'похожих товара', 'похожих товаров')} — какой?' : 'выберите товар';
      subColor = AppColors.warningInk;
      trailing = Text('Выбрать', style: AppText.bodyStrong.copyWith(color: AppColors.primary));
    }
    return InkWell(
      onTap: () => _pick(it),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          icon,
          const SizedBox(width: 10),
          Thumb(ref?.image, size: 44),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ref != null ? ref.name : (state == 'missing' ? 'Не найден в каталоге' : '${it['name']}'),
                  style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(sub, style: AppText.small.copyWith(color: subColor), maxLines: 1, overflow: TextOverflow.ellipsis),
              if (it['in_draft'] == true) const Text('уже в списке — штуки прибавятся', style: AppText.small),
            ]),
          ),
          const SizedBox(width: 8),
          trailing,
        ]),
      ),
    );
  }
}
