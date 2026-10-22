import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/version.dart';

void main() {
  // Подняли версию в pubspec.yaml — поднимите и appVersion: иначе шторка
  // «Есть обновление» будет считать приложение старым (или новым).
  test('appVersion совпадает с version в pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(appVersion, line.substring('version:'.length).trim().split('+').first);
  });
}
