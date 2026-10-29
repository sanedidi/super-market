import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

/// С1 · Вход — логин и пароль, которые выдаёт владелец магазина в «Сотрудники».
/// Первый вход по временному паролю → С2 «Придумайте свой пароль» (как в «SM Магазин»).
class EmployeeLoginScreen extends StatefulWidget {
  const EmployeeLoginScreen({super.key});

  @override
  State<EmployeeLoginScreen> createState() => _EmployeeLoginScreenState();
}

class _EmployeeLoginScreenState extends State<EmployeeLoginScreen> {
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

  static String _attempts(int n) => Lang.instance.isUz
      ? '$n ta urinish'
      : (n == 1 ? '1 попытка' : (n >= 2 && n <= 4 ? '$n попытки' : '$n попыток'));

  Future<void> _submit() async {
    final login = _login.text.trim().toLowerCase();
    final password = _password.text;
    if (login.isEmpty || password.isEmpty) {
      setState(() {
        _error = tr('Введите логин и пароль', 'Login va parolni kiriting');
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
          _error = tr('Неверный логин или пароль', 'Login yoki parol notoʻgʻri');
          _hint = left is num
              ? tr('Осталось ${_attempts(left.toInt())}, потом вход закроется на 15 минут',
                  'Yana ${_attempts(left.toInt())} qoldi, soʻng kirish 15 daqiqaga yopiladi')
              : null;
        } else {
          _error = e.message;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr('Нет связи с сервером. Проверьте интернет и попробуйте ещё раз',
            'Server bilan aloqa yoʻq. Internetni tekshirib, qayta urinib koʻring'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final err = _error != null;
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 56,
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(18)),
                      child: Text('SM', style: AppText.title.copyWith(color: AppColors.white, fontSize: 20)),
                    ),
                    const Spacer(),
                    const LangSwitch(),
                  ]),
                  const SizedBox(height: 24),
                  Text(tr('SM Сотрудник', 'SM Xodim'), style: AppText.h1.copyWith(fontSize: 28)),
                  const SizedBox(height: 8),
                  Text(
                      tr('Для продавцов, кладовщиков и сборщиков заказов. Логин и пароль выдаёт владелец магазина.',
                          'Sotuvchilar, omborchilar va buyurtma yigʻuvchilar uchun. Login va parolni doʻkon egasi beradi.'),
                      style: AppText.body.copyWith(color: AppColors.text2)),
                  const SizedBox(height: 24),
                  Text(tr('Логин', 'Login'), style: AppText.caption),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _login,
                    autofillHints: const [AutofillHints.username],
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.visiblePassword,
                    onSubmitted: (_) => _passwordFocus.requestFocus(),
                    decoration: InputDecoration(
                      hintText: tr('например, dilshod.ch', 'masalan, dilshod.ch'),
                      enabledBorder: err ? OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.error, width: 2)) : null,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(tr('Пароль', 'Parol'), style: AppText.caption),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _password,
                    focusNode: _passwordFocus,
                    obscureText: _hide,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: '••••••••',
                      enabledBorder: err ? OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.error, width: 2)) : null,
                      suffixIcon: IconButton(
                        tooltip: _hide ? tr('Показать пароль', 'Parolni koʻrsatish') : tr('Скрыть пароль', 'Parolni yashirish'),
                        icon: Icon(_hide ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: AppText.small.copyWith(color: AppColors.error, fontWeight: FontWeight.w600)),
                    if (_hint != null) Text(_hint!, style: AppText.small),
                  ],
                  const SizedBox(height: 20),
                  BigButton(label: tr('Войти', 'Kirish'), icon: Icons.login_rounded, busy: _busy, onPressed: _submit),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(16)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.help_outline_rounded, size: 20, color: AppColors.text2),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                            tr('Забыли пароль? Попросите владельца выдать новый временный пароль в «Сотрудники».',
                                'Parolni unutdingizmi? Egasidan «Xodimlar» boʻlimida yangi vaqtinchalik parol berishini soʻrang.'),
                            style: AppText.small),
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
