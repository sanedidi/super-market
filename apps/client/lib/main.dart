import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screens/home_screen.dart';
import 'state.dart';

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://10.0.2.2:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://169.58.31.233:8090/api/v1');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = Api(baseUrl: apiUrl, app: 'client');
  await api.init();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider(create: (_) => AppState(api)),
      ],
      child: const ClientApp(),
    ),
  );
}

Future<void> openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

class ClientApp extends StatelessWidget {
  const ClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.watch<Api>();
    return MaterialApp(
      title: 'Продукты с доставкой',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF16A34A), useMaterial3: true),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('uz'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: api.loggedIn
          ? const HomeScreen()
          : LoginScreen(
              api: api,
              title: 'Вход',
              subtitle: 'Продукты из магазинов рядом с вами',
              onOpenUrl: openUrl,
            ),
    );
  }
}

/// Сообщение об ошибке внизу экрана.
void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
}
