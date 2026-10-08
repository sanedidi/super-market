import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import 'account_logic.dart';

/// Ш4 · «Удалить аккаунт?»: причина, комментарий и запрос супер-админу
/// (POST /store/me/deletion-request). Сам аккаунт удаляет супер-админ.
Future<void> requestAccountDeletion(BuildContext context, {required bool isOwner}) async {
  final res = await showSheet<Map<String, dynamic>>(context, (_) => DeleteAccountSheet(isOwner: isOwner));
  if (res == null || !context.mounted) return;
  showMessage(context, deletionSentMessage(already: deletionAlreadySent(res, DateTime.now())));
}

class DeleteAccountSheet extends StatefulWidget {
  const DeleteAccountSheet({super.key, required this.isOwner});

  final bool isOwner;

  @override
  State<DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<DeleteAccountSheet> {
  final _comment = TextEditingController();
  String? _reason;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    try {
      final res = await api.post('/store/me/deletion-request', {'reason': deletionReason(_reason, _comment.text)});
      if (!mounted) return;
      Navigator.of(context).pop(res is Map<String, dynamic> ? res : <String, dynamic>{});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title: tr('Удалить аккаунт?', 'Akkauntni oʻchirasizmi?'), text: deletionText(isOwner: widget.isOwner)),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final r in deletionReasons)
          ChoiceChip(
            label: Text(deletionReasonLabel(r)),
            selected: _reason == r,
            showCheckmark: false,
            selectedColor: AppColors.ink,
            backgroundColor: AppColors.soft,
            side: BorderSide.none,
            shape: const StadiumBorder(),
            labelStyle: AppText.small.copyWith(fontWeight: FontWeight.w600, color: _reason == r ? AppColors.white : AppColors.ink),
            onSelected: _busy ? null : (bool v) => setState(() => _reason = v ? r : null),
          ),
      ]),
      const SizedBox(height: 16),
      TextField(
        controller: _comment,
        enabled: !_busy,
        maxLines: 3,
        minLines: 1,
        maxLength: 400,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: tr('Комментарий (необязательно)', 'Izoh (ixtiyoriy)'), counterText: '', errorText: _error, errorMaxLines: 3),
      ),
      const SizedBox(height: 20),
      SheetButton(label: tr('Отправить запрос', 'Soʻrov yuborish'), busy: _busy, onPressed: _submit),
      const SizedBox(height: 10),
      SheetButton(label: tr('Отмена', 'Bekor qilish'), primary: false, onPressed: _busy ? null : () => Navigator.of(context).pop()),
    ]);
  }
}
