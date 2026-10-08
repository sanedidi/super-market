import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show LangSwitch, tr;

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
      setState(() => _error = tr('Код — 8 символов, как в панели магазина', 'Kod — 8 ta belgi, doʻkon panelidagidek'));
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
      body: Stack(children: [
        Center(
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
                Text(tr('Подключите кассу', 'Kassani ulang'), style: t(28, w: FontWeight.w700)),
                const SizedBox(height: 16),
                Text(
                  tr('Владелец создаёт кассу в панели магазина → «Кассы» и видит код. Он действует сутки.',
                      'Egasi doʻkon panelida → «Kassalar» boʻlimida kassa yaratadi va kodni koʻradi. Kod bir sutka amal qiladi.'),
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
                  child: Text(_busy ? tr('Подключаем…', 'Ulanmoqda…') : tr('Подключить · Enter', 'Ulash · Enter'), style: t(15, w: FontWeight.w700, c: Colors.white)),
                ),
                const SizedBox(height: 24),
                Text(tr('Нет интернета? Подключение нужно один раз — дальше касса работает и без него.', 'Internet yoʻqmi? Ulanish bir marta kerak — keyin kassa usiz ham ishlaydi.'), style: t(12, c: C.ts)),
              ]),
            ),
          ]),
        ),
        const Positioned(top: 24, right: 24, child: LangSwitch()),
      ]),
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
      step(1, tr('Код кассы', 'Kassa kodi'), true),
      dash,
      step(2, tr('Вход кассира', 'Kassir kirishi'), false),
      dash,
      step(3, tr('Открытие смены', 'Smenani ochish'), false),
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

/// Касса отключена в панели (или подключена заново на другом компьютере).
class RevokedScreen extends StatelessWidget {
  const RevokedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    return Scaffold(
      body: Center(
        child: Container(
          width: 576,
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(24)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Logo(size: 72),
            const SizedBox(height: 20),
            Text(tr('Касса отключена', 'Kassa oʻchirilgan'), style: t(28, w: FontWeight.w700)),
            const SizedBox(height: 12),
            Text(
              tr(
                  'Эту кассу отключили в панели магазина или подключили на другом компьютере. '
                      'Создайте кассу в панели: «Касса → Кассы и ПИНы → Новая касса», и введите новый код.',
                  'Bu kassa doʻkon panelida oʻchirilgan yoki boshqa kompyuterda ulangan. '
                      'Panelda kassa yarating: «Kassa → Kassalar va PIN-kodlar → Yangi kassa» va yangi kodni kiriting.'),
              textAlign: TextAlign.center,
              style: t(14, c: C.ts),
            ),
            if (pos.queue > 0 || pos.shift != null) ...[
              const SizedBox(height: 12),
              Text(
                tr('Неотправленные чеки (${pos.queue}) и смена сохранены на кассе — после подключения они уйдут на сервер.',
                    'Yuborilmagan cheklar (${pos.queue}) va smena kassada saqlangan — ulangandan keyin serverga yuboriladi.'),
                textAlign: TextAlign.center,
                style: t(13, c: C.warning),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: pos.reconnect,
              style: FilledButton.styleFrom(backgroundColor: C.brand, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18)),
              child: Text(tr('Ввести новый код', 'Yangi kodni kiritish'), style: t(15, w: FontWeight.w700, c: Colors.white)),
            ),
          ]),
        ),
      ),
    );
  }
}
