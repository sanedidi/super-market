import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../state.dart';
import '../ui/person_form.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

const _telegramBlue = Color(0xFF2AABEE);

/// Вход: шаг 1 — номер и согласие с офертой, шаг 2 — код из Telegram-бота.
/// Шаг 3 («Как вас зовут?») показывает [NameStepScreen] после входа.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _phone = TextEditingController();
  bool _agree = false;
  bool _busy = false;
  String? _error;

  /// Шаг 2: номер, на который отправлен код, и секунды до повторной отправки.
  String? _sentTo;
  int _resendIn = 0;
  String _botUrl = '';
  String _offerUrl = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final c = await context.read<Api>().get('/client/config') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _offerUrl = '${c['offer_url'] ?? ''}';
        _botUrl = '${c['bot_url'] ?? ''}';
      });
    } catch (_) {
      // Ссылки необязательны: без них вход работает.
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');
  String get _fullPhone => '+998$_digits';
  bool get _canSend => _digits.length == 9 && _agree && !_busy;

  /// Отправить код. [resend] — повторно со второго шага.
  Future<void> _request({bool resend = false}) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await context.read<Api>().post('/auth/otp/request', {'phone': _fullPhone});
      final m = r is Map<String, dynamic> ? r : const <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _sentTo = _fullPhone;
        _resendIn = (m['resend_in'] as num?)?.toInt() ?? 60;
        final bot = '${m['bot_url'] ?? ''}';
        if (bot.isNotEmpty) _botUrl = bot;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'too_many_requests') {
        // Код уже отправлен недавно — просто ждём его на втором шаге.
        setState(() {
          _sentTo = _fullPhone;
          _resendIn = (e.details['retry_after'] as num?)?.toInt() ?? 60;
        });
      } else if (e.code == 'telegram_not_linked') {
        final bot = '${e.details['bot_url'] ?? _botUrl}';
        if (bot.isNotEmpty) _botUrl = bot;
        await _linkTelegram();
      } else if (resend && mounted) {
        showError(context, e);
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Номер ещё не привязан к боту: открыть бота, поделиться номером и вернуться.
  Future<void> _linkTelegram() async {
    final again = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const FaGlyph('telegram', size: 48, color: _telegramBlue),
            const SizedBox(height: 16),
            const Text('Подключите Telegram-бот', textAlign: TextAlign.center, style: AppText.h3),
            const SizedBox(height: 8),
            Text('Откройте бота Super Market, нажмите «Поделиться номером» и возвращайтесь — код придёт туда.',
                textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppColors.text2)),
            const SizedBox(height: 20),
            if (_botUrl.isNotEmpty) ...[
              _TelegramButton(onTap: () => openUrl(_botUrl)),
              const SizedBox(height: 10),
            ],
            StepButton(label: 'Я поделился номером', onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ),
      ),
    );
    if (again == true && mounted) await _request();
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sentTo;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: sent == null
          ? _phoneStep()
          : CodeStep(
              key: ValueKey(sent),
              phone: sent,
              resendIn: _resendIn,
              botUrl: _botUrl,
              onBack: () => setState(() => _sentTo = null),
              onResend: () => _request(resend: true),
            ),
    );
  }

  Widget _phoneStep() {
    final top = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      key: const ValueKey('phone'),
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
      body: Column(children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: EdgeInsets.fromLTRB(24, top + 40, 24, 32),
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SvgPicture.asset('assets/images/logo_words_white.svg', height: 76, semanticsLabel: 'Super Market'),
                  const SizedBox(height: 28),
                  Text('Продукты из магазинов\nрядом с домом',
                      style: AppText.body.copyWith(color: AppColors.white, fontSize: 17, height: 1.35, fontWeight: FontWeight.w500)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Вход', style: AppText.h1),
                  const SizedBox(height: 6),
                  Text('Пришлём код в Telegram-бот Super Market', style: AppText.body.copyWith(color: AppColors.text2)),
                  const SizedBox(height: 24),
                  _PhoneField(controller: _phone, error: _error != null, onChanged: () => setState(() => _error = null), onSubmit: _canSend ? _request : null),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: AppText.small.copyWith(color: AppColors.primary)),
                  ],
                  const SizedBox(height: 20),
                  _Consent(value: _agree, offerUrl: _offerUrl, onChanged: (v) => setState(() => _agree = v)),
                ]),
              ),
            ]),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              StepButton(label: 'Продолжить', arrow: true, busy: _busy, onPressed: _canSend ? _request : null),
              const SizedBox(height: 14),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 1), child: FaGlyph('telegram', size: 18, color: _telegramBlue)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Нет Telegram? Установите его — вход только через бота', style: AppText.small.copyWith(fontSize: 13)),
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

/// Поле номера: серая плашка «UZ +998» и 9 цифр «90 000 00 00».
class _PhoneField extends StatelessWidget {
  const _PhoneField({required this.controller, required this.error, required this.onChanged, this.onSubmit});
  final TextEditingController controller;
  final bool error;
  final VoidCallback onChanged;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.phone,
      autofillHints: const [AutofillHints.telephoneNumberNational],
      inputFormatters: [UzPhoneFormatter()],
      style: AppText.h3.copyWith(fontSize: 22, fontWeight: FontWeight.w500, letterSpacing: 0.5),
      onChanged: (_) => onChanged(),
      onSubmitted: (_) => onSubmit?.call(),
      decoration: outlinedField('99 999 99 99').copyWith(
        hintStyle: AppText.h3.copyWith(fontSize: 22, fontWeight: FontWeight.w400, color: AppColors.muted, letterSpacing: 0.5),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
        prefixIcon: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.md)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('UZ', style: AppText.caption.copyWith(fontWeight: FontWeight.w700, color: AppColors.text2)),
              const SizedBox(width: 6),
              Text('+998', style: AppText.title.copyWith(fontSize: 17)),
            ]),
          ),
        ),
        enabledBorder: error
            ? OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.lg), borderSide: const BorderSide(color: AppColors.primary, width: 1.5))
            : null,
      ),
    );
  }
}

/// Флажок «Согласен с условиями оферты…»; «оферты» — ссылка.
class _Consent extends StatelessWidget {
  const _Consent({required this.value, required this.offerUrl, required this.onChanged});
  final bool value;
  final String offerUrl;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final style = AppText.small.copyWith(fontSize: 14, height: 1.4);
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 24,
          height: 24,
          margin: const EdgeInsets.only(right: 12, top: 1),
          decoration: BoxDecoration(
            color: value ? AppColors.primary : AppColors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: value ? AppColors.primary : AppColors.line, width: 2),
          ),
          child: value ? const Icon(Icons.check_rounded, size: 18, color: AppColors.white) : null,
        ),
        Expanded(
          child: Text.rich(TextSpan(style: style, children: [
            const TextSpan(text: 'Согласен с условиями '),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: offerUrl.isEmpty ? null : () => openUrl(offerUrl),
                child: Text('оферты', style: style.copyWith(color: AppColors.primary)),
              ),
            ),
            const TextSpan(text: ' и обработкой персональных данных'),
          ])),
        ),
      ]),
    );
  }
}

/// Полоска «Шаг N из 3».
class StepProgress extends StatelessWidget {
  const StepProgress({super.key, required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Шаг $step из 3', style: AppText.smallStrong.copyWith(color: AppColors.primary)),
      const SizedBox(height: 8),
      Row(children: [
        for (var i = 1; i <= 3; i++) ...[
          if (i > 1) const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(color: i <= step ? AppColors.primary : AppColors.line, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ],
      ]),
    ]);
  }
}

/// Шаг 2: шесть цифр кода (3 + 3), кнопка бота и таймер повторной отправки.
class CodeStep extends StatefulWidget {
  const CodeStep({super.key, required this.phone, required this.resendIn, required this.botUrl, required this.onBack, required this.onResend});
  final String phone;
  final int resendIn;
  final String botUrl;
  final VoidCallback onBack;
  final Future<void> Function() onResend;

  @override
  State<CodeStep> createState() => _CodeStepState();
}

class _CodeStepState extends State<CodeStep> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  Timer? _timer;
  late int _left = widget.resendIn;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(CodeStep old) {
    super.didUpdateWidget(old);
    if (old.resendIn != widget.resendIn || _left == 0) {
      _left = widget.resendIn;
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _left = _left > 0 ? _left - 1 : 0);
      if (_left == 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    try {
      await api.verifyCode(widget.phone, _code.text);
      // Флажок на первом шаге обязателен — фиксируем согласие с офертой.
      api.patch('/client/me', {'accept_terms': true}).catchError((_) => null);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      _code.clear();
      _focus.requestFocus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    _code.clear();
    setState(() => _error = null);
    await widget.onResend();
  }

  String get _mmss => '${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final digits = _code.text;
    Widget cell(int i) {
      final filled = i < digits.length;
      final current = i == digits.length && _focus.hasFocus;
      final line = _error != null
          ? AppColors.primary
          : (filled || current)
              ? AppColors.ink
              : AppColors.line;
      return Container(
        width: 40,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: line, width: 2.5))),
        child: Text(filled ? digits[i] : '', style: AppText.h1.copyWith(fontSize: 32, fontWeight: FontWeight.w600, color: _error != null ? AppColors.primary : AppColors.ink)),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
                icon: const Icon(Icons.arrow_back_rounded, size: 28),
                onPressed: widget.onBack,
              ),
            ),
            const SizedBox(height: 8),
            const StepProgress(step: 2),
            const SizedBox(height: 24),
            const Text('Код из Telegram', style: AppText.h1),
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(style: AppText.body.copyWith(color: AppColors.text2), children: [
                TextSpan(text: 'Бот Super Market прислал 6 цифр на номер +998 ${UzPhoneFormatter.format(widget.phone.substring(4))}. '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: GestureDetector(
                    onTap: widget.onBack,
                    child: Text('Изменить', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _focus.requestFocus(),
              child: Stack(children: [
                // Настоящее поле невидимо: оно даёт клавиатуру и автоподстановку кода.
                Positioned.fill(
                  child: Opacity(
                    opacity: 0,
                    child: TextField(
                      controller: _code,
                      focusNode: _focus,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      maxLength: 6,
                      showCursor: false,
                      enableInteractiveSelection: false,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (v) {
                        setState(() => _error = null);
                        if (v.length == 6) _verify();
                      },
                    ),
                  ),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  cell(0),
                  cell(1),
                  cell(2),
                  Container(width: 14, height: 2.5, color: AppColors.line),
                  cell(3),
                  cell(4),
                  cell(5),
                ]),
              ]),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: AppText.small.copyWith(color: AppColors.primary, fontSize: 14)),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
            ],
            const SizedBox(height: 36),
            if (widget.botUrl.isNotEmpty) _TelegramButton(onTap: () => openUrl(widget.botUrl)),
            const SizedBox(height: 16),
            if (_left > 0)
              Text('Отправить код ещё раз через $_mmss', style: AppText.small.copyWith(fontSize: 14))
            else
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: _resend,
                  child: Text('Отправить код ещё раз', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Голубая кнопка «Открыть бота в Telegram».
class _TelegramButton extends StatelessWidget {
  const _TelegramButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFE8F5FC),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const FaGlyph('telegram', size: 22, color: _telegramBlue),
            const SizedBox(width: 10),
            Text('Открыть бота в Telegram', style: AppText.bodyStrong.copyWith(color: const Color(0xFF1E88C8), fontSize: 16)),
          ]),
        ),
      ),
    );
  }
}

/// Шаг 3 после входа: «Как вас зовут?» — имя обязательно, остальное по желанию.
class NameStepScreen extends StatefulWidget {
  const NameStepScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<NameStepScreen> createState() => _NameStepScreenState();
}

class _NameStepScreenState extends State<NameStepScreen> {
  late final PersonData _data = PersonData.fromProfile(context.read<AppState>().profile);
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await context.read<AppState>().updateProfile({..._data.toPatch(), 'accept_terms': true});
      widget.onDone();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// «Назад» на шаге 3 — выйти и войти заново другим номером.
  Future<void> _back() => context.read<Api>().logout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 24), children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                  icon: const Icon(Icons.arrow_back_rounded, size: 28),
                  onPressed: _back,
                ),
              ),
              const SizedBox(height: 8),
              const StepProgress(step: 3),
              const SizedBox(height: 24),
              const Text('Как вас зовут?', style: AppText.h1),
              const SizedBox(height: 8),
              Text('Курьер будет обращаться к вам по имени', style: AppText.body.copyWith(color: AppColors.text2)),
              const SizedBox(height: 24),
              PersonForm(data: _data, autofocus: true, onChanged: () => setState(() {})),
              const SizedBox(height: 24),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: StepButton(label: 'Готово', busy: _busy, onPressed: _data.firstName.trim().isEmpty ? null : _save),
          ),
        ]),
      ),
    );
  }
}
