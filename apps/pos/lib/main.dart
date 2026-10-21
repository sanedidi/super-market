import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show Lang, tr;

import 'cafe/cafe_sale_screen.dart';
import 'cafe/display_screen.dart';
import 'cafe/kitchen_screen.dart';
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
const appVersion = '0.4.2';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Lang.instance.init();
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
    // Сеть-кафе: касса у прилавка с плитками блюд, номером заказа и бегунком.
    final cafe = context.select<PosController, bool>((p) => p.catalog.cafe != null);
    return ListenableBuilder(
      listenable: Lang.instance,
      builder: (context, _) => MaterialApp(
        title: tr('Super Market · Касса', 'Super Market · Kassa'),
        debugShowCheckedModeBanner: false,
        theme: posTheme(),
        locale: Lang.instance.locale,
        supportedLocales: Lang.locales,
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
                Stage.work => cafe ? const CafeSaleScreen() : const SaleScreen(),
                Stage.kitchen => const KitchenScreen(),
                Stage.display => const DisplayScreen(),
              },
      ),
    );
  }
}
