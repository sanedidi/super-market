import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/app_lock.dart';
import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'new_product_screen.dart';
import 'photo_screen.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

enum StartMode { photo, barcode }

/// Н3 · Камера «Начала работы»: фото товара или полки (Super Market найдёт
/// товары в центральной базе) и сканер штрихкодов подряд: найденный товар
/// сразу встаёт в «Мои товары», повтор не добавляется.
class StartCameraScreen extends StatefulWidget {
  const StartCameraScreen({super.key, required this.start, this.mode = StartMode.photo});

  final StartApi start;
  final StartMode mode;

  @override
  State<StartCameraScreen> createState() => _StartCameraScreenState();
}

class _StartCameraScreenState extends State<StartCameraScreen> {
  final _picker = ImagePicker();
  final _shots = <Uint8List>[];
  late StartMode _mode = widget.mode;
  MobileScannerController? _scanner;
  bool _torch = false;
  bool _busy = false;
  bool _handling = false;
  bool _askedCamera = false;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);
  int _added = 0;

  static const maxShots = 6;

  @override
  void initState() {
    super.initState();
    if (_mode == StartMode.barcode) {
      _scanner = _newScanner();
    } else {
      // Камеру открываем, когда экран доехал (как в «Приходе по фото»).
      WidgetsBinding.instance.addPostFrameCallback((_) => _cameraAfterTransition());
    }
  }

  @override
  void dispose() {
    _scanner?.dispose();
    super.dispose();
  }

  MobileScannerController _newScanner() => MobileScannerController(
        formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE, BarcodeFormat.code128, BarcodeFormat.code39],
      );

  void _setMode(StartMode m) {
    if (m == _mode || _busy) return;
    final old = _scanner;
    setState(() {
      _mode = m;
      _torch = false;
      _scanner = m == StartMode.barcode ? _newScanner() : null;
    });
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _cameraAfterTransition() {
    if (!mounted || _askedCamera) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.status == AnimationStatus.completed) {
      _askedCamera = true;
      _take(ImageSource.camera);
      return;
    }
    void listener(AnimationStatus st) {
      if (st != AnimationStatus.completed) return;
      anim.removeStatusListener(listener);
      WidgetsBinding.instance.addPostFrameCallback((_) => _cameraAfterTransition());
    }

    anim.addStatusListener(listener);
  }

  Future<void> _take(ImageSource source) async {
    if (_shots.length >= maxShots) return;
    final lock = context.read<AppLock>();
    try {
      final x = await lock.hold(() => _picker.pickImage(source: source, maxWidth: 2000, maxHeight: 2000, imageQuality: 80));
      WidgetsBinding.instance.scheduleFrame();
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _shots.add(bytes));
    } catch (e) {
      if (mounted) showMessage(context, tr('Нет доступа к камере или фото. Разрешите доступ в настройках телефона.', 'Kamera yoki rasmlarga ruxsat yoʻq. Telefon sozlamalarida ruxsat bering.'));
    }
  }

  /// Фото → загрузка → Super Market ищет товары (Н4).
  Future<void> _send() async {
    final api = context.read<Api>();
    setState(() => _busy = true);
    try {
      final urls = <String>[];
      for (var i = 0; i < _shots.length; i++) {
        final res = await api.upload('/store/uploads', _shots[i], 'shelf_${i + 1}.jpg') as Map<String, dynamic>;
        urls.add(res['url'] as String);
      }
      final ph = await widget.start.createPhoto(urls);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PhotoResultsScreen(start: widget.start, id: ph['id'] as String)));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
        title: tr('Штрихкод', 'Shtrix-kod'), text: tr('Введите цифры под штрихкодом', 'Shtrix-kod ostidagi raqamlarni kiriting'), confirm: tr('Найти', 'Topish'), hint: '4780012345678', keyboardType: TextInputType.number);
    if (code != null && code.trim().isNotEmpty) await _handle(code.trim());
  }

  Future<void> _handle(String code) async {
    _handling = true;
    var added = false;
    try {
      final p = await widget.start.byBarcode(code);
      if (!mounted) return;
      if (p != null) {
        added = await addToMyGoods(context, widget.start, p, source: 'barcode', listButton: false) == AddResult.added;
      } else {
        final r = await pickProductSheet(context, widget.start, info: tr('Штрихкод $code — нет в центральной базе', 'Shtrix-kod $code — markaziy bazada yoʻq'), code: code);
        if (!mounted || r == null) return;
        if (r.create) {
          final created = await Navigator.of(context).push<ProductRef>(
            MaterialPageRoute(builder: (_) => NewProductScreen(start: widget.start, barcode: code)),
          );
          added = created != null;
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: _mode == StartMode.barcode ? _barcodeBody() : _photoBody(),
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

  Widget _photoBody() {
    return SafeArea(
      child: Column(children: [
        _top(),
        Expanded(
          child: _shots.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
                  child: Column(children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(border: Border.all(color: AppColors.white.withValues(alpha: 0.85), width: 2), borderRadius: BorderRadius.circular(20)),
                        child: const Center(child: Icon(Icons.photo_camera_rounded, size: 64, color: AppColors.muted)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(tr('Сфотографируйте товар или целую полку', 'Mahsulotni yoki butun javonni suratga oling'), style: AppText.bodyStrong.copyWith(color: AppColors.white), textAlign: TextAlign.center),
                    const SizedBox(height: 6),
                    Text(tr('Super Market найдёт товары в каталоге. Можно снять несколько фото подряд', 'Super Market mahsulotlarni katalogdan topadi. Ketma-ket bir nechta rasm olish mumkin'),
                        style: AppText.small.copyWith(color: AppColors.muted), textAlign: TextAlign.center),
                  ]),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.8),
                  itemCount: _shots.length,
                  itemBuilder: (_, i) => Stack(children: [
                    Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_shots[i], fit: BoxFit.cover))),
                    Positioned(left: 8, top: 8, child: StatusChip(tr('Фото ${i + 1}', 'Rasm ${i + 1}'))),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: _busy ? null : () => setState(() => _shots.removeAt(i))),
                    ),
                  ]),
                ),
        ),
        _ModeSwitch(mode: _mode, onChanged: _setMode),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Row(children: [
            _SquareButton(icon: Icons.photo_library_rounded, onTap: _busy || _shots.length >= maxShots ? null : () => _take(ImageSource.gallery)),
            const Spacer(),
            GestureDetector(
              onTap: _busy || _shots.length >= maxShots ? null : () => _take(ImageSource.camera),
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.white, width: 5)),
                padding: const EdgeInsets.all(5),
                child: Container(decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle)),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 92,
              height: 52,
              child: Material(
                color: _shots.isEmpty ? AppColors.dark : AppColors.primary,
                borderRadius: BorderRadius.circular(26),
                child: InkWell(
                  borderRadius: BorderRadius.circular(26),
                  onTap: _shots.isEmpty || _busy ? null : _send,
                  child: Center(
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.white))
                        : Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(tr('Готово', 'Tayyor'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                            if (_shots.isNotEmpty) Text(tr('${_shots.length} фото', '${_shots.length} ta rasm'), style: AppText.caption.copyWith(color: AppColors.white, fontSize: 11)),
                          ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _barcodeBody() {
    final scanner = _scanner;
    return Stack(fit: StackFit.expand, children: [
      if (scanner != null) MobileScanner(key: ObjectKey(scanner), controller: scanner, onDetect: _onDetect),
      SafeArea(
        child: Column(children: [
          _top(
            right: RoundIcon(
              icon: _torch ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded,
              color: AppColors.white,
              tooltip: tr('Фонарик', 'Chiroq'),
              onTap: () {
                scanner?.toggleTorch();
                setState(() => _torch = !_torch);
              },
            ),
          ),
          const SizedBox(height: 12),
          _ModeSwitch(mode: _mode, onChanged: _setMode),
          const Spacer(),
          Container(
            width: 260,
            height: 150,
            decoration: BoxDecoration(border: Border.all(color: AppColors.white, width: 2.5), borderRadius: BorderRadius.circular(18)),
            child: Center(child: Container(height: 2, margin: const EdgeInsets.symmetric(horizontal: 14), color: AppColors.primary)),
          ),
          const SizedBox(height: 14),
          Text(tr('Наведите на штрихкод', 'Shtrix-kodga qarating'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
          const Spacer(),
          if (_added > 0) ...[
            StatusChip(tr('Добавлено: ${goods(_added)}', 'Qoʻshildi: ${goods(_added)}'), icon: Icons.check_circle_rounded, tone: ChipTone.green),
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

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final StartMode mode;
  final ValueChanged<StartMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget item(StartMode m, String label) {
      final on = m == mode;
      return GestureDetector(
        onTap: () => onChanged(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(color: on ? AppColors.white : Colors.transparent, borderRadius: BorderRadius.circular(20)),
          child: Text(label, style: AppText.bodyStrong.copyWith(color: on ? AppColors.ink : AppColors.white)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(24)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [item(StartMode.photo, tr('Фото', 'Rasm')), item(StartMode.barcode, tr('Штрихкод', 'Shtrix-kod'))]),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(border: Border.all(color: AppColors.white, width: 2), borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: onTap == null ? AppColors.muted : AppColors.white),
      ),
    );
  }
}
