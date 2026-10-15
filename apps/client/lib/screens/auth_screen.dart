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


/// Код входа отправлен: на какой номер, куда (sms; пусто — не
/// знаем) и через сколько секунд можно отправить ещё раз.
class OtpSent {
  const OtpSent({required this.phone, required this.channel, required this.resendIn, this.botUrl = ''});
  final String phone;
  final String channel;
  final int resendIn;
  final String botUrl;
}

/// Запросить код входа: POST /auth/otp/request → {channel, resend_in, bot_url}.
/// Сервер шлёт код по SMS.
/// too_many_requests — код уже отправлен недавно, просто ждём его.
/// Остальные ошибки (sms_send_failed — SMS не ушло) — ApiError.
Future<OtpSent> requestOtp(Api api, String phone) async {
  try {
    final r = await api.post('/auth/otp/request', {'phone': phone});
    final m = r is Map<String, dynamic> ? r : const <String, dynamic>{};
    return OtpSent(
      phone: phone,
      channel: '${m['channel'] ?? ''}',
      resendIn: (m['resend_in'] as num?)?.toInt() ?? 60,
      botUrl: '${m['bot_url'] ?? ''}',
    );
  } on ApiError catch (e) {
    if (e.code != 'too_many_requests') rethrow;
    return OtpSent(phone: phone, channel: '', resendIn: (e.details['retry_after'] as num?)?.toInt() ?? 60);
  }
}

/// Вход (Figma «Т3», «Т4»): шаг 1 — номер и согласие с офертой и политикой,
/// шаг 2 — код из SMS, шаг 3 — «Как вас зовут?», если имя не указано.
///
/// Открывается поверх приложения (openLogin в guest.dart) и закрывается
/// с true после входа; «Посмотреть магазины без входа» закрывает с false.
/// [sent] — код уже запрошен из шторки входа, сразу шаг 2.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.sent});
  final OtpSent? sent;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late final _phone = TextEditingController(text: widget.sent == null ? '' : UzPhoneFormatter.format(widget.sent!.phone.substring(4)));

  /// Из шторки код запрошен с согласием («Нажимая «Получить код»…»).
  late bool _agree = widget.sent != null;
  bool _busy = false;
  String? _error;

  /// Шаг 2: куда отправлен код.
  late OtpSent? _sent = widget.sent;

  /// Шаг 3 после входа: имя ещё не указано.
  bool _needName = false;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadConfig();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');
  String get _fullPhone => '+998$_digits';
  bool get _canSend => _digits.length == 9 && _agree && !_busy;

  /// Закрыть экран входа: true — вошли.
  void _close(bool loggedIn) {
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop(loggedIn);
  }

  /// Отправить код. [resend] — повторно со второго шага.
  Future<void> _request({bool resend = false}) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    try {
      final sent = await requestOtp(api, _fullPhone);
      if (!mounted) return;
      final prev = _sent;
      setState(() {
        // Повторный запрос слишком рано: канал прежний.
        _sent = sent.channel.isEmpty && prev?.phone == sent.phone
            ? OtpSent(phone: sent.phone, channel: prev!.channel, resendIn: sent.resendIn, botUrl: sent.botUrl)
            : sent;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (resend) {
        showError(context, e);
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Код подошёл: спросить имя, если его ещё нет, иначе закрыть вход.
  Future<void> _afterLogin() async {
    final state = context.read<AppState>();
    var needName = false;
    try {
      await state.loadProfile();
      needName = '${state.profile?['first_name'] ?? ''}'.trim().isEmpty;
    } catch (_) {
      // Нет сети — имя можно указать в профиле.
    }
    if (!mounted) return;
    if (needName) {
      setState(() => _needName = true);
    } else {
      _close(true);
    }
  }

  /// «Назад» на шаге 3 — выйти и войти заново другим номером.
  Future<void> _backFromName() async {
    await context.read<Api>().logout();
    if (!mounted) return;
    setState(() {
      _needName = false;
      _sent = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sent;
    final Widget child;
    if (_needName) {
      child = NameStepScreen(key: const ValueKey('name'), onDone: () => _close(true), onBack: _backFromName);
    } else if (sent == null) {
      child = _phoneStep();
    } else {
      child = CodeStep(
        key: ValueKey(sent.phone),
        phone: sent.phone,
        channel: sent.channel,
        resendIn: sent.resendIn,
        onBack: () => setState(() => _sent = null),
        onResend: () => _request(resend: true),
        onVerified: _afterLogin,
      );
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: child);
  }

  Widget _phoneStep() {
    final top = MediaQuery.paddingOf(context).top;
    final state = context.watch<AppState>();
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
                  Text(tr('Продукты из магазинов\nрядом с домом', 'Uyingiz yaqinidagi\ndoʻkonlardan mahsulotlar'),
                      style: AppText.body.copyWith(color: AppColors.white, fontSize: 17, height: 1.35, fontWeight: FontWeight.w500)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(tr('Вход', 'Kirish'), style: AppText.h1),
                  const SizedBox(height: 6),
                  Text(tr('Пришлём код по SMS', 'Kodni SMS orqali yuboramiz'), style: AppText.body.copyWith(color: AppColors.text2)),
                  const SizedBox(height: 24),
                  PhoneField(controller: _phone, error: _error != null, onChanged: () => setState(() => _error = null), onSubmit: _canSend ? _request : null),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: AppText.small.copyWith(color: AppColors.primary)),
                  ],
                  const SizedBox(height: 20),
                  _Consent(
                    value: _agree,
                    offerUrl: state.link('offer_url'),
                    privacyUrl: state.privacyUrl,
                    onChanged: (v) => setState(() => _agree = v),
                  ),
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
              StepButton(label: tr('Продолжить', 'Davom etish'), arrow: true, busy: _busy, onPressed: _canSend ? _request : null),
              const SizedBox(height: 6),
              // Вход не обязателен: магазины и товары можно смотреть без него (Apple 5.1.1).
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _close(false),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    textStyle: AppText.smallStrong.copyWith(fontSize: 14),
                  ),
                  icon: const Icon(Icons.storefront_rounded, size: 18),
                  label: Text(tr('Посмотреть магазины без входа', 'Doʻkonlarni kirmasdan koʻrish')),
                ),
              ),
            ]),
          ),
        ),
      ]),
      ),
    );
  }
}

/// Поле номера: серая плашка «UZ +998» и 9 цифр «90 000 00 00».
class PhoneField extends StatelessWidget {
  const PhoneField({super.key, required this.controller, required this.error, required this.onChanged, this.onSubmit, this.autofocus = false});
  final TextEditingController controller;
  final bool error;
  final VoidCallback onChanged;
  final VoidCallback? onSubmit;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
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

/// Ссылки «офертой» и «политикой конфиденциальности» внутри текста согласия.
/// Открываются в браузере; пустая ссылка — просто текст. По-узбекски глагол
/// стоит после ссылок — его добавляет вызывающий (`tr('', ' roziman')`).
List<InlineSpan> legalSpans(TextStyle style, {required String offerUrl, required String privacyUrl}) {
  InlineSpan link(String text, String url) => WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: url.isEmpty ? null : () => openUrl(url),
          child: Text(text, style: style.copyWith(color: AppColors.primary)),
        ),
      );
  return [
    link(tr('офертой', 'ofertaga'), offerUrl),
    TextSpan(text: tr(' и ', ' va ')),
    link(tr('политикой конфиденциальности', 'maxfiylik siyosatiga'), privacyUrl),
  ];
}

/// Флажок «Согласен с офертой и политикой конфиденциальности»; обе — ссылки.
class _Consent extends StatelessWidget {
  const _Consent({required this.value, required this.offerUrl, required this.privacyUrl, required this.onChanged});
  final bool value;
  final String offerUrl;
  final String privacyUrl;
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
            TextSpan(text: tr('Согласен с ', 'Men ')),
            ...legalSpans(style, offerUrl: offerUrl, privacyUrl: privacyUrl),
            TextSpan(text: tr('', ' roziman')),
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
      Text(tr('Шаг $step из 3', 'Qadam $step/3'), style: AppText.smallStrong.copyWith(color: AppColors.primary)),
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

/// Заголовок и текст шага 2 по каналу из ответа /auth/otp/request.
(String, String) codeStepText(String channel, String phone) {
  final number = '+998 ${UzPhoneFormatter.format(phone.substring(4))}';
  return switch (channel) {
    'sms' => (tr('Код из SMS', 'SMS dagi kod'), tr('Отправили SMS с 6 цифрами на номер $number. ', '$number raqamiga 6 xonali kod bilan SMS yubordik. ')),
    _ => (tr('Введите код', 'Kodni kiriting'), tr('Отправили 6 цифр на номер $number по SMS. ', '$number raqamiga SMS orqali 6 xonali kod yubordik. ')),
  };
}

/// Шаг 2: шесть цифр кода (3 + 3), кнопка бота и таймер повторной отправки.
/// [channel] — куда ушёл код: sms или пусто (не знаем).
class CodeStep extends StatefulWidget {
  const CodeStep({
    super.key,
    required this.phone,
    required this.resendIn,
    required this.onBack,
    required this.onResend,
    this.channel = 'sms',
    this.onVerified,
  });
  final String phone;
  final int resendIn;
  final VoidCallback onBack;
  final Future<void> Function() onResend;
  final String channel;

  /// Код подошёл, токены сохранены.
  final VoidCallback? onVerified;

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
      widget.onVerified?.call();
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
    final (title, text) = codeStepText(widget.channel, widget.phone);
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
            Text(title, style: AppText.h1),
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(style: AppText.body.copyWith(color: AppColors.text2), children: [
                TextSpan(text: text),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: GestureDetector(
                    onTap: widget.onBack,
                    child: Text(tr('Изменить', 'Oʻzgartirish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
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
            const SizedBox(height: 16),
            if (_left > 0)
              Text(tr('Отправить код ещё раз через $_mmss', 'Kodni $_mmss dan keyin qayta yuborish mumkin'), style: AppText.small.copyWith(fontSize: 14))
            else
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: _resend,
                  child: Text(tr('Отправить код ещё раз', 'Kodni qayta yuborish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Шаг 3 после входа: «Как вас зовут?» — имя обязательно, остальное по желанию.
class NameStepScreen extends StatefulWidget {
  const NameStepScreen({super.key, required this.onDone, this.onBack});
  final VoidCallback onDone;

  /// «Назад»; по умолчанию — выйти и войти заново другим номером.
  final Future<void> Function()? onBack;

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
  Future<void> _back() => widget.onBack?.call() ?? context.read<Api>().logout();

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
              Text(tr('Как вас зовут?', 'Ismingiz nima?'), style: AppText.h1),
              const SizedBox(height: 8),
              Text(tr('Курьер будет обращаться к вам по имени', 'Kuryer sizga ismingiz bilan murojaat qiladi'), style: AppText.body.copyWith(color: AppColors.text2)),
              const SizedBox(height: 24),
              PersonForm(data: _data, autofocus: true, onChanged: () => setState(() {})),
              const SizedBox(height: 24),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: StepButton(label: tr('Готово', 'Tayyor'), busy: _busy, onPressed: _data.firstName.trim().isEmpty ? null : _save),
          ),
        ]),
      ),
    );
  }
}
