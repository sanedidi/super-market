import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'document_screen.dart';
import 'logic.dart';
import 'payments.dart';
import 'ui.dart';

/// Д3 · Магазин: чего не хватает и чего нет на полке → расход одной кнопкой.
/// Д11 · Магазин не подключён: только адрес и «Договориться».
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key, required this.storeId});

  final String storeId;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  Map<String, dynamic>? _s;
  Map<String, dynamic>? _money;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = context.read<Api>();
      final s = await api.get('/store/supply/stores/${widget.storeId}') as Map<String, dynamic>;
      // Долг и оплаты — для подключённого магазина (и бывшего: долг остаётся).
      Map<String, dynamic>? stmt;
      if (s['link_status'] == 'active') {
        try {
          stmt = await api.get('/store/supply/stores/${widget.storeId}/statement') as Map<String, dynamic>;
        } catch (_) {
          stmt = null;
        }
      }
      if (mounted) {
        setState(() {
          _s = s;
          _money = stmt;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _shipment() async {
    setState(() => _busy = true);
    try {
      final doc = await context.read<Api>().post('/store/supply/stores/${widget.storeId}/shipment') as Map<String, dynamic>;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(id: '${doc['id']}')));
      if (mounted) _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _agree() async {
    final s = _s!;
    final res = await showSheet<String>(context, (ctx) => _AgreeSheet(storeName: '${s['name']}'));
    if (res == null || !mounted) return;
    if (res == _AgreeSheet.code) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CodeScreen(storeId: widget.storeId, storeName: '${s['name']}')));
    } else {
      try {
        await context.read<Api>().post('/store/supply/stores/${widget.storeId}/request', {'message': res.substring(_AgreeSheet.request.length)});
        if (mounted) showMessage(context, tr('Запрос отправлен — магазин получит уведомление', 'Soʻrov yuborildi — doʻkon xabarnoma oladi'));
      } catch (e) {
        if (mounted) showMessage(context, e);
      }
    }
    if (mounted) _load();
  }

  Future<void> _answer(bool accept) async {
    final link = _s?['link'] as Map<String, dynamic>?;
    if (link == null) return;
    try {
      await context.read<Api>().post('/store/supply/links/${link['id']}/${accept ? 'accept' : 'reject'}');
      if (mounted) _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  Future<void> _disconnect() async {
    final ok = await confirmSheet(context,
        title: tr('Отключиться от магазина?', 'Doʻkondan uzilasizmi?'),
        text: tr('Перестанете видеть его остатки, незакрытые заказы отменятся. Документы останутся.', 'Uning qoldiqlarini koʻrmay qolasiz, yopilmagan buyurtmalar bekor boʻladi. Hujjatlar qoladi.'),
        confirm: tr('Отключиться', 'Uzilish'),
        icon: Icons.link_off_rounded);
    if (!ok || !mounted) return;
    try {
      await context.read<Api>().post('/store/supply/stores/${widget.storeId}/disconnect');
      if (mounted) _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final linked = s?['link_status'] == 'active';
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${s?['name'] ?? ''}', style: AppText.title),
          if (s != null)
            Text([if ('${s['address']}'.isNotEmpty) '${s['address']}', if (s['distance_km'] != null) '${qty(s['distance_km'])} км'].join(' · '), style: AppText.small),
        ]),
        actions: [
          if (linked && '${s?['phone'] ?? ''}'.isNotEmpty) IconButton(icon: const Icon(Icons.call_rounded), onPressed: () => callPhone(s?['phone'])),
          if (linked)
            PopupMenuButton<String>(
              onSelected: (_) => _disconnect(),
              itemBuilder: (_) => [PopupMenuItem(value: 'off', child: Text(tr('Отключиться', 'Uzilish')))],
            ),
        ],
      ),
      bottomNavigationBar: s == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: linked ? _linkedBottom(s) : _notLinkedBottom(s),
              ),
            ),
      body: _error != null && s == null
          ? LoadError(_error!, onRetry: _load)
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: linked ? _linked(s) : _notLinked(s),
                  ),
                ),
    );
  }

  Widget _linkedBottom(Map<String, dynamic> s) {
    final n = (s['lacking'] as List? ?? const []).length;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      BigButton(
        label: n > 0 ? tr('Сформировать расход · $n поз.', 'Chiqim tuzish · $n ta') : tr('Новый расход', 'Yangi chiqim'),
        icon: Icons.local_shipping_rounded,
        busy: _busy,
        onPressed: n > 0
            ? _shipment
            : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DocumentScreen.create(type: 'shipment', toStore: {'id': widget.storeId, 'name': s['name']}))),
      ),
      if (n > 0) ...[
        const SizedBox(height: 6),
        Text(tr('Количество подставим из рекомендаций — поправите перед проведением', 'Miqdor tavsiyalardan qoʻyiladi — oʻtkazishdan oldin tuzatasiz'),
            style: AppText.small, textAlign: TextAlign.center),
      ],
    ]);
  }

  Widget _notLinkedBottom(Map<String, dynamic> s) {
    final link = s['link'] as Map<String, dynamic>?;
    if (link != null && link['status'] == 'requested' && link['waits_for_me'] == true) {
      return Row(children: [
        Expanded(child: BigButton(label: tr('Отклонить', 'Rad etish'), color: AppColors.soft, foreground: AppColors.ink, onPressed: () => _answer(false))),
        const SizedBox(width: 10),
        Expanded(flex: 2, child: BigButton(label: tr('Принять', 'Qabul qilish'), icon: Icons.check_rounded, onPressed: () => _answer(true))),
      ]);
    }
    return BigButton(label: tr('Договориться', 'Kelishish'), icon: Icons.handshake_rounded, onPressed: _agree);
  }

  List<Widget> _notLinked(Map<String, dynamic> s) {
    final link = s['link'] as Map<String, dynamic>?;
    final requested = link?['status'] == 'requested';
    final waitsForMe = link?['waits_for_me'] == true;
    return [
      AppCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBox(requested ? Icons.hourglass_top_rounded : Icons.lock_outline_rounded,
              bg: requested ? AppColors.blueSoft : AppColors.soft, fg: requested ? AppColors.blue : AppColors.text2, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  waitsForMe
                      ? tr('Магазин просит подключиться', 'Doʻkon ulanishni soʻrayapti')
                      : requested
                          ? tr('Запрос отправлен — ждём магазин', 'Soʻrov yuborildi — doʻkonni kutyapmiz')
                          : tr('Магазин вас ещё не подключил', 'Doʻkon sizni hali ulamagan'),
                  style: AppText.bodyStrong),
              const SizedBox(height: 2),
              Text(
                  waitsForMe
                      ? tr('Примите — и увидите остатки ваших товаров в магазине.', 'Qabul qiling — va doʻkondagi mahsulotlaringiz qoldigʻini koʻrasiz.')
                      : tr('Остатки, продажи и телефон станут видны, когда владелец магазина подтвердит связь.',
                          'Doʻkon egasi aloqani tasdiqlaganda qoldiqlar, sotuvlar va telefon koʻrinadi.'),
                  style: AppText.small),
              if ('${link?['message'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
                  child: Text('«${link!['message']}»', style: AppText.small.copyWith(color: AppColors.ink)),
                ),
              ],
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Как договориться', 'Qanday kelishish'), style: AppText.bodyStrong),
          const SizedBox(height: 10),
          _HowRow(icon: Icons.qr_code_2_rounded, title: tr('Вы в магазине', 'Siz doʻkondasiz'),
              text: tr('Покажите код владельцу — он введёт его в «SM Магазин», и связь сразу активна', 'Kodni egasiga koʻrsating — u «SM Doʻkon»ga kiritadi va aloqa darhol faollashadi')),
          const SizedBox(height: 10),
          _HowRow(icon: Icons.send_rounded, title: tr('Удалённо', 'Masofadan'),
              text: tr('Отправьте запрос с условиями — магазин подтвердит в приложении', 'Shartlar bilan soʻrov yuboring — doʻkon ilovada tasdiqlaydi')),
        ]),
      ),
    ];
  }

  /// Долг магазина, оплаты, которые ждут ответа, и акт сверки.
  Widget _debtCard(Map<String, dynamic> s, Map<String, dynamic> m) {
    final open = (m['open'] as List? ?? const []).cast<Map<String, dynamic>>();
    final pendingSum = double.tryParse('${m['pending_sum']}') ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Долг магазина', 'Doʻkon qarzi'), style: AppText.small),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(money(m['debt'], suffix: false), style: AppText.h2),
            const SizedBox(width: 6),
            Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(tr('сум', 'soʻm'), style: AppText.body.copyWith(color: AppColors.text2))),
          ]),
          if (pendingSum > 0)
            Text(tr('${money(m['pending_sum'])} магазин отдал — ждёт вашего подтверждения', '${money(m['pending_sum'])} ni doʻkon berdi — tasdiqlashingizni kutmoqda'),
                style: AppText.small.copyWith(color: AppColors.warningInk)),
          const SizedBox(height: 10),
          BigButton(
            label: tr('Акт сверки', 'Solishtirma dalolatnoma'),
            icon: Icons.description_outlined,
            color: AppColors.soft,
            foreground: AppColors.ink,
            height: 44,
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StatementScreen(storeId: widget.storeId, storeName: '${s['name']}')));
              if (mounted) _load();
            },
          ),
        ]),
      ),
      for (final p in open) ...[
        const SizedBox(height: 10),
        PaymentCard(payment: p, onChanged: _load, showStore: false),
      ],
    ]);
  }

  List<Widget> _linked(Map<String, dynamic> s) {
    final lacking = (s['lacking'] as List? ?? const []).cast<Map<String, dynamic>>();
    final missing = (s['missing'] as List? ?? const []).cast<Map<String, dynamic>>();
    final ships = (s['shipments'] as List? ?? const []).cast<Map<String, dynamic>>();
    return [
      Row(children: [
        Expanded(child: StatTile(label: tr('Последний заказ', 'Oxirgi buyurtma'), value: daysAgo(s['last_order_at'], DateTime.now()), bg: AppColors.white)),
        const SizedBox(width: 8),
        Expanded(child: StatTile(label: tr('Ваших товаров', 'Mahsulotlaringiz'), value: '${s['carried_count']}', bg: AppColors.white)),
        const SizedBox(width: 8),
        Expanded(child: StatTile(label: tr('За 30 дней', '30 kunda'), value: money(s['month_sum'], suffix: false), bg: AppColors.white)),
      ]),
      const SizedBox(height: 12),
      if (_money != null) ...[
        _debtCard(s, _money!),
        const SizedBox(height: 12),
      ],
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionTitle(tr('Не хватает', 'Yetishmaydi'), count: lacking.length),
          if (lacking.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  s['status'] == 'no_brand'
                      ? tr('Магазин пока не продаёт ваши товары — посмотрите «Нет на полке».', 'Doʻkon hozircha mahsulotlaringizni sotmaydi — «Javonda yoʻq»ni koʻring.')
                      : tr('Всего хватает до следующей поставки.', 'Keyingi yetkazishgacha hammasi yetarli.'),
                  style: AppText.small),
            ),
          for (final l in lacking) ...[
            const Divider(height: 20),
            Row(children: [
              ProductThumb(l['image']),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${l['name']}', style: AppText.bodyStrong),
                  Text(
                    tr('Осталось ${qty(l['qty'])} · продаётся ${qty(l['per_day'])} в день', 'Qoldi ${qty(l['qty'])} · kuniga ${qty(l['per_day'])} sotiladi'),
                    style: AppText.small.copyWith(color: stockColors(stockStatus(l['status'])).$2),
                  ),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(qty(l['recommend'], '${l['unit']}'), style: AppText.bodyStrong),
                Text(tr('рекомендуем', 'tavsiya'), style: AppText.small.copyWith(fontSize: 11)),
              ]),
            ]),
          ],
        ]),
      ),
      if (missing.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionTitle(tr('Нет на полке', 'Javonda yoʻq'), count: missing.length, tone: ChipTone.gray),
            Text(tr('Ваши товары, которых нет в этом магазине', 'Bu doʻkonda yoʻq mahsulotlaringiz'), style: AppText.small),
            for (final m in missing.take(5)) ...[
              const Divider(height: 20),
              Row(children: [
                ProductThumb(m['image']),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${m['name']}', style: AppText.bodyStrong),
                    Text(
                      (m['stores_count'] as num? ?? 0) > 0
                          ? tr('Продаётся в ${m['stores_count']} подключённых магазинах', '${m['stores_count']} ta ulangan doʻkonda sotiladi')
                          : money(m['price']),
                      style: AppText.small,
                    ),
                  ]),
                ),
              ]),
            ],
          ]),
        ),
      ],
      if (ships.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('История', 'Tarix'), style: AppText.title),
            for (final d in ships) ...[
              const Divider(height: 20),
              InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(id: '${d['id']}'))),
                child: Row(children: [
                  const IconBox(Icons.north_east_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk, size: 40, iconSize: 20, radius: 12),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${tr('Расход', 'Chiqim')} № ${d['number']}', style: AppText.bodyStrong),
                      Text('${dateTime(d['posted_at'] ?? d['created_at'])} · ${tr('${d['items_count']} поз.', '${d['items_count']} ta')}', style: AppText.small),
                    ]),
                  ),
                  Text(money(d['total'], suffix: false), style: AppText.bodyStrong),
                ]),
              ),
            ],
          ]),
        ),
      ],
    ];
  }
}

class _HowRow extends StatelessWidget {
  const _HowRow({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      IconBox(icon, bg: AppColors.blueSoft, fg: AppColors.blue, size: 40, iconSize: 20, radius: 12),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AppText.bodyStrong),
          Text(text, style: AppText.small),
        ]),
      ),
    ]);
  }
}

/// Д12 · «Договориться»: код на месте или запрос с сообщением.
/// Возвращает [code] или «[request]сообщение».
class _AgreeSheet extends StatefulWidget {
  const _AgreeSheet({required this.storeName});

  static const code = 'code';
  static const request = 'request:';

  final String storeName;

  @override
  State<_AgreeSheet> createState() => _AgreeSheetState();
}

class _AgreeSheetState extends State<_AgreeSheet> {
  final _msg = TextEditingController();

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Договориться с ${widget.storeName}', '${widget.storeName} bilan kelishish'), style: AppText.title),
        const SizedBox(height: 12),
        AppCard(
          color: AppColors.bg,
          onTap: () => Navigator.of(context).pop(_AgreeSheet.code),
          child: Row(children: [
            const IconBox(Icons.qr_code_2_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 20, radius: 12),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Я в магазине — показать код', 'Men doʻkondaman — kodni koʻrsatish'), style: AppText.bodyStrong),
                Text(tr('Код действует 10 минут. Владелец вводит его: Поставщики → Подключить по коду', 'Kod 10 daqiqa amal qiladi. Egasi uni kiritadi: Yetkazib beruvchilar → Kod orqali ulash'),
                    style: AppText.small),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ]),
        ),
        const SizedBox(height: 16),
        Text(tr('Или отправьте запрос', 'Yoki soʻrov yuboring'), style: AppText.bodyStrong),
        const SizedBox(height: 8),
        TextField(
          controller: _msg,
          maxLength: 500,
          maxLines: 3,
          minLines: 2,
          decoration: InputDecoration(hintText: tr('Сообщение магазину: что возите, доставка, минимальный заказ', 'Doʻkonga xabar: nima olib kelasiz, yetkazish, minimal buyurtma')),
        ),
        const SizedBox(height: 8),
        SheetButton(label: tr('Отправить запрос', 'Soʻrov yuborish'), onPressed: () => Navigator.of(context).pop('${_AgreeSheet.request}${_msg.text.trim()}')),
      ]),
    );
  }
}

/// Д13 · Код для магазина: 4 цифры и QR, 10 минут. Экран сам узнаёт,
/// что магазин ввёл код, и закрывается.
class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key, required this.storeId, required this.storeName});

  final String storeId;
  final String storeName;

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  Map<String, dynamic>? _code;
  Object? _error;
  Timer? _tick;
  Timer? _poll;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _new();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _check());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _new() async {
    setState(() => _busy = true);
    try {
      final c = await context.read<Api>().post('/store/supply/stores/${widget.storeId}/code') as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _code = c;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() async {
    try {
      final s = await context.read<Api>().get('/store/supply/stores/${widget.storeId}') as Map<String, dynamic>;
      if (s['link_status'] == 'active' && mounted) {
        _poll?.cancel();
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(SnackBar(content: Text(tr('${widget.storeName} подключил вас', '${widget.storeName} sizni uladi'))));
      }
    } catch (_) {
      // Нет сети — проверим в следующий раз.
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _code;
    final expires = DateTime.tryParse('${c?['expires_at'] ?? ''}');
    final left = expires == null ? Duration.zero : codeLeft(expires, DateTime.now());
    final expired = c != null && left == Duration.zero;
    final digits = '${c?['code'] ?? ''}'.split('');
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Код для ${widget.storeName}', '${widget.storeName} uchun kod'), style: AppText.title),
          Text(tr('Покажите владельцу магазина', 'Doʻkon egasiga koʻrsating'), style: AppText.small),
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BigButton(label: tr('Новый код', 'Yangi kod'), icon: Icons.refresh_rounded, color: AppColors.soft, foreground: AppColors.ink, busy: _busy, onPressed: _new),
        ),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        if (_error != null && c == null)
          LoadError(_error!, onRetry: _new)
        else if (c == null)
          const Padding(padding: EdgeInsets.only(top: 60), child: Center(child: CircularProgressIndicator()))
        else ...[
          AppCard(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Column(children: [
              Opacity(
                opacity: expired ? 0.2 : 1,
                child: QrImageView(data: '${c['qr']}', size: 200, backgroundColor: AppColors.white),
              ),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final d in digits) ...[
                  Container(
                    width: 56,
                    height: 68,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
                    child: Text(d, style: AppText.h1.copyWith(color: expired ? AppColors.muted : AppColors.ink)),
                  ),
                  const SizedBox(width: 10),
                ],
              ]),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(expired ? Icons.timer_off_rounded : Icons.schedule_rounded, size: 18, color: expired ? AppColors.primary : AppColors.text2),
                const SizedBox(width: 6),
                Text(expired ? tr('Код истёк — получите новый', 'Kod muddati tugadi — yangisini oling') : tr('Действует ещё ${mmss(left)}', 'Yana ${mmss(left)} amal qiladi'),
                    style: AppText.bodyStrong.copyWith(color: expired ? AppColors.primary : AppColors.text2)),
              ]),
            ]),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Что делает владелец', 'Egasi nima qiladi'), style: AppText.bodyStrong),
              const SizedBox(height: 8),
              Text(tr('1. «SM Магазин» → Ещё → Поставщики', '1. «SM Doʻkon» → Yana → Yetkazib beruvchilar'), style: AppText.small),
              Text(tr('2. «Подключить по коду» — вводит цифры или сканирует QR', '2. «Kod orqali ulash» — raqamlarni kiritadi yoki QR ni skanerlaydi'), style: AppText.small),
              Text(tr('3. Связь активна — у вас откроются остатки и заказы', '3. Aloqa faol — sizga qoldiqlar va buyurtmalar ochiladi'), style: AppText.small),
            ]),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.successSoft, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              const Icon(Icons.sync_rounded, color: AppColors.successInk, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('Экран обновится сам, как только магазин введёт код', 'Doʻkon kodni kiritishi bilan ekran oʻzi yangilanadi'), style: AppText.small.copyWith(color: AppColors.successInk))),
            ]),
          ),
        ],
      ]),
    );
  }
}
