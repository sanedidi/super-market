import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'push.dart';
import 'screens/shell.dart';
import 'state.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');

/// Версия для экрана «Ещё» (совпадает с pubspec.yaml).
const appVersion = '0.2.0';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Push.init();
  final api = Api(baseUrl: apiUrl, app: 'store');
  await api.init();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider(create: (_) => StoreState(api)),
      ],
      child: const StoreApp(),
    ),
  );
}

class StoreApp extends StatelessWidget {
  const StoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<Api>();
    final loggedIn = context.select<Api, bool>((a) => a.loggedIn);
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Super Market Магазин',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('uz'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: loggedIn
          ? const _Gate()
          : LoginScreen(
              api: api,
              title: 'Super Market Магазин',
              subtitle: 'Приход по фото накладной, склад и заказы магазина',
              onOpenUrl: (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            ),
    );
  }
}

/// После входа: ждём профиль и список магазинов.
class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    if (st.me == null) {
      return Scaffold(
        body: Center(
          child: st.error == null
              ? const CircularProgressIndicator()
              : EmptyState(
                  icon: Icons.wifi_off_rounded,
                  title: 'Не удалось загрузить данные',
                  text: st.error.toString(),
                  action: 'Повторить',
                  onAction: st.load,
                ),
        ),
      );
    }
    if (st.storeId == null) {
      return Scaffold(
        body: Center(
          child: EmptyState(
            icon: Icons.storefront_outlined,
            title: 'Нет доступных магазинов',
            text: 'Попросите владельца сети дать вам доступ к магазину в панели магазина.',
            action: 'Выйти',
            onAction: () => context.read<Api>().logout(),
          ),
        ),
      );
    }
    return const Shell();
  }
}

/// Сообщение внизу экрана.
void showMessage(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(e.toString())));
}
