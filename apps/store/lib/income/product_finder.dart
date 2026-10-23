import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart' show showMessage;
import '../start/new_items.dart' show NewItemCameraScreen, openNewItemReview, showQueuedSheet;
import '../start/sheets.dart' show pickProductSheet, similarSheet;
import '../start/start_api.dart';
import '../start/start_logic.dart';
import '../start/tasnif.dart' show tasnifBarcodeSheet;
import '../ui/theme.dart';

/// Товар по штрихкоду или по фото — общее для ручного прихода (Р6, Р7) и
/// прихода по фото накладной (Н6–Н9): свой товар; есть в базе — в «Мои
/// товары»; нет нигде — каталог ИКПУ, привязать штрихкод к своему товару или
/// новый товар по фото.
class ProductFinder {
  ProductFinder(this.start);

  final StartApi start;

  /// Товар из «Моих товаров» (null — его нет в магазине).
  Future<Map<String, dynamic>?> my(String productId) async {
    final r = await start.api.get('/store/inventory/my-products', {'store_id': start.storeId, 'product_id': productId, 'limit': 1}) as Map<String, dynamic>;
    final items = (r['items'] as List?) ?? const [];
    return items.isEmpty ? null : (items.first as Map).cast<String, dynamic>();
  }

  /// Штрихкод: свой товар — сразу он; есть в базе — спросить и добавить в
  /// магазин; нет нигде — [missing]. [askBase] — текст вопроса для товара из базы.
  Future<ProductRef?> byCode(BuildContext ctx, String code, {required String title, required String Function(ProductRef p) text, required String confirm}) async {
    final p = await start.byBarcode(code);
    if (!ctx.mounted) return null;
    if (p != null) {
      final m = await my(p.id);
      if (!ctx.mounted) return null;
      if (m != null) return p;
      final yes = await confirmSheet(ctx, title: title, text: text(p), confirm: confirm, cancel: tr('Нет', 'Yoʻq'), icon: Icons.add_rounded);
      if (!yes || !ctx.mounted) return null;
      return await addToStore(ctx, p) ? p : null;
    }
    return capture(() => missing(ctx, code));
  }

  /// Товар в «Мои товары»; повтор — тоже успех (он уже наш). bind — привязать штрихкод.
  Future<bool> addToStore(BuildContext ctx, ProductRef p, {String? bind}) async {
    try {
      var o = await start.add(p.id, source: 'barcode', bind: bind);
      if (o.kind == AddKind.similar) {
        if (!ctx.mounted) return false;
        final yes = await similarSheet(ctx, p, o.similar ?? const {});
        if (!yes) return false;
        o = await start.add(p.id, source: 'barcode', bind: bind, confirmSimilar: true);
      }
      return o.kind == AddKind.added || o.kind == AddKind.duplicate;
    } catch (e) {
      if (ctx.mounted) showMessage(ctx, e);
      return false;
    }
  }

  /// Запомнить товар, который экраны «Начала работы» добавят в магазин
  /// (каталог ИКПУ, новый товар по фото, ручная карточка).
  Future<ProductRef?> capture(Future<ProductRef?> Function() body) async {
    ProductRef? got;
    final prev = start.afterAdd;
    start.afterAdd = (_, p) async {
      got = p;
    };
    try {
      return await body() ?? got;
    } finally {
      start.afterAdd = prev;
    }
  }

  /// Р7 · Штрихкода нет ни в магазине, ни в базе: каталог ИКПУ, привязать
  /// штрихкод к своему товару или новый товар по фото.
  Future<ProductRef?> missing(BuildContext ctx, String code) async {
    final queued = await start.newItemByBarcode(code);
    if (!ctx.mounted) return null;
    if (queued != null) {
      // Карточка уже в «Новых»: готова — откроется на проверку, подтвердили — товар наш.
      await showQueuedSheet(ctx, start, queued);
      return null;
    }
    final t = await tasnifBarcodeSheet(ctx, start, code);
    if (!ctx.mounted || t == null || t) return null;
    final r = await pickProductSheet(ctx, start,
        info: tr('Штрихкод $code — нет ни в ваших товарах, ни в центральной базе', 'Shtrix-kod $code — na mahsulotlaringizda, na markaziy bazada bor'), code: code);
    if (!ctx.mounted || r == null) return null;
    if (r.create) return newByPhoto(ctx, code);
    final p = r.product;
    if (p != null && await addToStore(ctx, p, bind: r.bind ? code : null)) return p;
    return null;
  }

  /// Р7а / Р7б · Новый товар по фото: Super Market заполняет карточку, магазин
  /// её подтверждает. Товар ловит [capture] (вызывайте внутри него).
  Future<ProductRef?> newByPhoto(BuildContext ctx, String? code) async {
    Map<String, dynamic>? sent;
    final r = await Navigator.of(ctx).push<String>(MaterialPageRoute(builder: (_) => NewItemCameraScreen(start: start, barcode: code, onSent: (it) => sent = it)));
    if (!ctx.mounted || r == null) return null;
    if (r == 'exists') {
      showMessage(ctx, tr('Этот товар уже в «Новых» — проверьте его карточку', 'Bu mahsulot allaqachon «Yangilar»da — kartochkasini tekshiring'));
      return null;
    }
    final id = sent?['id'];
    if (r == 'manual' || id == null) return null; // ручную карточку поймает capture
    final item = await showDialog<Map<String, dynamic>>(context: ctx, barrierDismissible: false, builder: (_) => WaitCard(start: start, id: '$id'));
    if (!ctx.mounted) return null;
    if (item == null) {
      showMessage(ctx, tr('Карточка в «Новых» — товар появится в «Моих товарах», когда Super Market её заполнит',
          'Kartochka «Yangilar»da — Super Market toʻldirgach, mahsulot «Mahsulotlarim»da paydo boʻladi'));
      return null;
    }
    await openNewItemReview(ctx, start, item);
    return null;
  }
}

/// Р7б · Ждём, пока Super Market заполнит карточку нового товара (до 2 минут).
class WaitCard extends StatefulWidget {
  const WaitCard({super.key, required this.start, required this.id});

  final StartApi start;
  final String id;

  @override
  State<WaitCard> createState() => _WaitCardState();
}

class _WaitCardState extends State<WaitCard> {
  Timer? _timer;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (++_ticks > 40) {
      _timer?.cancel();
      if (mounted) Navigator.pop(context);
      return;
    }
    try {
      final it = await widget.start.newItem(widget.id);
      if (!mounted) return;
      if (it['status'] != 'processing') {
        _timer?.cancel();
        Navigator.pop(context, it);
      }
    } catch (_) {
      // следующая попытка
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.white,
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        const CircularProgressIndicator(),
        const SizedBox(height: 18),
        Text(tr('Super Market заполняет карточку', 'Super Market kartochkani toʻldirmoqda'), style: AppText.bodyStrong, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(tr('Обычно до минуты. Потом проверите карточку — и товар сразу в приходе.', 'Odatda bir daqiqagacha. Keyin kartochkani tekshirasiz — mahsulot darhol kirimda.'),
            style: AppText.small, textAlign: TextAlign.center),
      ]),
      actions: [
        TextButton(
          onPressed: () {
            _timer?.cancel();
            Navigator.pop(context);
          },
          child: Text(tr('Не ждать', 'Kutmaslik')),
        ),
      ],
    );
  }
}
