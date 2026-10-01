import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Вход курьера по логину и паролю (Figma «Курьер · приложение», К1).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
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
    final login = _login.text.trim();
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
      await context.read<Api>().signIn('/auth/courier/login', {'login': login, 'password': password});
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
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _attempts(int n) => n == 1 ? '1 попытка' : (n >= 2 && n <= 4 ? '$n попытки' : '$n попыток');

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final err = _error != null;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: AutofillGroup(
          child: ListView(padding: EdgeInsets.zero, children: [
            Container(
              padding: EdgeInsets.fromLTRB(24, top + 36, 24, 28),
              decoration: const BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Super\nMarket',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 44, height: 1, fontWeight: FontWeight.w700, color: AppColors.white, letterSpacing: -1.5)),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: const Color(0x2EFFFFFF), borderRadius: BorderRadius.circular(20)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.delivery_dining_rounded, color: AppColors.white, size: 18),
                    SizedBox(width: 6),
                    Text('Курьер', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.white)),
                  ]),
                ),
                const SizedBox(height: 14),
                const Text('Заказы, маршрут и звонки — в одном приложении',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 16, height: 1.35, color: Color(0xE6FFFFFF))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Вход для курьера', style: AppText.h2),
                const SizedBox(height: 6),
                Text('Логин и пароль выдаёт магазин', style: AppText.body.copyWith(color: AppColors.text2)),
                const SizedBox(height: 20),
                const Text('Логин', style: AppText.caption),
                const SizedBox(height: 8),
                TextField(
                  controller: _login,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.username],
                  style: AppText.body.copyWith(fontSize: 17),
                  onSubmitted: (_) => _passwordFocus.requestFocus(),
                  decoration: InputDecoration(
                    hintText: 'например, aziz.karimov',
                    prefixIcon: const Icon(Icons.person_rounded, color: AppColors.muted),
                    errorText: err ? '' : null,
                    errorStyle: const TextStyle(height: 0, fontSize: 0),
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
                  style: AppText.body.copyWith(fontSize: 17),
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: 'Пароль',
                    prefixIcon: const Icon(Icons.lock_rounded, color: AppColors.muted),
                    suffixIcon: IconButton(
                      tooltip: _hide ? 'Показать пароль' : 'Скрыть пароль',
                      icon: Icon(_hide ? Icons.visibility_rounded : Icons.visibility_off_rounded, color: AppColors.muted),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                    errorText: err ? '' : null,
                    errorStyle: const TextStyle(height: 0, fontSize: 0),
                  ),
                ),
                if (err) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(color: AppColors.errorSoft, borderRadius: BorderRadius.circular(14)),
                    child: Row(children: [
                      const Icon(Icons.error_rounded, color: AppColors.error),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_error!, style: AppText.bodyStrong.copyWith(color: AppColors.error)),
                          if (_hint != null) Text(_hint!, style: AppText.small.copyWith(color: AppColors.error)),
                        ]),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: 20),
                BigButton(label: 'Войти', icon: Icons.arrow_forward_rounded, busy: _busy, onPressed: _submit),
                const SizedBox(height: 18),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.help_rounded, size: 18, color: AppColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Забыли пароль? Попросите менеджера магазина сбросить его в панели → «Курьеры»', style: AppText.small),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
