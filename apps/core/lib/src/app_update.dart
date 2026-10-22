import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'i18n.dart';
import 'sheet.dart';

// ОБ1 · «Есть обновление» (Figma «Обновление приложения»): при запуске и при
// возврате в приложение спрашиваем сервер, нет ли версии новее. Есть — шторка
// с «Что нового»: «Обновить» открывает App Store / Google Play, «Позже» —
// следующий раз через сутки. Без связи или без ответа — ничего не показываем.
// Версии и «Что нового» задаёт супер-админ («Версии приложений»).

/// Обёртка главного экрана приложения (`MaterialApp.home`): проверяет
/// обновление и показывает шторку поверх того, что открыто.
class UpdateCheck extends StatefulWidget {
  const UpdateCheck({super.key, required this.api, required this.app, required this.version, required this.open, required this.child});

  final Api api;

  /// client, store, courier или agent.
  final String app;

  /// Версия приложения, «0.9.2» (как в pubspec.yaml).
  final String version;

  /// Открыть ссылку на стор (url_launcher в приложении).
  final Future<void> Function(String url) open;

  final Widget child;

  @override
  State<UpdateCheck> createState() => _UpdateCheckState();
}

class _UpdateCheckState extends State<UpdateCheck> with WidgetsBindingObserver {
  // Не чаще раза в час — и на весь процесс, а не на экран.
  static DateTime? _checkedAt;
  static bool _showing = false;

  static const _every = Duration(hours: 1);
  static const _later = Duration(days: 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  String? get _platform {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      _ => null,
    };
  }

  Future<void> _check() async {
    final platform = _platform;
    if (platform == null || _showing || !mounted) return;
    final now = DateTime.now();
    final last = _checkedAt;
    if (last != null && now.difference(last) < _every) return;
    _checkedAt = now;
    Map<String, dynamic> r;
    try {
      r = await widget.api.get('/public/app-version', {'app': widget.app, 'platform': platform, 'version': widget.version}) as Map<String, dynamic>;
    } catch (_) {
      return; // нет связи — не мешаем работать
    }
    final latest = '${r['latest'] ?? ''}';
    final url = '${r['store_url'] ?? ''}';
    if (r['update'] != true || latest.isEmpty || url.isEmpty || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'update_later_${widget.app}_$latest';
    final later = prefs.getInt(key);
    if (later != null && now.millisecondsSinceEpoch - later < _later.inMilliseconds) return;
    if (!mounted || _showing) return;
    final notes = [for (final n in (r['notes'] as List?) ?? const []) '$n'];
    _showing = true;
    final go = await showSheet<bool>(context, (_) => UpdateSheet(latest: latest, notes: notes, ios: platform == 'ios'));
    _showing = false;
    if (go == true) {
      await widget.open(url);
      // Вернулся, не обновив, — напомним при следующей проверке (через час).
    } else {
      await prefs.setInt(key, DateTime.now().millisecondsSinceEpoch);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Содержимое шторки «Есть обновление»: true — «Обновить», false / null — «Позже».
class UpdateSheet extends StatelessWidget {
  const UpdateSheet({super.key, required this.latest, required this.notes, required this.ios});

  final String latest;
  final List<String> notes;
  final bool ios;

  static const _bg = Color(0xFFF7F7F8);
  static const _ink = Color(0xFF151515);
  static const _text2 = Color(0xFF6B6B70);
  static const _green = Color(0xFF067647);

  @override
  Widget build(BuildContext context) {
    final store = ios ? 'App Store' : 'Google Play';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        icon: Icons.system_update_rounded,
        title: tr('Есть обновление', 'Yangilanish bor'),
        text: tr('Вышла версия $latest — обновитесь, чтобы пользоваться новыми функциями.',
            '$latest versiyasi chiqdi — yangi imkoniyatlardan foydalanish uchun ilovani yangilang.'),
      ),
      if (notes.isNotEmpty) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Что нового', 'Yangiliklar'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text2)),
            for (final n in notes) ...[
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.check_circle_rounded, size: 18, color: _green)),
                const SizedBox(width: 10),
                Expanded(child: Text(n, style: const TextStyle(fontSize: 15, height: 1.35, color: _ink))),
              ]),
            ],
          ]),
        ),
      ],
      const SizedBox(height: 20),
      SheetButton(label: tr('Обновить в $store', '$store’da yangilash'), onPressed: () => Navigator.pop(context, true)),
      const SizedBox(height: 10),
      SheetButton(label: tr('Позже', 'Keyinroq'), primary: false, onPressed: () => Navigator.pop(context, false)),
    ]);
  }
}
