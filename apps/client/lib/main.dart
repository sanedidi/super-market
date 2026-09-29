import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screens/onboarding_screen.dart';
import 'screens/root_shell.dart';
import 'state.dart';
import 'ui/brand.dart';
import 'ui/theme.dart';

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://10.0.2.2:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://169.58.31.233:8090/api/v1');

const _onboardingKey = 'sm_client_onboarding_done';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

Future<void> openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

class ClientApp extends StatelessWidget {
  const ClientApp({super.key, required this.onboardingDone});
  final bool onboardingDone;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Super Market',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('uz'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: _Gate(onboardingDone: onboardingDone),
    );
  }
}

/// Заставка → онбординг (один раз) → вход → приложение.
class _Gate extends StatefulWidget {
  const _Gate({required this.onboardingDone});
  final bool onboardingDone;

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  bool _splash = true;
  late bool _onboardingDone = widget.onboardingDone;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _splash = false);
    });
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey, true);
    if (mounted) setState(() => _onboardingDone = true);
  }

  @override
  Widget build(BuildContext context) {
    final api = context.watch<Api>();
    final Widget child;
    if (_splash) {
      child = const BrandSplash();
    } else if (!_onboardingDone) {
      child = OnboardingScreen(onDone: _finishOnboarding);
    } else if (!api.loggedIn) {
      child = LoginScreen(
        api: api,
        title: 'Вход',
        subtitle: 'Продукты из магазинов рядом с вами',
        onOpenUrl: openUrl,
        logo: const BrandMark(size: 88),
      );
    } else {
      child = const RootShell();
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: child);
  }
}

/// Сообщение об ошибке внизу экрана.
void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
}
