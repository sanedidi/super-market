// Первая настройка магазина (Figma «SM Магазин · первая настройка», С0–С7).
// Пока в сети нет магазина с точкой на карте и часами работы, после входа
// открывается только мастер; доставку можно пропустить — тогда на главной
// чек-лист. Прогресс общий с веб-панелью.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/pin_screens.dart';
import '../push.dart';
import '../start/start_screen.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'setup_logic.dart';
import 'setup_map.dart';

class SetupApi {
  SetupApi(this.api);

  final Api api;

  Future<SetupState> get([String? storeId]) async =>
      SetupState(await api.get('/store/setup', storeId == null ? null : {'store_id': storeId}) as Map<String, dynamic>);

  Future<SetupState> store(Map<String, dynamic> body) async => SetupState(await api.post('/store/setup/store', body) as Map<String, dynamic>);

  Future<SetupState> hours(String storeId, List<WorkingHours> hours) async => SetupState(
      await api.put('/store/setup/hours', {'store_id': storeId, 'working_hours': hours.map((h) => h.toJson()).toList()}) as Map<String, dynamic>);

  Future<SetupState> delivery(Map<String, dynamic> body) async => SetupState(await api.put('/store/setup/delivery', body) as Map<String, dynamic>);
}

// ------------------------------------------------------------------ мастер

/// Мастер: 0 — приветствие, 1–3 — шаги, 4 — готово.
/// [required] — первый вход (мастер вместо приложения); иначе открыт с главной на шаге [startStep].
class SetupFlow extends StatefulWidget {
  const SetupFlow({super.key, required this.initial, this.required = false, this.startStep});

  final SetupState initial;
  final bool required;
  final int? startStep;

  @override
  State<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends State<SetupFlow> {
  late SetupState _s = widget.initial;
  // Правка с экрана «Готово» — после сохранения шага вернуться на него.
  bool _fromDone = false;
  bool _finishing = false;
  late int _step = widget.startStep ?? (widget.required && !widget.initial.storeDone ? 0 : widget.initial.firstStep);
  // Назад дальше этого шага нельзя: первый вход — до приветствия или шага 1, с главной — до открытого шага.
  late final int _first = widget.required ? (_step == 0 ? 0 : 1) : _step;

  void _go(int step) => setState(() => _step = step);

  /// Шаг сохранён. С главной: следующий шаг уже пройден — возвращаемся.
  void _saved(SetupState s, int next) {
    _s = s;
    if (widget.required && _fromDone) {
      _go(4);
      return;
    }
    final nextDone = next == 2 ? s.hoursDone : (next == 3 ? s.deliveryDone : true);
    if (!widget.required && nextDone) {
      Navigator.of(context).pop(true);
      return;
    }
    _go(next);
  }

  Future<void> _finish({bool openStart = false}) async {
    if (!widget.required) {
      Navigator.of(context).pop(true);
      return;
    }
    if (_finishing) return;
    setState(() => _finishing = true);
    // Мастер пройден: StoreState перечитает магазины, и вместо мастера откроется приложение.
    final st = context.read<StoreState>();
    await st.load();
    if (mounted) setState(() => _finishing = false);
    if (openStart && st.error == null && st.storeId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => const StartScreen()));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final back = _step > _first && _step < 4 ? () => _go(_step - 1) : (widget.required ? null : () => Navigator.of(context).pop());
    return PopScope(
      canPop: !widget.required ? _step <= _first : false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > _first && _step < 4) _go(_step - 1);
      },
      child: switch (_step) {
        0 => _Welcome(networkName: context.read<StoreState>().networkName, onStart: () => _go(1), onSignOut: () => signOut(context)),
        1 => _StoreStep(s: _s, onBack: back, onSaved: (s) => _saved(s, 2)),
        2 => _HoursStep(s: _s, onBack: back, onSaved: (s) => _saved(s, 3)),
        3 => _DeliveryStep(
            s: _s,
            onBack: back,
            onSaved: (s) {
              _s = s;
              widget.required ? _go(4) : _finish();
            },
            onSkip: () {
              _finish();
            },
          ),
        _ => _Done(
            s: _s,
            busy: _finishing,
            onEdit: (step) {
              _fromDone = true;
              _go(step);
            },
            onStart: () => _finish(openStart: true),
            onHome: _finish,
          ),
      },
    );
  }
}

// ------------------------------------------------------------------ каркас шага

class _StepPage extends StatelessWidget {
  const _StepPage({required this.title, required this.sub, this.step, this.label, this.onBack, required this.children, required this.bottom});

  final String title;
  final String sub;
  final int? step;
  final String? label;
  final VoidCallback? onBack;
  final List<Widget> children;
  final List<Widget> bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              Row(children: [
                if (onBack != null) ...[RoundIcon(icon: Icons.arrow_back_rounded, color: AppColors.white, onTap: onBack), const SizedBox(width: 12)],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: AppText.h3),
                    Text(sub, style: AppText.small),
                  ]),
                ),
              ]),
              if (step != null) ...[const SizedBox(height: 16), _Stepper(step: step!, label: label ?? '')],
              const SizedBox(height: 16),
              ...children,
            ]),
          ),
          _Bottom(children: bottom),
        ]),
      ),
    );
  }
}

class _Bottom extends StatelessWidget {
  const _Bottom({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bg,
      padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.step, required this.label});

  final int step;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(TextSpan(children: [
        TextSpan(text: tr('Шаг $step из 3', '$step-qadam, jami 3 ta'), style: AppText.small.copyWith(color: AppColors.primary, fontWeight: FontWeight.w600)),
        TextSpan(text: ' · $label', style: AppText.small),
      ])),
      const SizedBox(height: 8),
      Row(children: [
        for (var i = 1; i <= 3; i++) ...[
          if (i > 1) const SizedBox(width: 6),
          Expanded(
            child: Container(height: 4, decoration: BoxDecoration(color: i <= step ? AppColors.primary : AppColors.line, borderRadius: BorderRadius.circular(2))),
          ),
        ],
      ]),
    ]);
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text, style: AppText.small.copyWith(fontWeight: FontWeight.w500)));
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.ink : AppColors.white,
      shape: StadiumBorder(side: selected ? BorderSide.none : const BorderSide(color: AppColors.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(label, style: AppText.bodyStrong.copyWith(fontSize: 14, color: selected ? AppColors.white : AppColors.ink)),
        ),
      ),
    );
  }
}

Widget _tag(String text, {bool required = true}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: required ? AppColors.primarySoft : AppColors.soft, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: AppText.caption.copyWith(color: required ? AppColors.primary : AppColors.text2)),
    );

// ------------------------------------------------------------------ С0

class _Welcome extends StatelessWidget {
  const _Welcome({required this.networkName, required this.onStart, required this.onSignOut});

  final String networkName;
  final VoidCallback onStart;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    Widget row(int n, String title, String text, bool required) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: n == 1 ? AppColors.primary : AppColors.bg, shape: BoxShape.circle),
              child: Text('$n', style: AppText.bodyStrong.copyWith(color: n == 1 ? AppColors.white : AppColors.ink)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: AppText.bodyStrong.copyWith(fontSize: 16)),
                Text(text, style: AppText.small),
              ]),
            ),
            const SizedBox(width: 8),
            _tag(required ? tr('обязательно', 'majburiy') : tr('можно позже', 'keyinroq ham mumkin'), required: required),
          ]),
        );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 32, 16, 24), children: [
              const Center(child: IconBox(Icons.storefront_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 88, iconSize: 44, radius: 44)),
              const SizedBox(height: 16),
              Text(tr('Добро пожаловать в Super Market!', 'Super Marketga xush kelibsiz!'), style: AppText.h2, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(tr('Настроим магазин за 3 шага — после этого покупатели увидят его в приложении.', 'Doʻkonni 3 qadamda sozlaymiz — shundan soʻng xaridorlar uni ilovada koʻradi.'),
                  style: AppText.body.copyWith(color: AppColors.text2), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              AppCard(
                padding: const EdgeInsets.all(4),
                child: Column(children: [
                  row(1, tr('Магазин и адрес', 'Doʻkon va manzil'), tr('Название, телефон и точка на карте', 'Nomi, telefon va xaritadagi nuqta'), true),
                  const Divider(height: 1, color: AppColors.line),
                  row(2, tr('Часы работы', 'Ish vaqti'), tr('Покупатели увидят «открыто» или «закрыто»', 'Xaridorlar «ochiq» yoki «yopiq» ekanini koʻradi'), true),
                  const Divider(height: 1, color: AppColors.line),
                  row(3, tr('Доставка', 'Yetkazib berish'), tr('Радиус, цена и за сколько привезёте', 'Radius, narx va qancha vaqtda yetkazasiz'), false),
                ]),
              ),
              const SizedBox(height: 16),
              Row(children: [
                const Icon(Icons.devices_rounded, size: 20, color: AppColors.text2),
                const SizedBox(width: 10),
                Expanded(child: Text(tr('Около 3 минут. Начали здесь — можно закончить в веб-панели, всё сохранится.', 'Taxminan 3 daqiqa. Shu yerda boshlab, veb-panelda tugatish mumkin — hammasi saqlanadi.'), style: AppText.small)),
              ]),
            ]),
          ),
          _Bottom(children: [
            BigButton(label: tr('Начать настройку', 'Sozlashni boshlash'), onPressed: onStart),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Flexible(child: Text(networkName.isEmpty ? tr('Вы — владелец', 'Siz — egasisiz') : tr('Сеть «$networkName»', '«$networkName» tarmogʻi'), style: AppText.small, overflow: TextOverflow.ellipsis)),
              TextButton(onPressed: onSignOut, child: Text(tr('Выйти', 'Chiqish'), style: AppText.small.copyWith(fontWeight: FontWeight.w600, color: AppColors.primary))),
            ]),
          ]),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ С1

class _StoreStep extends StatefulWidget {
  const _StoreStep({required this.s, required this.onBack, required this.onSaved});

  final SetupState s;
  final VoidCallback? onBack;
  final ValueChanged<SetupState> onSaved;

  @override
  State<_StoreStep> createState() => _StoreStepState();
}

class _StoreStepState extends State<_StoreStep> {
  late final _name = TextEditingController(text: widget.s.storeName.isNotEmpty ? widget.s.storeName : context.read<StoreState>().networkName);
  late final _phone = TextEditingController(text: formatUzLocal(widget.s.phone));
  late final _address = TextEditingController(text: widget.s.address);
  late LatLng? _point = widget.s.lat == null ? null : LatLng(widget.s.lat!, widget.s.lng!);
  String? _city;
  String? _phoneError;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    FocusScope.of(context).unfocus();
    final r = await Navigator.of(context).push<PickedPoint>(MaterialPageRoute(builder: (_) => MapPickerScreen(initial: _point, address: _address.text)));
    if (r == null || !mounted) return;
    setState(() {
      _point = r.point;
      if (_address.text.trim().isEmpty && r.address != null) _address.text = r.address!;
    });
    cityAt(r.point).then((c) => _city = c);
  }

  Future<void> _save() async {
    final phoneDigits = uzLocalDigits(_phone.text);
    final phone = phoneDigits.isEmpty ? '' : normalizeUzPhone(_phone.text);
    setState(() => _phoneError = phone == null ? tr('Номер из 9 цифр: 90 123 45 67', '9 xonali raqam: 90 123 45 67') : null);
    if (phone == null) return;
    if (_name.text.trim().isEmpty) {
      showSnack(context, tr('Укажите название магазина', 'Doʻkon nomini kiriting'));
      return;
    }
    if (_address.text.trim().isEmpty) {
      showSnack(context, tr('Укажите адрес', 'Manzilni kiriting'));
      return;
    }
    if (_point == null) {
      showSnack(context, tr('Поставьте метку на вход в магазин', 'Doʻkon kirish joyiga belgi qoʻying'));
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await SetupApi(context.read<Api>()).store({
        if (widget.s.storeId != null) 'store_id': widget.s.storeId,
        'name': _name.text.trim(),
        'phone': phone,
        'address': _address.text.trim(),
        'lat': _point!.latitude,
        'lng': _point!.longitude,
        if (_city != null) 'city': _city,
      });
      if (mounted) widget.onSaved(s);
    } catch (e) {
      if (mounted) showSnack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _StepPage(
      title: tr('Ваш магазин', 'Doʻkoningiz'),
      sub: tr('Так его увидят покупатели', 'Xaridorlar uni shunday koʻradi'),
      step: 1,
      label: tr('Магазин', 'Doʻkon'),
      onBack: widget.onBack,
      bottom: [BigButton(label: tr('Дальше', 'Keyingi'), busy: _busy, onPressed: _save)],
      children: [
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Label(tr('Название магазина', 'Doʻkon nomi')),
            TextField(controller: _name, textCapitalization: TextCapitalization.sentences, maxLength: 120, decoration: const InputDecoration(counterText: '')),
            const SizedBox(height: 14),
            _Label(tr('Телефон магазина', 'Doʻkon telefoni')),
            PhoneField(controller: _phone, errorText: _phoneError),
            const SizedBox(height: 6),
            Text(tr('Покупатели и курьеры смогут позвонить в магазин', 'Xaridorlar va kuryerlar doʻkonga qoʻngʻiroq qila oladi'), style: AppText.small),
          ]),
        ),
        const SizedBox(height: 16),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Label(tr('Адрес', 'Manzil')),
            TextField(
              controller: _address,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(hintText: tr('Чиланзар, 9-й квартал, 12', 'Chilonzor, 9-mavze, 12'), prefixIcon: const Icon(Icons.search_rounded, color: AppColors.muted)),
            ),
            const SizedBox(height: 12),
            if (_point != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _pick,
                child: MapPreview(
                  point: _point!,
                  overlay: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 8, offset: Offset(0, 2))],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.open_in_full_rounded, size: 16),
                      const SizedBox(width: 6),
                      Text(tr('Уточнить на карте', 'Xaritada aniqlashtirish'), style: AppText.bodyStrong.copyWith(fontSize: 14)),
                    ]),
                  ),
                ),
              )
            else
              Material(
                color: AppColors.soft,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _pick,
                  child: SizedBox(
                    height: 150,
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.add_location_alt_rounded, size: 36, color: AppColors.primary),
                        const SizedBox(height: 8),
                        Text(tr('Поставить метку на карте', 'Xaritada belgi qoʻyish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                      ]),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(_point == null ? Icons.info_outline_rounded : Icons.check_circle_rounded, size: 18, color: _point == null ? AppColors.text2 : AppColors.success),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('Метка на входе в магазин — по ней покупатели найдут вас, а курьер подъедет к двери', 'Belgi — doʻkon kirish joyida: xaridorlar sizni shu boʻyicha topadi, kuryer esa eshik oldiga keladi'), style: AppText.small)),
            ]),
          ]),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ С3

class _HoursStep extends StatefulWidget {
  const _HoursStep({required this.s, required this.onBack, required this.onSaved});

  final SetupState s;
  final VoidCallback? onBack;
  final ValueChanged<SetupState> onSaved;

  @override
  State<_HoursStep> createState() => _HoursStepState();
}

class _HoursStepState extends State<_HoursStep> {
  late HoursPreset _preset;
  late List<DayHours> _days;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final init = initHours(widget.s);
    _preset = init.$1;
    _days = init.$2;
  }

  void _choose(HoursPreset p) => setState(() {
        _preset = p;
        _days = applyPreset(p, _days);
      });

  void _edit(int w, DayHours d) => setState(() {
        _days = [for (var i = 0; i < 7; i++) i == w ? d : _days[i]];
        _preset = HoursPreset.custom;
      });

  Future<String?> _time(String help, String v) async {
    final p = v.split(':');
    final t = await showTimePicker(
      context: context,
      helpText: help,
      initialTime: TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1])),
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t == null) return null;
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDay(int w) async {
    final o = await _time(tr('${dayNames[w]} — открытие', '${dayNames[w]} — ochilish'), _days[w].opens);
    if (o == null || !mounted) return;
    final c = await _time(tr('${dayNames[w]} — закрытие', '${dayNames[w]} — yopilish'), _days[w].closes);
    if (c == null || !mounted) return;
    _edit(w, _days[w].copyWith(opens: o, closes: c));
  }

  Future<void> _save() async {
    final err = hoursError(_preset, _days);
    if (err != null) {
      showSnack(context, err);
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await SetupApi(context.read<Api>()).hours(widget.s.storeId!, hoursToSave(_preset, _days));
      if (mounted) widget.onSaved(s);
    } catch (e) {
      if (mounted) showSnack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _StepPage(
      title: tr('Часы работы', 'Ish vaqti'),
      sub: tr('Когда магазин открыт для покупателей', 'Doʻkon xaridorlar uchun qachon ochiq'),
      step: 2,
      label: tr('Часы работы', 'Ish vaqti'),
      onBack: widget.onBack,
      bottom: [BigButton(label: tr('Дальше', 'Keyingi'), busy: _busy, onPressed: _save)],
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (p, l) in [
            (HoursPreset.daily, tr('Каждый день', 'Har kuni')),
            (HoursPreset.monSat, tr('Пн–Сб', 'Du–Sh')),
            (HoursPreset.round, tr('Круглосуточно', 'Kecha-kunduz')),
            (HoursPreset.custom, tr('По дням', 'Kunlar boʻyicha')),
          ])
            _Pill(l, selected: _preset == p, onTap: () => _choose(p)),
        ]),
        const SizedBox(height: 16),
        if (_preset == HoursPreset.round)
          AppCard(
            child: Row(children: [
              const IconBox(Icons.all_inclusive_rounded, bg: AppColors.successSoft, fg: AppColors.successInk),
              const SizedBox(width: 12),
              Expanded(child: Text(tr('Магазин работает 24 часа без выходных — покупатели всегда видят «открыто»', 'Doʻkon dam olish kunlarisiz 24 soat ishlaydi — xaridorlar doim «ochiq»ni koʻradi'), style: AppText.body)),
            ]),
          )
        else ...[
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(children: [
              for (final w in week)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(children: [
                    Switch(
                      value: _days[w].on,
                      activeTrackColor: AppColors.success,
                      thumbColor: const WidgetStatePropertyAll(AppColors.white),
                      onChanged: (v) => _edit(w, _days[w].copyWith(on: v)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(dayNames[w], style: AppText.bodyStrong.copyWith(color: _days[w].on ? AppColors.ink : AppColors.text2))),
                    if (_days[w].on)
                      Material(
                        color: AppColors.bg,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _pickDay(w),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                            child: Row(children: [
                              Text('${_days[w].opens} – ${_days[w].closes}', style: AppText.bodyStrong),
                              const Icon(Icons.expand_more_rounded, size: 18, color: AppColors.text2),
                            ]),
                          ),
                        ),
                      )
                    else
                      Text(tr('Выходной', 'Dam olish'), style: AppText.small),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _days = List.generate(7, (_) => _days[1]);
                _preset = presetOf(_days);
              }),
              icon: const Icon(Icons.content_copy_rounded, size: 18, color: AppColors.primary),
              label: Text(tr('Скопировать понедельник на все дни', 'Dushanbani barcha kunlarga nusxalash'), style: AppText.bodyStrong.copyWith(color: AppColors.primary, fontSize: 14)),
            ),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.nightlight_round, size: 18, color: AppColors.text2),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('Работаете после полуночи? Укажите, например, 08:00 – 02:00', 'Yarim tundan keyin ishlaysizmi? Masalan, 08:00 – 02:00 deb koʻrsating'), style: AppText.small)),
          ]),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ С4

/// Сумма с пробелами: «150 000».
class _MoneyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final d = newValue.text.replaceAll(RegExp(r'\D'), '');
    final t = d.isEmpty ? '' : spacedMoney(d);
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }
}

class _DeliveryStep extends StatefulWidget {
  const _DeliveryStep({required this.s, required this.onBack, required this.onSaved, required this.onSkip});

  final SetupState s;
  final VoidCallback? onBack;
  final ValueChanged<SetupState> onSaved;
  final VoidCallback onSkip;

  @override
  State<_DeliveryStep> createState() => _DeliveryStepState();
}

class _DeliveryStepState extends State<_DeliveryStep> {
  late bool _deliver = !(widget.s.declined && !widget.s.acceptsOnline);
  late int _radius = widget.s.radiusM > 0 ? widget.s.radiusM : 3000;
  late final _fee = TextEditingController(text: spacedMoney(widget.s.fee ?? '10000'));
  late final _free = TextEditingController(text: spacedMoney(widget.s.freeFrom ?? ''));
  late final _min = TextEditingController(text: spacedMoney(widget.s.minOrder));
  late int _eta = () {
    final i = etas.indexWhere((e) => e.$1 == widget.s.etaMin && e.$2 == widget.s.etaMax);
    return i < 0 ? 1 : i;
  }();
  bool _busy = false;

  @override
  void dispose() {
    _fee.dispose();
    _free.dispose();
    _min.dispose();
    super.dispose();
  }

  String _digits(TextEditingController c) => c.text.replaceAll(RegExp(r'\D'), '');

  Future<void> _otherRadius() async {
    final m = await showDialog<int>(context: context, builder: (_) => _RadiusDialog(initial: _radius));
    if (m != null && mounted) setState(() => _radius = m);
  }

  Future<void> _save() async {
    final st = widget.s.storeId!;
    final Map<String, dynamic> body;
    if (_deliver) {
      if (_digits(_fee).isEmpty) {
        showSnack(context, tr('Укажите стоимость доставки — 0, если бесплатно', 'Yetkazib berish narxini kiriting — bepul boʻlsa, 0'));
        return;
      }
      final e = etas[_eta];
      body = {
        'store_id': st,
        'mode': 'deliver',
        'delivery_radius_m': _radius,
        'fee': _digits(_fee),
        'free_from': _digits(_free).isEmpty ? null : _digits(_free),
        'min_order_amount': _digits(_min).isEmpty ? '0' : _digits(_min),
        'eta_min': e.$1,
        'eta_max': e.$2,
      };
    } else {
      body = {'store_id': st, 'mode': 'none'};
    }
    setState(() => _busy = true);
    try {
      final s = await SetupApi(context.read<Api>()).delivery(body);
      if (mounted) widget.onSaved(s);
    } catch (e) {
      if (mounted) showSnack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _option(bool v, IconData icon, String title, String text) {
    final on = _deliver == v;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        border: on ? AppColors.primary : null,
        onTap: () => setState(() => _deliver = v),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBox(icon, bg: on ? AppColors.primarySoft : AppColors.bg, fg: on ? AppColors.primary : AppColors.text2, size: 40, iconSize: 22, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong.copyWith(fontSize: 16)),
              const SizedBox(height: 3),
              Text(text, style: AppText.small),
            ]),
          ),
          Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: on ? AppColors.primary : AppColors.muted),
        ]),
      ),
    );
  }

  Widget _money(String label, TextEditingController c, {String? hint}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Label(label),
        TextField(
          controller: c,
          keyboardType: TextInputType.number,
          inputFormatters: [LengthLimitingTextInputFormatter(13), _MoneyFormatter()],
          decoration: InputDecoration(hintText: hint, suffixText: tr('сум', 'soʻm')),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return _StepPage(
      title: tr('Доставка', 'Yetkazib berish'),
      sub: tr('Можно настроить позже', 'Keyinroq sozlash mumkin'),
      step: 3,
      label: tr('Доставка', 'Yetkazib berish'),
      onBack: widget.onBack,
      bottom: [
        BigButton(label: tr('Готово', 'Tayyor'), busy: _busy, onPressed: _save),
        if (!s.deliveryDone) TextButton(onPressed: _busy ? null : widget.onSkip, child: Text(tr('Пропустить, настрою позже', 'Oʻtkazib yuborish, keyin sozlayman'), style: AppText.bodyStrong.copyWith(fontSize: 16))),
      ],
      children: [
        _option(true, Icons.delivery_dining_rounded, tr('Доставляем сами', 'Oʻzimiz yetkazamiz'), tr('Своими курьерами или курьерами по пути', 'Oʻz kuryerlarimiz yoki yoʻlakay kuryerlar orqali')),
        _option(false, Icons.storefront_rounded, tr('Пока без доставки', 'Hozircha yetkazib berishsiz'),
            tr('Покупатели увидят магазин и цены, но заказать не смогут. По кнопке «Хочу доставку» вы узнаете, сколько людей её ждут',
                'Xaridorlar doʻkon va narxlarni koʻradi, lekin buyurtma bera olmaydi. «Yetkazishni xohlayman» tugmasi orqali uni qancha odam kutayotganini bilasiz')),
        if (_deliver) ...[
          const SizedBox(height: 4),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Label(tr('Куда доставляем', 'Qayerga yetkazamiz')),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final r in radii) _Pill(radiusLabel(r), selected: _radius == r, onTap: () => setState(() => _radius = r)),
                _Pill(radii.contains(_radius) ? tr('Другое', 'Boshqa') : radiusLabel(_radius), selected: !radii.contains(_radius), onTap: _otherRadius),
              ]),
              if (s.lat != null) ...[const SizedBox(height: 12), MapPreview(point: LatLng(s.lat!, s.lng!), radiusM: _radius, height: 170)],
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: _money(tr('Стоимость доставки', 'Yetkazib berish narxi'), _fee)),
                const SizedBox(width: 10),
                Expanded(child: _money(tr('Бесплатно от', 'Bepul (summadan)'), _free, hint: tr('не нужно', 'shart emas'))),
              ]),
              const SizedBox(height: 14),
              _money(tr('Минимальный заказ', 'Eng kam buyurtma'), _min),
              const SizedBox(height: 6),
              Text(tr('Заказ на меньшую сумму оформить нельзя', 'Bundan kam summaga buyurtma berib boʻlmaydi'), style: AppText.small),
              const SizedBox(height: 14),
              _Label(tr('Привезём за', 'Yetkazish vaqti')),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 0; i < etas.length; i++) _Pill(etaLabel(etas[i]), selected: _eta == i, onTap: () => setState(() => _eta = i)),
              ]),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.text2),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
                  tr('Зоны на карте, цену по расстоянию и доставку ко времени можно настроить потом в веб-панели, раздел «Доставка»',
                      'Xaritadagi hududlar, masofaga qarab narx va belgilangan vaqtga yetkazishni keyinroq veb-panelning «Yetkazib berish» boʻlimida sozlash mumkin'),
                  style: AppText.small)),
        ]),
      ],
    );
  }
}

/// Свой радиус доставки, км.
class _RadiusDialog extends StatefulWidget {
  const _RadiusDialog({required this.initial});

  final int initial;

  @override
  State<_RadiusDialog> createState() => _RadiusDialogState();
}

class _RadiusDialogState extends State<_RadiusDialog> {
  late final _c = TextEditingController(text: radiusInput(widget.initial));
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _done() {
    final m = radiusFromKm(_c.text);
    if (m == null) {
      setState(() => _error = tr('От 0,1 до 100 км', '0,1 dan 100 km gacha'));
      return;
    }
    Navigator.of(context).pop(m);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Радиус доставки', 'Yetkazib berish radiusi')),
      content: TextField(
        controller: _c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onSubmitted: (_) => _done(),
        decoration: InputDecoration(suffixText: tr('км', 'km'), errorText: _error),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Отмена', 'Bekor qilish'))),
        TextButton(onPressed: _done, child: Text(tr('Готово', 'Tayyor'))),
      ],
    );
  }
}

// ------------------------------------------------------------------ С5

class _Done extends StatelessWidget {
  const _Done({required this.s, required this.busy, required this.onEdit, required this.onStart, required this.onHome});

  final SetupState s;
  final bool busy;
  final ValueChanged<int> onEdit;
  final VoidCallback onStart;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    Widget row(int step, IconData icon, String title, String text) => InkWell(
          onTap: () => onEdit(step),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              IconBox(icon, bg: AppColors.bg, size: 40, iconSize: 22, radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppText.bodyStrong),
                  Text(text, style: AppText.small),
                ]),
              ),
              const Icon(Icons.edit_rounded, size: 18, color: AppColors.muted),
            ]),
          ),
        );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 24, 16, 24), children: [
              const Center(child: IconBox(Icons.check_rounded, bg: AppColors.success, fg: AppColors.white, size: 80, iconSize: 44, radius: 40)),
              const SizedBox(height: 12),
              Text(tr('Магазин настроен!', 'Doʻkon sozlandi!'), style: AppText.h2, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(tr('Покупатели рядом уже видят «${s.storeName}» в приложении Super Market', 'Yaqin atrofdagi xaridorlar «${s.storeName}»ni Super Market ilovasida allaqachon koʻrmoqda'),
                  style: AppText.body.copyWith(color: AppColors.text2), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              AppCard(
                padding: const EdgeInsets.all(4),
                child: Column(children: [
                  row(1, Icons.storefront_rounded, s.storeName, [s.address, if (s.phone.isNotEmpty) formatPhone(s.phone)].join(' · ')),
                  row(2, Icons.schedule_rounded, tr('Часы работы', 'Ish vaqti'), hoursText(s.hours)),
                  row(3, Icons.delivery_dining_rounded, tr('Доставка', 'Yetkazib berish'), deliveryText(s)),
                ]),
              ),
              const SizedBox(height: 16),
              AppCard(
                color: AppColors.primarySoft,
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const IconBox(Icons.rocket_launch_rounded, bg: AppColors.white, fg: AppColors.primary, size: 40, iconSize: 22, radius: 12),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('Следующий шаг — товары', 'Keyingi qadam — mahsulotlar'), style: AppText.bodyStrong),
                      const SizedBox(height: 3),
                      Text(
                          tr('Отметьте, что уже стоит на полках: по фото, штрихкоду или галочками в каталоге. Пока товаров нет, магазин в приложении пустой.',
                              'Javonlarda nima borligini belgilang: rasm, shtrix-kod yoki katalogdagi belgilar orqali. Mahsulotlar boʻlmaguncha, ilovadagi doʻkon boʻsh turadi.'),
                          style: AppText.small),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
          _Bottom(children: [
            BigButton(label: tr('Внести товары', 'Mahsulotlarni kiritish'), icon: Icons.rocket_launch_rounded, busy: busy, onPressed: onStart),
            TextButton(onPressed: busy ? null : onHome, child: Text(tr('На главную', 'Bosh sahifaga'), style: AppText.bodyStrong.copyWith(fontSize: 16))),
          ]),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ С7

/// Сотрудник без права «Магазины»: владелец ещё не прошёл мастер.
class SetupWaitingScreen extends StatelessWidget {
  const SetupWaitingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(children: [
              const IconBox(Icons.hourglass_top_rounded, bg: AppColors.white, fg: AppColors.text2, size: 80, iconSize: 40, radius: 40),
              const SizedBox(height: 16),
              Text(tr('Магазин ещё настраивается', 'Doʻkon hali sozlanmoqda'), style: AppText.h2, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                  tr('Владелец указывает адрес и часы работы. Как только он закончит, здесь появятся заказы, склад и касса.',
                      'Egasi manzil va ish vaqtini kiritmoqda. U tugatishi bilan bu yerda buyurtmalar, ombor va kassa paydo boʻladi.'),
                  style: AppText.body, textAlign: TextAlign.center),
            ]),
          ),
          const Spacer(),
          _Bottom(children: [
            BigButton(label: tr('Обновить', 'Yangilash'), icon: Icons.refresh_rounded, color: AppColors.primarySoft, foreground: AppColors.primary, busy: st.loading, onPressed: st.load),
            TextButton(onPressed: () => signOut(context), child: Text(tr('Выйти', 'Chiqish'), style: AppText.bodyStrong.copyWith(fontSize: 16))),
          ]),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ С6

/// Чек-лист «Настройка магазина · 2 из 3» на главной, пока не пройдены все шаги.
class SetupHomeBlock extends StatefulWidget {
  const SetupHomeBlock({super.key, required this.storeId});

  final String storeId;

  @override
  State<SetupHomeBlock> createState() => _SetupHomeBlockState();
}

class _SetupHomeBlockState extends State<SetupHomeBlock> {
  SetupState? _s;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await SetupApi(context.read<Api>()).get(widget.storeId);
      if (mounted) setState(() => _s = s);
    } catch (_) {
      // блок просто не показывается
    }
  }

  Future<void> _open(int step) async {
    final s = _s!;
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => SetupFlow(initial: s, startStep: step)));
    if (!mounted) return;
    _load();
    // Название или адрес могли поменяться — шапка главной берёт их из списка магазинов.
    if (step == 1) context.read<StoreState>().load();
  }

  Future<void> _noDelivery() async {
    setState(() => _busy = true);
    try {
      final s = await SetupApi(context.read<Api>()).delivery({'store_id': widget.storeId, 'mode': 'none'});
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) showSnack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null || !s.showChecklist) return const SizedBox.shrink();
    Widget done(String title, int step) => InkWell(
          onTap: () => _open(step),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: AppText.body.copyWith(color: AppColors.text2))),
            ]),
          ),
        );
    Widget todo(String title, String text, String action, int step) => Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.radio_button_unchecked_rounded, color: AppColors.muted, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppText.bodyStrong),
                  Text(text, style: AppText.small),
                ]),
              ),
            ]),
            if (step == 3 && s.wishes > 0) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  const Icon(Icons.favorite_rounded, color: AppColors.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr('${buyersWord(s.wishes)} рядом нажали «Хочу доставку»', 'Yaqin atrofdagi ${buyersWord(s.wishes)} «Yetkazishni xohlayman»ni bosdi'), style: AppText.bodyStrong.copyWith(fontSize: 13))),
                ]),
              ),
            ],
            const SizedBox(height: 10),
            BigButton(label: action, height: 44, onPressed: step == 3 && !s.storeDone ? null : () => _open(step)),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(tr('Настройка магазина', 'Doʻkonni sozlash'), style: AppText.title)),
            Text(tr('${s.doneCount} из 3', '${s.doneCount} / 3'), style: AppText.bodyStrong.copyWith(color: AppColors.success)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: Container(height: 6, decoration: BoxDecoration(color: i < s.doneCount ? AppColors.success : AppColors.line, borderRadius: BorderRadius.circular(3))),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          if (s.storeDone)
            done(tr('Магазин и адрес', 'Doʻkon va manzil'), 1)
          else
            todo(tr('Магазин и адрес', 'Doʻkon va manzil'), tr('Поставьте точку на карте — без неё покупатели не найдут магазин', 'Xaritada nuqta qoʻying — busiz xaridorlar doʻkonni topa olmaydi'), tr('Указать', 'Koʻrsatish'), 1),
          if (s.hoursDone)
            done(tr('Часы работы', 'Ish vaqti'), 2)
          else
            todo(tr('Часы работы', 'Ish vaqti'), tr('Укажите, когда магазин открыт', 'Doʻkon qachon ochiqligini koʻrsating'), tr('Указать', 'Koʻrsatish'), 2),
          if (s.deliveryDone)
            done(tr('Доставка', 'Yetkazib berish'), 3)
          else ...[
            todo(
                tr('Доставка', 'Yetkazib berish'),
                s.storeDone && s.hoursDone
                    ? tr('Сейчас покупатели видят «Магазин не доставляет»', 'Hozir xaridorlar «Doʻkon yetkazib bermaydi» yozuvini koʻradi')
                    : tr('Радиус, цена и за сколько привезёте', 'Radius, narx va qancha vaqtda yetkazasiz'),
                tr('Настроить доставку', 'Yetkazib berishni sozlash'),
                3),
            TextButton(
              onPressed: _busy ? null : _noDelivery,
              style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
              child: Text(tr('Пока без доставки — убрать из списка', 'Hozircha yetkazib berishsiz — roʻyxatdan olib tashlash'), style: AppText.small.copyWith(fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      ),
    );
  }
}
