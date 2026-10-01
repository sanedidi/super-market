import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/codes.dart';
import '../data/api.dart';
import '../state/pos.dart';
import 'theme.dart';
import 'widgets.dart';

/// Первый запуск: код кассы из панели магазина → касса подключена.
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = fixLayout(_ctrl.text).toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');
    if (code.length != 8) {
      setState(() => _error = 'Код — 8 символов, как в панели магазина');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<PosController>().activate(code);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _Steps(),
          const SizedBox(height: 24),
          Container(
            width: 576,
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(24)),
            child: Column(children: [
              const Logo(size: 72),
              const SizedBox(height: 20),
              Text('Подключите кассу', style: t(28, w: FontWeight.w700)),
              const SizedBox(height: 16),
              Text(
                'Владелец создаёт кассу в панели магазина → «Кассы» и видит код. Он действует сутки.',
                textAlign: TextAlign.center,
                style: t(14, c: C.ts),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 360,
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  enabled: !_busy,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [_CodeFormatter()],
                  style: t(32, w: FontWeight.w700).copyWith(letterSpacing: 6),
                  decoration: const InputDecoration(hintText: 'XXXX-XXXX', contentPadding: EdgeInsets.symmetric(vertical: 16)),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: t(14, c: C.error)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(backgroundColor: C.brand, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18)),
                child: Text(_busy ? 'Подключаем…' : 'Подключить · Enter', style: t(15, w: FontWeight.w700, c: Colors.white)),
              ),
              const SizedBox(height: 24),
              Text('Нет интернета? Подключение нужно один раз — дальше касса работает и без него.', style: t(12, c: C.ts)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps();

  @override
  Widget build(BuildContext context) {
    Widget step(int n, String label, bool on) => Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: on ? C.brand : C.surface,
            child: Text('$n', style: t(12, w: FontWeight.w700, c: on ? Colors.white : C.ts)),
          ),
          const SizedBox(width: 8),
          Text(label, style: t(14, w: on ? FontWeight.w600 : FontWeight.w400, c: on ? C.tp : C.ts)),
        ]);
    final dash = Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('—', style: t(14, c: C.td)));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      step(1, 'Код кассы', true),
      dash,
      step(2, 'Вход кассира', false),
      dash,
      step(3, 'Открытие смены', false),
    ]);
  }
}

/// Буквы и цифры, верхний регистр, дефис после 4 символов.
class _CodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var s = fixLayout(newValue.text).toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');
    if (s.length > 8) s = s.substring(0, 8);
    final text = s.length > 4 ? '${s.substring(0, 4)}-${s.substring(4)}' : s;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}
