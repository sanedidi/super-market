import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sm_core/sm_core.dart';

import '../start/scanner.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Р4 · Сканер ручного прихода: штрихкоды подряд. Каждый код отдаётся
/// [onCode] — он открывает шторки поверх камеры (камера на это время
/// выключена) и возвращает true, если строка добавлена в приход.
class IncomeScannerScreen extends StatefulWidget {
  const IncomeScannerScreen({super.key, required this.onCode, required this.count});

  final Future<bool> Function(BuildContext context, String code) onCode;

  /// Сколько позиций сейчас в приходе.
  final int Function() count;

  @override
  State<IncomeScannerScreen> createState() => _IncomeScannerScreenState();
}

class _IncomeScannerScreenState extends State<IncomeScannerScreen> {
  late final MobileScannerController _scanner = barcodeScanner(
    formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE, BarcodeFormat.code128, BarcodeFormat.code39],
  );
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
        title: tr('Штрихкод', 'Shtrix-kod'),
        text: tr('Введите цифры под штрихкодом', 'Shtrix-kod ostidagi raqamlarni kiriting'),
        confirm: tr('Найти', 'Topish'),
        hint: '4780012345678',
        keyboardType: TextInputType.number);
    if (code != null && code.trim().isNotEmpty) await _handle(code.trim());
  }

  Future<void> _handle(String code) async {
    _handling = true;
    var added = false;
    // Пока открыты шторки и экраны после скана, камера сканера выключена.
    await whileScannerIdle(_scanner, () async {
      try {
        added = await widget.onCode(context, code);
      } finally {
        _lastCode = code;
        _lastAt = DateTime.now();
        _handling = false;
      }
    });
    if (added && mounted) {
      setState(() => _added++);
    }
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
                RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: () => Navigator.of(context).pop(_added > 0)),
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
            const Spacer(),
            Container(
              width: 260,
              height: 150,
              decoration: BoxDecoration(border: Border.all(color: AppColors.white, width: 2.5), borderRadius: BorderRadius.circular(18)),
              child: Center(child: Container(height: 2, margin: const EdgeInsets.symmetric(horizontal: 14), color: AppColors.primary)),
            ),
            const SizedBox(height: 14),
            Text(tr('Наведите на штрихкод', 'Shtrix-kodga qarating'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
            const SizedBox(height: 6),
            Text(tr('Снизу откроется количество и цены', 'Pastdan miqdor va narxlar ochiladi'), style: AppText.small.copyWith(color: AppColors.muted)),
            const Spacer(),
            if (widget.count() > 0) ...[
              StatusChip(tr('В приходе: ${widget.count()} поз.', 'Kirimda: ${widget.count()} ta'), icon: Icons.check_circle_rounded, tone: ChipTone.green),
              const SizedBox(height: 12),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(children: [
                Expanded(child: SmallButton(label: tr('Ввести вручную', 'Qoʻlda kiritish'), icon: Icons.keyboard_rounded, onPressed: _manual)),
                const SizedBox(width: 10),
                Expanded(
                  child: SmallButton(
                    label: tr('Готово', 'Tayyor'),
                    icon: Icons.check_rounded,
                    primary: true,
                    onPressed: () => Navigator.of(context).pop(_added > 0),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
