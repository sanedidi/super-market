import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sm_core/sm_core.dart';

import '../my_qr.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'debts_screen.dart';
import 'profile_screen.dart' show profileName;

// «Мой QR-код» (Figma Q1–Q3): покупатель показывает QR кассиру — тот
// сканирует и записывает покупку в долг. Номер и код называть не нужно.

Future<void> openMyQr(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyQrScreen()));

/// Q1 · тёмная карточка в профиле.
class MyQrProfileCard extends StatelessWidget {
  const MyQrProfileCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Material(
        color: const Color(0xFF101828),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () => openMyQr(context),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const Icon(Icons.qr_code_2_rounded, size: 30, color: AppColors.white),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Мой QR-код', 'Mening QR kodim'), style: AppText.bodyStrong.copyWith(fontSize: 16, color: AppColors.white)),
                  const SizedBox(height: 2),
                  Text(tr('покажите на кассе — в долг без номера', 'kassada koʻrsating — raqamsiz qarzga'),
                      style: AppText.small.copyWith(color: const Color(0xFF98A2B3))),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF98A2B3)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Q2 · экран QR. Пока он открыт, проверяем, не записала ли касса покупку
/// в долг, — и сразу показываем «Записано в долг» (Q3).
class MyQrScreen extends StatefulWidget {
  const MyQrScreen({super.key});

  @override
  State<MyQrScreen> createState() => _MyQrScreenState();
}

class _MyQrScreenState extends State<MyQrScreen> {
  QrKey? _key;
  Object? _error;
  Timer? _tick;
  Timer? _poll;
  bool _polling = false;
  bool _sheet = false;

  /// Экран открыт (часы телефона) и последняя показанная покупка (часы
  /// сервера): покупки в долг после этого показываем на экране.
  final DateTime _openedAt = DateTime.now();
  DateTime? _lastEntryAt;

  DateTime get _since =>
      _lastEntryAt ?? _openedAt.add(_key?.clockOffset ?? Duration.zero).toUtc().subtract(const Duration(seconds: 5));

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _checkRecent());
    _load();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    // Сначала ключ с телефона — QR виден сразу и без интернета; потом обновляем.
    final saved = await loadQrKey();
    if (mounted && saved != null) setState(() => _key = saved);
    try {
      final fresh = await fetchQrKey(api);
      if (mounted) {
        setState(() {
          _key = fresh;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _key == null) setState(() => _error = e);
    }
  }

  Future<void> _checkRecent() async {
    if (_polling || _sheet || _key == null || !mounted) return;
    _polling = true;
    try {
      final state = context.read<AppState>();
      final r = await state.api.get('/client/qr/recent', {'since': _since.toIso8601String()}) as Map<String, dynamic>;
      final e = r['entry'] as Map<String, dynamic>?;
      if (e == null || !mounted) return;
      final at = DateTime.tryParse('${e['created_at']}');
      if (at != null) _lastEntryAt = at.toUtc();
      HapticFeedback.mediumImpact();
      state.loadDebts().catchError((_) {});
      _sheet = true;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: AppColors.white,
        builder: (_) => _RecordedSheet(entry: e),
      );
      _sheet = false;
    } catch (_) {
      // Нет связи — QR всё равно работает, проверим в следующий раз.
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = state.profile;
    final key = _key;
    Widget body;
    if (key == null && _error == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (key == null) {
      body = EmptyState(
        icon: Icons.wifi_off_rounded,
        title: tr('Не удалось получить QR', 'QR kodni olib boʻlmadi'),
        text: tr('Нужен интернет один раз — дальше QR работает и без него.', 'Bir marta internet kerak — keyin QR internetsiz ham ishlaydi.'),
        action: tr('Повторить', 'Qayta urinish'),
        onAction: () {
          setState(() => _error = null);
          _load();
        },
      );
    } else {
      final left = key.secondsLeft();
      body = ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
          decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(28)),
          child: Column(children: [
            Row(children: [
              Avatar(name: profileName(p), size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(profileName(p).isEmpty ? tr('Покупатель', 'Xaridor') : profileName(p),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontWeight: FontWeight.w700)),
                  Text(_masked('${p?['phone'] ?? ''}'), style: AppText.small.copyWith(fontSize: 14)),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            LayoutBuilder(builder: (context, c) {
              final size = c.maxWidth.clamp(180.0, 280.0);
              return QrImageView(
                data: key.payload(),
                size: size,
                padding: EdgeInsets.zero,
                backgroundColor: AppColors.white,
              );
            }),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: left / key.step,
                minHeight: 6,
                backgroundColor: AppColors.soft,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.autorenew_rounded, size: 16, color: AppColors.muted),
              const SizedBox(width: 6),
              Text(tr('Код обновится через 0:${left.toString().padLeft(2, '0')}', 'Kod 0:${left.toString().padLeft(2, '0')} dan keyin yangilanadi'),
                  style: AppText.caption.copyWith(fontSize: 13)),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(AppRadius.xl)),
          child: Column(children: [
            _info(Icons.storefront_rounded,
                tr('Покажите кассиру — он отсканирует и запишет покупку в долг на вас. Номер и код называть не нужно.',
                    'Kassirga koʻrsating — u skanerlaydi va xaridni sizning nomingizga qarzga yozadi. Raqam va kodni aytish shart emas.')),
            const SizedBox(height: 14),
            _info(Icons.lock_rounded,
                tr('QR меняется каждые 30 секунд — фото или скриншот чужого QR не сработает.',
                    'QR har 30 soniyada oʻzgaradi — birovning QR rasmi yoki skrinshoti ishlamaydi.')),
            const SizedBox(height: 14),
            _info(Icons.wifi_off_rounded, tr('Работает и без интернета.', 'Internetsiz ham ishlaydi.')),
          ]),
        ),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.brightness_high_rounded, size: 16, color: AppColors.muted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(tr('Касса не читает QR — прибавьте яркость экрана', 'Kassa QRni oʻqimasa — ekran yorqinligini oshiring'),
                style: AppText.caption.copyWith(color: AppColors.muted)),
          ),
        ]),
      ]);
    }
    return Scaffold(
      backgroundColor: AppColors.soft,
      body: SafeArea(
        child: Column(children: [
          PageHeader(title: tr('Мой QR-код', 'Mening QR kodim')),
          Expanded(child: body),
        ]),
      ),
    );
  }

  Widget _info(IconData icon, String text) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 22, color: AppColors.primary),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: AppText.body.copyWith(fontSize: 14, color: AppColors.dark))),
      ]);

  /// «+998905764723» → «+998 90 ••• •• 23».
  static String _masked(String phone) {
    final d = phone.replaceAll(RegExp(r'\D'), '');
    if (d.length != 12) return formatPhone(phone);
    return '+${d.substring(0, 3)} ${d.substring(3, 5)} ••• •• ${d.substring(10)}';
  }
}

/// Q3 · «Записано в долг»: сумма, долг в магазине, срок, «Это не я».
class _RecordedSheet extends StatelessWidget {
  const _RecordedSheet({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final at = DateTime.tryParse('${e['created_at']}')?.toLocal();
    final time = at == null ? '' : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final store = '${e['store_name'] ?? ''}';
    Widget row(String label, String value, {Color color = AppColors.ink, bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text(label, style: AppText.body.copyWith(color: AppColors.text2))),
            Text(value, style: (big ? AppText.price.copyWith(fontSize: 18) : AppText.bodyStrong).copyWith(color: color)),
          ]),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
              child: const Icon(Icons.check_circle_rounded, size: 36, color: AppColors.successInk),
            ),
          ),
          const SizedBox(height: 12),
          Text(tr('Записано в долг', 'Qarzga yozildi'), style: AppText.h2.copyWith(fontSize: 22), textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(tr('$store · сегодня, $time', '$store · bugun, $time'), style: AppText.small.copyWith(fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [
              row(tr('Эта покупка', 'Bu xarid'), money(e['amount']), big: true),
              row(tr('Долг в магазине', 'Doʻkondagi qarz'), money(e['balance']), color: AppColors.primary),
              if (e['due_date'] != null) row(tr('Вернуть до', 'Qaytarish muddati'), debtDay(e['due_date'])),
            ]),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: AppButton(
                label: tr('Это не я', 'Bu men emasman'),
                type: AppButtonType.secondary,
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final nav = Navigator.of(context);
                  final sent = await showDebtDispute(context, e, store);
                  if (!sent) return;
                  nav.pop();
                  messenger.showSnackBar(SnackBar(
                      content: Text(tr('Отправили владельцу магазина — он проверит запись', 'Doʻkon egasiga yuborildi — u yozuvni tekshiradi'))));
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: AppButton(label: tr('Понятно', 'Tushunarli'), onPressed: () => Navigator.of(context).pop())),
          ]),
        ]),
      ),
    );
  }
}
