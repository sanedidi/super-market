import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../push.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'app_lock.dart';

/// Выйти из аккаунта: код этого входа стирается, дальше — снова по номеру.
Future<void> signOut(BuildContext context) async {
  final api = context.read<Api>();
  final lock = context.read<AppLock>();
  await Push.unregister(api);
  await api.logout();
  await lock.clear();
}

// ------------------------------------------------------------------ виджеты

/// Точки кода: заполненные, пустые, красные при ошибке.
class PinDots extends StatelessWidget {
  const PinDots({super.key, required this.filled, this.error = false});

  final int filled;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < pinLength; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 9),
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled ? (error ? AppColors.error : AppColors.ink) : Colors.transparent,
              border: i < filled ? null : Border.all(color: const Color(0xFFC7C7CC), width: 2),
            ),
          ),
      ]),
    );
  }
}

/// Цифровая клавиатура 3×4; слева внизу — Face ID (если есть).
class PinPad extends StatelessWidget {
  const PinPad({super.key, required this.onDigit, required this.onBackspace, this.onBiometrics});

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onBiometrics;

  @override
  Widget build(BuildContext context) {
    Widget key(Widget child, VoidCallback? onTap, {bool plain = false}) => SizedBox(
          width: 76,
          height: 76,
          child: Material(
            color: plain ? Colors.transparent : AppColors.white,
            shape: const CircleBorder(),
            child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Center(child: child)),
          ),
        );
    Widget digit(String d) => key(Text(d, style: const TextStyle(fontFamily: 'Inter', fontSize: 28, fontWeight: FontWeight.w500, color: AppColors.ink)), () {
          HapticFeedback.selectionClick();
          onDigit(d);
        });
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final r in rows) ...[
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final d in r) Padding(padding: const EdgeInsets.symmetric(horizontal: 13), child: digit(d)),
        ]),
        const SizedBox(height: 14),
      ],
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: onBiometrics == null
              ? const SizedBox(width: 76, height: 76)
              : key(const Icon(Icons.face_unlock_rounded, size: 30, color: AppColors.primary), onBiometrics, plain: true),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 13), child: digit('0')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: key(const Icon(Icons.backspace_rounded, size: 28, color: AppColors.ink), onBackspace, plain: true),
        ),
      ]),
    ]);
  }
}

class _LockIcon extends StatelessWidget {
  const _LockIcon();

  @override
  Widget build(BuildContext context) =>
      const IconBox(Icons.lock_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 56, iconSize: 28, radius: 28);
}

// ------------------------------------------------------------ В3, В4, В5

/// Придумать код (В3), повторить (В4), затем предложить Face ID (В5).
/// [change] — смена кода из настроек: по готовности экран закрывается.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key, this.change = false});

  final bool change;

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String _first = '';
  String _pin = '';
  bool _repeat = false;
  String? _error;
  bool _busy = false;

  void _digit(String d) {
    if (_busy || _pin.length >= pinLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == pinLength) Future<void>.delayed(const Duration(milliseconds: 150), _next);
  }

  void _back() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _next() async {
    // За 150 мс до проверки могли стереть цифру.
    if (!mounted || _busy || _pin.length != pinLength) return;
    if (!_repeat) {
      final weak = weakPin(_pin);
      if (weak != null) {
        HapticFeedback.heavyImpact();
        setState(() {
          _error = weak;
          _pin = '';
        });
        return;
      }
      setState(() {
        _first = _pin;
        _pin = '';
        _repeat = true;
      });
      return;
    }
    if (_pin != _first) {
      HapticFeedback.heavyImpact();
      setState(() {
        _error = 'Не совпадает — введите ещё раз';
        _pin = '';
      });
      return;
    }
    setState(() => _busy = true);
    final lock = context.read<AppLock>();
    // Face ID предлагаем до сохранения кода: как только код сохранён,
    // приложение сразу открывается и этот экран уходит.
    if (!widget.change && lock.bioAvailable && !lock.bioEnabled) await _offerBiometrics(lock);
    if (!mounted) return;
    await lock.setPin(_pin);
    if (!mounted) return;
    if (widget.change) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код изменён')));
    }
  }

  Future<void> _offerBiometrics(AppLock lock) async {
    final on = await showSheet<bool>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        const IconBox(Icons.face_unlock_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 72, iconSize: 40, radius: 36),
        const SizedBox(height: 16),
        const Text('Входить по Face ID?', style: AppText.h3, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text('Приложение откроется, как только посмотрите на экран. Код из 4 цифр останется запасным вариантом.',
            style: AppText.body.copyWith(color: AppColors.text2), textAlign: TextAlign.center),
        const SizedBox(height: 20),
        SheetButton(label: 'Включить Face ID', onPressed: () => Navigator.pop(ctx, true)),
        const SizedBox(height: 10),
        SheetButton(label: 'Не сейчас', primary: false, onPressed: () => Navigator.pop(ctx, false)),
      ]),
    );
    if (on == true) await lock.setBiometrics(true);
  }

  @override
  Widget build(BuildContext context) {
    final title = _repeat ? 'Повторите код' : (widget.change ? 'Новый код' : 'Придумайте код');
    final sub = _error ?? (_repeat ? 'Введите те же $pinLength цифры' : '$pinLength цифры — для входа в приложение на этом телефоне');
    return Scaffold(
      appBar: widget.change || _repeat
          ? AppBar(
              backgroundColor: AppColors.bg,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => _repeat
                    ? setState(() {
                        _repeat = false;
                        _pin = '';
                        _first = '';
                        _error = null;
                      })
                    : Navigator.of(context).pop(),
              ),
            )
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            child: Column(children: [
              const _LockIcon(),
              const SizedBox(height: 16),
              Text(title, style: AppText.h2),
              const SizedBox(height: 6),
              Text(sub,
                  textAlign: TextAlign.center,
                  style: _error != null ? AppText.body.copyWith(color: AppColors.error, fontWeight: FontWeight.w500) : AppText.body.copyWith(color: AppColors.text2)),
              const SizedBox(height: 16),
              PinDots(filled: _pin.length),
              const SizedBox(height: 24),
              PinPad(onDigit: _digit, onBackspace: _back),
              if (!widget.change) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => signOut(context),
                  child: Text('Войти под другим логином', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ В6, В6а

/// Экран блокировки: имя, точки, клавиатура, Face ID, «Забыли код?».
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  bool _wrong = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Клавиатуру открытого под замком экрана прячем.
    FocusManager.instance.primaryFocus?.unfocus();
    // Face ID — после того как экран кода нарисован (системное окно посреди
    // анимации на iPhone замораживает её).
    Future<void>.delayed(const Duration(milliseconds: 400), _bio);
  }

  Future<void> _bio() async {
    if (!mounted) return;
    await context.read<AppLock>().unlockWithBiometrics();
  }

  void _digit(String d) {
    if (_busy || _pin.length >= pinLength) return;
    setState(() {
      _pin += d;
      _wrong = false;
    });
    if (_pin.length == pinLength) _check();
  }

  void _back() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final lock = context.read<AppLock>();
    final r = await lock.check(_pin);
    if (!mounted) return;
    switch (r) {
      case PinCheck.ok:
        return;
      case PinCheck.wrong:
        HapticFeedback.heavyImpact();
        setState(() => _wrong = true);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (mounted) {
          setState(() {
            _pin = '';
            _busy = false;
          });
        }
      case PinCheck.reset:
        final messenger = ScaffoldMessenger.of(context);
        await signOut(context);
        messenger.showSnackBar(const SnackBar(content: Text('5 неверных кодов — войдите снова по логину и паролю')));
    }
  }

  Future<void> _forgot() async {
    final ok = await confirmSheet(
      context,
      icon: Icons.lock_reset_rounded,
      title: 'Забыли код?',
      text: 'Войдите снова по логину и паролю, затем придумайте новый код.',
      confirm: 'Войти по логину',
    );
    if (ok && mounted) await signOut(context);
  }

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLock>();
    final me = context.watch<StoreState>().me;
    final name = '${me?['full_name'] ?? ''}'.trim();
    final first = name.split(' ').first;
    final initials = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();
    final sub = [if ('${me?['role_name'] ?? ''}'.isNotEmpty) '${me!['role_name']}', '${(me?['network'] as Map?)?['name'] ?? ''}'].where((s) => s.isNotEmpty).join(' · ');
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
            child: Column(children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                child: initials.isEmpty
                    ? const Icon(Icons.storefront_rounded, color: AppColors.white, size: 30)
                    : Text(initials, style: AppText.h3.copyWith(color: AppColors.white)),
              ),
              const SizedBox(height: 16),
              Text(
                _wrong ? 'Неверный код' : (first.isEmpty ? 'Введите код' : '$first, введите код'),
                style: AppText.h3.copyWith(fontSize: 22, color: _wrong ? AppColors.error : AppColors.ink),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                _wrong || lock.fails > 0 ? 'Осталось попыток: ${lock.attemptsLeft}' : sub,
                style: AppText.small.copyWith(fontSize: 14, color: _wrong || lock.fails > 0 ? AppColors.error : AppColors.text2),
              ),
              const SizedBox(height: 16),
              PinDots(filled: _pin.length, error: _wrong),
              const SizedBox(height: 24),
              PinPad(onDigit: _digit, onBackspace: _back, onBiometrics: lock.bioEnabled && lock.bioAvailable ? _bio : null),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _forgot,
                child: Text('Забыли код? Войти по логину', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ Ш3

/// «Ещё → Код и Face ID»: Face ID, сменить код, когда спрашивать код.
class LockSettingsScreen extends StatelessWidget {
  const LockSettingsScreen({super.key});

  Future<void> _pickAfter(BuildContext context, AppLock lock) async {
    final d = await showSheet<Duration>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SheetHeader(title: 'Спрашивать код', text: 'Через сколько после сворачивания приложения снова просить код.'),
        const SizedBox(height: 8),
        for (final o in lockAfterOptions)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(lockAfterTitle(o), style: AppText.bodyStrong),
            trailing: o == lock.lockAfter ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
            onTap: () => Navigator.pop(ctx, o),
          ),
      ]),
    );
    if (d != null) await lock.setLockAfter(d);
  }

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLock>();
    return Scaffold(
      appBar: AppBar(title: const Text('Код и Face ID')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(children: [
            if (lock.bioAvailable)
              SwitchListTile(
                secondary: const Icon(Icons.face_unlock_rounded),
                title: const Text('Входить по Face ID', style: AppText.bodyStrong),
                value: lock.bioEnabled,
                activeTrackColor: AppColors.success,
                onChanged: (v) async {
                  final ok = await lock.setBiometrics(v);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Face ID не подтверждён')));
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.pin_rounded),
              title: const Text('Сменить код', style: AppText.bodyStrong),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PinSetupScreen(change: true))),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Спрашивать код', style: AppText.bodyStrong),
              trailing: Text('${lockAfterTitle(lock.lockAfter)} ›', style: AppText.small.copyWith(fontSize: 15)),
              onTap: () => _pickAfter(context, lock),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(20)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_rounded, size: 20, color: AppColors.blue),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                lock.bioAvailable
                    ? 'Код и Face ID работают только на этом телефоне. Если Face ID не прошёл — просим код из 4 цифр.'
                    : 'Код работает только на этом телефоне. Face ID или отпечаток на этом телефоне не настроены.',
                style: AppText.small.copyWith(color: AppColors.ink),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
