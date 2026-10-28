import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/money.dart';
import '../state/pos.dart';
import 'close_shift_screen.dart';
import 'equipment_screen.dart';
import 'kit.dart';
import 'shift_menu_screen.dart' show XReportView;
import 'theme.dart';
import 'widgets.dart';

/// «День закрыт» — касса без открытой смены (Figma «Касса · Закрыть день»,
/// ЗД5): итог закрытого дня, «Начать день» (Enter) и меню. Если вчера день не
/// закрыли (смена на кассе или на сервере), «Начать день» спрашивает один раз
/// (ЗД3): Enter — касса закрывает её сама по расчёту и начинает новый день.
class DayClosedScreen extends StatefulWidget {
  const DayClosedScreen({super.key});

  @override
  State<DayClosedScreen> createState() => _DayClosedScreenState();
}

class _DayClosedScreenState extends State<DayClosedScreen> {
  bool _busy = false;
  String? _error;

  PosController get pos => context.read<PosController>();

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      int? cash;
      // Вчерашняя смена осталась открытой на кассе.
      final local = pos.shift;
      if (local != null) {
        final rep = pos.report;
        final choice = await showDialog<String>(
          context: context,
          builder: (_) => StartDayDialog(
            number: local.number,
            salesCount: rep.salesCount,
            salesTotal: rep.salesTotal,
            who: local.openedByName,
            left: rep.expectedCash,
          ),
        );
        if (!mounted || choice == null) return;
        if (choice == 'continue') {
          pos.continueShift();
          return;
        }
        await pos.closeShift(null, '', auto: true);
        cash = pos.lastDay?.left;
      }
      // Вчерашняя смена осталась открытой на сервере (Z-отчёт не дошёл).
      if (pos.online && local == null) {
        while (pos.syncing) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (pos.queue > 0) await pos.sync();
        ServerShift? stale;
        try {
          stale = await pos.staleServerShift();
        } catch (_) {
          stale = null;
        }
        if (!mounted) return;
        final sh = stale;
        if (sh != null) {
          final choice = await showDialog<String>(
            context: context,
            builder: (_) => StartDayDialog(
              number: sh.number,
              salesCount: sh.salesCount,
              salesTotal: sh.salesTotal,
              who: sh.openedByName,
              left: sh.expectedCash,
            ),
          );
          if (!mounted || choice == null) return;
          if (choice == 'continue') {
            await pos.continueServerShift(sh);
            return;
          }
          final err = await pos.closeServerShift(sh);
          if (err != null) {
            if (mounted) setState(() => _error = err);
            return;
          }
        }
      }
      cash ??= await pos.openingCashGuess();
      if (!mounted || pos.cashier == null) return;
      await pos.openShift(cash);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Пункт меню, которому нужна открытая смена.
  void _needDay() => setState(() => _error = tr('Сначала начните день — Enter', 'Avval kunni boshlang — Enter'));

  Future<void> _showX() async {
    if (pos.shift == null) {
      _needDay();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: C.page,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(width: 800, height: 640, child: Padding(padding: const EdgeInsets.all(12), child: XReportView(report: pos.report))),
      ),
    );
  }

  Future<void> _closeYesterday() async {
    if (pos.shift == null) {
      _needDay();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CloseShiftScreen()));
  }

  Future<void> _equipment() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const EquipmentScreen()));
  }

  bool _onKey(KeyEvent e) {
    if (_busy) return true;
    if (isEnter(e)) {
      // Только нажатие: удержанный Enter после «Закрыть день» не начинает новый день.
      if (e is KeyDownEvent) _start();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      pos.logout();
      return true;
    }
    switch (printable(e)) {
      case '1':
        _showX();
      case '2':
        _closeYesterday();
      case '3' || '4' || '5':
        _needDay();
      case '6':
        _equipment();
      case '7':
        pos.logout();
      default:
        return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    final d = densityOf(context);
    final now = DateTime.now();
    final last = pos.lastDay;
    // Итог закрытого сегодня дня (ЗД5); вчерашний или не закрытый — «Начните день».
    final day = last != null && pos.shift == null && last.closedAt.year == now.year && last.closedAt.month == now.month && last.closedAt.day == now.day
        ? last
        : null;
    final who = pos.cashier?.name ?? '';
    final subtitle = day != null
        ? [
            if (day.printed) tr('Отчёт напечатан', 'Hisobot chop etildi'),
            if (day.number != null) tr('смена №${day.number}', 'smena №${day.number}'),
            tr('${day.salesCount} чеков', '${day.salesCount} ta chek'),
            fmtMoney(day.salesTotal),
            day.closedBy,
          ].join('  ·  ')
        : tr('Начните день, чтобы продавать  ·  $who', 'Sotish uchun kunni boshlang  ·  $who');
    final sync = pos.catalogAt;
    final tw = switch (d) { Density.l => 216.0, Density.m => 200.0, Density.s => 186.0 };
    final th = switch (d) { Density.l => 112.0, Density.m => 104.0, Density.s => 96.0 };
    final tiles = <_Tile>[
      _Tile(Icons.play_arrow_outlined, _busy ? tr('Начинаем…', 'Boshlanmoqda…') : tr('Начать день', 'Kunni boshlash'), 'Enter', _start, primary: true),
      _Tile(Icons.bar_chart_rounded, tr('X-отчёт', 'X-hisobot'), '1', _showX),
      _Tile(Icons.power_settings_new_rounded, tr('Закрыть день', 'Kunni yopish'), '2', _closeYesterday, danger: true),
      _Tile(Icons.swap_horiz_rounded, tr('Внесение / изъятие', 'Kiritish / olish'), '3', _needDay),
      _Tile(Icons.receipt_long_outlined, tr('Чеки смены', 'Smena cheklari'), '4', _needDay),
      _Tile(Icons.menu_book_outlined, tr('Погашение долга', 'Qarzni toʻlash'), '5', _needDay),
      _Tile(Icons.print_outlined, tr('Оборудование', 'Uskunalar'), '6', _equipment),
      _Tile(Icons.lock_outline_rounded, tr('Блокировка', 'Bloklash'), '7', pos.logout),
      _Tile(Icons.logout_rounded, tr('Выход', 'Chiqish'), 'Esc', pos.logout, danger: true),
    ];

    Widget tile(_Tile x) => SizedBox(
          width: tw,
          height: th,
          child: Material(
            color: x.primary ? C.brand : C.surface,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _busy ? null : x.onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: x.primary ? null : BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(x.icon, size: 30, color: x.primary ? Colors.white : (x.danger ? C.error : C.t2)),
                  const SizedBox(height: 8),
                  FitText(x.label, textAlign: TextAlign.center, style: t(15, w: FontWeight.w600, c: x.primary ? Colors.white : C.tp)),
                  const SizedBox(height: 4),
                  FitText(x.hint, textAlign: TextAlign.center, style: t(12, w: FontWeight.w500, c: x.primary ? C.brandLine : C.td)),
                ]),
              ),
            ),
          ),
        );

    return Scaffold(
      backgroundColor: C.page,
      body: KeyCatcher(
        onKey: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('День закрыт', 'Kun yopilgan'), style: tb(24)),
                      const SizedBox(height: 2),
                      FitText(subtitle, style: t(13, w: FontWeight.w500, c: C.td)),
                    ]),
                  ),
                  if (sync != null)
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(tr('Синхронизация', 'Sinxronizatsiya'), style: t(12, c: C.td)),
                      Text('${sync.hour.toString().padLeft(2, '0')}:${sync.minute.toString().padLeft(2, '0')}', style: t(14, w: FontWeight.w700)),
                    ]),
                ]),
                if (day != null && !day.auto) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(color: C.successSoft, borderRadius: BorderRadius.circular(12)),
                    child: Text(
                      day.printed
                          ? tr('✓ День закрыт — отчёт напечатан. Размен ${fmtMoney(day.left)} оставлен в ящике, завтра он подставится сам.',
                              '✓ Kun yopildi — hisobot chop etildi. ${fmtMoney(day.left)} maydalik gʻaladonda qoldi, ertaga oʻzi qoʻyiladi.')
                          : tr('✓ День закрыт. Размен ${fmtMoney(day.left)} оставлен в ящике, завтра он подставится сам.',
                              '✓ Kun yopildi. ${fmtMoney(day.left)} maydalik gʻaladonda qoldi, ertaga oʻzi qoʻyiladi.'),
                      style: t(13, w: FontWeight.w500, c: C.success),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(12)),
                    child: Text(_error!, style: t(13, w: FontWeight.w600, c: C.error)),
                  ),
                ],
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (d != Density.s) ...[
                          Container(
                            width: 92,
                            height: 92,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(22)),
                            child: Text('Super\nMarket', textAlign: TextAlign.center, style: tb(24, c: Colors.white, h: 0.95)),
                          ),
                          const SizedBox(height: 20),
                        ],
                        for (var r = 0; r < 3; r++) ...[
                          if (r > 0) const SizedBox(height: 8),
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            for (var c = 0; c < 3; c++) ...[
                              if (c > 0) const SizedBox(width: 8),
                              tile(tiles[r * 3 + c]),
                            ],
                          ]),
                        ],
                      ]),
                    ),
                  ),
                ),
                Row(children: [
                  Expanded(
                    child: Text(
                      [
                        pos.catalog.settings.deviceName,
                        pos.fiscalMode ? tr('фискальный модуль подключён', 'fiskal modul ulangan') : tr('тестовый режим', 'test rejimi'),
                        tr('версия ${pos.appVersion}', 'versiya ${pos.appVersion}'),
                      ].where((x) => x.isNotEmpty).join('  ·  '),
                      style: t(12, c: C.td),
                    ),
                  ),
                  Material(
                    color: C.exit,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _busy ? null : pos.logout,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.people_outline_rounded, size: 18, color: Colors.white),
                          const SizedBox(width: 8),
                          Text(tr('Сменить кассира', 'Kassirni almashtirish'), style: t(14, w: FontWeight.w600, c: Colors.white)),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Tile {
  const _Tile(this.icon, this.label, this.hint, this.onTap, {this.primary = false, this.danger = false});

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;
}

/// ЗД3: «Начать день», когда вчерашняя смена не закрыта (на кассе или на
/// сервере). Enter — касса закрывает её сама по расчёту (pos_auto) и начинает
/// новый день; 2 — редкий случай: продолжить ту же смену. Возвращает
/// 'start', 'continue' или null (Esc).
class StartDayDialog extends StatelessWidget {
  const StartDayDialog({
    super.key,
    required this.number,
    required this.salesCount,
    required this.salesTotal,
    required this.who,
    required this.left,
  });

  final int? number;
  final int salesCount;
  final int salesTotal;
  final String who;

  /// Наличные по расчёту — останутся в ящике размéном нового дня.
  final int left;

  @override
  Widget build(BuildContext context) {
    final no = number == null ? '' : ' №$number';
    final whoPart = who.isEmpty ? '' : ' · $who';
    Widget option({required String title, required String sub, required String keyLabel, required bool main, required VoidCallback onTap}) => Material(
          color: main ? C.brandSoft : C.surface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 18, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: main ? C.brand : C.borderStrong, width: main ? 2 : 1),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: t(17, w: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(sub, style: t(13, c: C.ts, h: 1.3)),
                  ]),
                ),
                const SizedBox(width: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: main ? C.brand : C.keyBg, borderRadius: BorderRadius.circular(8)),
                  child: Text(keyLabel, style: t(14, w: FontWeight.w700, c: main ? Colors.white : C.tp)),
                ),
              ]),
            ),
          ),
        );
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        // Только нажатие: удержанный Enter с прошлого экрана не выбирает за кассира.
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (isEnter(e)) {
          Navigator.of(context).pop('start');
          return KeyEventResult.handled;
        }
        if (printable(e) == '2') {
          Navigator.of(context).pop('continue');
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        backgroundColor: C.surface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr('Начать день', 'Kunni boshlash'), style: tb(24)),
              const SizedBox(height: 12),
              Text(
                tr('Вчерашняя смена$no не была закрыта: $salesCount чеков · ${fmtMoney(salesTotal)}$whoPart. Enter — касса закроет её сама по расчёту и начнёт новый день. Отчёт за вчера — в панели, Финансы → Смены.',
                    'Kechagi$no smena yopilmagan: $salesCount ta chek · ${fmtMoney(salesTotal)}$whoPart. Enter — kassa uni hisob boʻyicha oʻzi yopadi va yangi kunni boshlaydi. Kechagi hisobot — panelda, Moliya → Smenalar.'),
                style: t(15, c: C.ts, h: 1.35),
              ),
              const SizedBox(height: 18),
              option(
                title: tr('Начать день', 'Kunni boshlash'),
                sub: tr('Размен в ящике ${fmtMoney(left)} — как оставили вчера. Вчерашняя смена закроется по расчёту, пересчёт не нужен.',
                    'Gʻaladonda ${fmtMoney(left)} maydalik — kecha qanday qoldirilgan boʻlsa. Kechagi smena hisob boʻyicha yopiladi, sanash shart emas.'),
                keyLabel: 'Enter',
                main: true,
                onTap: () => Navigator.of(context).pop('start'),
              ),
              const SizedBox(height: 10),
              option(
                title: tr('Продолжить вчерашнюю смену$no', 'Kechagi$no smenani davom ettirish'),
                sub: tr('Редкий случай: касса переустановлена, а это та же смена. Закрывать не будем, продажи пойдут в$no.',
                    'Kamdan-kam holat: kassa qayta oʻrnatilgan va bu oʻsha smena. Yopmaymiz, sotuvlar$no ga yoziladi.'),
                keyLabel: '2',
                main: false,
                onTap: () => Navigator.of(context).pop('continue'),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(width: 160, height: 46, child: PosButton(label: tr('Отмена', 'Bekor qilish'), hint: 'Esc', center: true, onTap: () => Navigator.of(context).pop())),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
