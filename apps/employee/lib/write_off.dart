import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/lock/app_lock.dart';
import 'package:sm_store/start/scanner.dart' show withScannersPaused;
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'scanner.dart';
import 'ui.dart';

/// «Списание» с главной: сначала скан товара, потом С11.
Future<void> openWriteOff(BuildContext context) async {
  // Экран списания заменяет сканер; ждём, пока закроют и его.
  Future<void>? next;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => CodeScanner(
      title: tr('Списание · наведите на штрихкод', 'Hisobdan chiqarish · shtrix-kodga qarating'),
      onCode: (ctx, code) async {
        final g = await fetchGlance(ctx, code: code);
        if (g == null || !ctx.mounted || next != null) return;
        next = Navigator.of(ctx).pushReplacement(MaterialPageRoute<void>(builder: (_) => WriteOffScreen(product: g)));
      },
    ),
  ));
  if (next != null) await next;
}

/// С11 · Списание — причина и фото обязательны. Проводится сразу: остаток
/// уменьшается, владелец видит списание с фото в журнале.
class WriteOffScreen extends StatefulWidget {
  const WriteOffScreen({super.key, required this.product});

  /// Товар из сканера (GET /store/staff/glance).
  final Map<String, dynamic> product;

  @override
  State<WriteOffScreen> createState() => _WriteOffScreenState();
}

class _WriteOffScreenState extends State<WriteOffScreen> {
  late num _qty = widget.product['weight'] != null ? n(widget.product['weight']) : 1;
  String? _reason;
  final _photos = <Uint8List>[];
  final _comment = TextEditingController();
  final _picker = ImagePicker();
  bool _busy = false;

  Map<String, dynamic> get g => widget.product;
  bool get _fractional => g['is_fractional'] == true;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _photo() async {
    final lock = context.read<AppLock>();
    try {
      final x = await lock.hold(() => withScannersPaused(() => _picker.pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600, imageQuality: 80)));
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _photos.add(bytes));
    } catch (e) {
      if (mounted) toast(context, e);
    }
  }

  Future<void> _typeQty() async {
    final v = await askQty(context, title: tr('Сколько списать', 'Qancha chiqarish'), initial: _qty, fractional: _fractional);
    if (v != null && v > 0 && mounted) setState(() => _qty = v);
  }

  bool get _ready => _qty > 0 && _reason != null && _photos.isNotEmpty && (_reason != 'other' || _comment.text.trim().isNotEmpty);

  Future<void> _submit() async {
    final api = context.read<Api>();
    final store = context.read<StoreState>().storeId;
    setState(() => _busy = true);
    try {
      final urls = <String>[];
      for (var i = 0; i < _photos.length; i++) {
        final res = await api.upload('/store/uploads', _photos[i], 'write_off_${i + 1}.jpg') as Map<String, dynamic>;
        urls.add('${res['url']}');
      }
      await api.post('/store/staff/write-off', {
        'store_id': store,
        'product_id': g['product_id'],
        'qty': qtyBody(_qty, _fractional),
        'reason': _reason,
        'photos': urls,
        'comment': _comment.text.trim(),
      });
      if (!mounted) return;
      toast(context, tr('Списано: ${qty(_qty, '${g['unit_short'] ?? ''}')} · ${g['name']}', 'Hisobdan chiqarildi: ${qty(_qty, '${g['unit_short'] ?? ''}')} · ${g['name']}'));
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'insufficient_stock') {
        await infoSheet(context,
            icon: Icons.inventory_2_outlined,
            title: tr('В системе меньше', 'Tizimda kamroq'),
            text: tr('По учёту этого товара меньше, чем вы списываете. Сначала пересчитайте его на полке.',
                'Hisob boʻyicha bu mahsulot siz chiqarayotgandan kam. Avval uni javonda qayta sanang.'));
      } else {
        toast(context, e);
      }
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unit = '${g['unit_short'] ?? ''}';
    return Scaffold(
      appBar: AppBar(title: Text(tr('Списание', 'Hisobdan chiqarish'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
        AppCard(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            ProductThumb(image: g['image'] as String?, size: 52, fractional: _fractional),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${g['name']}', style: AppText.bodyStrong),
                Text(g['uncounted'] == true ? tr('Остаток не посчитан', 'Qoldiq sanalmagan') : tr('Остаток ${qty(g['qty'], unit)}', 'Qoldiq ${qty(g['qty'], unit)}'), style: AppText.small),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Text(tr('Сколько списать', 'Qancha chiqarish'), style: AppText.caption),
        const SizedBox(height: 6),
        QtyStepper(value: _qty, min: _fractional ? 0.001 : 1, fractional: _fractional, unit: unit, onChanged: (v) => setState(() => _qty = v), onTapValue: _typeQty),
        const SizedBox(height: 16),
        Text(tr('Причина *', 'Sabab *'), style: AppText.caption),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final r in writeOffReasons)
            ChoiceChip(
              label: Text(writeOffReasonTitle(r)),
              selected: _reason == r,
              showCheckmark: false,
              selectedColor: AppColors.primary,
              backgroundColor: AppColors.soft,
              side: BorderSide.none,
              labelStyle: AppText.bodyStrong.copyWith(fontSize: 14, color: _reason == r ? AppColors.white : AppColors.ink),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onSelected: (_) => setState(() => _reason = r),
            ),
        ]),
        const SizedBox(height: 16),
        Text(tr('Фото *', 'Rasm *'), style: AppText.caption),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < _photos.length; i++)
            Stack(children: [
              ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.memory(_photos[i], width: 84, height: 84, fit: BoxFit.cover)),
              Positioned(
                right: 2,
                top: 2,
                child: InkWell(
                  onTap: () => setState(() => _photos.removeAt(i)),
                  child: Container(
                    decoration: const BoxDecoration(color: AppColors.white, shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded, size: 18),
                  ),
                ),
              ),
            ]),
          if (_photos.length < 3)
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _photo,
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.add_a_photo_rounded, color: AppColors.text2),
                  Text(_photos.isEmpty ? tr('Снять', 'Suratga olish') : tr('Ещё', 'Yana'), style: AppText.caption),
                ]),
              ),
            ),
        ]),
        const SizedBox(height: 16),
        Text(_reason == 'other' ? tr('Что случилось *', 'Nima boʻldi *') : tr('Комментарий (необязательно)', 'Izoh (ixtiyoriy)'), style: AppText.caption),
        const SizedBox(height: 6),
        TextField(
          controller: _comment,
          maxLines: 2,
          maxLength: 300,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(hintText: tr('например, упаковка порвана', 'masalan, qadoq yirtilgan')),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BigButton(label: tr('Списать', 'Hisobdan chiqarish'), icon: Icons.delete_sweep_rounded, busy: _busy, onPressed: _ready ? _submit : null),
            const SizedBox(height: 6),
            Text(tr('Спишется сразу, владелец увидит в журнале', 'Darhol chiqariladi, egasi jurnalda koʻradi'), style: AppText.small),
          ]),
        ),
      ),
    );
  }
}
