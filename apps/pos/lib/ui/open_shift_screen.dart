import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart' show tr;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../state/pos.dart';
import 'theme.dart';
import 'widgets.dart';

/// Открытие смены: сколько размена положили в ящик. Enter — открыть.
class OpenShiftScreen extends StatefulWidget {
  const OpenShiftScreen({super.key});

  @override
  State<OpenShiftScreen> createState() => _OpenShiftScreenState();
}

class _OpenShiftScreenState extends State<OpenShiftScreen> {
  String _input = '';
  bool _busy = false;

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await context.read<PosController>().openShift(parseMoney(_input));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _onKey(KeyEvent e) {
    final k = e.logicalKey;
    if (isEnter(e)) {
      _open();
      return true;
    }
    if (k == LogicalKeyboardKey.backspace) {
      if (_input.isNotEmpty) setState(() => _input = _input.substring(0, _input.length - 1));
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_input.isEmpty) {
        context.read<PosController>().logout();
      } else {
        setState(() => _input = '');
      }
      return true;
    }
    final ch = printable(e);
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch) && _input.length < 10) {
      setState(() => _input += ch);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    final amount = parseMoney(_input);
    return Scaffold(
      body: KeyCatcher(
        onKey: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Center(
              child: SizedBox(
                width: 560,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(tr('Открытие смены', 'Smenani ochish'), style: t(28, w: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(
                      tr('${pos.cashier?.name ?? ''}, сколько размена в ящике? Наберите сумму и Enter. Нет размена — просто Enter.',
                          '${pos.cashier?.name ?? ''}, gʻaladonda qancha mayda pul bor? Summani tering va Enter. Mayda pul yoʻq boʻlsa — shunchaki Enter.'),
                      style: t(14, c: C.ts)),
                  const SizedBox(height: 24),
                  Panel(
                    color: C.dark,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('Размен на начало смены', 'Smena boshidagi mayda pul'), style: t(14, c: Colors.white70)),
                      const SizedBox(height: 8),
                      Text(fmtMoney(amount), style: t(56, w: FontWeight.w700, c: Colors.white)),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  Center(child: NumPad(onDigit: _onDigit, onBackspace: _back)),
                  const SizedBox(height: 16),
                  KeyCard(
                    keyLabel: 'Enter',
                    title: _busy ? tr('Открываем…', 'Ochilmoqda…') : tr('Открыть смену', 'Smenani ochish'),
                    subtitle: tr('дальше — продажа', 'keyin — sotuv'),
                    style: KeyCardStyle.primary,
                    onTap: _open,
                  ),
                  const SizedBox(height: 8),
                  KeyCard(keyLabel: 'Esc', title: tr('Другой кассир', 'Boshqa kassir'), onTap: () => pos.logout()),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  void _onDigit(String d) {
    if (_input.length < 10) setState(() => _input += d);
  }

  void _back() {
    if (_input.isNotEmpty) setState(() => _input = _input.substring(0, _input.length - 1));
  }
}
