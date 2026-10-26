// Шахзод — чат с помощником Super Market на весь экран, без таббара
// (Figma «SM Магазин · таб «Помощник»», М3–М7). Тот же сервер и та же
// история, что в панели: GET/POST /store/assistant/messages. Ответ приходит
// фоном — пока он pending, список опрашивается раз в 1,5 с.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/app_lock.dart';
import '../screens/orders_screen.dart';
import '../screens/warehouse_screen.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'assistant_logic.dart';

const _path = '/store/assistant/messages';

/// Есть ли ответ Шахзода, который владелец ещё не видел (красная точка на табе).
final assistantUnread = ValueNotifier<bool>(false);

/// Открыть чат (с таба, с главной или из уведомления).
Future<void> openAssistant(BuildContext context) async {
  assistantUnread.value = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('assistant_opens', (prefs.getInt('assistant_opens') ?? 0) + 1);
  } catch (_) {
    // счётчик подсказки — не важно
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AssistantScreen()));
}

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  List<Map<String, dynamic>> _items = const [];
  bool _pending = false;
  bool _loaded = false;
  bool _busy = false;
  Object? _error;
  ApiError? _locked;
  Timer? _poll;
  final _text = TextEditingController();
  final _scroll = ScrollController();

  // Голосовое: удерживать микрофон.
  AudioRecorder? _rec;
  String? _recPath;
  DateTime? _recStart;
  Timer? _recTimer;
  int _recSecs = 0;
  bool _recCancel = false;
  double _dragStart = 0;

  late final Api _api = context.read<Api>();
  late final StoreState _st = context.read<StoreState>();

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _recTimer?.cancel();
    _rec?.dispose();
    _text.dispose();
    _scroll.dispose();
    // Ушли, а Шахзод ещё отвечает — красная точка на табе, когда ответит.
    if (_pending) _watchInBackground(_api, _st.storeId);
    super.dispose();
  }

  Future<void> _load() async {
    final storeId = _st.storeId;
    if (storeId == null) return;
    try {
      final r = await _api.get(_path, {'store_id': storeId}) as Map<String, dynamic>;
      if (!mounted) return;
      final items = [for (final m in (r['items'] as List? ?? const [])) Map<String, dynamic>.from(m as Map)];
      final grew = items.length != _items.length || (items.isNotEmpty && _items.isNotEmpty && items.last['status'] != _items.last['status']);
      setState(() {
        _items = items;
        _pending = r['pending'] == true;
        _loaded = true;
        _error = null;
        _locked = null;
      });
      if (grew) _toBottom();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        if (e.code == 'plan_feature' || e.status == 403) {
          _locked = e;
        } else {
          _error = e;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    _poll?.cancel();
    if (_pending && mounted) _poll = Timer(const Duration(milliseconds: 1500), _load);
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _post(Map<String, dynamic> body) async {
    final storeId = _st.storeId;
    if (storeId == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _api.post(_path, {'store_id': storeId, ...body});
      await _load();
    } on ApiError catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _sendText([String? text, String? ref]) {
    final t = (text ?? _text.text).trim();
    if (t.isEmpty) return;
    if (text == null) _text.clear();
    _post({'text': t, if (ref != null) 'ref': ref});
  }

  void _sendAction(Map<String, dynamic> action) => _post({'action': action});

  // ------------------------------------------------------------ фото

  /// М5 · «Что сфотографируем?» — накладную, новый товар или из галереи.
  Future<void> _attachSheet() async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Что сфотографируем?', 'Nimani suratga olamiz?'), style: AppText.title),
            const SizedBox(height: 12),
            _SheetTile(
              icon: Icons.receipt_long_rounded,
              bg: AppColors.primarySoft,
              fg: AppColors.primary,
              title: tr('Накладную', 'Nakladnoyni'),
              text: tr('Сделаю приход по всем строкам', 'Barcha qatorlar boʻyicha kirim qilaman'),
              onTap: () => Navigator.pop(ctx, 'invoice'),
            ),
            const SizedBox(height: 8),
            _SheetTile(
              icon: Icons.photo_camera_rounded,
              bg: AppColors.blueSoft,
              fg: AppColors.blue,
              title: tr('Новый товар', 'Yangi tovar'),
              text: tr('Super Market заполнит карточку, добавлю в товары', 'Super Market kartochkani toʻldiradi, tovarlarga qoʻshaman'),
              onTap: () => Navigator.pop(ctx, 'product'),
            ),
            const SizedBox(height: 8),
            _SheetTile(
              icon: Icons.photo_library_rounded,
              bg: AppColors.soft,
              fg: AppColors.ink,
              title: tr('Из галереи', 'Galereyadan'),
              text: tr('Выберите готовое фото', 'Tayyor rasmni tanlang'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
          ]),
        ),
      ),
    );
    if (pick == null || !mounted) return;
    if (pick == 'gallery') {
      final x = await _pick(ImageSource.gallery);
      if (x == null || !mounted) return;
      final kind = await showModalBottomSheet<AssistAttach>(
        context: context,
        showDragHandle: true,
        backgroundColor: AppColors.white,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Что на фото?', 'Rasmda nima?'), style: AppText.title),
              const SizedBox(height: 12),
              BigButton(label: tr('Накладная', 'Nakladnoy'), onPressed: () => Navigator.pop(ctx, AssistAttach.invoice)),
              const SizedBox(height: 8),
              BigButton(label: tr('Новый товар', 'Yangi tovar'), onPressed: () => Navigator.pop(ctx, AssistAttach.product), color: AppColors.soft, foreground: AppColors.ink),
            ]),
          ),
        ),
      );
      if (kind != null) await _sendPhoto(x, kind);
      return;
    }
    await _photo(pick == 'product' ? AssistAttach.product : AssistAttach.invoice);
  }

  Future<XFile?> _pick(ImageSource source) async {
    final lock = context.read<AppLock>();
    try {
      return await lock.hold(() => ImagePicker().pickImage(source: source, maxWidth: 2000, maxHeight: 2000, imageQuality: 82));
    } catch (_) {
      _snack(tr('Не удалось открыть камеру', 'Kamerani ochib boʻlmadi'));
      return null;
    }
  }

  Future<void> _photo(AssistAttach kind) async {
    final x = await _pick(ImageSource.camera);
    if (x != null) await _sendPhoto(x, kind);
  }

  Future<void> _sendPhoto(XFile x, AssistAttach kind) async {
    final storeId = _st.storeId;
    if (storeId == null) return;
    setState(() => _busy = true);
    try {
      final up = await _api.upload('/store/uploads', await x.readAsBytes(), x.name) as Map<String, dynamic>;
      await _api.post(_path, {
        'store_id': storeId,
        'images': [up['url']],
        'kind': kind == AssistAttach.product ? 'product' : 'invoice',
      });
      await _load();
    } on ApiError catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ голос

  /// М6 · палец на микрофоне — запись; отпустил — отправилось; влево — отмена.
  Future<void> _recStartNow(double x) async {
    if (_rec != null || _busy || _pending) return;
    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        await rec.dispose();
        _snack(tr('Разрешите доступ к микрофону в настройках телефона', 'Telefon sozlamalarida mikrofonga ruxsat bering'));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/shahzod_${DateTime.now().millisecondsSinceEpoch}.wav';
      // WAV 16 кГц моно: 60 с ≈ 1,9 МБ, понимают все модели.
      await rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: path);
      HapticFeedback.mediumImpact();
      setState(() {
        _rec = rec;
        _recPath = path;
        _recStart = DateTime.now();
        _recSecs = 0;
        _recCancel = false;
        _dragStart = x;
      });
      _recTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final s = DateTime.now().difference(_recStart!).inSeconds;
        if (s != _recSecs && mounted) setState(() => _recSecs = s);
        if (s >= maxVoiceSeconds) _recStop();
      });
    } catch (_) {
      await rec.dispose();
      _snack(tr('Не удалось включить микрофон', 'Mikrofonni yoqib boʻlmadi'));
    }
  }

  void _recMove(double x) {
    if (_rec == null) return;
    final cancel = _dragStart - x > cancelSwipe;
    if (cancel != _recCancel) setState(() => _recCancel = cancel);
  }

  Future<void> _recStop() async {
    final rec = _rec;
    if (rec == null) return;
    _recTimer?.cancel();
    final started = _recStart;
    final cancel = _recCancel;
    setState(() {
      _rec = null;
      _recCancel = false;
    });
    String? path;
    try {
      path = await rec.stop();
    } catch (_) {
      path = null;
    }
    await rec.dispose();
    path ??= _recPath;
    final long = started != null && DateTime.now().difference(started).inMilliseconds >= minVoiceMillis;
    if (path == null || cancel || !long) {
      if (!cancel && !long) _snack(tr('Удерживайте микрофон и говорите', 'Mikrofonni bosib turing va gapiring'));
      _deleteFile(path);
      return;
    }
    final storeId = _st.storeId;
    if (storeId == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await File(path).readAsBytes();
      await _api.multipart(_path, {'store_id': storeId}, 'audio', bytes, 'voice.wav');
      await _load();
    } on ApiError catch (e) {
      _snack(e.message);
    } finally {
      _deleteFile(path);
      if (mounted) setState(() => _busy = false);
    }
  }

  void _deleteFile(String? path) {
    if (path == null) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  // ------------------------------------------------------------ ссылки

  void _open(String href) {
    switch (placeFor(href)) {
      case AppPlace.home:
        Navigator.of(context).popUntil((r) => r.isFirst);
      case AppPlace.orders:
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OrdersScreen(pushed: true)));
      case AppPlace.stock:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Scaffold(appBar: AppBar(title: Text(tr('Склад', 'Ombor'))), body: const WarehouseScreen()),
        ));
      case null:
        // В приложении такого экрана нет — открываем панель магазина в браузере.
        _openPanel(href);
    }
  }

  Future<void> _openPanel(String href) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(panelUrl(href)), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok) _snack(tr('Это открывается в панели магазина на компьютере', 'Bu kompyuterdagi doʻkon panelida ochiladi'));
  }

  void _onButton(AssistButton b) {
    switch (b.attach) {
      case AssistAttach.invoice:
        _photo(AssistAttach.invoice);
      case AssistAttach.product:
        _photo(AssistAttach.product);
      case AssistAttach.none:
        final a = b.labeledAction;
        if (a != null) {
          _sendAction(a);
        } else {
          _sendText(b.send ?? b.label, b.ref);
        }
    }
  }

  // ------------------------------------------------------------ экран

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          const _Avatar(size: 38),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Шахзод', 'Shahzod'), style: AppText.title),
              Text(tr('помощник Super Market', 'Super Market yordamchisi'), style: AppText.small.copyWith(fontSize: 12, color: AppColors.successInk)),
            ]),
          ),
        ]),
      ),
      body: Column(children: [
        Expanded(child: _body()),
        if (_locked == null) _composer(),
      ]),
    );
  }

  Widget _body() {
    if (_locked != null) {
      return EmptyState(
        icon: Icons.lock_outline_rounded,
        title: tr('Шахзод пока недоступен', 'Shahzod hozircha mavjud emas'),
        text: _locked!.message,
      );
    }
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) {
      return EmptyState(
        icon: Icons.wifi_off_rounded,
        title: tr('Не удалось загрузить чат', 'Chatni yuklab boʻlmadi'),
        text: '$_error',
        action: tr('Повторить', 'Qayta urinish'),
        onAction: _load,
      );
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      children: [
        if (_items.isEmpty) _welcome(),
        for (final m in _items) ...[_message(m), const SizedBox(height: 10)],
      ],
    );
  }

  /// М3 · первое открытие.
  Widget _welcome() {
    final hints = [
      (Icons.move_to_inbox_rounded, tr('Пришли товары', 'Tovarlar keldi')),
      (Icons.search_rounded, tr('Сколько осталось?', 'Qancha qoldi?')),
      (Icons.shopping_cart_outlined, tr('Что заказать?', 'Nima buyurtma qilish kerak?')),
      (Icons.insights_rounded, tr('Продажи за сегодня', 'Bugungi sotuvlar')),
      (Icons.account_balance_wallet_outlined, tr('Кто мне должен?', 'Kim menga qarz?')),
    ];
    return _BotBubble(children: [
      Text(
        tr('Салом! Я Шахзод, помощник Super Market. Скажите голосом или напишите, что нужно — я сделаю в магазине.',
            'Salom! Men Shahzod, Super Market yordamchisiman. Nima kerakligini ayting yoki yozing — doʻkonda men qilaman.'),
        style: AppText.body,
      ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final h in hints) _Chip(label: h.$2, icon: h.$1, onTap: () => _sendText(h.$2)),
      ]),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AppColors.successSoft, borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.mic_rounded, size: 18, color: AppColors.successInk),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('Удерживайте микрофон и говорите по-узбекски или по-русски. Камера — фото накладной или нового товара.',
                  'Mikrofonni bosib turing va oʻzbek yoki rus tilida gapiring. Kamera — nakladnoy yoki yangi tovar rasmi.'),
              style: AppText.small.copyWith(color: AppColors.successInk),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _message(Map<String, dynamic> m) {
    final role = m['role'];
    final text = '${m['text'] ?? ''}';
    if (role == 'system') {
      return Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: AppColors.successSoft, borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.check_circle_rounded, size: 16, color: AppColors.successInk),
            const SizedBox(width: 6),
            Flexible(child: Text(text, style: AppText.caption.copyWith(color: AppColors.successInk))),
          ]),
        ),
      );
    }
    if (role == 'owner') {
      final images = [for (final u in (m['images'] as List? ?? const [])) '$u'];
      final transcript = m['transcript'];
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(4)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (m['kind'] == 'audio') ...[
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.mic_rounded, size: 18, color: AppColors.white),
                  const SizedBox(width: 6),
                  Text(tr('Голосовое', 'Ovozli xabar'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                ]),
                const SizedBox(height: 4),
                Text(transcript is String ? '«$transcript»' : tr('расшифровываю…', 'tinglayapman…'), style: AppText.small.copyWith(color: const Color(0xFFFFD6D9))),
              ],
              if (images.isNotEmpty)
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final u in images)
                    ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.network(u, width: 140, height: 104, fit: BoxFit.cover, errorBuilder: (context, error, stack) => const SizedBox(width: 140, height: 104))),
                ]),
              if (text.isNotEmpty) Text(text, style: AppText.body.copyWith(color: AppColors.white)),
            ]),
          ),
        ),
      );
    }
    final failed = m['status'] == 'failed';
    if (m['status'] == 'pending') {
      return const _BotBubble(children: [_Typing()]);
    }
    return _BotBubble(failed: failed, children: [
      if (text.isNotEmpty) Text(text, style: AppText.body.copyWith(color: failed ? AppColors.error : AppColors.ink)),
      for (final b in parseBlocks(m['blocks'])) _block(b),
    ]);
  }

  Widget _block(AssistBlock b) {
    if (b is ButtonsBlock) {
      return Wrap(spacing: 8, runSpacing: 8, children: [for (final it in b.items) _Chip.of(it, onTap: () => _onButton(it))]);
    }
    if (b is CardBlock) {
        final (bg, fg) = switch (b.statusKind) {
          'error' => (AppColors.primarySoft, AppColors.primary),
          'ok' => (AppColors.successSoft, AppColors.successInk),
          _ => (AppColors.warningSoft, AppColors.warningInk),
        };
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(b.title, style: AppText.bodyStrong)),
              if (b.sum != null) Text(b.sum!, style: AppText.bodyStrong),
            ]),
            if (b.note != null) ...[const SizedBox(height: 4), Text(b.note!, style: AppText.small)],
            if (b.status != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                child: Text(b.status!, style: AppText.small.copyWith(color: fg, fontWeight: FontWeight.w600)),
              ),
            ],
            if (b.buttons.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [for (final it in b.buttons) _Chip.of(it, onTap: () => _onButton(it))]),
            ],
          ]),
        );
    }
    if (b is TableBlock) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.line)),
            clipBehavior: Clip.antiAlias,
            child: DataTable(
              headingRowHeight: 36,
              dataRowMinHeight: 34,
              dataRowMaxHeight: 48,
              horizontalMargin: 12,
              columnSpacing: 16,
              headingRowColor: const WidgetStatePropertyAll(AppColors.soft),
              headingTextStyle: AppText.caption,
              dataTextStyle: AppText.small.copyWith(color: AppColors.ink),
              columns: [for (var i = 0; i < b.columns.length; i++) DataColumn(label: Text(b.columns[i]), numeric: i > 0)],
              rows: [
                for (final r in b.rows)
                  DataRow(cells: [for (var i = 0; i < b.columns.length; i++) DataCell(Text(i < r.length ? r[i] : ''))]),
              ],
            ),
          ),
        );
    }
    if (b is LinkBlock) {
        return InkWell(
          onTap: () => _open(b.href),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(b.label, style: AppText.bodyStrong.copyWith(color: AppColors.primary))),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_forward_rounded, size: 18, color: AppColors.primary),
          ]),
        );
    }
    if (b is ConfirmBlock) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: b.enabled && !_busy ? () => _sendAction(b.labeledAction) : null,
            icon: const Icon(Icons.check_rounded),
            label: Text(b.label, style: AppText.bodyStrong.copyWith(color: AppColors.white)),
          ),
          const SizedBox(height: 6),
          Text(
            b.hint ?? tr('Провести можно только этой кнопкой — текстом «проведи» не сработает.', 'Faqat shu tugma bilan oʻtkaziladi — «oʻtkaz» deb yozish ishlamaydi.'),
            style: AppText.small.copyWith(fontSize: 12),
          ),
        ]);
    }
    return const SizedBox.shrink();
  }

  /// Поле ввода: камера, текст, микрофон (или «Отправить», если есть текст).
  Widget _composer() {
    final recording = _rec != null;
    final hasText = _text.text.trim().isNotEmpty;
    return Container(
      decoration: const BoxDecoration(color: AppColors.white, border: Border(top: BorderSide(color: AppColors.line))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            if (!recording) ...[
              _RoundButton(icon: Icons.photo_camera_rounded, onTap: _busy ? null : _attachSheet),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendText(),
                  decoration: InputDecoration(
                    hintText: tr('Напишите или скажите…', 'Yozing yoki ayting…'),
                    filled: true,
                    fillColor: AppColors.bg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                  ),
                ),
              ),
            ] else
              Expanded(child: _recordingBar()),
            const SizedBox(width: 8),
            if (hasText && !recording)
              _RoundButton(icon: Icons.send_rounded, primary: true, onTap: _busy || _pending ? null : _sendText)
            else
              Listener(
                onPointerDown: (e) => _recStartNow(e.position.dx),
                onPointerMove: (e) => _recMove(e.position.dx),
                onPointerUp: (_) => _recStop(),
                onPointerCancel: (_) {
                  _recCancel = true;
                  _recStop();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: recording ? 60 : 44,
                  height: recording ? 60 : 44,
                  decoration: BoxDecoration(color: _busy || _pending ? AppColors.muted : AppColors.primary, shape: BoxShape.circle),
                  child: Icon(Icons.mic_rounded, color: AppColors.white, size: recording ? 30 : 24),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _recordingBar() {
    final mm = (_recSecs ~/ 60).toString();
    final ss = (_recSecs % 60).toString().padLeft(2, '0');
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: _recCancel ? AppColors.soft : AppColors.primarySoft, borderRadius: BorderRadius.circular(24)),
      child: Row(children: [
        Container(width: 10, height: 10, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text('$mm:$ss', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
        const Spacer(),
        Text(
          _recCancel ? tr('Отпустите — отменится', 'Qoʻyib yuboring — bekor boʻladi') : tr('‹ влево — отмена', '‹ chapga — bekor'),
          style: AppText.small.copyWith(fontSize: 12),
        ),
      ]),
    );
  }
}

/// Ушли из чата, пока Шахзод отвечает: ждём ответ и зажигаем точку на табе.
void _watchInBackground(Api api, String? storeId) {
  if (storeId == null) return;
  var tries = 0;
  Timer.periodic(const Duration(seconds: 3), (t) async {
    tries++;
    if (tries > 60) {
      t.cancel();
      return;
    }
    try {
      final r = await api.get(_path, {'store_id': storeId}) as Map<String, dynamic>;
      if (r['pending'] != true) {
        t.cancel();
        assistantUnread.value = true;
      }
    } catch (_) {
      // сеть — попробуем ещё раз
    }
  });
}

// ------------------------------------------------------------ мелочи

class _Avatar extends StatelessWidget {
  const _Avatar({this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
      child: Text(tr('Ш', 'Sh'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: size * 0.42)),
    );
  }
}

class _BotBubble extends StatelessWidget {
  const _BotBubble({required this.children, this.failed = false});
  final List<Widget> children;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: failed ? AppColors.errorSoft : AppColors.white,
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomRight: Radius.circular(18), bottomLeft: Radius.circular(4)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 10), children[i]],
          ]),
        ),
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      const SizedBox(width: 10),
      Text(tr('Шахзод думает…', 'Shahzod oʻylayapti…'), style: AppText.small),
    ]);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap, this.icon, this.primary = false});

  factory _Chip.of(AssistButton b, {required VoidCallback onTap}) => _Chip(
        label: b.label,
        onTap: onTap,
        primary: b.primary,
        icon: switch (b.attach) {
          AssistAttach.invoice => Icons.receipt_long_rounded,
          AssistAttach.product => Icons.photo_camera_rounded,
          AssistAttach.none => null,
        },
      );

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? AppColors.white : AppColors.ink;
    return Material(
      color: primary ? AppColors.primary : AppColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: primary ? BorderSide.none : const BorderSide(color: AppColors.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 6)],
            Flexible(child: Text(label, style: AppText.bodyStrong.copyWith(fontSize: 14, color: fg))),
          ]),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap, this.primary = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary ? AppColors.primary : AppColors.bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: Icon(icon, color: primary ? AppColors.white : AppColors.ink, size: 22)),
      ),
    );
  }
}

class _SheetTile extends StatelessWidget {
  const _SheetTile({required this.icon, required this.bg, required this.fg, required this.title, required this.text, required this.onTap});
  final IconData icon;
  final Color bg;
  final Color fg;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      border: AppColors.line,
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        IconBox(icon, bg: bg, fg: fg),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong),
            Text(text, style: AppText.small),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
      ]),
    );
  }
}
