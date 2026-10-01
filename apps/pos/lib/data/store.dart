import 'dart:convert';
import 'dart:io';

/// Данные кассы на диске: обычные JSON-файлы в папке приложения.
/// Запись атомарная (через временный файл), чтобы выключение света посреди
/// записи не испортило каталог или очередь.
class FileStore {
  FileStore(this.root);

  final Directory root;

  File file(String name) => File('${root.path}${Platform.pathSeparator}$name');

  Directory dir(String name) => Directory('${root.path}${Platform.pathSeparator}$name');

  Future<Map<String, dynamic>?> readJson(String name) async {
    final f = file(name);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }

  /// Записи в один файл идут строго по очереди: два одновременных сохранения
  /// (например, состояние кассы из разных событий) не мешают друг другу.
  final Map<String, Future<void>> _writes = {};

  Future<void> writeJson(String name, Object data) {
    final content = jsonEncode(data);
    final prev = _writes[name] ?? Future<void>.value();
    final next = prev.catchError((Object _) {}).then((_) => writeAtomic(file(name), content));
    _writes[name] = next;
    return next.whenComplete(() {
      if (identical(_writes[name], next)) _writes.remove(name);
    });
  }

  Future<void> delete(String name) async {
    final f = file(name);
    if (await f.exists()) await f.delete();
  }

  /// Дописать строку JSON в журнал (по строке на запись).
  Future<void> append(String name, Map<String, dynamic> entry) async {
    final f = file(name);
    await f.parent.create(recursive: true);
    await f.writeAsString('${jsonEncode(entry)}\n', mode: FileMode.append, flush: true);
  }

  /// Прочитать журнал. Недописанная последняя строка (сбой питания) пропускается.
  Future<List<Map<String, dynamic>>> readLines(String name) async {
    final f = file(name);
    if (!await f.exists()) return [];
    final out = <Map<String, dynamic>>[];
    for (final line in await f.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(jsonDecode(line) as Map<String, dynamic>);
      } on FormatException {
        // обрыв записи — пропускаем
      }
    }
    return out;
  }
}

Future<void> writeAtomic(File f, String content) async {
  await f.parent.create(recursive: true);
  final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
  await tmp.writeAsString(content, flush: true);
  try {
    await tmp.rename(f.path);
  } on FileSystemException {
    // Windows может не дать заменить файл, который кто-то читает — пробуем ещё раз.
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }
}
