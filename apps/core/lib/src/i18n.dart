import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sheet.dart';

/// Язык интерфейса приложений: узбекский (латиница, по умолчанию) или русский.
///
/// Строки в коде пишутся парой: `tr('Сохранить', 'Saqlash')` — русский
/// первым, узбекский вторым. Выбор хранится на устройстве; каждый запрос к API
/// уходит с заголовком `Accept-Language` (см. api.dart), и сервер отвечает
/// на том же языке — ошибки, названия товаров и категорий.
///
/// Апострофы в узбекском — типографские: oʻ, gʻ (U+02BB) и ʼ (U+02BC),
/// не ASCII `'`.
class Lang extends ChangeNotifier {
  Lang._();

  static final Lang instance = Lang._();

  static const uz = 'uz';
  static const ru = 'ru';
  static const supported = [uz, ru];

  /// Названия языков — каждое на своём языке.
  static const names = {uz: 'Oʻzbekcha', ru: 'Русский'};

  /// Для `MaterialApp.supportedLocales`.
  static const locales = [Locale(uz), Locale(ru)];

  static const _key = 'sm_lang';

  String _code = uz;

  /// 'uz' или 'ru'.
  String get code => _code;
  bool get isUz => _code == uz;
  bool get isRu => _code == ru;
  Locale get locale => Locale(_code);

  /// Прочитать сохранённый выбор (вызвать в main до runApp).
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    if (v != null && supported.contains(v)) _code = v;
  }

  /// Сменить язык: сохраняет выбор и перерисовывает весь интерфейс без
  /// потери навигации и состояния экранов.
  Future<void> set(String code) async {
    if (!supported.contains(code) || code == _code) return;
    _code = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, code);
    notifyListeners();
    _rebuildAll();
  }

  /// Строки, посчитанные в build(), обновятся сами; но виджеты, которые не
  /// перестраиваются (const-предки, кеш), — нет. Помечаем всё дерево грязным.
  static void _rebuildAll() {
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(rebuild);
  }
}

/// Строка на текущем языке: [ru] — русский, [uz] — узбекский (латиница).
///
/// Не const: внутри `const`-виджетов не работает — у таких виджетов `const`
/// снимается.
String tr(String ru, String uz) => Lang.instance._code == Lang.uz ? uz : ru;

/// Значение из пары полей данных с сервера: `pick(p, 'name')` → `name_uz`
/// при узбекском, если он заполнен, иначе `name`. Обычно сервер уже сам
/// отдаёт `name` на языке запроса — это для экранов редактирования.
String pickLang(Map<String, dynamic> m, String field) {
  if (Lang.instance.isUz) {
    final uz = m['${field}_uz'];
    if (uz is String && uz.trim().isNotEmpty) return uz;
  }
  return '${m[field] ?? ''}';
}

/// Шторка выбора языка. Возвращает выбранный код или null.
Future<String?> pickLanguage(BuildContext context) async {
  final picked = await showSheet<String>(
    context,
    (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            tr('Язык приложения', 'Ilova tili'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
        for (final code in Lang.supported)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(Lang.names[code]!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            trailing: code == Lang.instance.code
                ? Icon(Icons.check_rounded, color: Theme.of(ctx).colorScheme.primary)
                : null,
            onTap: () => Navigator.of(ctx).pop(code),
          ),
      ],
    ),
  );
  if (picked != null) await Lang.instance.set(picked);
  return picked;
}

/// Готовый пункт настроек «Язык / Til» с текущим языком справа.
/// Приложения со своим стилем пунктов могут вызвать [pickLanguage] сами.
class LanguageTile extends StatelessWidget {
  const LanguageTile({super.key, this.onChanged});

  /// Вызывается после смены языка (например, сохранить язык в профиле).
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Lang.instance,
      builder: (context, _) => ListTile(
        leading: const Icon(Icons.language_rounded),
        title: Text(tr('Язык', 'Til')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Lang.names[Lang.instance.code]!, style: TextStyle(color: Theme.of(context).hintColor)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
        onTap: () async {
          final v = await pickLanguage(context);
          if (v != null) onChanged?.call(v);
        },
      ),
    );
  }
}

/// Компактный переключатель «UZ | RU» — для экранов входа и шапок,
/// где нет меню настроек.
class LangSwitch extends StatelessWidget {
  const LangSwitch({super.key, this.onChanged});

  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: Lang.instance,
      builder: (context, _) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: const Color(0xFFF3F3F4), borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final code in Lang.supported)
              GestureDetector(
                onTap: () async {
                  await Lang.instance.set(code);
                  onChanged?.call(code);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: code == Lang.instance.code ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    code.toUpperCase(),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: code == Lang.instance.code ? primary : const Color(0xFF6B6B70),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
