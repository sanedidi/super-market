import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Курьеры «по пути»: проверка личности нового курьера и бонусы магазина.
/// Документ не фотографируется и не хранится — только отметки и последние 4 цифры.
class CrowdScreen extends StatefulWidget {
  const CrowdScreen({super.key});

  @override
  State<CrowdScreen> createState() => _CrowdScreenState();
}

class _CrowdScreenState extends State<CrowdScreen> {
  final _code = TextEditingController();
  Map<String, dynamic>? _bonuses;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    try {
      final b = await context.read<Api>().get('/store/crowd/bonuses', {'store_id': st.storeId}) as Map<String, dynamic>;
      if (mounted) setState(() => _bonuses = b);
    } catch (_) {
      // бонусы — вспомогательный блок
    }
  }

  Future<void> _lookup() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() => _busy = true);
    final api = context.read<Api>();
    try {
      final card = await api.post('/store/crowd/lookup', {'code': code}) as Map<String, dynamic>;
      if (!mounted) return;
      final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _VerifyScreen(card: card)));
      if (done == true) {
        _code.clear();
        await _load();
      }
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bonuses;
    final items = ((b?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Курьеры по пути', 'Yoʻlakay kuryerlar'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Проверить нового курьера', 'Yangi kuryerni tekshirish'), style: AppText.title),
              const SizedBox(height: 4),
              Text(tr('Попросите показать код в приложении курьера (KR-12345) и документ с фото.', 'Kuryer ilovasidagi kodni (KR-12345) va rasmli hujjatni koʻrsatishini soʻrang.'), style: AppText.small),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                style: AppText.h3,
                decoration: const InputDecoration(hintText: 'KR-12345', prefixIcon: Icon(Icons.badge_outlined)),
                onSubmitted: (_) => _lookup(),
              ),
              const SizedBox(height: 12),
              BigButton(label: tr('Найти курьера', 'Kuryerni topish'), icon: Icons.search_rounded, busy: _busy, height: 48, onPressed: _lookup),
            ]),
          ),
          if (b != null) ...[
            const SizedBox(height: 20),
            Text(tr('Бонусы магазину', 'Doʻkon uchun bonuslar'), style: AppText.h3),
            const SizedBox(height: 4),
            Text(
              tr('За каждую из первых ${b['max_deliveries']} доставок проверенного вами курьера — ${money(b['per_delivery'])}.',
                  'Siz tekshirgan kuryerning dastlabki ${b['max_deliveries']} ta yetkazishining har biri uchun — ${money(b['per_delivery'])}.'),
              style: AppText.small,
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _Kpi(tr('Начислено за месяц', 'Oy davomida hisoblandi'), money(b['credited_month']))),
              const SizedBox(width: 8),
              Expanded(child: _Kpi(tr('Ожидается', 'Kutilmoqda'), money(b['pending']))),
              const SizedBox(width: 8),
              Expanded(child: _Kpi(tr('Проверено', 'Tekshirilgan'), '${b['verified'] ?? 0}')),
            ]),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 10),
              AppCard(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(children: [
                  for (final c in items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${c['name']} · ${c['code']}', style: AppText.bodyStrong),
                            Text(tr('Доставок засчитано: ${c['deliveries']} из ${b['max_deliveries']}', 'Hisobga olingan yetkazishlar: ${c['deliveries']} / ${b['max_deliveries']}'), style: AppText.small),
                          ]),
                        ),
                        Text(money(c['credited']), style: AppText.bodyStrong),
                      ]),
                    ),
                ]),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.small.copyWith(fontSize: 12)),
        Text(value, style: AppText.bodyStrong),
      ]),
    );
  }
}

/// Карточка курьера и проверка документа.
class _VerifyScreen extends StatefulWidget {
  const _VerifyScreen({required this.card});

  final Map<String, dynamic> card;

  @override
  State<_VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<_VerifyScreen> {
  late final _name = TextEditingController(text: '${widget.card['full_name'] ?? ''}');
  final _birth = TextEditingController();
  final _last4 = TextEditingController();
  final _reason = TextEditingController();
  String _docType = 'passport';
  bool _photoMatch = false;
  bool _docValid = false;
  String? _busy;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _birth.dispose();
    _last4.dispose();
    _reason.dispose();
    super.dispose();
  }

  /// «15.03.1998» → «1998-03-15».
  String? _birthIso() {
    final m = RegExp(r'^(\d{2})\.(\d{2})\.(\d{4})$').firstMatch(_birth.text.trim());
    if (m == null) return null;
    return '${m[3]}-${m[2]}-${m[1]}';
  }

  Future<void> _send(String decision) async {
    final approve = decision == 'approve';
    String? err;
    if (approve) {
      if (_name.text.trim().split(RegExp(r'\s+')).length < 2) {
        err = tr('ФИО как в документе', 'F.I.Sh. hujjatdagidek');
      } else if (_birthIso() == null) {
        err = tr('Дата рождения в виде ДД.ММ.ГГГГ', 'Tugʻilgan sana KK.OO.YYYY koʻrinishida');
      } else if (!RegExp(r'^\d{4}$').hasMatch(_last4.text.trim())) {
        err = tr('Последние 4 цифры номера документа', 'Hujjat raqamining oxirgi 4 ta raqami');
      } else if (!_photoMatch || !_docValid) {
        err = tr('Отметьте, что фото совпадает и документ действителен', 'Rasm mos kelishi va hujjat amal qilishini belgilang');
      }
    } else if (_reason.text.trim().isEmpty) {
      err = tr('Укажите причину отказа', 'Rad etish sababini koʻrsating');
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = decision;
      _error = null;
    });
    final api = context.read<Api>();
    final storeId = context.read<StoreState>().storeId;
    try {
      await api.post('/store/crowd/verify', {
        'code': widget.card['code'],
        'store_id': storeId,
        'decision': decision,
        'doc_type': _docType,
        'full_name': _name.text.trim(),
        'birth_date': _birthIso() ?? '',
        'doc_last4': _last4.text.trim(),
        'photo_match': _photoMatch,
        'doc_valid': _docValid,
        'reason': _reason.text.trim(),
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(approve ? tr('Курьер подтверждён — ему начнут приходить заказы', 'Kuryer tasdiqlandi — unga buyurtmalar kela boshlaydi') : tr('Отказ сохранён', 'Rad etish saqlandi'))));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.card;
    final status = c['status'] as String? ?? '';
    final checkable = status == 'unverified';
    return Scaffold(
      appBar: AppBar(title: Text('${c['code']}')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        AppCard(
          child: Row(children: [
            const IconBox(Icons.directions_walk_rounded, bg: AppColors.blueSoft, fg: AppColors.blue, size: 52, radius: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${c['full_name'] ?? ''}'.isEmpty ? tr('Без имени', 'Ismsiz') : '${c['full_name']}', style: AppText.bodyStrong.copyWith(fontSize: 16)),
                Text(tr('${formatPhone(c['phone'])} · ${c['level'] ?? ''} · доставок ${c['delivered'] ?? 0}', '${formatPhone(c['phone'])} · ${c['level'] ?? ''} · ${c['delivered'] ?? 0} ta yetkazish'), style: AppText.small),
              ]),
            ),
            StatusChip(
              switch (status) { 'active' => tr('Подтверждён', 'Tasdiqlangan'), 'blocked' => tr('Заблокирован', 'Bloklangan'), _ => tr('Не проверен', 'Tekshirilmagan') },
              tone: switch (status) { 'active' => ChipTone.green, 'blocked' => ChipTone.red, _ => ChipTone.amber },
            ),
          ]),
        ),
        if (!checkable) ...[
          const SizedBox(height: 16),
          SectionCard(children: [
            Text(
              status == 'active'
                  ? tr('Личность уже подтверждена${c['verified_store'] != null ? ' в магазине «${c['verified_store']}»' : ''}${c['verified_at'] != null ? ' ${dateTime(c['verified_at'])}' : ''}.',
                      'Shaxs allaqachon tasdiqlangan${c['verified_store'] != null ? ' — «${c['verified_store']}» doʻkonida' : ''}${c['verified_at'] != null ? ', ${dateTime(c['verified_at'])}' : ''}.')
                  : tr('Курьер заблокирован платформой — проверка недоступна.', 'Kuryer platforma tomonidan bloklangan — tekshirish imkonsiz.'),
              style: AppText.body,
            ),
          ]),
        ] else ...[
          const SizedBox(height: 16),
          Text(tr('ДОКУМЕНТ', 'HUJJAT'), style: AppText.caption),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final (v, t) in [('passport', tr('Паспорт', 'Pasport')), ('id_card', tr('ID-карта', 'ID-karta'))])
              ChoiceChip(
                label: Text(t),
                selected: _docType == v,
                showCheckmark: false,
                selectedColor: AppColors.primarySoft,
                labelStyle: AppText.bodyStrong.copyWith(color: _docType == v ? AppColors.primary : AppColors.ink),
                onSelected: (_) => setState(() => _docType = v),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _name, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(labelText: tr('ФИО как в документе', 'F.I.Sh. hujjatdagidek'))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _birth,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(labelText: tr('Дата рождения', 'Tugʻilgan sana'), hintText: tr('ДД.ММ.ГГГГ', 'KK.OO.YYYY')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _last4,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: InputDecoration(labelText: tr('Посл. 4 цифры', 'Oxirgi 4 raqam'), counterText: ''),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _photoMatch,
            onChanged: (v) => setState(() => _photoMatch = v ?? false),
            title: Text(tr('Фото в документе совпадает с человеком', 'Hujjatdagi rasm shu odamga mos keladi'), style: AppText.body),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _docValid,
            onChanged: (v) => setState(() => _docValid = v ?? false),
            title: Text(tr('Документ действителен, возраст от 18 лет', 'Hujjat amal qiladi, yoshi 18 va undan katta'), style: AppText.body),
          ),
          const SizedBox(height: 4),
          Text(tr('Документ не фотографируется и не хранится.', 'Hujjat suratga olinmaydi va saqlanmaydi.'), style: AppText.small),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
          ],
          const SizedBox(height: 16),
          BigButton(label: tr('Подтвердить курьера', 'Kuryerni tasdiqlash'), icon: Icons.verified_user_rounded, busy: _busy == 'approve', onPressed: _busy == null ? () => _send('approve') : null),
          const SizedBox(height: 20),
          TextField(controller: _reason, decoration: InputDecoration(labelText: tr('Причина отказа (если не подходит)', 'Rad etish sababi (mos kelmasa)'))),
          const SizedBox(height: 10),
          BigButton(
            label: tr('Отказать', 'Rad etish'),
            color: AppColors.primarySoft,
            foreground: AppColors.primary,
            busy: _busy == 'reject',
            onPressed: _busy == null ? () => _send('reject') : null,
          ),
        ],
      ]),
    );
  }
}
