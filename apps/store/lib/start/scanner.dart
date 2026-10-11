import 'dart:async';
import 'dart:io' show Platform;

import 'package:mobile_scanner/mobile_scanner.dart';

/// Сканеры штрихкодов, которые сейчас держат камеру (экран ещё открыт).
final _live = <MobileScannerController>{};

/// Сканер штрихкодов для «Начала работы».
///
/// iPhone: виртуальная камера (тройная / двойная широкая) с увеличением «1x».
/// Основная камера 1x на iPhone Pro не фокусируется ближе ~15–20 см — штрихкод,
/// поднесённый близко, размывается. Виртуальная камера сама переключается на
/// сверхширокую с макро-фокусом, когда штрихкод близко, и обратно. Сразу после
/// запуска она стоит на 0,5x (мелкая картинка), поэтому возвращаем «1x» —
/// resetZoomScale ставит зум, на котором включается основная камера. Делаем это
/// при каждом запуске: сканер перезапускается после системной камеры (фото).
///
/// Android: основная камера; autoZoom приближает, если штрихкод далеко.
///
/// Закрывать — только через [disposeScanner].
MobileScannerController barcodeScanner({List<BarcodeFormat> formats = const []}) {
  final ios = Platform.isIOS;
  final c = MobileScannerController(
    lensType: ios ? CameraLensType.any : CameraLensType.normal,
    autoZoom: !ios,
    formats: formats,
  );
  if (ios) {
    var wasRunning = false;
    c.addListener(() {
      final running = c.value.isRunning;
      if (running && !wasRunning && _live.contains(c)) {
        c.resetZoomScale().catchError((Object _) {});
      }
      wasRunning = running;
    });
  }
  _live.add(c);
  return c;
}

/// Дождаться, пока камера сканера закончит запускаться.
///
/// Пока идёт запуск, stop() ничего не делает, а закрытие плагина на iPhone
/// обнуляет сессию камеры, которую фоновый поток ещё запускает, — приложение
/// падало, если сканер быстро закрыть или переключить на «Фото».
Future<void> _settle(MobileScannerController c) async {
  for (var i = 0; i < 60 && c.value.isStarting; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Закрыть сканер безопасно: дождаться запуска, остановить камеру, освободить.
Future<void> disposeScanner(MobileScannerController c) async {
  _live.remove(c);
  await _settle(c);
  try {
    await c.stop();
  } catch (_) {
    // уже остановлен
  }
  try {
    await c.dispose();
  } catch (_) {
    // уже закрыт
  }
}

/// Камера сканера не нужна, пока поверх него шторка или другой экран.
///
/// После скана открываются шторки и экраны («Количество и цены», «Новый товар»),
/// а камера под ними продолжала снимать и искать штрихкоды — телефон грелся
/// и садился. Выключаем камеру сканера, после — запускаем снова.
/// Именно stop, а не pause: у плагина одно состояние камеры на все сканеры,
/// и после pause второй сканер (например, «Новый товар» → штрихкод) путал его.
Future<T> whileScannerIdle<T>(MobileScannerController? c, Future<T> Function() action) async {
  if (c == null) return action();
  final paused = await _pause(c);
  try {
    return await action();
  } finally {
    if (paused) _resume(c);
  }
}

/// Системная камера (фото товара) поверх работающего сканера.
///
/// Шторка количества и цен и «Новый товар» открывают камеру iPhone, пока под
/// ними работает сканер штрихкодов. Две камеры сразу — приложение закрывалось.
/// Поэтому сканеры на время снимка выключаем, а после — запускаем снова.
Future<T> withScannersPaused<T>(Future<T> Function() action) async {
  final paused = <MobileScannerController>[];
  for (final c in _live.toList()) {
    if (await _pause(c)) paused.add(c);
  }
  try {
    return await action();
  } finally {
    paused.forEach(_resume);
  }
}

/// Выключить камеру сканера (true — она работала и выключена).
Future<bool> _pause(MobileScannerController c) async {
  await _settle(c);
  if (!c.value.isRunning) return false;
  try {
    await c.stop();
    return true;
  } catch (_) {
    // не остановился — значит и не держит камеру
    return false;
  }
}

void _resume(MobileScannerController c) {
  if (_live.contains(c)) unawaited(c.start().catchError((Object _) {}));
}
