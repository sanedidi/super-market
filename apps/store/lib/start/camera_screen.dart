import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'new_items.dart';
import 'scanner.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';
import 'tasnif.dart';

/// Н3 · Камера «Начала работы»: сканер штрихкодов подряд — найденный товар
/// сразу встаёт в «Мои товары», повтор не добавляется.
class StartCameraScreen extends StatefulWidget {
  const StartCameraScreen({super.key, required this.start, this.inventory = false});

  final StartApi start;

  /// Шаг 2: найденный штрихкод открывает не «Добавить», а шторку количества и цен.
  final bool inventory;

  @override
  State<StartCameraScreen> createState() => _StartCameraScreenState();
}

class _StartCameraScreenState extends State<StartCameraScreen> {
  late final MobileScannerController _scanner = _newScanner();
  bool _torch = false;
  bool _handling = false;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);
  int _added = 0;

  @override
  void dispose() {
    disposeScanner(_scanner);
    super.dispose();
  }

  // Камера для штрихкодов — см. scanner.dart (на iPhone сама включает макро вблизи).
  MobileScannerController _newScanner() => barcodeScanner(
        formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE, BarcodeFormat.code128, BarcodeFormat.code39],
      );

  void _onDetect(BarcodeCapture capture) {
    if (_handling || capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    // Тот же штрихкод сразу после шторки — не открываем снова.
    if (code == _lastCode && DateTime.now().difference(_lastAt) < const Duration(seconds: 2)) return;
    _handle(code);
  }

  Future<void> _manual() async {
    final code = await promptSheet(context,
        title: tr('Штрихкод', 'Shtrix-kod'), text: tr('Введите цифры под штрихкодом', 'Shtrix-kod ostidagi raqamlarni kiriting'), confirm: tr('Найти', 'Topish'), hint: '4780012345678', keyboardType: TextInputType.number);
    if (code != null && code.trim().isNotEmpty) await _handle(code.trim());
  }

  Future<void> _handle(String code) async {
    _handling = true;
    var added = false;
    // Пока открыты шторки и экраны после скана, камера сканера выключена.
    await whileScannerIdle(_scanner, () async {
      try {
        if (widget.inventory) {
          added = await _count(code);
          return;
        }
        final p = await widget.start.byBarcode(code);
        if (!mounted) return;
        if (p != null) {
          added = await addToMyGoods(context, widget.start, p, source: 'barcode', listButton: false) == AddResult.added;
        } else {
          // Штрихкод уже в «Новых» — вторую карточку не заводим (Д1).
          final queued = await widget.start.newItemByBarcode(code);
          if (!mounted) return;
          if (queued != null) {
            await showQueuedSheet(context, widget.start, queued);
            return;
          }
          // Нет в центральной базе — сначала каталог ИКПУ (tasnif.soliq.uz).
          final t = await tasnifBarcodeSheet(context, widget.start, code);
          if (!mounted || t == null) return;
          if (t) {
            added = true;
            return;
          }
          final r = await pickProductSheet(context, widget.start, info: tr('Штрихкод $code — нет в центральной базе', 'Shtrix-kod $code — markaziy bazada yoʻq'), code: code);
          if (!mounted || r == null) return;
          if (r.create) {
            // Фото нового товара → Super Market заполнит карточку в фоне; сканер работает дальше (Р2).
            await openNewItemCamera(context, widget.start, barcode: code);
          } else if (r.product != null) {
            added = await addToMyGoods(context, widget.start, r.product!, source: 'barcode', bind: r.bind ? code : null, listButton: false) == AddResult.added;
          }
        }
      } catch (e) {
        if (mounted) showMessage(context, e);
      } finally {
        _lastCode = code;
        _lastAt = DateTime.now();
        _handling = false;
        if (added && mounted) setState(() => _added++);
      }
    });
  }

  /// И2–И5 · Шаг «Инвентаризация»: штрихкод из «Моих товаров» — сразу шторка
  /// количества и цен поверх камеры; товар есть в базе, но не добавлен —
  /// «Добавить и заполнить»; нет нигде — как на шаге 1 (каталог ИКПУ, новый
  /// товар, привязка штрихкода). true — строка записана.
  Future<bool> _count(String code) async {
    final r = await widget.start.scan(code);
    if (!mounted) return false;
    final line = r['line'];
    if (line is Map) return countSheet(context, widget.start, line.cast<String, dynamic>());
    final product = r['product'];
    if (product is Map) {
      final p = ProductRef.fromItem(product.cast<String, dynamic>());
      final yes = await confirmSheet(context,
          title: tr('Товара нет в вашем списке', 'Mahsulot roʻyxatingizda yoʻq'),
          text: tr('«${p.name}» есть в центральной базе, но вы не добавляли его на шаге 1. Добавим в «Мои товары» и сразу откроем количество и цены.',
              '«${p.name}» markaziy bazada bor, lekin siz uni 1-qadamda qoʻshmagansiz. «Mahsulotlarim»ga qoʻshamiz va darhol miqdor va narxlarni ochamiz.'),
          confirm: tr('Добавить и заполнить', 'Qoʻshish va toʻldirish'),
          cancel: tr('Пропустить', 'Oʻtkazib yuborish'),
          icon: Icons.add_rounded);
      if (!yes || !mounted) return false;
      if (await addToMyGoods(context, widget.start, p, source: 'barcode', listButton: false) != AddResult.added || !mounted) return false;
      final again = await widget.start.scan(code);
      if (!mounted) return false;
      final l = again['line'];
      if (l is Map) return countSheet(context, widget.start, l.cast<String, dynamic>());
      return true;
    }
    // Нет ни в «Моих товарах», ни в центральной базе — дальше как на шаге 1.
    return _missing(code);
  }

  /// Штрихкода нет в центральной базе: карточка в «Новых», каталог ИКПУ,
  /// новый товар по фото или привязка кода к товару из базы.
  Future<bool> _missing(String code) async {
    final queued = await widget.start.newItemByBarcode(code);
    if (!mounted) return false;
    if (queued != null) {
      await showQueuedSheet(context, widget.start, queued);
      return false;
    }
    final t = await tasnifBarcodeSheet(context, widget.start, code);
    if (!mounted || t == null) return false;
    if (t) return true;
    final r = await pickProductSheet(context, widget.start, info: tr('Штрихкод $code — нет в центральной базе', 'Shtrix-kod $code — markaziy bazada yoʻq'), code: code);
    if (!mounted || r == null) return false;
    if (r.create) {
      await openNewItemCamera(context, widget.start, barcode: code);
      return false;
    }
    if (r.product != null) {
      return await addToMyGoods(context, widget.start, r.product!, source: 'barcode', bind: r.bind ? code : null, listButton: false) == AddResult.added;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: _barcodeBody(),
    );
  }

  Widget _top({Widget? right}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(children: [
          RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: () => Navigator.of(context).pop(_added > 0)),
          const Spacer(),
          if (right != null) right,
        ]),
      );

  Widget _barcodeBody() {
    final scanner = _scanner;
    return Stack(fit: StackFit.expand, children: [
      MobileScanner(key: ObjectKey(scanner), controller: scanner, onDetect: _onDetect),
      SafeArea(
        child: Column(children: [
          _top(
            right: RoundIcon(
              icon: _torch ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded,
              color: AppColors.white,
              tooltip: tr('Фонарик', 'Chiroq'),
              onTap: () {
                scanner.toggleTorch();
                setState(() => _torch = !_torch);
              },
            ),
          ),
          const Spacer(),
          Container(
            width: 260,
            height: 150,
            decoration: BoxDecoration(border: Border.all(color: AppColors.white, width: 2.5), borderRadius: BorderRadius.circular(18)),
            child: Center(child: Container(height: 2, margin: const EdgeInsets.symmetric(horizontal: 14), color: AppColors.primary)),
          ),
          const SizedBox(height: 14),
          Text(tr('Наведите на штрихкод', 'Shtrix-kodga qarating'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
          if (widget.inventory) ...[
            const SizedBox(height: 6),
            Text(tr('Снизу откроется количество и цены', 'Pastdan miqdor va narxlar ochiladi'), style: AppText.small.copyWith(color: AppColors.muted)),
          ],
          const Spacer(),
          if (_added > 0) ...[
            StatusChip(
                widget.inventory
                    ? tr('Заполнено: ${goods(_added)}', 'Toʻldirildi: ${goods(_added)}')
                    : tr('Добавлено: ${goods(_added)}', 'Qoʻshildi: ${goods(_added)}'),
                icon: Icons.check_circle_rounded,
                tone: ChipTone.green),
            const SizedBox(height: 12),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SmallButton(label: tr('Ввести штрихкод вручную', 'Shtrix-kodni qoʻlda kiritish'), icon: Icons.keyboard_rounded, onPressed: _manual),
          ),
        ]),
      ),
    ]);
  }
}
