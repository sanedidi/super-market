import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sm_core/sm_core.dart';

import '../start/scanner.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'kassa.dart';
import 'pay.dart';

String _sum() => tr('сум', 'soʻm');

/// КQ2–КQ3 · «В долг» по QR покупателя: камера ждёт «Мой QR-код» из
/// приложения, касса проверяет его на сервере и показывает карточку —
/// номер и код не нужны. Нет приложения — «ввести номер» (прежняя шторка).
/// [qr] — QR уже отсканирован камерой кассы: сразу ищем покупателя.
/// Возвращает долг для чека или null — назад.
class DebtQrScreen extends StatefulWidget {
  const DebtQrScreen({super.key, required this.kassa, this.qr});

  final Kassa kassa;
  final String? qr;

  @override
  State<DebtQrScreen> createState() => _DebtQrScreenState();
}

class _DebtQrScreenState extends State<DebtQrScreen> {
  late final MobileScannerController _scanner;
  DebtorView? _who;
  bool _busy = false;
  bool _torch = false;
  String? _err;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);

  Kassa get kassa => widget.kassa;
  int get _total => kassa.cart.total;

  @override
  void initState() {
    super.initState();
    _scanner = barcodeScanner(formats: const [BarcodeFormat.qrCode]);
    final qr = widget.qr;
    if (qr != null) WidgetsBinding.instance.addPostFrameCallback((_) => _lookup(qr));
  }

  @override
  void dispose() {
    disposeScanner(_scanner);
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_busy || _who != null || capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    final now = DateTime.now();
    final again = code == _lastCode && now.difference(_lastAt) < const Duration(seconds: 2);
    _lastCode = code;
    _lastAt = now;
    if (again) return;
    if (parseClientQr(code) == null) {
      HapticFeedback.heavyImpact();
      setState(() => _err = tr('Это не QR покупателя Super Market', 'Bu Super Market xaridorining QR kodi emas'));
      return;
    }
    _lookup(code);
  }

  Future<void> _lookup(String code) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final w = await kassa.lookupDebtorQr(code);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
      setState(() => _who = w);
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Нет приложения — прежняя шторка с номером телефона.
  Future<void> _byPhone() async {
    final r = await whileScannerIdle(_scanner, () => debtSheet(context, kassa));
    if (r != null && mounted) Navigator.of(context).pop(r);
  }

  void _again() => setState(() {
        _who = null;
        _err = null;
        _lastCode = null;
      });

  @override
  Widget build(BuildContext context) {
    final w = _who;
    Widget round(IconData icon, VoidCallback onTap) => Material(
          color: Colors.white.withValues(alpha: 0.18),
          shape: const CircleBorder(),
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 44, height: 44, child: Icon(icon, color: AppColors.white))),
        );
    return Scaffold(
      backgroundColor: const Color(0xFF1F1D1A),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(controller: _scanner, onDetect: _onDetect),
        const DecoratedBox(decoration: BoxDecoration(color: Color(0x55000000))),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(children: [
                round(Icons.close_rounded, () => Navigator.of(context).pop()),
                Expanded(
                  child: Column(children: [
                    Text(tr('В долг · ${fmtMoney(_total)} ${_sum()}', 'Qarzga · ${fmtMoney(_total)} ${_sum()}'),
                        style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                    Text(tr('${kassa.cart.count} поз. в чеке', 'Chekda ${kassa.cart.count} ta pozitsiya'),
                        style: AppText.small.copyWith(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
                  ]),
                ),
                round(_torch ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded, () {
                  _scanner.toggleTorch();
                  setState(() => _torch = !_torch);
                }),
              ]),
            ),
            const SizedBox(height: 24),
            Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: _err != null ? AppColors.error : Colors.white.withValues(alpha: 0.85), width: 2.5),
                borderRadius: BorderRadius.circular(28),
              ),
              child: _busy ? const Center(child: CircularProgressIndicator(color: AppColors.white)) : null,
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _err != null
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(16)),
                      child: Text(_err!, textAlign: TextAlign.center, style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
                    )
                  : Text(
                      _busy ? tr('Проверяем QR…', 'QR tekshirilmoqda…') : tr('Наведите камеру на QR покупателя', 'Kamerani xaridor QR kodiga qarating'),
                      textAlign: TextAlign.center,
                      style: AppText.bodyStrong.copyWith(color: AppColors.white),
                    ),
            ),
          ]),
        ),
        if (w != null) const DecoratedBox(decoration: BoxDecoration(color: Color(0x73000000))),
        Align(alignment: Alignment.bottomCenter, child: w == null ? _waiting() : _found(w)),
      ]),
    );
  }

  Widget _sheet(List<Widget> children) => Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.paddingOf(context).bottom),
        decoration: const BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 36, height: 5, decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(3)))),
          const SizedBox(height: 14),
          ...children,
        ]),
      );

  /// КQ2 · ждём QR.
  Widget _waiting() => _sheet([
        Row(children: [
          const IconBox(Icons.qr_code_2_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk, size: 44, iconSize: 26, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Покупатель показывает свой QR', 'Xaridor oʻz QR kodini koʻrsatadi'), style: AppText.bodyStrong.copyWith(fontSize: 16)),
              Text(tr('Super Market → Профиль → «Мой QR-код»', 'Super Market → Profil → «Mening QR kodim»'), style: AppText.small),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        BigButton(
          label: tr('Нет приложения — ввести номер', 'Ilova yoʻq — raqam kiritish'),
          icon: Icons.dialpad_rounded,
          color: AppColors.soft,
          foreground: AppColors.ink,
          height: 52,
          onPressed: _busy ? null : _byPhone,
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Назад к способам оплаты', 'Toʻlov usullariga qaytish'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
        ),
      ]);

  /// КQ3 · покупатель найден: долг, лимит, свободно, «В долг».
  Widget _found(DebtorView w) {
    final enough = w.available >= _total;
    final can = !w.blocked && enough;
    Widget fact(String label, int v, {Color color = AppColors.ink}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small.copyWith(fontSize: 12)),
              FittedBox(child: Text(fmtMoney(v), style: AppText.title.copyWith(fontSize: 17, color: color))),
            ]),
          ),
        );
    return _sheet([
      Row(children: [
        Expanded(child: Text(tr('В долг', 'Qarzga'), style: AppText.h3.copyWith(fontSize: 22))),
        Flexible(
          child: StatusChip(
            w.online ? tr('по QR · подтверждён', 'QR orqali · tasdiqlangan') : tr('по QR · без связи', 'QR orqali · aloqasiz'),
            icon: Icons.qr_code_2_rounded,
            tone: w.online ? ChipTone.green : ChipTone.amber,
          ),
        ),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: AppColors.soft, shape: BoxShape.circle),
          child: Text(_initials(w.name), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(w.name.isEmpty ? tr('Покупатель', 'Xaridor') : w.name, style: AppText.bodyStrong.copyWith(fontSize: 17)),
            Text(
                [formatPhone(w.phone), if (w.purchases > 0) tr('${w.purchases} покупок в долг', 'qarzga ${w.purchases} ta xarid')].join(' · '),
                style: AppText.small),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        fact(tr('Долг', 'Qarz'), w.debt),
        const SizedBox(width: 8),
        fact(tr('Лимит', 'Limit'), w.limit),
        const SizedBox(width: 8),
        fact(tr('Свободно', 'Boʻsh'), w.available, color: enough ? AppColors.successInk : AppColors.warningInk),
      ]),
      const SizedBox(height: 14),
      if (w.blocked)
        Text(tr('Покупатель в стоп-листе — в долг не давать', 'Xaridor stop-roʻyxatda — qarzga bermang'),
            textAlign: TextAlign.center, style: AppText.bodyStrong.copyWith(color: AppColors.error))
      else if (!enough)
        Text(tr('Не хватает лимита: свободно ${fmtMoney(w.available)} ${_sum()}', 'Limit yetmaydi: boʻsh ${fmtMoney(w.available)} ${_sum()}'),
            textAlign: TextAlign.center, style: AppText.bodyStrong.copyWith(color: AppColors.warningInk))
      else
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Expanded(child: Text(tr('Долг станет', 'Qarz boʻladi'), style: AppText.body.copyWith(fontWeight: FontWeight.w500))),
            Text('${fmtMoney(w.debt + _total)} ${_sum()}', style: AppText.title),
          ]),
        ),
      const SizedBox(height: 14),
      BigButton(
        label: tr('В долг · ${fmtMoney(_total)} ${_sum()}', 'Qarzga · ${fmtMoney(_total)} ${_sum()}'),
        icon: Icons.menu_book_rounded,
        onPressed: can ? () => Navigator.of(context).pop(DebtPay(who: w, amount: _total, name: w.name)) : null,
      ),
      TextButton(
        onPressed: _again,
        child: Text(tr('Другой покупатель — сканировать заново', 'Boshqa xaridor — qayta skanerlash'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
      ),
    ]);
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).take(2);
    final s = parts.map((p) => p[0].toUpperCase()).join();
    return s.isEmpty ? '?' : s;
  }
}
