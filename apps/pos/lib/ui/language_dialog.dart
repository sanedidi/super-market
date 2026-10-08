import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show Lang, tr;

import 'theme.dart';
import 'widgets.dart';

/// F11 → 9: окно выбора языка кассы (Figma «Язык приложения · Til», Я8).
/// 1 — узбекский, 2 — русский, Esc — назад. Язык применяется сразу; каталог
/// касса перезагружает сама (PosController слушает Lang).
Future<void> showLanguageDialog(BuildContext context) async {
  final code = await showDialog<String>(context: context, builder: (_) => const _LanguageDialog());
  if (code != null) await Lang.instance.set(code);
}

class _LanguageDialog extends StatelessWidget {
  const _LanguageDialog();

  @override
  Widget build(BuildContext context) {
    void pick(String code) => Navigator.of(context).pop(code);

    Widget option(String key, String code, String caption) => KeyCard(
          keyLabel: key,
          title: Lang.names[code]!,
          subtitle: caption,
          style: Lang.instance.code == code ? KeyCardStyle.active : KeyCardStyle.normal,
          onTap: () => pick(code),
        );

    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        final ch = printable(e);
        if (ch == '1') {
          pick(Lang.uz);
          return KeyEventResult.handled;
        }
        if (ch == '2') {
          pick(Lang.ru);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        backgroundColor: C.surface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Til · Язык', style: t(26, w: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                tr('Экраны кассы и надписи на чеке будут на выбранном языке. В фискальный чек названия товаров уходят как раньше.',
                    'Kassa ekranlari va chek yozuvlari tanlangan tilda boʻladi. Fiskal chekka mahsulot nomlari avvalgidek ketadi.'),
                style: t(15, c: C.ts, h: 1.35),
              ),
              const SizedBox(height: 18),
              option('1', Lang.uz, tr('Узбекский · латиница', 'Lotin alifbosi')),
              const SizedBox(height: 10),
              option('2', Lang.ru, tr('Русский язык', 'Rus tili')),
              const SizedBox(height: 18),
              Text(tr('1 / 2 — выбрать · Esc — назад', '1 / 2 — tanlash · Esc — orqaga'), style: t(14, c: C.ts)),
            ]),
          ),
        ),
      ),
    );
  }
}
