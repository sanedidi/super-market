// «SM Магазин» · Поставщики-агенты (Figma «SM Магазин · поставщики»):
// М23 список и запросы, М24 подключить по коду, М25 найти поставщика.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../kassa/widgets.dart' show Keypad;
import '../main.dart' show showMessage;
import '../start/scanner.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'supplier_screen.dart';

/// Подпись поставщика: бренды, товаров, срок поставки.
String supplierLine(Map<String, dynamic> s) {
  final brands = ((s['brands'] as List?) ?? const []).cast<Object?>().map((e) => '$e').where((e) => e.isNotEmpty).toList();
  final lead = (s['lead_days'] as num?)?.toInt() ?? 0;
  return [
    if (brands.isNotEmpty) brands.take(2).join(', '),
    tr('${s['products_count'] ?? 0} товаров', '${s['products_count'] ?? 0} ta mahsulot'),
    if (lead > 0) tr('доставка $lead дн.', 'yetkazish $lead kun'),
  ].join(' · ');
}

/// М23 · Поставщики: запросы, подключённые, «По коду» и «Найти».
class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key});

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  List<Map<String, dynamic>>? _items;
  Object? _error;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    try {
      final items = await context.read<Api>().list('/store/suppliers', {'store_id': st.storeId});
      if (mounted) setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _answer(Map<String, dynamic> s, bool accept) async {
    setState(() => _busy = '${s['link_id']}');
    try {
      await context.read<Api>().post('/store/suppliers/links/${s['link_id']}/${accept ? 'accept' : 'reject'}');
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _open(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final items = _items;
    final requests = [for (final s in items ?? const <Map<String, dynamic>>[]) if (s['waits_for_me'] == true) s];
    final mine = [for (final s in items ?? const <Map<String, dynamic>>[]) if (s['waits_for_me'] != true) s];
    final active = [for (final s in mine) if (s['link_status'] == 'active') s];
    final waiting = [for (final s in mine) if (s['link_status'] != 'active') s];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Поставщики', 'Yetkazib beruvchilar')),
          Text('${st.store?['name'] ?? ''}', style: AppText.small),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Row(children: [
            Expanded(child: SmallButton(label: tr('По коду', 'Kod bilan'), icon: Icons.qr_code_scanner_rounded, onPressed: () => _open(const ConnectCodeScreen()))),
            const SizedBox(width: 10),
            Expanded(child: SmallButton(label: tr('Найти', 'Topish'), icon: Icons.search_rounded, primary: true, onPressed: () => _open(const FindSupplierScreen()))),
          ]),
          const SizedBox(height: 16),
          if (_error != null && items == null)
            EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          else if (items == null)
            const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
          else ...[
            for (final s in requests) ...[
              AppCard(
                color: AppColors.blueSoft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const IconBox(Icons.storefront_rounded, bg: AppColors.white, fg: AppColors.blue, size: 40, iconSize: 20, radius: 12),
                    const SizedBox(width: 12),
                    Expanded(child: Text(tr('${s['name']} хочет стать поставщиком', '${s['name']} yetkazib beruvchi boʻlmoqchi'), style: AppText.bodyStrong)),
                  ]),
                  if ('${s['message'] ?? ''}'.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('«${s['message']}»', style: AppText.small),
                  ],
                  const SizedBox(height: 4),
                  Text(supplierLine(s), style: AppText.small),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: BigButton(
                          label: tr('Отклонить', 'Rad etish'),
                          color: AppColors.white,
                          foreground: AppColors.ink,
                          height: 44,
                          onPressed: _busy == null ? () => _answer(s, false) : null),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: BigButton(
                          label: tr('Принять', 'Qabul qilish'),
                          icon: Icons.check_rounded,
                          height: 44,
                          busy: _busy == '${s['link_id']}',
                          onPressed: _busy == null ? () => _answer(s, true) : null),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 12),
            ],
            if (active.isEmpty && waiting.isEmpty && requests.isEmpty)
              EmptyState(
                icon: Icons.local_shipping_outlined,
                title: tr('Поставщиков пока нет', 'Hozircha yetkazib beruvchilar yoʻq'),
                text: tr('Попросите агента показать код или найдите, кто возит нужный товар рядом.',
                    'Agentdan kodni koʻrsatishini soʻrang yoki yaqinda kerakli tovarni kim olib kelishini toping.'),
              ),
            if (active.isNotEmpty) ...[
              Text(tr('Подключённые · ${active.length}', 'Ulangan · ${active.length}'), style: AppText.title),
              const SizedBox(height: 10),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(children: [
                  for (final (i, s) in active.indexed) ...[
                    if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                    _SupplierTile(s: s, onTap: () => _open(DistSupplierScreen(id: '${s['id']}'))),
                  ],
                ]),
              ),
              const SizedBox(height: 16),
            ],
            if (waiting.isNotEmpty) ...[
              Text(tr('Ждём ответа', 'Javob kutilmoqda'), style: AppText.title),
              const SizedBox(height: 10),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(children: [
                  for (final s in waiting) _SupplierTile(s: s, onTap: null),
                ]),
              ),
              const SizedBox(height: 16),
            ],
            AppCard(
              color: AppColors.successSoft,
              padding: const EdgeInsets.all(14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline_rounded, size: 20, color: AppColors.successInk),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      tr('Поставщик видит остатки только своих товаров в вашем магазине. Отключить можно в любой момент',
                          'Yetkazib beruvchi doʻkoningizda faqat oʻz mahsulotlari qoldigʻini koʻradi. Istalgan vaqtda uzish mumkin'),
                      style: AppText.small.copyWith(color: AppColors.successInk)),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

class _SupplierTile extends StatelessWidget {
  const _SupplierTile({required this.s, required this.onTap});

  final Map<String, dynamic> s;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final open = (s['open_orders'] as num?)?.toInt() ?? 0;
    final pending = (s['pending_payments'] as num?)?.toInt() ?? 0;
    final disputed = (s['disputed_payments'] as num?)?.toInt() ?? 0;
    Widget? chip;
    if (disputed > 0) {
      chip = StatusChip(tr('Расхождение', 'Farq bor'), tone: ChipTone.red);
    } else if (open > 0) {
      chip = StatusChip(tr('Заказ в пути', 'Buyurtma yoʻlda'), tone: ChipTone.amber);
    } else if (pending > 0) {
      chip = StatusChip(tr('Оплата ждёт', 'Toʻlov kutmoqda'), tone: ChipTone.amber);
    } else if (s['link_status'] == 'requested') {
      chip = StatusChip(tr('Ждём ответа', 'Javob kutilmoqda'));
    }
    return ListTile(
      onTap: onTap,
      leading: const IconBox(Icons.local_shipping_rounded, bg: AppColors.successSoft, fg: AppColors.successInk, size: 40, iconSize: 20, radius: 12),
      title: Text('${s['name']}', style: AppText.bodyStrong),
      subtitle: Text(supplierLine(s), style: AppText.small),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (chip != null) chip,
        if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
      ]),
    );
  }
}

/// М24 · Подключить по коду: 4 цифры с экрана агента или его QR.
class ConnectCodeScreen extends StatefulWidget {
  const ConnectCodeScreen({super.key});

  @override
  State<ConnectCodeScreen> createState() => _ConnectCodeScreenState();
}

class _ConnectCodeScreenState extends State<ConnectCodeScreen> {
  String _code = '';
  bool _busy = false;
  String? _error;

  void _key(String k) {
    setState(() {
      _error = null;
      if (k == '⌫') {
        if (_code.isNotEmpty) _code = _code.substring(0, _code.length - 1);
      } else if (RegExp(r'^\d$').hasMatch(k) && _code.length < 4) {
        _code += k;
      }
    });
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _LinkQrScreen()));
    if (code == null || !mounted) return;
    setState(() => _code = code);
    await _connect();
  }

  Future<void> _connect() async {
    if (_code.length != 4) return;
    final st = context.read<StoreState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final link = await context.read<Api>().post('/store/suppliers/connect', {'store_id': st.storeId, 'code': _code}) as Map<String, dynamic>;
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop();
      showMessage(nav.context, tr('${link['distributor_name']} подключён — можно заказывать', '${link['distributor_name']} ulandi — buyurtma berish mumkin'));
      await nav.push(MaterialPageRoute<void>(builder: (_) => DistSupplierScreen(id: '${link['distributor_id']}')));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget box(int i) {
      final filled = i < _code.length;
      return Container(
        width: 64,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: i == _code.length ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Text(filled ? _code[i] : '', style: AppText.h2),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Подключить по коду', 'Kod bilan ulash')),
          Text(tr('Попросите агента показать код', 'Agentdan kodni koʻrsatishini soʻrang'), style: AppText.small),
        ]),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < 4; i++) ...[if (i > 0) const SizedBox(width: 12), box(i)],
            ]),
            const SizedBox(height: 12),
            Text(_error ?? tr('Код действует 10 минут', 'Kod 10 daqiqa amal qiladi'),
                style: AppText.small.copyWith(color: _error == null ? AppColors.text2 : AppColors.error), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            SmallButton(label: tr('Сканировать QR', 'QR skanerlash'), icon: Icons.qr_code_scanner_rounded, onPressed: _busy ? null : _scan),
            const Spacer(),
            Keypad(onKey: _key, extra: ''),
            const SizedBox(height: 12),
            BigButton(label: tr('Подключить', 'Ulash'), icon: Icons.link_rounded, busy: _busy, onPressed: _code.length == 4 ? _connect : null),
          ]),
        ),
      ),
    );
  }
}

/// QR агента: «smlink:1234» — возвращает 4 цифры.
class _LinkQrScreen extends StatefulWidget {
  const _LinkQrScreen();

  @override
  State<_LinkQrScreen> createState() => _LinkQrScreenState();
}

class _LinkQrScreenState extends State<_LinkQrScreen> {
  late final MobileScannerController _scanner = barcodeScanner(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue?.trim() ?? '';
    final m = RegExp(r'^smlink:(\d{4})$').firstMatch(raw) ?? RegExp(r'^(\d{4})$').firstMatch(raw);
    if (m == null) return;
    _done = true;
    Navigator.of(context).pop(m.group(1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(tr('QR с экрана агента', 'Agent ekranidagi QR')),
      ),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(controller: _scanner, onDetect: _onDetect),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(24)),
          ),
        ),
      ]),
    );
  }
}

/// М25 · Найти поставщика по товару или бренду рядом с магазином.
class FindSupplierScreen extends StatefulWidget {
  const FindSupplierScreen({super.key, this.query = ''});

  final String query;

  @override
  State<FindSupplierScreen> createState() => _FindSupplierScreenState();
}

class _FindSupplierScreenState extends State<FindSupplierScreen> {
  late final _q = TextEditingController(text: widget.query);
  List<Map<String, dynamic>>? _items;
  Object? _error;
  String? _busy;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final st = context.read<StoreState>();
    final seq = ++_seq;
    try {
      final items = await context.read<Api>().list('/store/suppliers/search', {'store_id': st.storeId, 'q': _q.text.trim()});
      if (mounted && seq == _seq) setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    }
  }

  Future<void> _request(Map<String, dynamic> s) async {
    final st = context.read<StoreState>();
    setState(() => _busy = '${s['id']}');
    try {
      await context.read<Api>().post('/store/suppliers/${s['id']}/request', {'store_id': st.storeId});
      if (mounted) showMessage(context, tr('Запрос отправлен — агент ответит в приложении', 'Soʻrov yuborildi — agent ilovada javob beradi'));
      await _search();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Найти поставщика', 'Yetkazib beruvchini topish')),
          Text(tr('Кто возит товар рядом с вами', 'Yaqiningizda kim tovar olib keladi'), style: AppText.small),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        TextField(
          controller: _q,
          autofocus: widget.query.isEmpty,
          textInputAction: TextInputAction.search,
          onChanged: (_) => _search(),
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Товар или бренд', 'Mahsulot yoki brend')),
        ),
        const SizedBox(height: 14),
        if (_error != null && items == null)
          EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _search)
        else if (items == null)
          const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
        else if (items.isEmpty)
          EmptyState(
            icon: Icons.travel_explore_rounded,
            title: tr('Никого не нашли', 'Hech kim topilmadi'),
            text: tr('Рядом пока нет агентов с таким товаром.', 'Yaqinda bunday tovarli agentlar hozircha yoʻq.'),
          )
        else
          for (final s in items) ...[
            _FoundCard(s: s, busy: _busy == '${s['id']}', onRequest: _busy == null ? () => _request(s) : null, onOpen: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DistSupplierScreen(id: '${s['id']}')));
              if (mounted) _search();
            }),
            const SizedBox(height: 10),
          ],
      ]),
    );
  }
}

class _FoundCard extends StatelessWidget {
  const _FoundCard({required this.s, required this.busy, required this.onRequest, required this.onOpen});

  final Map<String, dynamic> s;
  final bool busy;
  final VoidCallback? onRequest;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final status = '${s['link_status']}';
    final km = s['distance_km'];
    final matched = (s['matched'] as num?)?.toInt() ?? 0;
    final examples = ((s['examples'] as List?) ?? const []).map((e) => '$e').toList();
    final line = [
      if (km is num) tr('${km.toString().replaceAll('.', ',')} км', '${km.toString().replaceAll('.', ',')} km'),
      tr('${s['products_count'] ?? 0} товаров', '${s['products_count'] ?? 0} ta mahsulot'),
      if (matched > 0) tr('совпало $matched', '$matched ta mos'),
    ].join(' · ');
    return AppCard(
      onTap: status == 'active' ? onOpen : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBox(Icons.local_shipping_rounded, bg: AppColors.successSoft, fg: AppColors.successInk, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s['name']}', style: AppText.bodyStrong),
              Text(line, style: AppText.small),
            ]),
          ),
          if (status == 'active')
            StatusChip(tr('Подключён', 'Ulangan'), tone: ChipTone.green)
          else if (status == 'requested')
            StatusChip(s['waits_for_me'] == true ? tr('Ждёт вас', 'Sizni kutmoqda') : tr('Ждём ответа', 'Javob kutilmoqda'), tone: ChipTone.amber),
        ]),
        if (examples.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(examples.join(' · '), style: AppText.small.copyWith(color: AppColors.ink)),
        ],
        if (status != 'active' && status != 'requested') ...[
          const SizedBox(height: 12),
          BigButton(label: tr('Подключить', 'Ulash'), icon: Icons.send_rounded, height: 44, busy: busy, onPressed: onRequest),
        ],
      ]),
    );
  }
}
