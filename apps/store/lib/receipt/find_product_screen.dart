import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sm_core/sm_core.dart';

import '../income/product_finder.dart';
import '../main.dart' show showMessage;
import '../start/scanner.dart';
import '../start/start_logic.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Н6 · Товара из строки накладной нет: сначала штрихкод на товаре. Есть в
/// базе — «Да, это он» (Н7), карточку не создаём; нет — каталог ИКПУ,
/// привязать к своему товару (Н9) или новый товар по фото; у товара нет
/// штрихкода — сразу фото. Возвращает товар (он уже в «Моих товарах»).
class FindProductScreen extends StatefulWidget {
  const FindProductScreen({super.key, required this.finder, required this.line});

  final ProductFinder finder;

  /// «Строка 1 · «Окорочка с/з 12 кг мар»».
  final String line;

  @override
  State<FindProductScreen> createState() => _FindProductScreenState();
}

class _FindProductScreenState extends State<FindProductScreen> {
  late final MobileScannerController _scanner = barcodeScanner(
    formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE, BarcodeFormat.code128, BarcodeFormat.code39],
  );
  bool _torch = false;
  bool _handling = false;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);

  @override
  void dispose() {
    disposeScanner(_scanner);
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handling || capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    if (code == _lastCode && DateTime.now().difference(_lastAt) < const Duration(seconds: 2)) return;
    _code(code);
  }

  void _code(String code) {
    _run(() => widget.finder.byCode(
          context,
          code,
          title: tr('Нашли по штрихкоду', 'Shtrix-kod boʻyicha topildi'),
          text: (p) => tr('«${p.name}» уже есть в базе Super Market — карточку создавать не нужно. Добавим его в «Мои товары» и сопоставим строку накладной.',
              '«${p.name}» Super Market bazasida bor — kartochka yaratish shart emas. Uni «Mahsulotlarim»ga qoʻshamiz va yuk xati qatoriga moslaymiz.'),
          confirm: tr('Да, это он', 'Ha, shu'),
        ), code: code);
  }

  Future<void> _manual() async {
    final code = await promptSheet(context,
        title: tr('Штрихкод', 'Shtrix-kod'),
        text: tr('Введите цифры под штрихкодом', 'Shtrix-kod ostidagi raqamlarni kiriting'),
        confirm: tr('Найти', 'Topish'),
        hint: '4780012345678',
        keyboardType: TextInputType.number);
    if (code == null || code.trim().isEmpty || !mounted) return;
    _code(code.trim());
  }

  /// Н8 · У товара нет штрихкода — сразу фото.
  void _noBarcode() => _run(() => widget.finder.capture(() => widget.finder.newByPhoto(context, null)));

  Future<void> _run(Future<ProductRef?> Function() body, {String? code}) async {
    _handling = true;
    ProductRef? got;
    await whileScannerIdle(_scanner, () async {
      try {
        got = await body();
      } catch (e) {
        if (mounted) showMessage(context, e);
      } finally {
        _lastCode = code;
        _lastAt = DateTime.now();
        _handling = false;
      }
    });
    if (got != null && mounted) Navigator.of(context).pop(got);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(controller: _scanner, onDetect: _onDetect),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(children: [
                RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: () => Navigator.of(context).pop()),
                const Spacer(),
                RoundIcon(
                  icon: _torch ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded,
                  color: AppColors.white,
                  tooltip: tr('Фонарик', 'Chiroq'),
                  onTap: () {
                    _scanner.toggleTorch();
                    setState(() => _torch = !_torch);
                  },
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: AppColors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(99)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.receipt_long_rounded, size: 16, color: AppColors.white),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(widget.line,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppColors.white, fontSize: 13)),
                  ),
                ]),
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
            Text(tr('Отсканируйте штрихкод на товаре', 'Mahsulotdagi shtrix-kodni skanerlang'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(tr('Если штрихкод уже есть в базе — карточку создавать не нужно', 'Shtrix-kod bazada boʻlsa — kartochka yaratish shart emas'),
                  textAlign: TextAlign.center, style: AppText.small.copyWith(color: AppColors.muted)),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: BigButton(
                label: tr('У товара нет штрихкода', 'Mahsulotda shtrix-kod yoʻq'),
                icon: Icons.photo_camera_rounded,
                color: AppColors.white.withValues(alpha: 0.14),
                onPressed: _noBarcode,
              ),
            ),
            TextButton.icon(
              onPressed: _manual,
              icon: const Icon(Icons.keyboard_rounded, color: AppColors.muted),
              label: Text(tr('Ввести штрихкод вручную', 'Shtrix-kodni qoʻlda kiritish'), style: AppText.bodyStrong.copyWith(color: AppColors.muted)),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ]),
    );
  }
}
