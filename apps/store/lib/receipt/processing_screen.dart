import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'review_screen.dart';

/// П2 · ИИ читает накладную: ждём результат, затем — проверка.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.id});

  final String id;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  Timer? _timer;
  final _started = DateTime.now();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_done) return;
    try {
      final s = await context.read<Api>().get('/store/invoice-scans/${widget.id}') as Map<String, dynamic>;
      if (!mounted) return;
      if (s['status'] != 'processing') {
        _done = true;
        _timer?.cancel();
        await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ReviewScreen(id: widget.id)));
        return;
      }
      setState(() {});
    } catch (_) {
      // сеть моргнула — спросим ещё раз
    }
  }

  @override
  Widget build(BuildContext context) {
    final sec = DateTime.now().difference(_started).inSeconds;
    // Шаги — ориентир по времени: сервер распознаёт одним запросом к модели.
    final step = sec < 4 ? 0 : (sec < 9 ? 1 : 2);
    Widget row(int i, String text) {
      final done = i < step;
      final now = i == step;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
            width: 28,
            height: 28,
            child: now
                ? const Padding(padding: EdgeInsets.all(5), child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.primary))
                : IconBox(done ? Icons.check_rounded : Icons.radio_button_unchecked_rounded,
                    bg: done ? AppColors.successSoft : AppColors.soft, fg: done ? AppColors.success : AppColors.muted, size: 28, iconSize: 16, radius: 14),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AppText.body.copyWith(color: i > step ? AppColors.muted : AppColors.ink, fontWeight: now ? FontWeight.w600 : FontWeight.w500))),
        ]),
      );
    }

    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.bg, title: Text(tr('Новый приход', 'Yangi kirim'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          AppCard(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const IconBox(Icons.auto_awesome_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 22, radius: 12),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('ИИ читает накладную', 'Sunʼiy intellekt yuk xatini oʻqimoqda'), style: AppText.title),
                    Text(tr('Обычно 10–30 секунд', 'Odatda 10–30 soniya'), style: AppText.small),
                  ]),
                ),
              ]),
              const SizedBox(height: 14),
              row(0, tr('Читаем текст накладной', 'Yuk xati matnini oʻqiyapmiz')),
              row(1, tr('Находим поставщика, номер и итог', 'Yetkazib beruvchi, raqam va jamini topyapmiz')),
              row(2, tr('Сопоставляем товары с каталогом', 'Mahsulotlarni katalog bilan solishtiryapmiz')),
            ]),
          ),
          const SizedBox(height: 16),
          Text(tr('Можно закрыть экран — накладная сохранится в разделе «Склад → Накладные».', 'Ekranni yopish mumkin — yuk xati «Ombor → Yuk xatlari» boʻlimida saqlanadi.'),
              style: AppText.small, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
