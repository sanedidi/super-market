import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../start/scanner.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'debt_qr.dart';
import 'kassa.dart';
import 'pay.dart';
import 'quick_screen.dart';
import 'sheets.dart';
import 'widgets.dart';

String _sum() => tr('сум', 'soʻm');

/// К2 · Касса в телефоне: сверху камера сканирует штрихкоды и QR, снизу
/// собирается чек (новые сверху), «Оплатить» — способы оплаты как на POS.
class KassaScreen extends StatefulWidget {
  const KassaScreen({super.key});

  @override
  State<KassaScreen> createState() => _KassaScreenState();
}

class _KassaScreenState extends State<KassaScreen> {
  late final Kassa kassa;
  late final MobileScannerController _scanner;
  bool _torch = false;
  bool _handling = false;
  bool _paying = false;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);

  String? _toast;
  bool _toastOk = true;
  Timer? _toastTimer;

  late bool _canDiscount;
  late bool _canPrice;
  late bool _canDebt;

  @override
  void initState() {
    super.initState();
    final st = context.read<StoreState>();
    kassa = Kassa(api: context.read<Api>(), storeId: st.storeId!, employeeId: '${st.me?['employee_id'] ?? ''}');
    _canDiscount = st.can('sales.discount');
    _canPrice = st.can('prices.manage');
    _canDebt = st.can('debts.give');
    kassa.init();
    _scanner = barcodeScanner(formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.qrCode,
      BarcodeFormat.dataMatrix,
    ]);
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    disposeScanner(_scanner);
    kassa.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- скан

  void _onDetect(BarcodeCapture capture) {
    if (_handling || _paying || capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    // Тот же код считается снова, только если он ушёл из кадра хотя бы на 1,5 с.
    final now = DateTime.now();
    final again = code == _lastCode && now.difference(_lastAt) < const Duration(milliseconds: 1500);
    _lastCode = code;
    _lastAt = now;
    if (again) return;
    _handle(code);
  }

  Future<void> _handle(String code) async {
    if (!kassa.ready) return;
    // QR покупателя из приложения (Figma «КQ2–КQ3»): сразу «В долг».
    final qr = parseClientQr(code);
    if (qr != null) {
      if (!(_canDebt && kassa.catalog.settings.debtEnabled)) {
        HapticFeedback.heavyImpact();
        _showToast(tr('QR покупателя — для продажи в долг, а здесь в долг не дают', 'Xaridor QR kodi — qarzga sotish uchun, bu yerda esa qarzga berilmaydi'), ok: false);
      } else if (kassa.cart.isEmpty) {
        HapticFeedback.heavyImpact();
        _showToast(tr('Сначала товары, потом QR покупателя', 'Avval mahsulotlar, keyin xaridor QR kodi'), ok: false);
      } else {
        await _pay(debtQr: qr.payload);
      }
      return;
    }
    await _result(kassa.scan(code));
  }

  Future<void> _result(ScanResult r) async {
    if (r is Scanned) {
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
      final p = r.line.product;
      _showToast(p.fractional ? '${p.name} · ${fmtQty(r.added)} ${p.unit}' : '${p.name} · +${fmtQty(r.added)}', ok: true);
    } else if (r is NeedWeight) {
      await _idle(() => weightSheet(context, kassa, r.product));
    } else if (r is NeedPrice) {
      HapticFeedback.heavyImpact();
      await _needPrice(r);
    } else if (r is NotFound) {
      HapticFeedback.heavyImpact();
      await _unknown(r.code);
    } else if (r is ScanFail) {
      HapticFeedback.heavyImpact();
      _showToast(r.message, ok: false);
    }
  }

  /// Товар без цены: цена → сохраняем в магазине → тот же товар в чек.
  Future<void> _needPrice(NeedPrice r) async {
    final p = await _idle(() => priceSheet(context, kassa, r.product, canPrice: _canPrice));
    if (!mounted || p == null) return;
    final qty = r.qty;
    if (qty == null) {
      await _idle(() => weightSheet(context, kassa, p));
    } else {
      await _result(kassa.add(p, qty: qty, mark: r.mark));
    }
  }

  /// Пока открыта шторка или другой экран — камера выключена.
  Future<T> _idle<T>(Future<T> Function() action) async {
    _handling = true;
    try {
      return await whileScannerIdle(_scanner, action);
    } finally {
      _handling = false;
      _lastAt = DateTime.now();
    }
  }

  Future<void> _unknown(String code) async {
    final res = await _idle(() => unknownSheet(context, kassa, code, canPrice: _canPrice));
    if (!mounted || res == null) return;
    if (res == 'search') {
      await _openQuick(search: true);
      return;
    }
    final p = kassa.catalog.byId(res);
    if (p == null) return;
    if (p.marked) {
      _showToast(tr('Маркированный товар: сканируйте DataMatrix на упаковке', 'Markirovkali mahsulot: qadoqdagi DataMatrix kodini skanerlang'), ok: false);
    } else if (p.fractional) {
      await _idle(() => weightSheet(context, kassa, p));
    } else {
      try {
        kassa.addOne(p);
        _showToast('${p.name} · +1', ok: true);
      } on CartError catch (e) {
        _showToast(e.message, ok: false);
      }
    }
  }

  Future<void> _manual() async {
    final code = await _idle(() => promptSheet(context,
        title: tr('Штрихкод', 'Shtrix-kod'),
        text: tr('Введите цифры под штрихкодом', 'Shtrix-kod ostidagi raqamlarni kiriting'),
        confirm: tr('Добавить', 'Qoʻshish'),
        hint: '4780012345678',
        keyboardType: TextInputType.number));
    if (code != null && code.trim().isNotEmpty && mounted) await _handle(code.trim());
  }

  Future<void> _openQuick({bool search = false}) =>
      _idle(() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuickScreen(kassa: kassa, search: search))));

  void _showToast(String text, {required bool ok}) {
    _toastTimer?.cancel();
    setState(() {
      _toast = text;
      _toastOk = ok;
    });
    _toastTimer = Timer(Duration(milliseconds: ok ? 1600 : 3000), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // --------------------------------------------------------- строка чека

  Future<void> _editLine(CartLine line) async {
    final res = await _idle(() => lineSheet(context, kassa, line, canDiscount: _canDiscount));
    if (res == 'weight' && mounted && kassa.cart.lines.contains(line)) {
      await _idle(() => weightSheet(context, kassa, line.product));
    }
  }

  void _step(CartLine line, int delta) {
    try {
      kassa.setQty(line, line.qty + delta);
    } on CartError catch (e) {
      _showToast(e.message, ok: false);
    }
  }

  // -------------------------------------------------------------- оплата

  /// Оплата. [debtQr] — камера кассы прочитала QR покупателя: сразу «В долг».
  Future<void> _pay({String? debtQr}) async {
    if (kassa.cart.isEmpty || _paying) return;
    await _idle(() async {
      final total = kassa.cart.total;
      final canDebt = _canDebt && kassa.catalog.settings.debtEnabled;
      final kind = debtQr != null ? 'debt' : await methodSheet(context, kassa, canDebt: canDebt);
      if (kind == null || !mounted) return;
      List<Pay> pays = const [];
      DebtPay? debt;
      var received = 0;
      switch (kind) {
        case 'cash':
          final got = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => CashScreen(total: total)));
          if (got == null) return;
          received = got;
          pays = [Pay(kassa.method('cash')!, total)];
        case 'card':
          final cardOk = await confirmSheet(context,
              title: tr('Оплата картой', 'Karta bilan toʻlov'),
              text: tr('Проведите на терминале ${fmtMoney(total)} ${_sum()}. Терминал одобрил оплату?',
                  'Terminalda ${fmtMoney(total)} ${_sum()} oʻtkazing. Terminal toʻlovni tasdiqladimi?'),
              confirm: tr('Оплата прошла', 'Toʻlov oʻtdi'),
              cancel: tr('Назад', 'Orqaga'),
              icon: Icons.credit_card_rounded);
          if (!cardOk) return;
          pays = [Pay(kassa.method('card')!, total)];
        case 'qr':
          final qrOk = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => QrPayScreen(total: total)));
          if (qrOk != true) return;
          pays = [Pay(kassa.method('qr')!, total)];
        case 'mixed':
          final cash = await mixedSheet(context, total);
          if (cash == null) return;
          pays = [Pay(kassa.method('cash')!, cash), Pay(kassa.method('card')!, total - cash)];
        case 'debt':
          debt = await Navigator.of(context).push<DebtPay>(MaterialPageRoute(builder: (_) => DebtQrScreen(kassa: kassa, qr: debtQr)));
          if (debt == null) return;
        default:
          return;
      }
      if (!mounted) return;
      setState(() => _paying = true);
      try {
        final done = await kassa.pay(pays, debt: debt, received: received);
        if (!mounted) return;
        HapticFeedback.heavyImpact();
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DoneScreen(sale: done)));
      } catch (e) {
        if (mounted) {
          await infoSheet(context,
              title: tr('Чек не проведён', 'Chek oʻtkazilmadi'),
              text: tr('$e\n\nЧек сохранён — нажмите «Оплатить» ещё раз.', '$e\n\nChek saqlandi — «Toʻlash»ni yana bosing.'),
              icon: Icons.error_outline_rounded);
        }
      } finally {
        if (mounted) setState(() => _paying = false);
      }
    });
  }

  Future<bool> _confirmLeave() async {
    if (kassa.cart.isEmpty) return true;
    final ok = await confirmSheet(context,
        title: tr('Отменить чек?', 'Chek bekor qilinsinmi?'),
        text: tr('В чеке ${kassa.cart.count} поз. на ${fmtMoney(kassa.cart.total)} ${_sum()}', 'Chekda ${fmtMoney(kassa.cart.total)} ${_sum()}lik ${kassa.cart.count} ta pozitsiya'),
        confirm: tr('Отменить чек', 'Chekni bekor qilish'),
        cancel: tr('Вернуться к чеку', 'Chekka qaytish'));
    if (ok) kassa.clearCart();
    return ok;
  }

  // -------------------------------------------------------------- экран

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: kassa,
      builder: (context, _) => PopScope(
        canPop: kassa.cart.isEmpty && !_paying,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop || _paying) return;
          if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF1F1D1A),
          body: Stack(children: [
            Column(children: [
              SizedBox(height: MediaQuery.sizeOf(context).height * 0.40, child: _camera()),
              Expanded(child: _check()),
            ]),
            if (_paying)
              const Positioned.fill(
                child: ColoredBox(color: Color(0x66000000), child: Center(child: CircularProgressIndicator(color: AppColors.white))),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _camera() {
    final sub = kassa.shiftNumber == null ? tr('смена откроется сама', 'smena oʻzi ochiladi') : tr('смена ${kassa.shiftNumber}', 'smena ${kassa.shiftNumber}');
    Widget round(IconData icon, VoidCallback onTap, String tip) => Tooltip(
          message: tip,
          child: Material(
            color: Colors.white.withValues(alpha: 0.18),
            shape: const CircleBorder(),
            child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 44, height: 44, child: Icon(icon, color: AppColors.white))),
          ),
        );
    return Stack(fit: StackFit.expand, children: [
      MobileScanner(controller: _scanner, onDetect: _onDetect),
      const DecoratedBox(decoration: BoxDecoration(color: Color(0x33000000))),
      SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              round(Icons.close_rounded, () => Navigator.of(context).maybePop(), tr('Закрыть', 'Yopish')),
              Expanded(
                child: Column(children: [
                  Text(tr('Касса', 'Kassa'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                  Text(sub, style: AppText.small.copyWith(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
                ]),
              ),
              round(Icons.keyboard_rounded, _manual, tr('Ввести штрихкод', 'Shtrix-kodni kiritish')),
              const SizedBox(width: 8),
              round(_torch ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded, () {
                _scanner.toggleTorch();
                setState(() => _torch = !_torch);
              }, tr('Фонарик', 'Chiroq')),
            ]),
          ),
          Expanded(
            child: Center(
              child: Container(
                width: 260,
                height: 120,
                decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2.5), borderRadius: BorderRadius.circular(18)),
                child: Center(child: Container(height: 2, margin: const EdgeInsets.symmetric(horizontal: 14), color: AppColors.primary)),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: Center(
              child: _toast != null
                  ? Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(color: _toastOk ? AppColors.success : AppColors.error, borderRadius: BorderRadius.circular(20)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_toastOk ? Icons.check_circle_rounded : Icons.error_rounded, size: 18, color: AppColors.white),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(_toast!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
                        ),
                      ]),
                    )
                  : Text(
                      kassa.ready ? tr('Наведите на штрихкод или QR', 'Shtrix-kod yoki QR ga qarating') : tr('Загружаем товары…', 'Mahsulotlar yuklanmoqda…'),
                      style: AppText.small.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                    ),
            ),
          ),
          const SizedBox(height: 22),
        ]),
      ),
    ]);
  }

  /// Пустой чек или ошибка — в прокрутке: места под камерой немного.
  Widget _scroll(Widget child) => ListView(padding: EdgeInsets.zero, children: [child]);

  Widget _check() {
    final cart = kassa.cart;
    final lines = cart.lines.reversed.toList();
    Widget body;
    if (!kassa.ready && kassa.error != null) {
      body = _scroll(EmptyState(
        icon: Icons.cloud_off_rounded,
        title: tr('Не удалось загрузить товары', 'Mahsulotlarni yuklab boʻlmadi'),
        text: '${kassa.error}',
        action: tr('Повторить', 'Qayta urinish'),
        onAction: kassa.init,
      ));
    } else if (!kassa.ready) {
      body = const Center(child: CircularProgressIndicator());
    } else if (lines.isEmpty) {
      body = _scroll(EmptyState(
        icon: Icons.qr_code_scanner_rounded,
        title: tr('Чек пуст', 'Chek boʻsh'),
        text: tr('Сканируйте товар — он сразу появится здесь', 'Mahsulotni skanerlang — u darhol shu yerda paydo boʻladi'),
      ));
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        itemCount: lines.length,
        itemBuilder: (context, i) {
          final l = lines[i];
          return _LineRow(
            line: l,
            fresh: l == kassa.lastLine,
            onTap: () => _editLine(l),
            onMinus: l.product.marked || l.product.fractional ? null : () => _step(l, -1000),
            onPlus: l.product.marked || l.product.fractional ? null : () => _step(l, 1000),
            onWeight: () => _idle(() => weightSheet(context, kassa, l.product)),
          );
        },
      );
    }
    return Container(
      decoration: const BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(children: [
        const SizedBox(height: 8),
        Container(width: 36, height: 5, decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(3))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(cart.isEmpty ? tr('Чек', 'Chek') : tr('Чек · ${cart.count} поз.', 'Chek · ${cart.count} ta'), style: AppText.title),
                Text(tr('новые сверху', 'yangilari tepada'), style: AppText.small.copyWith(fontSize: 12)),
              ]),
            ),
            Material(
              color: AppColors.soft,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: kassa.ready ? () => _openQuick() : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.search_rounded, size: 18),
                    const SizedBox(width: 6),
                    Text(tr('Без штрихкода', 'Shtrix-kodsiz'), style: AppText.bodyStrong.copyWith(fontSize: 13)),
                  ]),
                ),
              ),
            ),
          ]),
        ),
        Expanded(child: body),
        Container(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
          decoration: const BoxDecoration(color: AppColors.white, border: Border(top: BorderSide(color: AppColors.line))),
          child: Column(children: [
            Row(children: [
              Expanded(
                child: Text(
                  cart.discount > 0
                      ? tr('${cart.count} поз. · скидка ${fmtMoney(cart.discount)}', '${cart.count} ta · chegirma ${fmtMoney(cart.discount)}')
                      : tr('${cart.count} поз. · скидок нет', '${cart.count} ta · chegirmasiz'),
                  style: AppText.small,
                ),
              ),
              Text('${fmtMoney(cart.total)} ${_sum()}', style: AppText.h2),
            ]),
            const SizedBox(height: 10),
            BigButton(label: tr('Оплатить', 'Toʻlash'), icon: Icons.payments_rounded, busy: _paying, onPressed: cart.isEmpty ? null : _pay),
          ]),
        ),
      ]),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.fresh, required this.onTap, required this.onMinus, required this.onPlus, required this.onWeight});

  final CartLine line;
  final bool fresh;
  final VoidCallback onTap;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final VoidCallback onWeight;

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    final sub = p.fractional ? tr('${fmtMoney(line.price)} ${_sum()}/${p.unit}', '${fmtMoney(line.price)} ${_sum()}/${p.unit}') : '${fmtMoney(line.price)} × ${fmtQty(line.qty)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: fresh ? AppColors.successSoft : AppColors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: fresh ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.line))),
            child: Row(children: [
              ProductThumb(p.image, size: 40, color: fresh ? AppColors.white : AppColors.soft),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    fresh ? tr('$sub · только что', '$sub · hozirgina') : (line.hasDiscount ? tr('$sub · скидка ${fmtMoney(line.discount)}', '$sub · chegirma ${fmtMoney(line.discount)}') : sub),
                    style: AppText.small.copyWith(fontSize: 12, color: fresh ? AppColors.successInk : AppColors.text2),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(fmtMoney(line.total), style: AppText.bodyStrong),
                const SizedBox(height: 6),
                if (p.fractional)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onWeight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(10)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.scale_rounded, size: 16, color: AppColors.text2),
                        const SizedBox(width: 4),
                        Text('${fmtQty(line.qty)} ${p.unit}', style: AppText.bodyStrong.copyWith(fontSize: 13)),
                      ]),
                    ),
                  )
                else
                  QtyStepper(label: fmtQty(line.qty), onMinus: onMinus, onPlus: onPlus),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
