import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' hide LoginScreen;

import 'login.dart';
import 'shell.dart';
import 'state.dart';
import 'tracker.dart';
import 'ui.dart';
import 'version.dart';

// «SM Продажник» (Figma «SM Продажник · Обход с записью пути», П1–П7) —
// приложение продажников Super Market: обход районов с записью пути, карта
// обойдённых улиц и белых зон, отметки магазинов и заявки на подключение.
// Вход — логином и паролем от супер-админа («Продажники»).

export 'version.dart' show appVersion;

/// Адрес API задаётся при сборке: flutter run --dart-define=API_URL=http://localhost:8080/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Lang.instance.init();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final api = Api(baseUrl: apiUrl, app: 'field');
  await api.init();
  final tracker = Tracker(api);
  await tracker.restore();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider.value(value: tracker),
        ChangeNotifierProvider(create: (_) => FieldState(api)),
      ],
      child: const FieldApp(),
    ),
  );
}

class FieldApp extends StatelessWidget {
  const FieldApp({super.key});

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.select<Api, bool>((a) => a.loggedIn);
    return ListenableBuilder(
      listenable: Lang.instance,
      builder: (context, _) => MaterialApp(
        title: tr('SM Продажник', 'SM Savdo agenti'),
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
          child: loggedIn ? const Shell() : const LoginScreen(),
        ),
      ),
    );
  }
}
