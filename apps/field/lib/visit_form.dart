import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'logic.dart';
import 'owner_login.dart';
import 'ui.dart';

/// Где продажник отмечает магазин.
class VisitPoint {
  const VisitPoint(this.lat, this.lng, this.accuracy);

  final double lat;
  final double lng;
  final double? accuracy;
}

/// Результат визита: «Подключить» (новый магазин), П5 «Отказ», «Закрыт»,
/// «Прийти позже», «Уже с Super Market». [place] — магазин, который уже
/// отмечен рядом («Это он — обновить»). Возвращает true, если отметили.
class VisitFormScreen extends StatefulWidget {
  const VisitFormScreen({super.key, required this.result, required this.point, this.place});

  final String result;
  final VisitPoint point;
  final Map<String, dynamic>? place;

  @override
  State<VisitFormScreen> createState() => _VisitFormScreenState();
}

class _VisitFormScreenState extends State<VisitFormScreen> {
  final _name = TextEditingController();
  final _owner = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _comment = TextEditingController();
  String? _photo;
  bool _uploading = false;
  String _reason = '';
  String _program = '';
  DateTime? _remind;
  // Логин владельца (П14): сам из названия, пока продажник его не изменил.
  String? _login;
  bool _busy = false;
  String? _error;

  String get _result => widget.result;

  @override
  void initState() {
    super.initState();
    final n = '${widget.place?['name'] ?? ''}'.trim();
    if (n.isNotEmpty) _name.text = n;
    _name.addListener(() {
      if (_result == 'lead' && _login == null) setState(() {});
    });
  }

  String get _ownerLogin => _login ?? loginFromName(_name.text);

  Future<void> _editLogin() async {
    final v = await promptSheet(
      context,
      title: tr('Логин владельца', 'Egasining logini'),
      text: tr('Латиница, цифры, точка, дефис или _ — от 3 до 32 символов', 'Lotin harflari, raqamlar, nuqta, defis yoki _ — 3 dan 32 tagacha belgi'),
      initial: _ownerLogin,
      hint: 'baraka.market',
      confirm: tr('Сохранить', 'Saqlash'),
    );
    if (v == null || !mounted) return;
    final login = v.trim().toLowerCase();
    if (!validLogin(login)) {
      setState(() => _error = tr('Логин: латиница, цифры, точка, дефис или _ — от 3 до 32 символов', 'Login: lotin harflari, raqamlar, nuqta, defis yoki _ — 3 dan 32 tagacha belgi'));
      return;
    }
    setState(() {
      _login = login;
      _error = null;
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _owner, _phone, _address, _comment]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _title => switch (_result) {
        'lead' => tr('Новый магазин', 'Yangi doʻkon'),
        'refused' => tr('Отказ', 'Rad etdi'),
        'closed' => tr('Закрыт / не работает', 'Yopiq / ishlamaydi'),
        'later' => tr('Прийти позже', 'Keyinroq kelish'),
        'ours' => tr('Уже с Super Market', 'Allaqachon Super Market’da'),
        _ => '',
      };

  bool get _photoRequired => _result == 'refused';
  bool get _photoShown => _result == 'refused' || _result == 'closed';

  Future<void> _takePhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 80);
    if (file == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final res = await context.read<Api>().upload('/field/uploads', bytes, 'shop.jpg') as Map<String, dynamic>;
      if (mounted) setState(() => _photo = '${res['url']}');
    } on ApiError catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _remind ?? now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 60)),
    );
    if (d != null) setState(() => _remind = d);
  }

  String? _check() {
    switch (_result) {
      case 'lead':
        if (_name.text.trim().isEmpty) return tr('Введите название магазина', 'Doʻkon nomini kiriting');
        if (_owner.text.trim().isEmpty) return tr('Введите имя владельца', 'Egasining ismini kiriting');
        if (normalizeUzPhone(_phone.text) == null) return tr('Введите телефон владельца — 9 цифр', 'Egasining telefonini kiriting — 9 ta raqam');
      case 'refused':
        if (_photo == null) return tr('Сфотографируйте витрину — так другой продажник узнает магазин', 'Vitrinani suratga oling — shunda boshqa agent doʻkonni taniydi');
        if (_reason.isEmpty) return tr('Выберите причину отказа', 'Rad etish sababini tanlang');
      case 'later':
        if (_remind == null) return tr('Выберите, когда прийти', 'Qachon kelishni tanlang');
    }
    return null;
  }

  Future<void> _save() async {
    final err = _check();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final p = widget.point;
    final body = <String, dynamic>{
      'result': _result,
      'lat': p.lat,
      'lng': p.lng,
      if (p.accuracy != null) 'accuracy': p.accuracy,
      if (widget.place != null) 'place_id': widget.place!['id'],
      'name': _name.text.trim(),
      'comment': _comment.text.trim(),
      if (_photo != null) 'photo_url': _photo,
      if (_result == 'refused') 'reason': _reason,
      if (_result == 'refused' && _reason == 'has_program' && _program.isNotEmpty) 'program': _program,
      if (_result == 'later' && _remind != null)
        'remind_on': '${_remind!.year}-${_remind!.month.toString().padLeft(2, '0')}-${_remind!.day.toString().padLeft(2, '0')}',
      if (_result == 'lead')
        'lead': {
          'name': _name.text.trim(),
          'owner_name': _owner.text.trim(),
          'owner_phone': normalizeUzPhone(_phone.text),
          'address': _address.text.trim(),
          if (_login != null) 'owner_login': _login,
        },
    };
    try {
      final res = await context.read<Api>().post('/field/visits', body);
      if (!mounted) return;
      if (_result == 'lead' && res is Map<String, dynamic> && res['owner'] != null) {
        // П15: логин и пароль владельцу — прямо сейчас.
        await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => OwnerLoginScreen(place: res)));
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      showSnack(context, tr('Отмечено', 'Belgilandi'));
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'login_taken') {
        setState(() => _error = tr('Логин «$_ownerLogin» уже занят — нажмите «Изменить» и придумайте другой', '«$_ownerLogin» logini band — «Oʻzgartirish»ni bosing va boshqasini oʻylab toping'));
      } else if (e.code == 'employee_exists') {
        setState(() => _error = tr('Этот номер уже работает в другом магазине Super Market — проверьте телефон владельца',
            'Bu raqam Super Market’ning boshqa doʻkonida ishlaydi — egasining telefonini tekshiring'));
      } else if (e.code == 'store_exists') {
        final d = e.details;
        final name = '${d['name'] ?? ''}';
        final mine = d['mine'] == true;
        final text = d['kind'] == 'lead'
            ? (mine
                ? tr('Вы уже отправили заявку на «$name».', '«$name» uchun arizani allaqachon yuborgansiz.')
                : tr('«$name» закреплён за другим агентом или продажником${d['until'] != null ? ' до ${shortDate(d['until'])}' : ''}.',
                    '«$name» boshqa agent yoki savdo agentiga biriktirilgan${d['until'] != null ? ' — ${shortDate(d['until'])} gacha' : ''}.'))
            : tr('«$name» уже работает в Super Market${d['reason'] == 'nearby' ? ' (${d['distance_m']} м от вас)' : ''}. Отметьте его как «Уже с Super Market».',
                '«$name» allaqachon Super Market’da ishlaydi${d['reason'] == 'nearby' ? ' (sizdan ${d['distance_m']} m)' : ''}. Uni «Allaqachon Super Market’da» deb belgilang.');
        await infoSheet(context, title: tr('Этот магазин уже есть', 'Bu doʻkon allaqachon bor'), text: text, icon: Icons.storefront_rounded);
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// П14 — «Вход для владельца в «SM Магазин»»: логин из названия, «Изменить».
  Widget _loginCard() {
    final login = _ownerLogin;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.key_rounded, size: 20, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('Вход для владельца в «SM Магазин»', 'Egasi uchun «SM Magazin»ga kirish'), style: AppText.bodyStrong)),
        ]),
        const SizedBox(height: 10),
        Material(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _editLogin,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Логин', 'Login'), style: AppText.small.copyWith(fontSize: 12)),
                    Text(_name.text.trim().isEmpty && _login == null ? '—' : login, style: AppText.title),
                  ]),
                ),
                const Icon(Icons.edit_rounded, size: 16, color: AppColors.primary),
                const SizedBox(width: 4),
                Text(tr('Изменить', 'Oʻzgartirish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary, fontSize: 14)),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          tr('${_login == null ? 'Придуман из названия магазина. ' : ''}Пароль Super Market придумает сам и покажет после подключения — владелец сменит его при первом входе.',
              '${_login == null ? 'Doʻkon nomidan olingan. ' : ''}Parolni Super Market oʻzi oʻylab topadi va ulangandan keyin koʻrsatadi — egasi uni birinchi kirishda almashtiradi.'),
          style: AppText.small,
        ),
      ]),
    );
  }

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(t, style: AppText.caption.copyWith(fontSize: 13)));

  Widget _chip(String label, bool on, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: on,
          showCheckmark: true,
          checkmarkColor: AppColors.white,
          selectedColor: AppColors.ink,
          backgroundColor: AppColors.soft,
          side: BorderSide.none,
          labelStyle: AppText.body.copyWith(fontSize: 14, color: on ? AppColors.white : AppColors.ink, fontWeight: FontWeight.w500),
          onSelected: (_) => onTap(),
        ),
      );

  Widget _photoField() {
    return Row(children: [
      if (_photo != null) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.network(_photo!, width: 80, height: 80, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(width: 80, height: 80, color: AppColors.soft)),
        ),
        const SizedBox(width: 10),
      ],
      InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _uploading ? null : _takePhoto,
        child: Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.muted, width: 1.5)),
          child: _uploading
              ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
              : Icon(_photo == null ? Icons.photo_camera_rounded : Icons.refresh_rounded, color: AppColors.text2, size: 28),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final quick = [
      (tr('Завтра', 'Ertaga'), today.add(const Duration(days: 1))),
      (tr('Через 3 дня', '3 kundan keyin'), today.add(const Duration(days: 3))),
      (tr('Через неделю', 'Bir haftadan keyin'), today.add(const Duration(days: 7))),
    ];
    final place = widget.place;
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
              Row(children: [
                const Icon(Icons.location_on_rounded, size: 18, color: AppColors.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    place != null
                        ? tr('Обновляем отметку: ${'${place['name'] ?? ''}'.trim().isEmpty ? resultLabel('${place['result']}') : place['name']}',
                            'Belgini yangilaymiz: ${'${place['name'] ?? ''}'.trim().isEmpty ? resultLabel('${place['result']}') : place['name']}')
                        : tr('Отметка — там, где вы стоите${widget.point.accuracy != null ? ' · точность ${widget.point.accuracy!.round()} м' : ''}',
                            'Belgi — siz turgan joyda${widget.point.accuracy != null ? ' · aniqlik ${widget.point.accuracy!.round()} m' : ''}'),
                    style: AppText.small,
                  ),
                ),
              ]),
              if (_photoShown) ...[
                _label(_photoRequired
                    ? tr('Фото витрины * — чтобы другой продажник узнал магазин', 'Vitrina surati * — boshqa agent doʻkonni tanishi uchun')
                    : tr('Фото витрины', 'Vitrina surati')),
                _photoField(),
              ],
              _label(_result == 'lead' ? tr('Название магазина *', 'Doʻkon nomi *') : tr('Название (если видно)', 'Nomi (koʻrinsa)')),
              TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: InputDecoration(hintText: tr('например, Oila Market', 'masalan, Oila Market'))),
              if (_result == 'lead') ...[
                _label(tr('Имя владельца *', 'Egasining ismi *')),
                TextField(controller: _owner, textCapitalization: TextCapitalization.words, decoration: InputDecoration(hintText: tr('например, Азиз Каримов', 'masalan, Aziz Karimov'))),
                _label(tr('Телефон владельца *', 'Egasining telefoni *')),
                PhoneField(controller: _phone),
                _label(tr('Адрес', 'Manzil')),
                TextField(controller: _address, decoration: InputDecoration(hintText: tr('улица, дом, ориентир', 'koʻcha, uy, moʻljal'))),
                const SizedBox(height: 14),
                _loginCard(),
                const SizedBox(height: 10),
                Text(
                  tr('Магазин сразу появится в Super Market с пробным периодом и закрепится за вами. Супер-админ получит уведомление.',
                      'Doʻkon darhol Super Market’da sinov davri bilan paydo boʻladi va sizga biriktiriladi. Super-admin xabar oladi.'),
                  style: AppText.small.copyWith(fontSize: 12),
                ),
              ],
              if (_result == 'refused') ...[
                _label(tr('Причина *', 'Sabab *')),
                Wrap(children: [
                  for (final r in refuseReasons) _chip(reasonLabel(r), _reason == r, () => setState(() => _reason = r)),
                ]),
                if (_reason == 'has_program') ...[
                  _label(tr('Какая программа?', 'Qaysi dastur?')),
                  Wrap(children: [
                    for (final p in programs) _chip(programLabel(p), _program == p, () => setState(() => _program = _program == p ? '' : p)),
                  ]),
                ],
              ],
              if (_result == 'later') ...[
                _label(tr('Когда прийти *', 'Qachon kelish *')),
                Wrap(children: [
                  for (final (label, day) in quick) _chip(label, _remind != null && _remind!.isAtSameMomentAs(day), () => setState(() => _remind = day)),
                  _chip(
                    _remind != null && !quick.any((q) => q.$2.isAtSameMomentAs(_remind!)) ? shortDate(_remind) : tr('Выбрать день', 'Kunni tanlash'),
                    _remind != null && !quick.any((q) => q.$2.isAtSameMomentAs(_remind!)),
                    _pickDate,
                  ),
                ]),
                Text(tr('В этот день магазин будет в «Сегодня прийти» на главной', 'Shu kuni doʻkon bosh sahifadagi «Bugun kelish» roʻyxatida boʻladi'), style: AppText.small),
              ],
              _label(tr('Комментарий', 'Izoh')),
              TextField(
                controller: _comment,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(hintText: tr('например, платят BILLZ до марта', 'masalan, martgacha BILLZ toʻlagan')),
              ),
              if (_result != 'lead') ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.public_rounded, size: 18, color: AppColors.text2),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tr('Отметка видна всем продажникам и остаётся на карте навсегда. Прийти снова можно — история визитов сохранится.',
                            'Belgi barcha agentlarga koʻrinadi va xaritada doim qoladi. Qayta kelish mumkin — tashriflar tarixi saqlanadi.'),
                        style: AppText.small,
                      ),
                    ),
                  ]),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: AppText.small.copyWith(color: AppColors.error, fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: BigButton(
              label: switch (_result) {
                'lead' => tr('Подключить и выдать логин', 'Ulash va login berish'),
                'refused' => tr('Сохранить отказ', 'Rad etishni saqlash'),
                _ => tr('Сохранить', 'Saqlash'),
              },
              icon: _result == 'lead' ? Icons.vpn_key_rounded : Icons.check_rounded,
              busy: _busy,
              onPressed: _uploading ? null : _save,
            ),
          ),
        ]),
      ),
    );
  }
}
