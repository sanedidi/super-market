import 'package:flutter/material.dart';

import 'api.dart';
import 'i18n.dart';

/// Кнопка «Перевести автоматически» для двуязычных полей (uz/ru).
///
/// Ставится в `suffixIcon` поля, которое нужно заполнить: берёт текст из
/// [source] (поле на другом языке), переводит через AI сервера на язык [to]
/// и пишет результат в [target].
///
/// ```dart
/// TextField(
///   controller: nameUz,
///   decoration: InputDecoration(
///     labelText: tr('Название (узб.)', 'Nomi (oʻzb.)'),
///     suffixIcon: TranslateButton(api: api, source: nameRu, target: nameUz, to: Lang.uz),
///   ),
/// )
/// ```
class TranslateButton extends StatefulWidget {
  const TranslateButton({
    super.key,
    required this.api,
    required this.source,
    required this.target,
    required this.to,
    this.onDone,
  });

  final Api api;
  final TextEditingController source;
  final TextEditingController target;

  /// Язык результата: [Lang.uz] или [Lang.ru].
  final String to;

  final VoidCallback? onDone;

  @override
  State<TranslateButton> createState() => _TranslateButtonState();
}

class _TranslateButtonState extends State<TranslateButton> {
  bool _busy = false;

  Future<void> _run() async {
    final text = widget.source.text.trim();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (text.isEmpty) {
      messenger?.showSnackBar(SnackBar(
        content: Text(widget.to == Lang.uz
            ? tr('Сначала заполните поле на русском', 'Avval rus tilidagi maydonni toʻldiring')
            : tr('Сначала заполните поле на узбекском', 'Avval oʻzbek tilidagi maydonni toʻldiring')),
      ));
      return;
    }
    setState(() => _busy = true);
    try {
      final out = await widget.api.translate([text], to: widget.to);
      if (out.isNotEmpty && out.first.trim().isNotEmpty) {
        widget.target.text = out.first.trim();
        widget.onDone?.call();
      }
    } on ApiError catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(tr('Не удалось перевести', 'Tarjima qilib boʻlmadi'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return IconButton(
      tooltip: tr('Перевести автоматически', 'Avtomatik tarjima qilish'),
      icon: const Icon(Icons.translate_rounded),
      onPressed: _run,
    );
  }
}
