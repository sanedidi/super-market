import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/login/password_login.dart' show supportPhone, supportTelegram;
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// Вход дистрибьютора по логину и паролю (выдаёт Super Market).
class DistributorLoginScreen extends StatefulWidget {
  const DistributorLoginScreen({super.key});

  @override
  State<DistributorLoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<DistributorLoginScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final login = _login.text.trim().toLowerCase();
    final password = _password.text;
    if (login.isEmpty || password.isEmpty) {
      setState(() => _error = tr('Введите логин и пароль', 'Login va parolni kiriting'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Api>().signIn('/auth/store/login', {'login': login, 'password': password});
      TextInput.finishAutofillContext();
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _error = e.code == 'invalid_credentials' ? tr('Неверный логин или пароль', 'Login yoki parol notoʻgʻri') : e.message);
      }
    } catch (_) {
      if (mounted) setState(() => _error = tr('Нет связи с сервером. Проверьте интернет', 'Server bilan aloqa yoʻq. Internetni tekshiring'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    IconBox(Icons.local_shipping_rounded, bg: AppColors.primary, fg: AppColors.white, size: 56, iconSize: 30, radius: 18),
                    LangSwitch(),
                  ]),
                  const SizedBox(height: 24),
                  Text(tr('Вход для агента', 'Agent uchun kirish'), style: AppText.h2),
                  const SizedBox(height: 6),
                  Text(tr('Логин и пароль выдаёт Super Market при подключении.', 'Login va parolni Super Market ulanishda beradi.'), style: AppText.small),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _login,
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(labelText: tr('Логин', 'Login'), prefixIcon: const Icon(Icons.person_outline_rounded)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: _hide,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: tr('Пароль', 'Parol'),
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
                  ],
                  const SizedBox(height: 20),
                  BigButton(label: tr('Войти', 'Kirish'), icon: Icons.login_rounded, busy: _busy, onPressed: _submit),
                  const SizedBox(height: 20),
                  Text(tr('Нет логина? Напишите нам — подключим вас как дистрибьютора.', 'Login yoʻqmi? Bizga yozing — sizni distribyutor sifatida ulaymiz.'),
                      style: AppText.small, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    TextButton.icon(
                      onPressed: () => launchUrl(Uri.parse('https://t.me/$supportTelegram'), mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.send_rounded, size: 18),
                      label: const Text('Telegram'),
                    ),
                    TextButton.icon(
                      onPressed: () => launchUrl(Uri.parse('tel:$supportPhone')),
                      icon: const Icon(Icons.call_rounded, size: 18),
                      label: Text(formatPhone(supportPhone)),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
