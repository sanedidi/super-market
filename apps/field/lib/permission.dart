import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sm_core/sm_core.dart';

import 'tracker.dart';
import 'ui.dart';

/// П7 · Перед обходом — разрешение геолокации. Без него обход не начать.
/// Возвращает true, когда разрешение есть.
class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key, this.access = LocationAccess.denied});

  final LocationAccess access;

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> with WidgetsBindingObserver {
  late LocationAccess _access = widget.access;
  bool _busy = false;
  bool _closed = false;

  /// Закрыть один раз: ответ на системный запрос и возврат в приложение
  /// (resumed) приходят почти одновременно.
  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Вернулись из настроек телефона — проверить ещё раз.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _recheck();
  }

  Future<void> _recheck() async {
    final a = await locationAccess();
    if (!mounted) return;
    if (a == LocationAccess.ok) {
      _close();
    } else {
      setState(() => _access = a);
    }
  }

  Future<void> _allow() async {
    setState(() => _busy = true);
    try {
      switch (_access) {
        case LocationAccess.serviceOff:
          await Geolocator.openLocationSettings();
        case LocationAccess.deniedForever:
          await Geolocator.openAppSettings();
        default:
          final a = await locationAccess(ask: true);
          if (!mounted) return;
          if (a == LocationAccess.ok) {
            _close();
            return;
          }
          setState(() => _access = a);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final steps = [
      tr('Нажмите «Разрешить»', '«Ruxsat berish» tugmasini bosing'),
      ios
          ? tr('Выберите «При использовании», потом — «Всегда разрешать»', '«Foydalanish vaqtida»ni, soʻng «Doim ruxsat berish»ni tanlang')
          : tr('Выберите «Разрешить всегда» или «Только во время использования»', '«Doim ruxsat berish» yoki «Faqat foydalanish vaqtida»ni tanlang'),
      if (!ios)
        tr('Отключите экономию батареи для приложения — иначе телефон может остановить запись пути',
            'Ilova uchun batareya tejamini oʻchiring — aks holda telefon yoʻlni yozishni toʻxtatishi mumkin'),
    ];
    final (button, note) = switch (_access) {
      LocationAccess.serviceOff => (
          tr('Включить геолокацию', 'Geojoylashuvni yoqish'),
          tr('Геолокация на телефоне выключена — включите её в настройках.', 'Telefonda geojoylashuv oʻchirilgan — sozlamalarda yoqing.')
        ),
      LocationAccess.deniedForever => (
          tr('Открыть настройки', 'Sozlamalarni ochish'),
          tr('Доступ к геопозиции запрещён — разрешите его в настройках приложения.', 'Geojoylashuvga ruxsat berilmagan — ilova sozlamalarida ruxsat bering.')
        ),
      _ => (tr('Разрешить', 'Ruxsat berish'), tr('Без разрешения обход не начать', 'Ruxsatsiz aylanishni boshlab boʻlmaydi')),
    };
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), children: [
              Center(
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
                  child: const Icon(Icons.share_location_rounded, size: 44, color: AppColors.primary),
                ),
              ),
              const SizedBox(height: 16),
              Text(tr('Разрешите геолокацию', 'Geojoylashuvga ruxsat bering'), textAlign: TextAlign.center, style: AppText.h2),
              const SizedBox(height: 10),
              Text(
                tr('Во время обхода Super Market записывает ваш путь, чтобы другие продажники не ходили там же. Путь пишется только между «Начать обход» и «Закончить».',
                    'Aylanish vaqtida Super Market yoʻlingizni yozib boradi — boshqa agentlar oʻsha yerdan yurmasligi uchun. Yoʻl faqat «Aylanishni boshlash» va «Tugatish» oraligʻida yoziladi.'),
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.text2),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(16)),
                child: Column(children: [
                  for (var i = 0; i < steps.length; i++)
                    Padding(
                      padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12)),
                          child: Text('${i + 1}', style: AppText.caption.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(steps[i], style: AppText.body)),
                      ]),
                    ),
                ]),
              ),
              if (!ios) ...[
                const SizedBox(height: 18),
                Text(tr('Во время обхода в шторке телефона висит уведомление:', 'Aylanish vaqtida telefon pardasida bildirishnoma turadi:'),
                    style: AppText.small),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.line),
                    boxShadow: shadow,
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(5)),
                        child: const Icon(Icons.directions_walk_rounded, size: 13, color: AppColors.white),
                      ),
                      const SizedBox(width: 6),
                      Text('SM ${tr('Продажник', 'Savdo agenti')} · ${tr('сейчас', 'hozir')}', style: AppText.small.copyWith(fontSize: 12)),
                    ]),
                    const SizedBox(height: 4),
                    Text(tr('Идёт обход', 'Aylanish davom etmoqda'), style: AppText.bodyStrong),
                    Text(tr('Super Market записывает ваш путь. Нажмите, чтобы открыть карту', 'Super Market yoʻlingizni yozib boryapti. Xaritani ochish uchun bosing'),
                        style: AppText.small),
                  ]),
                ),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(children: [
              BigButton(label: button, icon: Icons.check_rounded, busy: _busy, onPressed: _allow),
              const SizedBox(height: 6),
              Text(note, textAlign: TextAlign.center, style: AppText.small),
            ]),
          ),
        ]),
      ),
    );
  }
}
