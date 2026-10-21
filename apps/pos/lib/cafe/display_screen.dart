// Экран выдачи для гостей (Figma «Кухня» КХ3): телевизор в зале. Слева
// номера, которые готовятся, справа — «Готово — заберите». Новый готовый
// номер подсвечивается и звучит сигнал.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../data/api.dart';
import '../state/pos.dart';
import '../ui/theme.dart';
import 'kitchen_board.dart';

const _green = Color(0xFF079455);
const _greenSoft = Color(0xFFECFDF3);

class DisplayScreen extends StatefulWidget {
  const DisplayScreen({super.key});

  @override
  State<DisplayScreen> createState() => _DisplayScreenState();
}

class _DisplayScreenState extends State<DisplayScreen> {
  late final PosController pos = context.read<PosController>();
  late final LiveFeed feed;
  DisplayData data = DisplayData();

  /// Номер стал готов — когда (подсветка 10 секунд).
  final Map<int, DateTime> _fresh = {};
  bool _first = true;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    feed = LiveFeed(baseUrl: pos.api.baseUrl, token: pos.api.token, load: _load)
      ..addListener(_changed)
      ..start();
    // Подсветка гаснет сама; номера, убранные по времени, — перечитать.
    _tick = Timer.periodic(const Duration(seconds: 5), (timer) {
      final n = _fresh.length;
      _fresh.removeWhere((_, at) => DateTime.now().difference(at) > const Duration(seconds: 10));
      if (n != _fresh.length && mounted) setState(() {});
      // Готовый номер убирается и по времени — сервер не шлёт событие.
      if (timer.tick % 6 == 0) unawaited(feed.refresh());
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _tick?.cancel();
    feed.removeListener(_changed);
    feed.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<int> _load(PosApi api) async {
    final res = await api.get('/pos/kitchen/display') as Map<String, dynamic>;
    final next = DisplayData.fromJson(res);
    final added = next.ready.where((n) => !data.ready.contains(n)).toList();
    if (!_first && added.isNotEmpty) {
      for (final n in added) {
        _fresh[n] = DateTime.now();
      }
      SystemSound.play(SystemSoundType.alert);
    }
    _first = false;
    if (mounted) {
      setState(() => data = next);
    } else {
      data = next;
    }
    return (res['version'] as num?)?.toInt() ?? 0;
  }

  String _no(int n) => n.toString().padLeft(3, '0');

  @override
  Widget build(BuildContext context) {
    final storeName = data.storeName.isNotEmpty ? data.storeName : pos.catalog.settings.storeName;
    return Scaffold(
      backgroundColor: C.surface,
      body: LayoutBuilder(builder: (context, c) {
        final k = (c.maxHeight / 720).clamp(0.6, 2.0).toDouble();
        return Column(children: [
          Container(
            height: 72 * k,
            color: C.brand,
            padding: EdgeInsets.symmetric(horizontal: 32 * k),
            child: Row(children: [
              Expanded(child: Text(storeName, maxLines: 1, overflow: TextOverflow.ellipsis, style: tb(30 * k, c: Colors.white))),
              if (!feed.online)
                Padding(
                  padding: EdgeInsets.only(right: 20 * k),
                  child: Text(tr('нет связи', 'aloqa yoʻq'), style: t(16 * k, w: FontWeight.w600, c: Colors.white)),
                ),
              Text(tr('Номер — на вашем чеке', 'Raqam — chekingizda'), style: t(20 * k, w: FontWeight.w600, c: Colors.white)),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(28 * k),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (data.showCooking) ...[
                  Expanded(child: _cooking(k)),
                  SizedBox(width: 28 * k),
                ],
                Expanded(child: _ready(k)),
              ]),
            ),
          ),
        ]);
      }),
    );
  }

  Widget _panel({required double k, required Color bg, required IconData icon, required String title, required Color color, required Widget child}) =>
      Container(
        padding: EdgeInsets.all(28 * k),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18 * k)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color, size: 30 * k),
            SizedBox(width: 12 * k),
            Text(title, style: t(28 * k, w: FontWeight.w800, c: color)),
          ]),
          SizedBox(height: 22 * k),
          Expanded(child: child),
        ]),
      );

  Widget _cooking(double k) => _panel(
        k: k,
        bg: C.keyBg,
        icon: Icons.soup_kitchen_outlined,
        title: tr('Готовим', 'Tayyorlanmoqda'),
        color: C.t2,
        child: SingleChildScrollView(
          child: Wrap(spacing: 14 * k, runSpacing: 14 * k, children: [
            for (final n in data.cooking)
              Container(
                width: 150 * k,
                height: 82 * k,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12 * k), border: Border.all(color: C.border)),
                child: Text(_no(n), style: tb(44 * k, c: C.t2)),
              ),
          ]),
        ),
      );

  Widget _ready(double k) => _panel(
        k: k,
        bg: _greenSoft,
        icon: Icons.check_circle_outline_rounded,
        title: tr('Готово — заберите', 'Tayyor — olib keting'),
        color: _green,
        child: SingleChildScrollView(
          child: Wrap(spacing: 18 * k, runSpacing: 18 * k, children: [
            for (final n in data.ready)
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 250 * k,
                height: 120 * k,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _green,
                  borderRadius: BorderRadius.circular(14 * k),
                  border: Border.all(color: _fresh.containsKey(n) ? C.brand : _green, width: 6 * k),
                ),
                child: Text(_no(n), style: tb(80 * k, c: Colors.white)),
              ),
          ]),
        ),
      );
}
