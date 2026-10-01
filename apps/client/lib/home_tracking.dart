import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sm_core/sm_core.dart';

/// Статистика витрины: показы и нажатия блоков главной.
///
/// Показ — блок виден хотя бы наполовину 1 секунду (повторно — только после
/// того, как он уходил с экрана). Нажатие — касание внутри блока без
/// прокрутки. События копятся и уходят пачкой раз в 20 секунд, при
/// сворачивании приложения и при уходе с главной.
class HomeTracker with WidgetsBindingObserver {
  HomeTracker({required this.api, required this.storeId, required this.isActive});

  final Api api;
  final String storeId;

  /// Главная сейчас на экране (вкладка выбрана, сверху нет другого экрана).
  final bool Function() isActive;

  final _views = <String, int>{};
  final _clicks = <String, int>{};
  final _blocks = <String, BuildContext>{};
  final _visibleSince = <String, DateTime>{};
  final _counted = <String>{};
  Timer? _tick;
  Timer? _flush;

  static const minVisible = 0.5;
  static const minDuration = Duration(seconds: 1);

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(milliseconds: 300), (_) => check());
    _flush = Timer.periodic(const Duration(seconds: 20), (_) => flush());
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _flush?.cancel();
    flush();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      flush();
      _visibleSince.clear();
      _counted.clear();
    }
  }

  void register(String blockId, BuildContext context) => _blocks[blockId] = context;

  void unregister(String blockId, BuildContext context) {
    if (_blocks[blockId] == context) _blocks.remove(blockId);
  }

  void click(String blockId) => _clicks[blockId] = (_clicks[blockId] ?? 0) + 1;

  /// Доля блока на экране (0…1). Блок выше экрана считается видимым
  /// целиком, если занимает весь экран.
  static double visibleFraction(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize || box.size.height == 0) return 0;
    final view = View.maybeOf(context);
    if (view == null) return 0;
    final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final seen = rect.intersect(screen);
    if (seen.width <= 0 || seen.height <= 0) return 0;
    return seen.height / (rect.height < screen.height ? rect.height : screen.height);
  }

  /// Проверка видимости; now — для тестов.
  void check([DateTime? at]) {
    final now = at ?? DateTime.now();
    final active = isActive();
    for (final e in _blocks.entries) {
      final visible = active && e.value.mounted && visibleFraction(e.value) >= minVisible;
      if (!visible) {
        _visibleSince.remove(e.key);
        _counted.remove(e.key);
        continue;
      }
      final since = _visibleSince.putIfAbsent(e.key, () => now);
      if (!_counted.contains(e.key) && now.difference(since) >= minDuration) {
        _counted.add(e.key);
        _views[e.key] = (_views[e.key] ?? 0) + 1;
      }
    }
  }

  /// Отправить накопленное. Ошибка сети — события пропадут (статистика
  /// приблизительная, это честно написано в панели).
  Future<void> flush() async {
    final ids = {..._views.keys, ..._clicks.keys};
    if (ids.isEmpty) return;
    final items = [
      for (final id in ids) {'block_id': id, 'views': _views[id] ?? 0, 'clicks': _clicks[id] ?? 0},
    ];
    _views.clear();
    _clicks.clear();
    try {
      await api.post('/client/home/events', {'store_id': storeId, 'items': items});
    } catch (_) {}
  }

  /// Сколько накоплено (для тестов).
  Map<String, (int, int)> get pending => {
        for (final id in {..._views.keys, ..._clicks.keys}) id: (_views[id] ?? 0, _clicks[id] ?? 0),
      };
}

/// Блок главной: отдаёт вложенным виджетам свой id (товар в корзине
/// запомнит, откуда его добавили) и считает показы и нажатия.
class HomeBlockScope extends InheritedWidget {
  const HomeBlockScope({super.key, required this.blockId, required super.child});
  final String blockId;

  static String? of(BuildContext context) => context.getInheritedWidgetOfExactType<HomeBlockScope>()?.blockId;

  @override
  bool updateShouldNotify(HomeBlockScope old) => old.blockId != blockId;
}

class HomeTrackerScope extends InheritedWidget {
  const HomeTrackerScope({super.key, required this.tracker, required super.child});
  final HomeTracker? tracker;

  static HomeTracker? of(BuildContext context) => context.getInheritedWidgetOfExactType<HomeTrackerScope>()?.tracker;

  @override
  bool updateShouldNotify(HomeTrackerScope old) => old.tracker != tracker;
}

/// Обёртка блока: регистрирует его в трекере и считает касания.
class TrackedBlock extends StatefulWidget {
  const TrackedBlock({super.key, required this.blockId, required this.child});
  final String blockId;
  final Widget child;

  @override
  State<TrackedBlock> createState() => _TrackedBlockState();
}

class _TrackedBlockState extends State<TrackedBlock> {
  HomeTracker? _tracker;
  Offset? _down;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final t = HomeTrackerScope.of(context);
    if (t != _tracker) {
      _tracker?.unregister(widget.blockId, context);
      _tracker = t;
      _tracker?.register(widget.blockId, context);
    }
  }

  @override
  void dispose() {
    _tracker?.unregister(widget.blockId, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HomeBlockScope(
      blockId: widget.blockId,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => _down = e.position,
        onPointerUp: (e) {
          final d = _down;
          _down = null;
          if (d != null && (e.position - d).distance < 12) _tracker?.click(widget.blockId);
        },
        onPointerCancel: (_) => _down = null,
        child: widget.child,
      ),
    );
  }
}
