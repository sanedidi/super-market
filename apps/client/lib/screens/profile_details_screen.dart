import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show formatPhone;

import '../main.dart';
import '../state.dart';
import '../ui/person_form.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// «Личные данные»: имя, фамилия, дата рождения, пол; телефон только для чтения.
class ProfileDetailsScreen extends StatefulWidget {
  const ProfileDetailsScreen({super.key});

  @override
  State<ProfileDetailsScreen> createState() => _ProfileDetailsScreenState();
}

class _ProfileDetailsScreenState extends State<ProfileDetailsScreen> {
  late final PersonData _data = PersonData.fromProfile(context.read<AppState>().profile);
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await context.read<AppState>().updateProfile(_data.toPatch());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = '${context.watch<AppState>().profile?['phone'] ?? ''}';
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const PageHeader(title: 'Личные данные'),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 20), children: [
              PersonForm(data: _data, onChanged: () => setState(() {})),
              const SizedBox(height: 16),
              const FieldLabel('Телефон'),
              InputDecorator(
                decoration: outlinedField('').copyWith(fillColor: AppColors.soft, enabledBorder: InputBorder.none, border: InputBorder.none),
                child: Text(formatPhone(phone), style: AppText.body.copyWith(fontSize: 16, color: AppColors.text2)),
              ),
              const SizedBox(height: 6),
              Text('Номер меняется через поддержку — по нему приходят коды входа.', style: AppText.caption),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: SizedBox(
              width: double.infinity,
              child: StepButton(label: 'Сохранить', busy: _busy, onPressed: _data.firstName.trim().isEmpty ? null : _save),
            ),
          ),
        ]),
      ),
    );
  }
}
