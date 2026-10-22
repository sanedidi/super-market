import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' hide LoginScreen;
import 'package:url_launcher/url_launcher.dart';

import 'crowd/crowd_shell.dart';
import 'crowd/crowd_state.dart';
import 'screens/login_screen.dart';
import 'screens/shell.dart';
import 'state.dart';
import 'ui/theme.dart';
import 'version.dart';

// Версия для экранов «Ещё» / профиля — одна на приложение, в version.dart.
export 'version.dart' show appVersion;

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Lang.instance.init();
  // Одно приложение — два режима со своими токенами: штатный курьер
  // (логин и пароль) и курьер «по пути» (телефон и код).
  final api = Api(baseUrl: apiUrl, app: 'courier');
  final crowdApi = Api(baseUrl: apiUrl, app: 'crowd');
  await api.init();
  await crowdApi.init();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider(create: (_) => CourierState(api)),
        ChangeNotifierProvider(create: (_) => CrowdState(crowdApi)),
      ],
      child: const CourierApp(),
    ),
  );
}

class CourierApp extends StatelessWidget {
  const CourierApp({super.key});

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.select<Api, bool>((a) => a.loggedIn);
    final crowd = context.select<CrowdState, bool>((c) => c.loggedIn);
    return ListenableBuilder(
      listenable: Lang.instance,
      builder: (context, _) => MaterialApp(
        title: tr('Super Market Курьер', 'Super Market Kuryer'),
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        locale: Lang.instance.locale,
        supportedLocales: Lang.locales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // ОБ1 · «Есть обновление» — шторка поверх главного экрана.
        home: UpdateCheck(
          api: context.read<Api>(),
          app: appId,
          version: appVersion,
          open: openStore,
          child: loggedIn ? const Shell() : (crowd ? const CrowdShell() : const LoginScreen()),
        ),
      ),
    );
  }
}

/// Сообщение внизу экрана.
void showMessage(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(e.toString())));
}

Future<void> _open(BuildContext context, Uri uri) async {
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) showMessage(context, tr('Не удалось открыть: $uri', 'Ochib boʻlmadi: $uri'));
  } catch (_) {
    if (context.mounted) showMessage(context, tr('Не удалось открыть: $uri', 'Ochib boʻlmadi: $uri'));
  }
}

/// Открыть страницу сайта: политика конфиденциальности, условия для курьеров.
Future<void> openLink(BuildContext context, String url) => _open(context, Uri.parse(docUrl(url)));

/// Позвонить.
Future<void> call(BuildContext context, String phone) => _open(context, Uri.parse('tel:${phone.replaceAll(RegExp(r'[^+\d]'), '')}'));

/// Маршрут в Яндекс Картах (приложение или браузер).
Future<void> route(BuildContext context, num? lat, num? lng) async {
  if (lat == null || lng == null) return;
  await _open(context, Uri.parse('https://yandex.uz/maps/?rtext=~$lat,$lng&rtt=auto'));
}
