import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'courier_state.dart';
import 'screens/orders_screen.dart';

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://169.58.31.233:8090/api/v1');

const brand = Color(0xFF155EEF);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = Api(baseUrl: apiUrl, app: 'store');
  await api.init();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider(create: (_) => CourierState(api)),
      ],
      child: const CourierApp(),
    ),
  );
}

class CourierApp extends StatelessWidget {
  const CourierApp({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.watch<Api>();
    return MaterialApp(
      title: 'Курьер',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: brand, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF6F7F9)),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('uz'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: api.loggedIn
          ? const OrdersScreen()
          : LoginScreen(api: api, title: 'Курьер', subtitle: 'Вход сотрудника магазина', onOpenUrl: (u) => openUrl(u)),
    );
  }
}

Future<void> openUrl(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
}

/// Звонок.
Future<void> call(BuildContext context, String phone) async {
  try {
    await launchUrl(Uri.parse('tel:${phone.replaceAll(' ', '')}'));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Маршрут в Яндекс Картах (или в браузере, если приложения нет).
Future<void> route(BuildContext context, double lat, double lng) async {
  try {
    await openUrl('https://yandex.uz/maps/?rtext=~$lat,$lng&rtt=auto');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
