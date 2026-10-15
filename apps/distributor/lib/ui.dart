import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/start/scanner.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'logic.dart';

/// Цвета статуса магазина/товара.
(Color, Color) stockColors(StockStatus s) => switch (s) {
      StockStatus.out => (AppColors.primarySoft, AppColors.primary),
      StockStatus.low => (AppColors.warningSoft, AppColors.warningInk),
      StockStatus.ok => (AppColors.successSoft, AppColors.successInk),
      _ => (AppColors.soft, AppColors.text2),
    };

ChipTone stockTone(StockStatus s) => switch (s) {
      StockStatus.out => ChipTone.red,
      StockStatus.low => ChipTone.amber,
      StockStatus.ok => ChipTone.green,
      _ => ChipTone.gray,
    };

ChipTone orderTone(Object? s) => switch ('$s') {
      'new' => ChipTone.red,
      'accepted' => ChipTone.blue,
      'assembled' => ChipTone.amber,
      'delivered' => ChipTone.green,
      _ => ChipTone.gray,
    };

/// Иконка магазина в цвете статуса.
class StoreIcon extends StatelessWidget {
  const StoreIcon(this.status, {super.key});

  final StockStatus status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = stockColors(status);
    return IconBox(Icons.storefront_rounded, bg: bg, fg: fg, size: 40, iconSize: 20, radius: 12);
  }
}

/// Фото товара 44×44 или серая заглушка.
class ProductThumb extends StatelessWidget {
  const ProductThumb(this.url, {super.key, this.size = 44});

  final Object? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final u = '${url ?? ''}';
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: AppColors.bg,
        child: u.isEmpty
            ? const Icon(Icons.image_outlined, color: AppColors.muted, size: 20)
            : Image.network(u, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, color: AppColors.muted, size: 20)),
      ),
    );
  }
}

/// Заголовок секции в карточке: «Не хватает 5 … по продажам».
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.count, this.tone = ChipTone.red, this.action, this.onAction});

  final String title;
  final int? count;
  final ChipTone tone;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(title, style: AppText.title),
      if (count != null) ...[const SizedBox(width: 8), StatusChip('$count', tone: tone)],
      const Spacer(),
      if (action != null) TextButton(onPressed: onAction, child: Text(action!, style: AppText.bodyStrong.copyWith(color: AppColors.primary))),
    ]);
  }
}

/// Плитка со значением: «Закончилось 7 магаз.».
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.note, this.bg = AppColors.bg, this.fg = AppColors.ink});

  final String label;
  final String value;
  final String? note;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.small.copyWith(color: fg == AppColors.ink ? AppColors.text2 : fg)),
        const SizedBox(height: 4),
        Text(value, style: AppText.title.copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (note != null) Text(note!, style: AppText.small.copyWith(fontSize: 11, color: AppColors.muted)),
      ]),
    );
  }
}

/// Ошибка загрузки с «Повторить».
class LoadError extends StatelessWidget {
  const LoadError(this.error, {super.key, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.wifi_off_rounded,
        title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
        text: '$error',
        action: tr('Повторить', 'Qayta urinish'),
        onAction: onRetry,
      );
}

/// Позвонить.
Future<void> callPhone(Object? phone) async {
  final p = '${phone ?? ''}'.replaceAll(RegExp(r'[^0-9+]'), '');
  if (p.isEmpty) return;
  await launchUrl(Uri.parse('tel:$p'));
}

/// Сканер штрихкода на весь экран: возвращает первый распознанный код.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.title});

  final String? title;

  static Future<String?> open(BuildContext context, {String? title}) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => ScanScreen(title: title)));

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _c = barcodeScanner();
  bool _done = false;

  @override
  void dispose() {
    disposeScanner(_c);
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(v.trim());
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title ?? tr('Штрихкод', 'Shtrix-kod')),
      ),
      body: Stack(children: [
        MobileScanner(controller: _c, onDetect: _onDetect),
        Center(
          child: Container(
            width: 280,
            height: 140,
            decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(16)),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 48,
          child: Text(tr('Наведите камеру на штрихкод', 'Kamerani shtrix-kodga qarating'),
              textAlign: TextAlign.center, style: AppText.body.copyWith(color: Colors.white)),
        ),
      ]),
    );
  }
}
