import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart' show tr;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../state/pos.dart';
import 'rejected_dialog.dart';
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
  String? _error;

  /// Штрихкод со сканера — не размен в ящике.
  late final _scan = ScanGuard(
    snapshot: () {
      final input = _input;
      return () => _input = input;
    },
    onScan: (_) {
      if (!mounted) return;
      SystemSound.play(SystemSoundType.alert);
      setState(() => _error = scanRejected);
    },
  );

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  // Размен, оставленный при сдаче кассы (Figma «Финансы понятно», Ф2):
  // подставляем его, кассиру вводить не нужно.
  String? _left;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLeft());
  }

  Future<void> _loadLeft() async {
    final pos = context.read<PosController>();
    if (!pos.online) return;
    try {
      final left = await pos.leftInDrawer();
      if (!mounted || left == null) return;
      setState(() {
        _left = left;
        if (_input.isEmpty) _input = left;
      });
    } catch (_) {
      // без связи — кассир наберёт размен сам
    }
  }

  Future<void> _open() async {
    if (_busy) return;
    final pos = context.read<PosController>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // НП4: на сервере осталась открытой прошлая смена этой кассы — новую он
      // не примет. Без связи открываем как раньше (разберётся «Не принято»).
      ServerShift? found;
      if (pos.online) {
        // Сначала доотправить очередь: Z-отчёт прошлой смены мог ещё не уйти.
        while (pos.syncing) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (pos.queue > 0) await pos.sync();
        try {
          found = await pos.staleServerShift();
        } catch (_) {
          found = null;
        }
      }
      if (!mounted) return;
      final stale = found;
      if (stale != null) {
        final choice = await showDialog<String>(context: context, builder: (_) => StaleShiftOnOpen(shift: stale));
        if (!mounted || choice == null) return;
        if (choice == 'continue') {
          await pos.continueServerShift(stale);
          return;
        }
        final err = await pos.closeServerShift(stale);
        if (err != null) {
          if (mounted) setState(() => _error = err);
          return;
        }
        if (mounted) showPosNote(context, tr('Смена №${stale.number} закрыта на сервере', 'Smena №${stale.number} serverda yopildi'));
      }
      await pos.openShift(parseMoney(_input));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _onKey(KeyEvent e) {
    if (_scan.key(e)) return true;
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
      setState(() {
        _input += ch;
        _error = null;
      });
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
                      if (_left != null) ...[
                        const SizedBox(height: 6),
                        Text(
                            _input == _left
                                ? tr('Оставлено при сдаче кассы — пересчитайте и нажмите Enter', 'Kassani topshirishda qoldirilgan — sanab, Enter bosing')
                                : tr('При сдаче кассы оставили ${fmtMoney(parseMoney(_left))}', 'Kassani topshirishda ${fmtMoney(parseMoney(_left))} qoldirilgan'),
                            style: t(13, c: Colors.white70)),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 16),
                  Center(child: NumPad(onDigit: _onDigit, onBackspace: _back)),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(10)),
                      child: Text(_error!, style: t(13, w: FontWeight.w600, c: C.error)),
                    ),
                  ],
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
    if (_input.length < 10) {
      setState(() {
        _input += d;
        _error = null;
      });
    }
  }

  void _back() {
    if (_input.isNotEmpty) setState(() => _input = _input.substring(0, _input.length - 1));
  }
}
