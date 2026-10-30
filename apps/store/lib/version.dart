import 'package:url_launcher/url_launcher.dart';

/// Версия приложения — та же, что в pubspec.yaml (сверяет test/version_test.dart).
/// По ней сервер решает, показать ли шторку «Есть обновление» (sm_core UpdateCheck).
const appVersion = '0.9.7';

/// Код приложения для /public/app-version.
const appId = 'store';

/// Ссылка на App Store / Google Play — во внешнем приложении стора.
Future<void> openStore(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}
