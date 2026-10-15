import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' hide LoginScreen;
import 'package:url_launcher/url_launcher.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'crowd_state.dart';

/// Переключатель режима входа: «Курьер по пути» / «Сотрудник магазина».
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({super.key, required this.crowd, required this.onChanged});

  final bool crowd;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    Widget item(String label, bool value) {
      final on = crowd == value;
      return Expanded(
        child: Material(
          color: on ? AppColors.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onChanged == null || on ? null : () => onChanged!(value),
            child: SizedBox(
              height: 40,
              child: Center(
                child: Text(label,
                    style: AppText.bodyStrong.copyWith(fontSize: 14, color: on ? AppColors.white : AppColors.text2, fontWeight: on ? FontWeight.w600 : FontWeight.w500)),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        item(tr('Курьер по пути', 'Yoʻlakay kuryer'), true),
        const SizedBox(width: 4),
        item(tr('Сотрудник магазина', 'Doʻkon xodimi'), false),
      ]),
    );
  }
}

Future<void> openLink(BuildContext context, String url) async {
  if (url.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Документ скоро появится', 'Hujjat tez orada paydo boʻladi'))));
    return;
  }
  final ok = await launchUrl(Uri.parse(docUrl(url)), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Не удалось открыть: $url', 'Ochib boʻlmadi: $url'))));
  }
}

/// Вход курьера «по пути»: номер телефона и согласие с условиями (Figma Ц1).
class CrowdLoginForm extends StatefulWidget {
  const CrowdLoginForm({super.key});

  @override
  State<CrowdLoginForm> createState() => _CrowdLoginFormState();
}

class _CrowdLoginFormState extends State<CrowdLoginForm> {
  final _phone = TextEditingController();
  bool _agree = false;
  bool _busy = false;
  String? _error;
  String _termsUrl = '';
  String _privacyUrl = '';

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  Future<void> _loadLinks() async {
    try {
      final c = await context.read<CrowdState>().api.get('/client/config') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _termsUrl = '${c['courier_terms_url'] ?? ''}';
        _privacyUrl = '${c['privacy_url'] ?? ''}';
      });
    } catch (_) {
      // без ссылок вход всё равно работает
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone = normalizeUzPhone(_phone.text);
    if (phone == null) {
      setState(() => _error = tr('Введите номер полностью: 90 123 45 67', 'Raqamni toʻliq kiriting: 90 123 45 67'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<CrowdState>().api;
    try {
      final r = await api.post('/auth/otp/request', {'phone': phone, 'app': 'crowd'}) as Map<String, dynamic>;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => CrowdCodeScreen(phone: phone, channel: '${r['channel'] ?? 'sms'}', botUrl: '${r['bot_url'] ?? ''}',
            resendIn: (r['resend_in'] as num?)?.toInt() ?? 60),
      ));
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'too_many_requests') {
        // Код уже отправлен — сразу на экран ввода.
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => CrowdCodeScreen(phone: phone, channel: 'sms', botUrl: '', resendIn: (e.details['retry_after'] as num?)?.toInt() ?? 60),
        ));
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = AppText.small.copyWith(color: AppColors.primary, fontWeight: FontWeight.w600, decoration: TextDecoration.underline, decorationColor: AppColors.primary);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Вход по телефону', 'Telefon orqali kirish'), style: AppText.h2),
      const SizedBox(height: 6),
      Text(tr('Пришлём код из SMS. Аккаунт создастся сам', 'SMS orqali kod yuboramiz. Akkaunt avtomatik yaratiladi'), style: AppText.body.copyWith(color: AppColors.text2)),
      const SizedBox(height: 20),
      Text(tr('Номер телефона', 'Telefon raqami'), style: AppText.caption),
      const SizedBox(height: 8),
      TextField(
        controller: _phone,
        enabled: !_busy,
        keyboardType: TextInputType.phone,
        autofillHints: const [AutofillHints.telephoneNumberNational],
        inputFormatters: [UzPhoneFormatter()],
        style: AppText.body.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        onSubmitted: (_) => _agree ? _submit() : null,
        decoration: InputDecoration(
          hintText: '99 999 99 99',
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 16, right: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.phone_iphone_rounded, color: AppColors.muted),
              SizedBox(width: 8),
              Text('+998', style: TextStyle(fontFamily: 'Inter', fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.ink)),
            ]),
          ),
          errorText: _error == null ? null : '',
          errorStyle: const TextStyle(height: 0, fontSize: 0),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
      ],
      const SizedBox(height: 16),
      InkWell(
        onTap: _busy ? null : () => setState(() => _agree = !_agree),
        borderRadius: BorderRadius.circular(8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(_agree ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: _agree ? AppColors.primary : AppColors.muted, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(style: AppText.small.copyWith(color: AppColors.ink, fontSize: 14), children: [
              TextSpan(text: tr('Я прочитал и согласен с ', 'Men Super Marketning ')),
              TextSpan(
                  text: tr('Условиями для курьеров', 'kuryerlar uchun shartlari'),
                  style: link,
                  recognizer: TapGestureRecognizer()..onTap = () => openLink(context, _termsUrl)),
              TextSpan(text: tr(' и ', ' va ')),
              TextSpan(
                  text: tr('Политикой конфиденциальности', 'maxfiylik siyosati'),
                  style: link,
                  recognizer: TapGestureRecognizer()..onTap = () => openLink(context, _privacyUrl)),
              TextSpan(text: tr(' Super Market', ' bilan tanishdim va roziman')),
            ])),
          ),
        ]),
      ),
      const SizedBox(height: 20),
      BigButton(label: tr('Получить код', 'Kodni olish'), icon: Icons.arrow_forward_rounded, busy: _busy, onPressed: _agree ? _submit : null),
      const SizedBox(height: 18),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.verified_user_rounded, size: 18, color: AppColors.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              tr('Паспорт загружать не нужно — личность подтвердит продавец в любом магазине Super Market. Только с 18 лет.',
                  'Pasport yuklash shart emas — shaxsingizni istalgan Super Market doʻkonida sotuvchi tasdiqlaydi. Faqat 18 yoshdan.'),
              style: AppText.small),
        ),
      ]),
    ]);
  }
}

/// Ввод кода из SMS (Figma Ц1.1, Ц1.2): 6 цифр, проверка сразу после шестой.
class CrowdCodeScreen extends StatefulWidget {
  const CrowdCodeScreen({super.key, required this.phone, required this.channel, required this.botUrl, required this.resendIn});

  final String phone;
  final String channel;
  final String botUrl;
  final int resendIn;

  @override
  State<CrowdCodeScreen> createState() => _CrowdCodeScreenState();
}

class _CrowdCodeScreenState extends State<CrowdCodeScreen> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;
  late int _left = widget.resendIn;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _tick();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _tick() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
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
    final code = _code.text;
    if (code.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<CrowdState>().api.signIn('/auth/otp/verify', {
        'phone': widget.phone,
        'code': code,
        'app': 'crowd',
        'terms_accepted': true,
      });
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.code) {
            'validation' => tr('Неверный код или он устарел. Проверьте SMS или запросите новый',
                'Kod notoʻgʻri yoki eskirgan. SMSni tekshiring yoki yangisini soʻrang'),
            'crowd_blocked' => e.message,
            _ => e.message,
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      await context.read<CrowdState>().api.post('/auth/otp/request', {'phone': widget.phone, 'app': 'crowd'});
      if (!mounted) return;
      setState(() {
        _left = 60;
        _error = null;
        _code.clear();
      });
      _tick();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = _code.text;
    final sms = widget.channel == 'sms';
    final err = _error != null;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.bg),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
        Text(tr('Введите код из SMS', 'SMSdagi kodni kiriting'), style: AppText.h1.copyWith(fontSize: 30)),
        const SizedBox(height: 8),
        Text(tr('Отправили 6 цифр на ${widget.phone}', '${widget.phone} raqamiga 6 xonali kod yubordik'), style: AppText.body.copyWith(color: AppColors.text2, fontSize: 16)),
        const SizedBox(height: 4),
        TextButton.icon(
          style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft, foregroundColor: AppColors.primary),
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.edit_rounded, size: 16),
          label: Text(tr('Изменить номер', 'Raqamni oʻzgartirish'), style: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 15)),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => _focus.requestFocus(),
          child: Stack(children: [
            // Невидимое поле принимает ввод и автоподстановку кода из SMS.
            Opacity(
              opacity: 0,
              child: TextField(
                controller: _code,
                focusNode: _focus,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                onChanged: (v) {
                  setState(() => _error = null);
                  if (v.length == 6) _verify();
                },
              ),
            ),
            Row(children: [
              for (var i = 0; i < 6; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 62,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: err ? AppColors.primarySoft : AppColors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        width: 2,
                        color: err ? AppColors.primary : (i == digits.length ? AppColors.primary : AppColors.white),
                      ),
                    ),
                    child: Text(i < digits.length ? digits[i] : '',
                        style: AppText.h2.copyWith(fontSize: 28, color: err ? AppColors.primary : AppColors.ink)),
                  ),
                ),
              ],
            ]),
          ]),
        ),
        const SizedBox(height: 14),
        if (err)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              const Icon(Icons.error_rounded, color: AppColors.primary, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text(_error!, style: AppText.bodyStrong.copyWith(color: AppColors.primary))),
            ]),
          ),
        if (_left > 0)
          Row(children: [
            const Icon(Icons.schedule_rounded, size: 18, color: AppColors.text2),
            const SizedBox(width: 6),
            Text(
                tr('Отправить код ещё раз через ${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}',
                    'Kodni qayta yuborish ${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')} dan keyin'),
                style: AppText.body.copyWith(color: AppColors.text2, fontWeight: FontWeight.w500)),
          ])
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: _resend, child: Text(tr('Отправить код ещё раз', 'Kodni qayta yuborish'))),
          ),
        if (!sms && widget.botUrl.isNotEmpty) ...[
          const SizedBox(height: 8),
          SmallButton(label: tr('Открыть бота', 'Botni ochish'), icon: Icons.send_rounded, onPressed: () => openLink(context, widget.botUrl)),
        ],
        const SizedBox(height: 18),
        BigButton(label: tr('Подтвердить', 'Tasdiqlash'), busy: _busy, onPressed: digits.length == 6 ? _verify : null),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(16)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.lock_rounded, size: 20, color: AppColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  tr('Код действует 5 минут. После 5 неверных попыток нужно запросить новый код.',
                      'Kod 5 daqiqa amal qiladi. 5 marta notoʻgʻri kiritilsa, yangi kod soʻrash kerak.'),
                  style: AppText.small),
            ),
          ]),
        ),
      ]),
    );
  }
}
