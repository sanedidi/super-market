import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../receipt/receipt_logic.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'camera_screen.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// М5 · «Инвентаризация: Начало работы» — шаг 2. По каждому товару
/// «Моих товаров»: количество и цена продажи (обязательны, можно 0),
/// себестоимость — по желанию. Значения сохраняются при уходе из поля.
/// «Сохранить» — черновик; «Записать и закрыть» — остатки и цены магазина,
/// после этого «Начало работы» больше не показывается.
/// В режиме «Только товары и цены» (v5, Н2) — «Товары и цены»: количество не
/// нужно (у товаров «Остаток не посчитан»), кнопка «Начать продавать».
/// В «Сразу с остатками» — ещё «Остальное посчитаю потом» (Н4).
class StartCountScreen extends StatefulWidget {
  const StartCountScreen({super.key, required this.start, this.initialScan = false});

  final StartApi start;

  /// Сразу открыть сканер (нажали «Штрихкод» в блоке на главной на шаге 2).
  final bool initialScan;

  @override
  State<StartCountScreen> createState() => _StartCountScreenState();
}

class _StartCountScreenState extends State<StartCountScreen> {
  Map<String, dynamic>? _d;
  Object? _error;
  String? _only;
  String? _query;
  bool _busy = false;
  final _q = TextEditingController();
  // Сохранения полей, которые ещё идут.
  final _pending = <Future<void>>{};
  // Пока Super Market делает фото строк — обновляем список.
  Timer? _photoPoll;

  @override
  void initState() {
    super.initState();
    // Магазин на шаге 2: теперь «Штрихкод» на главной открывает инвентаризацию.
    widget.start.setStep(2).catchError((_) {});
    // Сканер — после черновика: шторке нужно знать режим (спрашивать ли количество).
    _load().then((_) {
      if (widget.initialScan && mounted) _scan();
    });
  }

  @override
  void dispose() {
    _q.dispose();
    _photoPoll?.cancel();
    super.dispose();
  }

  void _watchPhotos() {
    final lines = (_d?['lines'] as List?) ?? const [];
    final work = lines.any((l) => l is Map && l['photo'] == 'processing');
    if (work) {
      _photoPoll ??= Timer.periodic(const Duration(seconds: 5), (_) {
        if (_pending.isEmpty) _load();
      });
    } else {
      _photoPoll?.cancel();
      _photoPoll = null;
    }
  }

  /// Сканер поверх камеры: найденный товар открывает шторку количества и цен.
  Future<void> _scan() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => StartCameraScreen(start: widget.start, mode: StartMode.barcode, inventory: true)),
    );
    if (mounted) _load();
  }

  /// Поиск: штрихкод — сразу шторка, название — фильтр по товарам документа.
  Future<void> _find(String text) async {
    final t = text.trim();
    if (t.isEmpty) {
      setState(() => _query = null);
      _load();
      return;
    }
    if (!RegExp(r'^[0-9]{6,14}$').hasMatch(t)) {
      setState(() => _query = t);
      _load();
      return;
    }
    try {
      final r = await widget.start.scan(t);
      if (!mounted) return;
      final l = r['line'];
      if (l is Map) {
        await countSheet(context, widget.start, l.cast<String, dynamic>());
        if (!mounted) return;
        _q.clear();
        _load();
        return;
      }
      showMessage(context, tr('Штрихкода $t нет в этом документе — отсканируйте его камерой', '$t shtrix-kodi bu hujjatda yoʻq — uni kamera bilan skanerlang'));
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  /// Открыть шторку количества и цен по строке списка.
  Future<void> _open(Map<String, dynamic> line) async {
    await _flush();
    if (!mounted) return;
    await countSheet(context, widget.start, line);
    if (mounted) _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.start.draft(only: _only, q: _query, limit: 1000);
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
        _watchPhotos();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic> get _t => (_d?['totals'] as Map<String, dynamic>?) ?? const {};
  bool get _prices => pricesMode(_d);
  int _n(String k) => (_t[k] as num?)?.toInt() ?? 0;

  Future<void> _filter(String? only) async {
    await _flush();
    if (!mounted) return;
    setState(() => _only = only);
    _load();
  }

  void _track(Future<void> f) {
    _pending.add(f);
    f.whenComplete(() => _pending.remove(f));
  }

  /// Строка сохранена: обновить её и итоги, не перестраивая список.
  void _saved(Map<String, dynamic> r) {
    final d = _d;
    if (!mounted || d == null) return;
    final lines = ((d['lines'] as List?) ?? const []).cast<Map<String, dynamic>>().toList();
    for (final l in ((r['lines'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final i = lines.indexWhere((x) => x['product_id'] == l['product_id']);
      if (i >= 0) lines[i] = l;
    }
    setState(() => _d = {...d, 'lines': lines, if (r['totals'] != null) 'totals': r['totals']});
  }

  Future<void> _remove(Map<String, dynamic> l) async {
    try {
      await widget.start.deleteLine('${l['product_id']}');
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
    _load();
  }

  /// Уйти из поля и дождаться всех начатых сохранений.
  Future<void> _flush() async {
    FocusScope.of(context).unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await Future.wait(_pending.toList());
  }

  Future<void> _save() async {
    await _flush();
    await _load();
    if (mounted) showMessage(context, tr('Черновик сохранён — можно вернуться к нему позже', 'Qoralama saqlandi — keyinroq unga qaytish mumkin'));
  }

  Future<void> _post() async {
    await _flush();
    await _load();
    if (!mounted || _d == null) return;
    final unfilled = _n('unfilled');
    if (unfilled > 0) {
      showMessage(
          context,
          _prices
              ? tr('Укажите ${sellPriceWord().toLowerCase()}: без неё ${goods(unfilled)}', '${sellPriceWord()}ni kiriting: usiz ${goods(unfilled)}')
              : tr('Заполните строк: $unfilled — количество и ${sellPriceWord().toLowerCase()} обязательны', 'Toʻldiring: $unfilled ta qator — miqdor va ${sellPriceWord().toLowerCase()} majburiy'));
      _filter('unfilled');
      return;
    }
    final d = _d!;
    final ok = _prices
        ? await confirmSheet(
            context,
            title: tr('Начать продавать?', 'Sotishni boshlaymizmi?'),
            text: tr(
                'Цены встанут в магазин, товары — в «Мои товары». У ${goods(_n('no_qty'))} — «Остаток не посчитан»: продавать можно, посчитаете потом с главной или при приходе.',
                'Narxlar doʻkonga, mahsulotlar «Mahsulotlarim»ga tushadi. ${goods(_n('no_qty'))}da — «Qoldiq sanalmagan»: sotish mumkin, keyin bosh sahifadan yoki kirimda sanaysiz.'),
            confirm: tr('Начать продавать', 'Sotishni boshlash'),
            icon: Icons.storefront_rounded,
          )
        : await confirmSheet(
      context,
      title: tr('Записать и закрыть?', 'Yozib, yopilsinmi?'),
      text: tr(
          'Остатки встанут на склад «${d['warehouse_name']}», цены продажи — в магазин. После этого «Начало работы» больше не появится: новые товары — приходом или инвентаризацией.'
              '${_n('no_cost') > 0 ? ' Без себестоимости: ${goods(_n('no_cost'))} — она будет 0.' : ''}',
          'Qoldiqlar «${d['warehouse_name']}» omboriga, sotish narxlari doʻkonga tushadi. Shundan soʻng «Ishni boshlash» boshqa chiqmaydi: yangi mahsulotlar — kirim yoki inventarizatsiya orqali.'
              '${_n('no_cost') > 0 ? ' Tannarxsiz: ${goods(_n('no_cost'))} — u 0 boʻladi.' : ''}'),
      confirm: tr('Записать и закрыть', 'Yozish va yopish'),
      icon: Icons.check_circle_outline_rounded,
    );
    if (!ok || !mounted) return;
    await _send(d);
  }

  Future<void> _send(Map<String, dynamic> d, {bool restLater = false}) async {
    setState(() => _busy = true);
    try {
      final r = await widget.start.post(restLater: restLater);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => StartDoneScreen(result: r, warehouse: '${d['warehouse_name']}')));
    } on ApiError catch (e) {
      if (!mounted) return;
      showMessage(context, e);
      if (e.code == 'lines_unfilled') _filter('unfilled');
      if (e.code == 'lines_no_photo') _filter('no_photo');
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Н4 · «Остальное посчитать потом?»: посчитанное сохранится, остальное —
  /// «Остаток не посчитан». Без цены и без фото не записать.
  Future<void> _later() async {
    await _flush();
    await _load();
    if (!mounted || _d == null) return;
    final d = _d!;
    final noQty = _n('no_qty');
    final noPrice = _n('no_price');
    final noPhoto = _n('no_photo');
    final counted = _n('products') - noQty;
    Widget row(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: AppText.small.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500))),
          ]),
        );
    final blocked = noPrice > 0 || noPhoto > 0;
    final ok = await showSheet<bool>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetHeader(
          icon: Icons.schedule_rounded,
          title: tr('Остальное посчитать потом?', 'Qolganini keyin sanaymizmi?'),
          text: tr('Посчитанное сохранится, документ закроется. Остальные товары досчитаете по одному — без нового документа.',
              'Sanalgani saqlanadi, hujjat yopiladi. Qolgan mahsulotlarni bittadan, yangi hujjatsiz sanaysiz.'),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
          decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            row(Icons.check_circle_rounded, AppColors.successInk, tr('${goods(counted)} — остаток и цена сохранятся', '${goods(counted)} — qoldiq va narx saqlanadi')),
            if (noQty > 0) row(Icons.help_outline_rounded, AppColors.text2, tr('${goods(noQty)} — «Остаток не посчитан», продавать можно', '${goods(noQty)} — «Qoldiq sanalmagan», sotish mumkin')),
            if (noPrice > 0) row(Icons.error_outline_rounded, AppColors.error, tr('${goods(noPrice)} без цены — укажите цену, без неё не записать', '${goods(noPrice)} narxsiz — narx kiriting, usiz yozib boʻlmaydi')),
            if (noPhoto > 0) row(Icons.error_outline_rounded, AppColors.error, tr('${goods(noPhoto)} без фото — сделайте снимок', '${goods(noPhoto)} rasmsiz — rasmga oling')),
          ]),
        ),
        const SizedBox(height: 16),
        SheetButton(label: tr('Сохранить и начать продавать', 'Saqlash va sotishni boshlash'), onPressed: blocked ? null : () => Navigator.pop(ctx, true)),
        const SizedBox(height: 10),
        SheetButton(label: tr('Продолжить считать', 'Sanashni davom ettirish'), primary: false, onPressed: () => Navigator.pop(ctx, false)),
      ]),
    );
    if (ok != true || !mounted) {
      if (mounted && blocked) _filter(noPrice > 0 ? 'unfilled' : 'no_photo');
      return;
    }
    await _send(d, restLater: true);
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final prices = _prices;
    final lines = ((d?['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final products = _n('products');
    final unfilled = _n('unfilled');
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(prices ? tr('Товары и цены', 'Mahsulotlar va narxlar') : tr('Инвентаризация: Начало работы', 'Inventarizatsiya: Ishni boshlash'), maxLines: 2),
          if (d != null)
            Text(
                prices
                    ? tr('Шаг 2 из 2 · с ценой ${products - unfilled} из $products', '2-qadam · narx bilan ${products - unfilled} / $products')
                    : tr('Шаг 2 из 2 · заполнено ${products - unfilled} из $products', '2-qadam · toʻldirilgan ${products - unfilled} / $products'),
                style: AppText.small),
        ]),
      ),
      body: _error != null && d == null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: _error.toString(), action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  // Список строится лениво: с сотнями строк (у каждой — поля ввода
                  // и фото) всё сразу не помещалось в память и приложение закрывалось.
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: lines.length + 1,
                    itemBuilder: (_, index) {
                      if (index > 0) {
                        final l = lines[index - 1];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _CountCard(
                              key: ValueKey(l['product_id']),
                              line: l,
                              start: widget.start,
                              prices: prices,
                              onSaved: _saved,
                              onPending: _track,
                              onRemove: () => _remove(l),
                              onOpen: () => _open(l)),
                        );
                      }
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    StartSteps(step: 2, prices: prices),
                    const SizedBox(height: 12),
                    // И1 · тот же поиск и сканер, что при добавлении товара.
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _q,
                          textInputAction: TextInputAction.search,
                          onSubmitted: _find,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search_rounded, color: AppColors.muted),
                            hintText: tr('Штрихкод или название товара', 'Shtrix-kod yoki mahsulot nomi'),
                            suffixIcon: _q.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                                    onPressed: () {
                                      _q.clear();
                                      _find('');
                                    },
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: AppColors.ink,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _scan,
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Icon(Icons.qr_code_scanner_rounded, color: AppColors.white),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: AppColors.successSoft, borderRadius: BorderRadius.circular(14)),
                      child: Row(children: [
                        const Icon(Icons.qr_code_scanner_rounded, size: 20, color: AppColors.successInk),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                              prices
                                  ? tr('Сканируйте штрихкод — снизу откроется ввод цены. Количество не нужно', 'Shtrix-kodni skanerlang — pastdan narx kiritish ochiladi. Miqdor shart emas')
                                  : tr('Сканируйте штрихкод — снизу откроется ввод количества и цен', 'Shtrix-kodni skanerlang — pastdan miqdor va narx kiritish ochiladi'),
                              style: AppText.small.copyWith(color: AppColors.successInk, fontWeight: FontWeight.w500)),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    if (_n('no_photo') > 0 && !prices) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: AppColors.errorSoft, borderRadius: BorderRadius.circular(14)),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Icon(Icons.photo_camera_rounded, color: AppColors.primary, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                                tr('Без фото: ${goods(_n('no_photo'))} — покупатель их не увидит, документ не запишется. Откройте товар и сделайте фото.',
                                    'Rasmsiz: ${goods(_n('no_photo'))} — xaridor ularni koʻrmaydi, hujjat yozilmaydi. Mahsulotni ochib, rasmga oling.'),
                                style: AppText.small.copyWith(color: AppColors.error, fontWeight: FontWeight.w500)),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (unfilled > 0) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: AppColors.errorSoft, borderRadius: BorderRadius.circular(14)),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Icon(Icons.error_outline_rounded, color: AppColors.primary, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                                prices
                                    ? tr('Укажите цену у ${goods(unfilled)} — количество не нужно', '${goods(unfilled)}ga narx kiriting — miqdor shart emas')
                                    : tr('Заполните строк: $unfilled — количество и ${sellPriceWord().toLowerCase()} обязательны (можно 0)', 'Toʻldiring: $unfilled ta qator — miqdor va ${sellPriceWord().toLowerCase()} majburiy (0 boʻlishi mumkin)'),
                                style: AppText.small.copyWith(color: AppColors.error, fontWeight: FontWeight.w500)),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        _Chip(tr('Все · $products', 'Hammasi · $products'), on: _only == null, onTap: () => _filter(null)),
                        const SizedBox(width: 6),
                        _Chip(prices ? tr('Без цены · $unfilled', 'Narxsiz · $unfilled') : tr('Не заполнено · $unfilled', 'Toʻldirilmagan · $unfilled'),
                            on: _only == 'unfilled', tone: AppColors.error, onTap: () => _filter('unfilled')),
                        const SizedBox(width: 6),
                        _Chip(tr('Без закупки · ${_n('no_cost')}', 'Xarid narxisiz · ${_n('no_cost')}'), on: _only == 'no_cost', tone: AppColors.warningInk, onTap: () => _filter('no_cost')),
                        if (!prices) ...[
                          const SizedBox(width: 6),
                          _Chip(tr('Без фото · ${_n('no_photo')}', 'Rasmsiz · ${_n('no_photo')}'), on: _only == 'no_photo', tone: AppColors.error, onTap: () => _filter('no_photo')),
                        ],
                      ]),
                    ),
                    const SizedBox(height: 12),
                    if (lines.isEmpty)
                      Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(_only == null && _query == null ? tr('Нет товаров — добавьте их на шаге 1', 'Mahsulotlar yoʻq — ularni 1-qadamda qoʻshing') : tr('Таких товаров нет', 'Bunday mahsulotlar yoʻq'), style: AppText.small)),
                      ]);
                    },
                  ),
                ),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Expanded(
                      flex: 2,
                      child: BigButton(label: tr('Сохранить', 'Saqlash'), icon: Icons.save_rounded, color: AppColors.soft, foreground: AppColors.ink, height: 52, onPressed: _busy ? null : _save),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 3,
                      child: BigButton(
                          label: prices ? tr('Начать продавать', 'Sotishni boshlash') : tr('Записать и закрыть', 'Yozish va yopish'),
                          height: 52,
                          busy: _busy,
                          onPressed: products == 0 ? null : _post),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  if (prices)
                    Text(tr('Остатки посчитаете потом — это не обязательно сейчас', 'Qoldiqlarni keyin sanaysiz — hozir shart emas'), style: AppText.small)
                  else
                    TextButton(
                      onPressed: products == 0 || _busy ? null : _later,
                      child: Text(tr('Остальное посчитаю потом', 'Qolganini keyin sanayman'), style: AppText.bodyStrong.copyWith(fontSize: 14, color: AppColors.primary)),
                    ),
                ]),
              ),
            ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, {required this.on, required this.onTap, this.tone = AppColors.ink});

  final String label;
  final bool on;
  final Color tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: on ? AppColors.ink : AppColors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(label, style: AppText.caption.copyWith(fontSize: 13, color: on ? AppColors.white : tone)),
        ),
      ),
    );
  }
}

/// Карточка товара: название целиком, штрихкод; поля «Кол-во *», «Себестоимость»,
/// «Цена продажи *». Поле сохраняется, когда из него уходят.
class _CountCard extends StatefulWidget {
  const _CountCard(
      {super.key, required this.line, required this.start, this.prices = false, required this.onSaved, required this.onPending, required this.onRemove, required this.onOpen});

  final Map<String, dynamic> line;
  final StartApi start;

  /// «Только товары и цены»: «Остаток» необязателен — пусто значит «не посчитан».
  final bool prices;
  final ValueChanged<Map<String, dynamic>> onSaved;

  /// Открыть шторку количества и цен (там же — фото, если его нет).
  final VoidCallback onOpen;

  /// Начатое сохранение — экран дождётся его перед «Сохранить» и «Записать».
  final ValueChanged<Future<void>> onPending;
  final VoidCallback onRemove;

  @override
  State<_CountCard> createState() => _CountCardState();
}

class _CountCardState extends State<_CountCard> {
  static const _fields = ['qty', 'cost', 'price'];
  late final Map<String, TextEditingController> _c = {for (final f in _fields) f: TextEditingController(text: plainQty(widget.line[f]))};
  late final Map<String, FocusNode> _focus = {for (final f in _fields) f: FocusNode()};

  /// Последнее отправленное значение поля (пока ответ сервера не пришёл).
  final Map<String, String?> _sent = {};

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      _focus[f]!.addListener(() {
        if (!_focus[f]!.hasFocus) widget.onPending(_commit(f));
      });
    }
  }

  @override
  void didUpdateWidget(_CountCard old) {
    super.didUpdateWidget(old);
    // Новое значение с сервера — в поле, если его сейчас не правят.
    for (final f in _fields) {
      if (!_focus[f]!.hasFocus && old.line[f] != widget.line[f]) _c[f]!.text = plainQty(widget.line[f]);
    }
  }

  @override
  void dispose() {
    for (final f in _fields) {
      _c[f]!.dispose();
      _focus[f]!.dispose();
    }
    super.dispose();
  }

  Future<void> _commit(String f) async {
    final text = _c[f]!.text.trim();
    final v = text.isEmpty ? null : parseNum(text);
    if (text.isNotEmpty && v == null) {
      showMessage(context, tr('Неверное число', 'Notoʻgʻri son'));
      _c[f]!.text = plainQty(widget.line[f]);
      return;
    }
    final cur = _sent.containsKey(f) ? _sent[f] : widget.line[f]?.toString();
    if ((v == null && cur == null) || (v != null && cur != null && num.tryParse(v) == num.tryParse(cur))) return;
    _sent[f] = v;
    try {
      final r = await widget.start.setLines([
        {'product_id': widget.line['product_id'], f: v},
      ]);
      _sent.remove(f);
      if (mounted) widget.onSaved(r);
    } catch (e) {
      _sent.remove(f);
      if (!mounted) return;
      showMessage(context, e);
      _c[f]!.text = plainQty(widget.line[f]);
    }
  }

  Widget _field(String f, String label, {required bool required, String? hint}) {
    final empty = _c[f]!.text.trim().isEmpty;
    final err = required && empty;
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.caption.copyWith(fontSize: 11)),
        const SizedBox(height: 4),
        TextField(
          controller: _c[f],
          focusNode: _focus[f],
          onChanged: (_) => setState(() {}),
          keyboardType: TextInputType.numberWithOptions(decimal: f != 'qty' || widget.line['is_fractional'] == true),
          textInputAction: TextInputAction.next,
          style: AppText.bodyStrong.copyWith(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: err ? AppColors.errorSoft : AppColors.bg,
            hintText: hint ?? (required ? tr('обязательно', 'majburiy') : tr('по желанию', 'ixtiyoriy')),
            hintStyle: AppText.small.copyWith(fontSize: 13, color: err ? AppColors.error : AppColors.muted),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: err ? const BorderSide(color: AppColors.primary, width: 1.5) : BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.ink, width: 1.5)),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    final unit = (l['unit_short'] as String?) ?? tr('шт', 'dona');
    final img = l['image'];
    // Без фото продавать можно в режиме цен — фото только для витрины.
    final noPhoto = (img == null || '$img'.isEmpty) && !widget.prices;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          noPhoto
              ? Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.errorSoft,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary, width: 1.5),
                  ),
                  child: const Icon(Icons.photo_camera_rounded, size: 20, color: AppColors.primary),
                )
              : ProductThumb(l['image'] as String?, size: 44, badge: l['photo']),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${l['name']}', style: AppText.bodyStrong.copyWith(fontSize: 14)),
              Text(
                  noPhoto
                      ? tr('нужно фото товара', 'mahsulot rasmi kerak')
                      : '${l['barcode'] ?? tr('без штрихкода', 'shtrix-kodsiz')}',
                  style: AppText.small.copyWith(fontSize: 12, color: noPhoto ? AppColors.error : null)),
            ]),
          ),
          IconButton(
              tooltip: noPhoto ? tr('Сделать фото', 'Rasmga olish') : tr('Количество и цены', 'Miqdor va narxlar'),
              icon: Icon(noPhoto ? Icons.add_a_photo_rounded : Icons.edit_note_rounded, color: noPhoto ? AppColors.primary : AppColors.text2),
              onPressed: widget.onOpen),
          IconButton(tooltip: tr('Убрать', 'Olib tashlash'), icon: const Icon(Icons.delete_outline_rounded, color: AppColors.text2), onPressed: widget.onRemove),
        ]),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            widget.prices
                ? _field('qty', tr('Остаток, $unit', 'Qoldiq, $unit'), required: false, hint: tr('не посчитан', 'sanalmagan'))
                : _field('qty', tr('Кол-во, $unit *', 'Miqdor, $unit *'), required: true),
            const SizedBox(width: 8),
            _field('cost', tr('Цена закупки', 'Xarid narxi'), required: false),
            const SizedBox(width: 8),
            _field('price', '${sellPriceWord()} *', required: true),
          ]),
        ),
      ]),
    );
  }
}

/// Н10 · Магазин готов к работе.
class StartDoneScreen extends StatelessWidget {
  const StartDoneScreen({super.key, required this.result, required this.warehouse});

  final Map<String, dynamic> result;
  final String warehouse;

  @override
  Widget build(BuildContext context) {
    final r = result;
    int n(String k) => (r[k] as num?)?.toInt() ?? 0;
    final docs = ((r['documents'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final price = r['price_document'] as Map<String, dynamic>?;
    Widget row(String l, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(l, style: AppText.body)),
            Text(v, style: AppText.bodyStrong),
          ]),
        );
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 80, 24, 24), children: [
          const Center(child: IconBox(Icons.check_circle_rounded, bg: AppColors.successSoft, fg: AppColors.success, size: 96, iconSize: 56, radius: 48)),
          const SizedBox(height: 20),
          Text(tr('Магазин готов к работе', 'Doʻkon ishga tayyor'), style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            n('uncounted') > 0
                ? tr('${goods(n('products'))} в товарах магазина. У ${n('uncounted')} — «Остаток не посчитан»: продавать можно, посчитаете потом с главной.',
                    'Doʻkon mahsulotlarida ${goods(n('products'))}. ${n('uncounted')} tasida — «Qoldiq sanalmagan»: sotish mumkin, keyin bosh sahifadan sanaysiz.')
                : tr(
                '${goods(n('products'))} в товарах магазина, остатки — на складе «$warehouse». ${n('visible')} уже видят покупатели'
                    '${n('pending') > 0 ? ', ${n('pending')} новых — после модерации' : ''}.',
                'Doʻkon mahsulotlarida ${goods(n('products'))}, qoldiqlar — «$warehouse» omborida. Ulardan ${n('visible')} tasini xaridorlar allaqachon koʻrmoqda'
                    '${n('pending') > 0 ? ', ${n('pending')} ta yangisi — moderatsiyadan keyin' : ''}.'),
            style: AppText.small,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (docs.isNotEmpty || price != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(16)),
              child: Column(children: [
                for (final doc in docs) row(tr('Оприходование № ${doc['number']}', 'Kirim № ${doc['number']}'), docs.length == 1 ? money(r['cost_total']) : ''),
                if (price != null) row(tr('Установка цен № ${price['number']}', 'Narx belgilash № ${price['number']}'), tr('проведена', 'oʻtkazildi')),
              ]),
            ),
          const SizedBox(height: 12),
          Text(tr('Новые товары дальше — приходом или инвентаризацией.', 'Yangi mahsulotlar endi — kirim yoki inventarizatsiya orqali.'), style: AppText.small, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          BigButton(label: tr('На главную', 'Bosh sahifaga'), onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst)),
        ]),
      ),
    );
  }
}
