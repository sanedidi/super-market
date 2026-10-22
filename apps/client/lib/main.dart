import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'push.dart';
import 'screens/auth_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/root_shell.dart';
import 'state.dart';
import 'ui/brand.dart';
import 'ui/theme.dart';
import 'version.dart';

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://10.0.2.2:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');

const _onboardingKey = 'sm_client_onboarding_done';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Lang.instance.init();
  await Push.init();
  final api = Api(baseUrl: apiUrl, app: 'client');
  await api.init();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider(create: (_) => AppState(api)),
      ],
      child: ClientApp(onboardingDone: prefs.getBool(_onboardingKey) ?? false),
    ),
  );
}

Future<void> openUrl(String url) => launchUrl(Uri.parse(docUrl(url)), mode: LaunchMode.externalApplication);

class ClientApp extends StatelessWidget {
  const ClientApp({super.key, required this.onboardingDone});
  final bool onboardingDone;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Lang.instance,
      builder: (context, _) => MaterialApp(
        title: 'Super Market',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        locale: Lang.instance.locale,
        supportedLocales: Lang.locales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // Тёмные значки статус-бара по умолчанию; красные экраны (главная,
        // вход, заставка) задают светлые своим AnnotatedRegion.
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(value: SystemUiOverlayStyle.dark, child: child!),
        // ОБ1 · «Есть обновление» — шторка поверх главного экрана.
        home: UpdateCheck(api: context.read<Api>(), app: appId, version: appVersion, open: openStore, child: _Gate(onboardingDone: onboardingDone)),
      ),
    );
  }
}

/// Онбординг (один раз) → приложение. Вход не обязателен: гость сразу видит
/// главную, а войти просят при оформлении заказа и в разделах профиля
/// (guest.dart). Заставку показывает система (flutter_native_splash).
class _Gate extends StatefulWidget {
  const _Gate({required this.onboardingDone});
  final bool onboardingDone;

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  late bool _onboardingDone = widget.onboardingDone;

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey, true);
    if (mounted) setState(() => _onboardingDone = true);
  }

  @override
  Widget build(BuildContext context) {
    final Widget child = _onboardingDone ? const _ProfileGate() : OnboardingScreen(onDone: _finishOnboarding);
    return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: child);
  }
}

/// Запуск со входом: если имя ещё не указано — шаг 3 «Как вас зовут?», иначе
/// приложение. Гость сразу попадает в приложение; вход по ходу работы
/// спрашивает имя сам (AuthScreen).
class _ProfileGate extends StatefulWidget {
  const _ProfileGate();

  @override
  State<_ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<_ProfileGate> {
  /// null — ещё проверяем профиль.
  bool? _needName;

  @override
  void initState() {
    super.initState();
    // Гостю имя не нужно — сразу приложение.
    if (context.read<AppState>().isGuest) {
      _needName = false;
    } else {
      _check();
    }
  }

  Future<void> _check() async {
    final state = context.read<AppState>();
    var need = false;
    try {
      await state.loadProfile();
      need = '${state.profile?['first_name'] ?? ''}'.trim().isEmpty;
    } catch (_) {
      // Нет сети — пускаем в приложение, имя можно указать в профиле.
    }
    if (mounted) setState(() => _needName = need);
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.select<Api, bool>((a) => a.loggedIn);
    final need = _needName;
    // Пока грузится профиль — та же картинка, что у нативной заставки.
    if (need == null) return const BrandSplash();
    // «Назад» на шаге имени выходит из аккаунта — тогда приложение гостя.
    if (need && loggedIn) {
      return NameStepScreen(
        onDone: () => setState(() => _needName = false),
        onBack: () {
          final api = context.read<Api>();
          setState(() => _needName = false);
          return api.logout();
        },
      );
    }
    return const RootShell();
  }
}

/// Сообщение об ошибке внизу экрана.
void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
}
