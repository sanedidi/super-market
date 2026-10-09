import 'dart:io' show Platform;

import 'package:mobile_scanner/mobile_scanner.dart';

/// Сканер штрихкодов для «Начала работы».
///
/// iPhone: виртуальная камера (тройная / двойная широкая) с увеличением «1x».
/// Основная камера 1x на iPhone Pro не фокусируется ближе ~15–20 см — штрихкод,
/// поднесённый близко, размывается. Виртуальная камера сама переключается на
/// сверхширокую с макро-фокусом, когда штрихкод близко, и обратно. Сразу после
/// запуска она стоит на 0,5x (мелкая картинка), поэтому возвращаем «1x» —
/// resetZoomScale ставит зум, на котором включается основная камера.
///
/// Android: основная камера; autoZoom приближает, если штрихкод далеко.
MobileScannerController barcodeScanner({List<BarcodeFormat> formats = const []}) {
  final ios = Platform.isIOS;
  final c = MobileScannerController(
    lensType: ios ? CameraLensType.any : CameraLensType.normal,
    autoZoom: !ios,
    formats: formats,
  );
  if (ios) {
    void onStart() {
      if (!c.value.isRunning) return;
      c.removeListener(onStart);
      c.resetZoomScale().catchError((Object _) {});
    }

    c.addListener(onStart);
  }
  return c;
}
