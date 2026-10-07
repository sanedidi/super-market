import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../lock/pin_screens.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Контакты поддержки Super Market — для «Забыли пароль?».
const supportTelegram = 'super_market_support';
const supportPhone = '+998505764723';

/// В1 — вход в магазин по логину и паролю (Figma «SM Магазин · вход по логину и паролю»).
/// Логин и временный пароль выдаёт Super Market при подключении магазина,
/// сотрудникам — владелец в панели магазина.
class PasswordLoginScreen extends StatefulWidget {
  const PasswordLoginScreen({super.key});

  @override
  State<PasswordLoginScreen> createState() => _PasswordLoginScreenState();
}

class _PasswordLoginScreenState extends State<PasswordLoginScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _hide = true;
  bool _busy = false;
  String? _error;
  String? _hint;

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final login = _login.text.trim().toLowerCase();
    final password = _password.text;
    if (login.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Введите логин и пароль';
        _hint = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    try {
      await context.read<Api>().signIn('/auth/store/login', {'login': login, 'password': password});
      TextInput.finishAutofillContext();
    } on ApiError catch (e) {
      if (!mounted) return;
      final left = e.details['attempts_left'];
      setState(() {
        if (e.code == 'invalid_credentials') {
          _error = 'Неверный логин или пароль';
          _hint = left is num ? 'Осталось ${_attempts(left.toInt())}, потом вход закроется на 15 минут' : null;
        } else {
          _error = e.message;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _attempts(int n) => n == 1 ? '1 попытка' : (n >= 2 && n <= 4 ? '$n попытки' : '$n попыток');

  @override
  Widget build(BuildContext context) {
    final err = _error != null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: IconBox(Icons.storefront_rounded, bg: AppColors.primary, fg: AppColors.white, size: 56, iconSize: 30, radius: 18),
                  ),
                  const SizedBox(height: 16),
                  const Text('Вход в магазин', style: TextStyle(fontFamily: 'Inter', fontSize: 28, height: 1.2, fontWeight: FontWeight.w700, color: AppColors.ink)),
                  const SizedBox(height: 6),
                  Text('Логин и пароль выдаёт Super Market при подключении магазина.', style: AppText.body.copyWith(color: AppColors.text2)),
                  const SizedBox(height: 24),
                  const Text('Логин', style: AppText.caption),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _login,
                    enabled: !_busy,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                    inputFormatters: [LengthLimitingTextInputFormatter(32)],
                    style: AppText.body.copyWith(fontSize: 17),
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _passwordFocus.requestFocus(),
                    decoration: const InputDecoration(
                      hintText: 'например, olma',
                      prefixIcon: Icon(Icons.person_rounded, color: AppColors.muted),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Пароль', style: AppText.caption),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _password,
                    focusNode: _passwordFocus,
                    enabled: !_busy,
                    obscureText: _hide,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    inputFormatters: [LengthLimitingTextInputFormatter(72)],
                    style: AppText.body.copyWith(fontSize: 17),
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.lock_rounded, color: AppColors.muted),
                      suffixIcon: IconButton(
                        tooltip: _hide ? 'Показать пароль' : 'Скрыть пароль',
                        icon: Icon(_hide ? Icons.visibility_rounded : Icons.visibility_off_rounded, color: AppColors.muted),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                      enabledBorder: err
                          ? OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.error, width: 2))
                          : null,
                    ),
                  ),
                  if (err) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: AppText.bodyStrong.copyWith(color: AppColors.error)),
                    if (_hint != null) Text(_hint!, style: AppText.small),
                  ],
                  const SizedBox(height: 16),
                  BigButton(label: 'Войти', icon: Icons.login_rounded, busy: _busy, onPressed: _submit),
                  const SizedBox(height: 16),
                  const _SupportNote(),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SupportNote extends StatelessWidget {
  const _SupportNote();

  @override
  Widget build(BuildContext context) {
    final link = AppText.small.copyWith(color: AppColors.blue, fontWeight: FontWeight.w600);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(20)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_rounded, size: 20, color: AppColors.blue),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Забыли пароль? Напишите в поддержку Super Market — сбросим и пришлём новый. После входа — свой код из 4 цифр или Face ID.',
                style: AppText.small.copyWith(color: AppColors.ink)),
            const SizedBox(height: 6),
            Wrap(spacing: 16, children: [
              GestureDetector(
                onTap: () => launchUrl(Uri.parse('https://t.me/$supportTelegram'), mode: LaunchMode.externalApplication),
                child: Text('Telegram @$supportTelegram', style: link),
              ),
              GestureDetector(
                onTap: () => launchUrl(Uri.parse('tel:$supportPhone')),
                child: Text('+998 50 576 47 23', style: link),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// В1а — вошли по временному паролю: придумать свой. Дальше — код из 4 цифр.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _pw = TextEditingController();
  final _repeat = TextEditingController();
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _repeat.dispose();
    super.dispose();
  }

  List<(bool, String)> get _checks {
    final p = _pw.text;
    return [
      (p.length >= 8 && p.length <= 72, 'Не меньше 8 символов'),
      (RegExp(r'\p{L}', unicode: true).hasMatch(p) && RegExp(r'\d').hasMatch(p), 'Есть буквы и цифры'),
      (p.isNotEmpty && p == _repeat.text, 'Пароли совпадают'),
    ];
  }

  Future<void> _save() async {
    if (!_checks.every((c) => c.$1) || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final st = context.read<StoreState>();
    try {
      await context.read<Api>().post('/auth/store/password', {'new_password': _pw.text});
      TextInput.finishAutofillContext();
      // Пароль уже сменён: если профиль не загрузится, покажем «Повторить», а не этот экран.
      st.mustChangePassword = false;
      await st.load();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, {bool autofocus = false, TextInputAction action = TextInputAction.next}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label, style: AppText.caption),
      const SizedBox(height: 8),
      TextField(
        controller: c,
        enabled: !_busy,
        autofocus: autofocus,
        obscureText: _hide,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: action,
        autofillHints: const [AutofillHints.newPassword],
        inputFormatters: [LengthLimitingTextInputFormatter(72)],
        style: AppText.body.copyWith(fontSize: 17),
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: action == TextInputAction.done ? (_) => _save() : null,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.lock_rounded, color: AppColors.muted),
          suffixIcon: IconButton(
            tooltip: _hide ? 'Показать пароль' : 'Скрыть пароль',
            icon: Icon(_hide ? Icons.visibility_rounded : Icons.visibility_off_rounded, color: AppColors.muted),
            onPressed: () => setState(() => _hide = !_hide),
          ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final checks = _checks;
    final ready = checks.every((c) => c.$1);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: IconBox(Icons.key_rounded, bg: AppColors.primary, fg: AppColors.white, size: 56, iconSize: 30, radius: 18),
                  ),
                  const SizedBox(height: 16),
                  const Text('Свой пароль', style: TextStyle(fontFamily: 'Inter', fontSize: 28, height: 1.2, fontWeight: FontWeight.w700, color: AppColors.ink)),
                  const SizedBox(height: 6),
                  Text('Вы вошли по временному паролю. Придумайте новый — его будете знать только вы.',
                      style: AppText.body.copyWith(color: AppColors.text2)),
                  const SizedBox(height: 24),
                  _field(_pw, 'Новый пароль', autofocus: true),
                  const SizedBox(height: 16),
                  _field(_repeat, 'Повторите пароль', action: TextInputAction.done),
                  const SizedBox(height: 14),
                  for (final (ok, text) in checks)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 18, color: ok ? AppColors.success : AppColors.muted),
                        const SizedBox(width: 8),
                        Text(text, style: AppText.body.copyWith(fontSize: 14)),
                      ]),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 6),
                    Text(_error!, style: AppText.bodyStrong.copyWith(color: AppColors.error)),
                  ],
                  const SizedBox(height: 16),
                  BigButton(label: 'Сохранить', icon: Icons.check_rounded, busy: _busy, onPressed: ready ? _save : null),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : () => signOut(context),
                    child: Text('Выйти', style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(20)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.info_rounded, size: 20, color: AppColors.blue),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Дальше — код из 4 цифр или Face ID для быстрого входа на этом телефоне.',
                            style: AppText.small.copyWith(color: AppColors.ink)),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
