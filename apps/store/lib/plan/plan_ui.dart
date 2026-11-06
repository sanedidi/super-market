import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../control/cashiers_screen.dart' show plural;
import '../finance/balance_screen.dart' show subscriptionReadOnly;
import '../finance/finance_logic.dart' show n;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

// Тариф в «SM Магазин» — как в веб-панели (Figma «Тарифы магазинов», B1–B3):
// все функции видны всегда; если функции нет в тарифе — замок и «нет на
// вашем тарифе», с переходом в «Тариф».
//
// На iOS тариф только для просмотра (Apple 3.1.1): без цен и без смены тарифа.

/// Функции, которые показываем в карточках тарифов.
const _shownFeatures = [
  'debts',
  'invoice_scans',
  'reports_pro',
  'abc_xyz',
  'promotions',
  'crowd',
  'assistant',
  'brand_ads',
  'showcase_custom',
  'showcase_per_store',
];

String _soum(Object? v) => money(v);

/// «12.11.2026» из даты API.
String _day(Object? v) {
  final d = DateTime.tryParse('${v ?? ''}')?.toLocal();
  if (d == null) return '';
  String two(int x) => x.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year}';
}

// ------------------------------------------------------------ проверка

/// Можно ли открыть функцию. Нет в тарифе — шторка «Нет на вашем тарифе» и
/// false; тариф неизвестен — пускаем (сервер сам ответит).
bool planAllows(BuildContext context, String feature) {
  final st = context.read<StoreState>();
  if (st.hasFeature(feature) != false) return true;
  showPlanSheet(context, feature: feature);
  return false;
}

/// Плашка «🔒 Бизнес» у плитки закрытой функции. Пусто, если функция есть.
class PlanLockChip extends StatelessWidget {
  const PlanLockChip(this.feature, {super.key});

  final String feature;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    if (st.hasFeature(feature) != false) return const SizedBox.shrink();
    final need = st.planWith(feature);
    return StatusChip(need ?? tr('нет на тарифе', 'tarifda yoʻq'), icon: Icons.lock_rounded, tone: ChipTone.amber);
  }
}

// ------------------------------------------------- B3 · шторка «Нет на тарифе»

DateTime? _lastSheet;

/// Шторка «Нет на вашем тарифе»: по ошибке сервера [error] или по ключу
/// функции [feature] (когда знаем заранее, что её нет).
Future<void> showPlanSheet(BuildContext context, {ApiError? error, String? feature}) async {
  // Одна ошибка может прийти из нескольких запросов сразу — одна шторка.
  final now = DateTime.now();
  if (_lastSheet != null && now.difference(_lastSheet!) < const Duration(seconds: 2)) return;
  _lastSheet = now;

  final st = context.read<StoreState>();
  final d = error?.details ?? const <String, dynamic>{};
  final key = feature ?? d['feature'] as String?;
  final code = error?.code ?? 'plan_feature';
  final need = (d['need_plan_name'] as String?) ?? (key == null ? null : st.planWith(key));
  final current = (d['plan_name'] as String?) ?? st.planName ?? '';
  final name = (d['feature_name'] as String?) ?? (d['limit_name'] as String?) ?? (key == null ? null : st.featureName(key)) ?? '';

  final String title;
  final String text;
  switch (code) {
    case 'tariff_limit':
      title = tr('Лимит тарифа', 'Tarif limiti');
      text = error?.message ?? '';
    case 'plan_min_stores':
      title = tr('Тариф для сетей побольше', 'Kattaroq tarmoqlar uchun tarif');
      text = error?.message ?? '';
    default:
      title = tr('Нет на вашем тарифе', 'Tarifingizda yoʻq');
      text = name.isEmpty
          ? (error?.message ?? tr('Этой функции нет на вашем тарифе «$current».', 'Bu funksiya «$current» tarifingizda yoʻq.'))
          : tr('«$name» нет на тарифе «$current»${need != null ? ' — доступно на тарифе «$need»' : ''}.',
              '«$name» «$current» tarifida yoʻq${need != null ? ' — «$need» tarifida mavjud' : ''}.');
  }

  await showSheet<void>(context, (ctx) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Align(alignment: Alignment.centerLeft, child: IconBox(Icons.lock_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk)),
      const SizedBox(height: 14),
      Text(title, style: AppText.h3),
      const SizedBox(height: 8),
      Text(text, style: AppText.body.copyWith(color: AppColors.text2)),
      if (code == 'tariff_limit' && d['limit'] != null) ...[
        const SizedBox(height: 8),
        Text('${d['used'] ?? ''} / ${d['limit']}', style: AppText.bodyStrong),
      ],
      const SizedBox(height: 8),
      Text(tr('Данные не удаляются — на другом тарифе всё будет на месте.', 'Maʼlumotlar oʻchmaydi — boshqa tarifda hammasi joyida boʻladi.'), style: AppText.small),
      const SizedBox(height: 20),
      SheetButton(
        label: subscriptionReadOnly || need == null ? tr('Посмотреть тарифы', 'Tariflarni koʻrish') : tr('Перейти на «$need»', '«$need» tarifiga oʻtish'),
        onPressed: () {
          Navigator.of(ctx).pop();
          openPlan(context);
        },
      ),
      const SizedBox(height: 10),
      SheetButton(label: tr('Закрыть', 'Yopish'), primary: false, onPressed: () => Navigator.of(ctx).pop()),
    ]);
  });
}

/// Открыть экран «Тариф».
Future<void> openPlan(BuildContext context) async {
  final st = context.read<StoreState>();
  unawaited(st.loadPlan());
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlanScreen()));
}

// ---------------------------------------------- B2 · экран закрытой функции

/// Вместо содержимого экрана, если функции нет в тарифе.
class PlanLockedView extends StatelessWidget {
  const PlanLockedView({super.key, this.error, this.feature});

  final ApiError? error;
  final String? feature;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final d = error?.details ?? const <String, dynamic>{};
    final key = feature ?? d['feature'] as String?;
    final name = (d['feature_name'] as String?) ?? (key == null ? null : st.featureName(key));
    final current = (d['plan_name'] as String?) ?? st.planName ?? '';
    final need = (d['need_plan_name'] as String?) ?? (key == null ? null : st.planWith(key));
    final title = name == null
        ? tr('Нет на вашем тарифе', 'Tarifingizda yoʻq')
        : tr('«$name» нет на тарифе «$current»', '«$name» «$current» tarifida yoʻq');
    final text = [
      if (need != null) tr('Доступно на тарифе «$need».', '«$need» tarifida mavjud.'),
      tr('Данные не удаляются — на другом тарифе всё будет на месте.', 'Maʼlumotlar oʻchmaydi — boshqa tarifda hammasi joyida boʻladi.'),
    ].join(' ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 88,
          height: 88,
          decoration: const BoxDecoration(color: AppColors.warningSoft, shape: BoxShape.circle),
          child: const Icon(Icons.lock_rounded, size: 40, color: AppColors.warningInk),
        ),
        const SizedBox(height: 16),
        Text(title, style: AppText.h3, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(text, style: AppText.body.copyWith(color: AppColors.text2), textAlign: TextAlign.center),
        const SizedBox(height: 20),
        BigButton(
          label: subscriptionReadOnly || need == null ? tr('Посмотреть тарифы', 'Tariflarni koʻrish') : tr('Перейти на «$need»', '«$need» tarifiga oʻtish'),
          icon: Icons.workspace_premium_rounded,
          height: 48,
          onPressed: () => openPlan(context),
        ),
      ]),
    );
  }
}

/// Компактный замок внутри блока экрана (ABC/XYZ на главной, «Накладные» на
/// складе): «Доступно на тарифе «…»» и что даёт функция. Нажали — шторка.
class PlanLockedBox extends StatelessWidget {
  const PlanLockedBox({super.key, required this.feature, required this.text});

  final String feature;
  final String text;

  @override
  Widget build(BuildContext context) {
    final need = context.watch<StoreState>().planWith(feature);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showPlanSheet(context, feature: feature),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.lock_rounded, size: 26, color: AppColors.warningInk),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(need == null ? tr('Нет на вашем тарифе', 'Tarifingizda yoʻq') : tr('Доступно на тарифе «$need»', '«$need» tarifida mavjud'),
                  style: AppText.bodyStrong),
              const SizedBox(height: 4),
              Text(text, style: AppText.small.copyWith(fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded, color: AppColors.warningInk),
        ]),
      ),
    );
  }
}

/// Ошибка загрузки экрана: функции нет в тарифе — замок и переход в «Тариф»,
/// иначе — «Не удалось загрузить» и «Повторить».
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry, this.title});

  final Object? error;
  final VoidCallback onRetry;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final e = error;
    if (e is ApiError && e.isPlan) return PlanLockedView(error: e);
    return EmptyState(
      icon: Icons.wifi_off_rounded,
      title: title ?? tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
      text: '$e',
      action: tr('Повторить', 'Qayta urinish'),
      onAction: onRetry,
    );
  }
}

/// Ошибка тарифа при загрузке (GET): функции нет — null вместо ошибки (и
/// [locked] с ошибкой), чтобы остальной экран загрузился.
Future<T?> unlessPlan<T>(Future<T> f, [void Function(ApiError e)? locked]) => f.then<T?>((v) => v).catchError((Object e) {
      if (e is ApiError && e.isPlan) {
        locked?.call(e);
        return null;
      }
      throw e;
    });

/// «1 касса · 5 сотрудников · 2 курьера» — лимиты в карточке тарифа.
String _limitsLine(Map<String, dynamic> p) {
  const words = {
    'registers': (('касса', 'кассы', 'касс'), 'kassa'),
    'staff': (('сотрудник', 'сотрудника', 'сотрудников'), 'xodim'),
    'couriers': (('курьер', 'курьера', 'курьеров'), 'kuryer'),
  };
  final parts = <String>[];
  for (final l in (p['limits'] as List? ?? const [])) {
    final m = l as Map;
    final w = words[m['key']];
    if (w == null) continue;
    final v = (m['value'] as num?)?.toInt();
    final (ru, uz) = w;
    parts.add(v == null
        ? tr('${ru.$3} без лимита', '$uz cheklovsiz')
        : tr('$v ${plural(v, ru.$1, ru.$2, ru.$3)}', '$v $uz'));
  }
  return parts.join(' · ');
}

// ----------------------------------------------------------- B1 · Тариф

class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key});

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  String? _busy;

  Future<void> _choose(Map<String, dynamic> p, Map<String, dynamic> plan) async {
    final st = context.read<StoreState>();
    final stores = (plan['stores_count'] as num?)?.toInt() ?? 1;
    final total = n(p['price_uzs']) * (stores < 1 ? 1 : stores);
    final ok = await showSheet<bool>(context, (ctx) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetHeader(
          title: tr('Перейти на тариф «${p['name']}»?', '«${p['name']}» tarifiga oʻtilsinmi?'),
          text: tr(
            '${_soum(total)} в месяц войдут в ближайший счёт за подписку${plan['in_trial'] == true ? ' после пробного периода' : ''}. Функции меняются сразу.',
            'Oyiga ${_soum(total)} obuna uchun eng yaqin hisobga qoʻshiladi${plan['in_trial'] == true ? ' (sinov davridan keyin)' : ''}. Funksiyalar darhol oʻzgaradi.',
          ),
        ),
        const SizedBox(height: 20),
        SheetButton(label: tr('Перейти', 'Oʻtish'), onPressed: () => Navigator.of(ctx).pop(true)),
        const SizedBox(height: 10),
        SheetButton(label: tr('Отмена', 'Bekor qilish'), primary: false, onPressed: () => Navigator.of(ctx).pop(false)),
      ]);
    });
    if (ok != true || !mounted) return;
    setState(() => _busy = '${p['key']}');
    try {
      st.plan = await context.read<Api>().post('/store/plan', {'plan': p['key']}) as Map<String, dynamic>;
      await st.loadPlan();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Тариф изменён', 'Tarif oʻzgartirildi'))));
    } on ApiError catch (e) {
      if (mounted && !e.isPlan) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final plan = st.plan;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Тариф', 'Tarif'))),
      body: plan == null
          ? Center(
              child: EmptyState(
                icon: Icons.workspace_premium_rounded,
                title: tr('Загружаем тариф…', 'Tarif yuklanmoqda…'),
                action: tr('Обновить', 'Yangilash'),
                onAction: st.loadPlan,
              ),
            )
          : RefreshIndicator(
              onRefresh: st.loadPlan,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
                _current(plan),
                const SizedBox(height: 24),
                Text(tr('Тарифы', 'Tariflar'), style: AppText.h3),
                if (!subscriptionReadOnly) ...[
                  const SizedBox(height: 4),
                  Text(tr('Цена — со следующего счёта, функции — сразу', 'Narx keyingi hisobdan, funksiyalar — darhol'), style: AppText.small),
                ],
                const SizedBox(height: 12),
                for (final p in (plan['plans'] as List? ?? const [])) ...[
                  _card(Map<String, dynamic>.from(p as Map), plan),
                  const SizedBox(height: 12),
                ],
              ]),
            ),
    );
  }

  Widget _current(Map<String, dynamic> plan) {
    final cur = Map<String, dynamic>.from(plan['current'] as Map);
    final limits = [
      for (final l in (cur['limits'] as List? ?? const []))
        if ((l as Map)['key'] != 'ads' && !(l['used'] == null && l['value'] == null)) Map<String, dynamic>.from(l),
    ];
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('ТЕКУЩИЙ ТАРИФ', 'HOZIRGI TARIF'), style: AppText.caption),
        const SizedBox(height: 4),
        Row(children: [
          Flexible(child: Text('${cur['name']}', style: AppText.h2)),
          if (plan['in_trial'] == true) ...[const SizedBox(width: 8), StatusChip(tr('пробный', 'sinov'), tone: ChipTone.amber)],
        ]),
        if (!subscriptionReadOnly) ...[
          const SizedBox(height: 2),
          Text(tr('${_soum(plan['custom_price_uzs'] ?? cur['price_uzs'])} за магазин в месяц', 'Doʻkon uchun oyiga ${_soum(plan['custom_price_uzs'] ?? cur['price_uzs'])}'),
              style: AppText.bodyStrong),
        ],
        if (plan['in_trial'] == true && plan['trial_until'] != null) ...[
          const SizedBox(height: 4),
          Text(tr('Пробный период до ${_day(plan['trial_until'])}', 'Sinov davri ${_day(plan['trial_until'])} gacha'), style: AppText.small),
        ],
        if (limits.isNotEmpty) ...[
          const Divider(height: 24),
          Text(tr('ЛИМИТЫ', 'LIMITLAR'), style: AppText.caption),
          for (final l in limits) _limit(l),
        ],
      ]),
    );
  }

  Widget _limit(Map<String, dynamic> l) {
    final used = l['used'] as num?;
    final value = l['value'] as num?;
    final full = value != null && used != null && used >= value;
    final label = used == null
        ? (value == null ? tr('без лимита', 'cheklovsiz') : tr('до $value', '$value tagacha'))
        : (value == null ? '$used · ${tr('без лимита', 'cheklovsiz')}' : '$used / $value');
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${l['name']}', style: AppText.body)),
          Text(label, style: AppText.bodyStrong.copyWith(color: full ? AppColors.error : null)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 6,
            value: value == null ? 0.15 : (used == null ? 0.0 : (value == 0 ? 1.0 : (used / value).clamp(0, 1).toDouble())),
            backgroundColor: AppColors.soft,
            color: full ? AppColors.error : (value == null ? AppColors.muted : AppColors.primary),
          ),
        ),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> p, Map<String, dynamic> plan) {
    final chosen = (plan['chosen'] as Map?)?['key'] == p['key'];
    final stores = (plan['stores_count'] as num?)?.toInt() ?? 0;
    final minStores = (p['min_stores'] as num?)?.toInt() ?? 1;
    final features = [
      for (final f in (p['features'] as List? ?? const []))
        if (_shownFeatures.contains((f as Map)['key'])) Map<String, dynamic>.from(f),
    ];
    return AppCard(
      border: p['recommended'] == true ? AppColors.primary : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${p['name']}', style: AppText.title),
          if (p['recommended'] == true) StatusChip(tr('Рекомендуем', 'Tavsiya etamiz'), tone: ChipTone.red),
          if (chosen) StatusChip(tr('Ваш тариф', 'Sizning tarifingiz'), tone: ChipTone.green),
        ]),
        if (!subscriptionReadOnly) ...[
          const SizedBox(height: 4),
          Text(_soum(p['price_uzs']), style: AppText.h3),
          Text(
            [
              minStores > 1 ? tr('за каждый магазин в месяц', 'har bir doʻkon uchun / oy') : tr('за магазин в месяц', 'doʻkon uchun / oy'),
              if (minStores > 1) tr('от $minStores магазинов', '$minStores ta doʻkondan'),
            ].join(' · '),
            style: AppText.small,
          ),
        ],
        if ('${p['description'] ?? ''}'.isNotEmpty) ...[const SizedBox(height: 6), Text('${p['description']}', style: AppText.small)],
        const Divider(height: 20),
        for (final f in features)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(f['included'] == true ? Icons.check_circle_rounded : Icons.lock_rounded,
                  size: 18, color: f['included'] == true ? AppColors.success : AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${f['name']}',
                    style: f['included'] == true ? AppText.bodyStrong.copyWith(fontSize: 14) : AppText.body.copyWith(fontSize: 14, color: AppColors.text2)),
              ),
            ]),
          ),
        if (_limitsLine(p).isNotEmpty) ...[const SizedBox(height: 6), Text(_limitsLine(p), style: AppText.caption)],
        if (!subscriptionReadOnly) ...[
          const SizedBox(height: 12),
          if (chosen)
            BigButton(label: tr('Ваш тариф', 'Hozirgi tarifingiz'), height: 48, onPressed: null)
          else if (stores < minStores)
            BigButton(label: tr('От $minStores магазинов · у вас $stores', '$minStores ta doʻkondan · sizda $stores ta'), height: 48, onPressed: null)
          else if (plan['can_change'] != true)
            BigButton(label: tr('Тариф меняет владелец', 'Tarifni doʻkon egasi oʻzgartiradi'), height: 48, onPressed: null)
          else
            BigButton(
              label: tr('Перейти на «${p['name']}»', '«${p['name']}» tarifiga oʻtish'),
              height: 48,
              color: p['recommended'] == true ? AppColors.primary : AppColors.ink,
              busy: _busy == p['key'],
              onPressed: _busy == null ? () => _choose(p, plan) : null,
            ),
        ],
      ]),
    );
  }
}
