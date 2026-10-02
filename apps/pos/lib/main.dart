import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'data/api.dart';
import 'data/store.dart';
import 'state/pos.dart';
import 'ui/activation_screen.dart';
import 'ui/login_screen.dart';
import 'ui/open_shift_screen.dart';
import 'ui/sale_screen.dart';
import 'ui/theme.dart';

/// Адрес API задаётся при сборке: flutter build windows --dart-define=API_URL=https://…/api/v1
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.super-market.uz/api/v1');
const appVersion = '0.3.0';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}pos');
  await dir.create(recursive: true);
  final pos = PosController(store: FileStore(dir), api: PosApi(apiUrl), appVersion: appVersion);
  await pos.init();
  runApp(ChangeNotifierProvider.value(value: pos, child: const PosApp()));
}

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    final stage = context.select<PosController, Stage>((p) => p.stage);
    final revoked = context.select<PosController, bool>((p) => p.revoked);
    return MaterialApp(
      title: 'Super Market · Касса',
      debugShowCheckedModeBanner: false,
      theme: posTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('uz'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: revoked && stage != Stage.activate
          ? const RevokedScreen()
          : switch (stage) {
              Stage.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
              Stage.activate => const ActivationScreen(),
              Stage.login => const LoginScreen(),
              Stage.openShift => const OpenShiftScreen(),
              Stage.work => const SaleScreen(),
            },
    );
  }
}
