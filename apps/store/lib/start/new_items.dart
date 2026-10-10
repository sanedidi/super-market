import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/app_lock.dart';
import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'new_product_screen.dart';
import 'sheets.dart';
import 'start_api.dart';

// Новый товар по фото (Figma «SM Магазин · новый товар по фото», Р1–Р5).
// Товара нет ни в базе, ни в каталоге ИКПУ — магазин снимает 1–3 фото и сразу
// работает дальше; Super Market в фоне заполняет карточку. Вкладка «Новые»:
// распознаётся / проверить / не удалось — заполнить. Только после
// подтверждения товар создаётся и встаёт в «Мои товары».
// Без дублей (Figma «без дублей в «Новых»», Д1–Д3): штрихкод, который уже в
// «Новых», — шторка «Этот товар уже в «Новых»» вместо «Новый товар»; похожая
// карточка помечена «Похоже на дубль», «Это он» объединяет карточки.

const _purple = Color(0xFF6938EF);
const _purpleSoft = Color(0xFFF4F3FF);

/// Р1 · Фото нового товара. true — отправлено Super Market; ручная форма —
/// «Заполнить вручную» (возвращает то, что вернула форма).
class NewItemCameraScreen extends StatefulWidget {
  const NewItemCameraScreen({super.key, required this.start, this.barcode});

  final StartApi start;
  final String? barcode;

  @override
  State<NewItemCameraScreen> createState() => _NewItemCameraScreenState();
}

class _NewItemCameraScreenState extends State<NewItemCameraScreen> {
  static const maxShots = 3;
  final _picker = ImagePicker();
  final _shots = <Uint8List>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Сразу камера — меньше нажатий.
    WidgetsBinding.instance.addPostFrameCallback((_) => _take(ImageSource.camera));
  }

  Future<void> _take(ImageSource source) async {
    if (_shots.length >= maxShots) return;
    final lock = context.read<AppLock>();
    try {
      final x = await lock.hold(() => _picker.pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 82));
      WidgetsBinding.instance.scheduleFrame();
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _shots.add(bytes));
    } catch (_) {
      if (mounted) showMessage(context, tr('Нет доступа к камере или фото. Разрешите доступ в настройках телефона.', 'Kamera yoki rasmlarga ruxsat yoʻq. Telefon sozlamalarida ruxsat bering.'));
    }
  }

  Future<void> _send() async {
    final api = context.read<Api>();
    setState(() => _busy = true);
    try {
      final urls = <String>[];
      for (var i = 0; i < _shots.length; i++) {
        final res = await api.upload('/store/uploads', _shots[i], 'new_${i + 1}.jpg') as Map<String, dynamic>;
        urls.add(res['url'] as String);
      }
      final it = await widget.start.createNewItem(urls, barcode: widget.barcode);
      if (!mounted) return;
      Navigator.of(context).pop(it['status'] == 'failed' ? 'failed' : 'sent');
    } on ApiError catch (e) {
      if (!mounted) return;
      // Тот же штрихкод уже в «Новых» (например, отправил другой сотрудник) — вторую карточку не заводим.
      if (e.code == 'new_item_exists') {
        Navigator.of(context).pop('exists');
      } else {
        showMessage(context, e);
      }
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manual() async {
    final r = await Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => NewProductScreen(start: widget.start, barcode: widget.barcode)));
    if (mounted && r != null) Navigator.of(context).pop('manual');
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.barcode;
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: () => Navigator.of(context).pop()),
              const Spacer(),
              TextButton(onPressed: _busy ? null : _manual, child: Text(tr('Заполнить вручную', 'Qoʻlda toʻldirish'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14))),
            ]),
          ),
          if (code != null && code.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: AppColors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(99)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.qr_code_2_rounded, size: 16, color: AppColors.white),
                const SizedBox(width: 6),
                Text(tr('Штрихкод $code — нет в базе', 'Shtrix-kod $code — bazada yoʻq'), style: AppText.caption.copyWith(color: AppColors.white, fontSize: 13)),
              ]),
            ),
          Expanded(
            child: _shots.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
                    child: Column(children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(border: Border.all(color: AppColors.white.withValues(alpha: 0.85), width: 2), borderRadius: BorderRadius.circular(20)),
                          child: const Center(child: Icon(Icons.add_a_photo_rounded, size: 64, color: AppColors.muted)),
                        ),
                      ),
                    ]),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10),
                    itemCount: _shots.length,
                    itemBuilder: (_, i) => Stack(children: [
                      Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_shots[i], fit: BoxFit.cover))),
                      Positioned(
                        right: 6,
                        top: 6,
                        child: RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: _busy ? null : () => setState(() => _shots.removeAt(i))),
                      ),
                    ]),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(children: [
              Text(tr('Сфотографируйте новый товар', 'Yangi mahsulotni suratga oling'), style: AppText.bodyStrong.copyWith(color: AppColors.white), textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                tr('Лицевую сторону и этикетку с составом и весом. Super Market сам заполнит карточку — вы продолжите работу',
                    'Old tomoni va tarkibi hamda ogʻirligi yozilgan yorligʻi. Super Market kartochkani oʻzi toʻldiradi — siz ishni davom ettirasiz'),
                style: AppText.small.copyWith(color: AppColors.muted),
                textAlign: TextAlign.center,
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 20, 32, 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              _Square(icon: Icons.photo_library_rounded, onTap: _busy || _shots.length >= maxShots ? null : () => _take(ImageSource.gallery)),
              GestureDetector(
                onTap: _busy || _shots.length >= maxShots ? null : () => _take(ImageSource.camera),
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.white, width: 4)),
                  padding: const EdgeInsets.all(5),
                  child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: _shots.length >= maxShots ? AppColors.dark : AppColors.primary)),
                ),
              ),
              Material(
                color: _shots.isEmpty ? AppColors.dark : AppColors.primary,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _shots.isEmpty || _busy ? null : _send,
                  child: SizedBox(
                    width: 92,
                    height: 52,
                    child: Center(
                      child: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.white))
                          : Column(mainAxisSize: MainAxisSize.min, children: [
                              Text(tr('Отправить', 'Yuborish'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 14)),
                              if (_shots.isNotEmpty) Text(tr('${_shots.length} фото', '${_shots.length} ta rasm'), style: AppText.caption.copyWith(color: AppColors.white, fontSize: 11)),
                            ]),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Square extends StatelessWidget {
  const _Square({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.dark,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(width: 52, height: 52, child: Icon(icon, color: AppColors.white)),
      ),
    );
  }
}

/// Открыть камеру нового товара и показать, что дальше (Р2): true — что-то отправлено или создано.
Future<bool> openNewItemCamera(BuildContext context, StartApi start, {String? barcode}) async {
  final r = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => NewItemCameraScreen(start: start, barcode: barcode)));
  if (!context.mounted || r == null) return false;
  if (r == 'sent') {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(tr('Отправлено Super Market — через минуту товар встанет в «Мои товары» или попадёт во «Внимание»',
            'Super Market’ga yuborildi — bir daqiqada mahsulot «Mahsulotlarim»ga tushadi yoki «Eʼtibor»ga oʻtadi')),
      ));
  } else if (r == 'failed') {
    showMessage(context, tr('Фото сохранены — заполните карточку во вкладке «Внимание»', 'Rasmlar saqlandi — kartochkani «Eʼtibor» boʻlimida toʻldiring'));
  } else if (r == 'exists') {
    showMessage(context, tr('Этот товар уже в «Новых» — проверьте его карточку', 'Bu mahsulot allaqachon «Yangilar»da — kartochkasini tekshiring'));
  }
  return true;
}

String _queuedName(Map<String, dynamic> item) => switch (item['status']) {
      'ready' => '${(item['result'] as Map<String, dynamic>?)?['name'] ?? ''}',
      'processing' => tr('Распознаётся…', 'Aniqlanmoqda…'),
      _ => tr('Не удалось распознать', 'Aniqlab boʻlmadi'),
    };

/// Состояние карточки в «Новых»: готово / распознаётся / не удалось.
class NewItemStateChip extends StatelessWidget {
  const NewItemStateChip({super.key, required this.status});

  final Object? status;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, IconData icon, String text) = switch (status) {
      'ready' => (AppColors.successSoft, AppColors.successInk, Icons.check_circle_rounded, tr('Готово к проверке', 'Tekshirishga tayyor')),
      'processing' => (_purpleSoft, _purple, Icons.auto_awesome_rounded, tr('Super Market… ~1 мин', 'Super Market… ~1 daq')),
      _ => (AppColors.errorSoft, AppColors.error, Icons.error_outline_rounded, tr('Не удалось — заполните', 'Boʻlmadi — toʻldiring')),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: fg),
        const SizedBox(width: 4),
        Text(text, style: AppText.caption.copyWith(fontSize: 11, color: fg)),
      ]),
    );
  }
}

/// Карточка из «Новых» (фото, название, состояние) — в шторке и подсказке.
class QueuedItemCard extends StatelessWidget {
  const QueuedItemCard({super.key, required this.item, this.color = AppColors.bg});

  final Map<String, dynamic> item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final images = (item['images'] as List?) ?? const [];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        ProductThumb(images.isEmpty ? null : '${images.first}', size: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_queuedName(item), style: AppText.bodyStrong.copyWith(fontSize: 14)),
            const SizedBox(height: 2),
            Text(tr('${images.length} фото', '${images.length} ta rasm'), style: AppText.small.copyWith(fontSize: 12)),
            const SizedBox(height: 4),
            NewItemStateChip(status: item['status']),
          ]),
        ),
      ]),
    );
  }
}

/// Открыть карточку из «Новых» на проверку (Р4).
Future<void> openNewItemReview(BuildContext context, StartApi start, Map<String, dynamic> item) =>
    Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => NewProductScreen(start: start, review: item)));

/// Д1 · Штрихкод уже в «Новых»: вторую карточку не заводим. «Проверить
/// карточку» (готова) или «Заполнить» (не удалось) открывает её; пока
/// распознаётся — только «Сканировать дальше». true — карточку открыли.
Future<bool> showQueuedSheet(BuildContext context, StartApi start, Map<String, dynamic> item) async {
  final status = item['status'];
  final code = '${item['barcode'] ?? ''}';
  final r = await showSheet<String>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        icon: Icons.auto_awesome_rounded,
        title: tr('Этот товар уже в «Новых»', 'Bu mahsulot allaqachon «Yangilar»da'),
        text: tr('Штрихкод $code вы уже сфотографировали — Super Market готовит карточку. Второй раз добавлять не нужно.',
            '$code shtrix-kodini allaqachon suratga olgansiz — Super Market kartochkani tayyorlamoqda. Qayta qoʻshish shart emas.'),
      ),
      const SizedBox(height: 16),
      QueuedItemCard(item: item),
      const SizedBox(height: 20),
      if (status != 'processing') ...[
        SheetButton(label: status == 'ready' ? tr('Проверить карточку', 'Kartochkani tekshirish') : tr('Заполнить', 'Toʻldirish'), onPressed: () => Navigator.pop(ctx, 'open')),
        const SizedBox(height: 10),
      ],
      SheetButton(label: tr('Сканировать дальше', 'Skanerlashni davom ettirish'), primary: false, onPressed: () => Navigator.pop(ctx)),
    ]),
  );
  if (r != 'open' || !context.mounted) return false;
  await openNewItemReview(context, start, item);
  return true;
}

/// Подсказка в поиске: штрихкод уже в «Новых» (вместо вариантов ИКПУ и «Новый товар»).
class QueuedCallout extends StatelessWidget {
  const QueuedCallout({super.key, required this.item, required this.onOpen});

  final Map<String, dynamic> item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final status = item['status'];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.content_copy_rounded, size: 16, color: AppColors.warningInk),
          const SizedBox(width: 6),
          Expanded(child: Text(tr('Этот товар уже в «Новых»', 'Bu mahsulot allaqachon «Yangilar»da'), style: AppText.bodyStrong.copyWith(fontSize: 14))),
        ]),
        const SizedBox(height: 6),
        Text(tr('Его уже отправили Super Market — второй раз добавлять не нужно.', 'U allaqachon Super Market’ga yuborilgan — qayta qoʻshish shart emas.'), style: AppText.small),
        const SizedBox(height: 10),
        QueuedItemCard(item: item, color: AppColors.white),
        if (status != 'processing') ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: SmallButton(
              label: status == 'ready' ? tr('Проверить', 'Tekshirish') : tr('Заполнить', 'Toʻldirish'),
              icon: status == 'ready' ? Icons.fact_check_rounded : Icons.edit_rounded,
              primary: true,
              onPressed: onOpen,
            ),
          ),
        ],
      ]),
    );
  }
}

/// Р3 · Вкладка «Новые»: карточки Super Market. Пока что-то распознаётся —
/// список обновляется сам. onChanged — после подтверждения или удаления.
class NewItemsTab extends StatefulWidget {
  const NewItemsTab({super.key, required this.start, required this.data, required this.onChanged, this.onMore});

  final StartApi start;
  final Map<String, dynamic>? data;
  final Future<void> Function() onChanged;

  /// Следующая страница очереди — докрутили до конца.
  final Future<void> Function()? onMore;

  @override
  State<NewItemsTab> createState() => _NewItemsTabState();
}

class _NewItemsTabState extends State<NewItemsTab> {
  Future<void> _open(Map<String, dynamic> it) async {
    await Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => NewProductScreen(start: widget.start, review: it)));
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final items = ((widget.data?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final hasMore = widget.onMore != null && items.length < newItemsTotal(widget.data);
    return RefreshIndicator(
      onRefresh: widget.onChanged,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (hasMore && n.metrics.extentAfter < 400) widget.onMore!();
          return false;
        },
        // Лениво: в очереди бывают сотни карточек с фото — все сразу телефон не держит.
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          itemCount: items.length + 2,
          itemBuilder: (_, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(tr('Super Market заполняет карточки по фото — можно работать дальше', 'Super Market rasmlar boʻyicha kartochkalarni toʻldiradi — ishni davom ettirish mumkin'),
                    style: AppText.caption),
              );
            }
            if (index <= items.length) {
              final i = index - 1;
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(i == 0 ? 20 : 0),
                    bottom: Radius.circular(i == items.length - 1 ? 20 : 0),
                  ),
                ),
                child: Column(children: [
                  if (i > 0) const Divider(height: 1, indent: 72, color: AppColors.line),
                  _NewTile(item: items[i], onTap: items[i]['status'] == 'processing' ? null : () => _open(items[i])),
                ]),
              );
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (items.isEmpty)
                Text(tr('Пока пусто. Нет товара ни в базе, ни в каталоге ИКПУ — нажмите «+» и сфотографируйте его.', 'Hozircha boʻsh. Mahsulot na bazada, na MXIK katalogida boʻlsa — «+»ni bosing va uni suratga oling.'),
                    style: AppText.small),
              if (hasMore)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                ),
              const SizedBox(height: 12),
              Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(16)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_rounded, size: 18, color: AppColors.blue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('Распознанные товары без дублей Super Market сам добавляет в «Мои товары». Здесь — то, что нужно проверить. Новые товары уйдут на проверку в общую базу после «Инвентаризации».',
                      'Aniqlangan va dubl boʻlmagan mahsulotlarni Super Market oʻzi «Mahsulotlarim»ga qoʻshadi. Bu yerda — tekshirish kerak boʻlganlar. Yangi mahsulotlar «Inventarizatsiya»dan soʻng umumiy bazaga tekshiruvga yuboriladi.'),
                  style: AppText.small.copyWith(fontSize: 12, color: AppColors.blue),
                ),
                ),
              ]),
            ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Сколько всего в очереди «Новые» (total с сервера; старый сервер — по items).
int newItemsTotal(Map<String, dynamic>? data) =>
    (data?['total'] as num?)?.toInt() ?? ((data?['items'] as List?) ?? const []).length;

/// Страницы «Новых» одной очередью: очередь могла сдвинуться — без повторов.
List<dynamic> uniqueNewItems(List<dynamic> items) {
  final seen = <Object?>{};
  return [for (final it in items) if (seen.add((it as Map)['id'])) it];
}

class _NewTile extends StatelessWidget {
  const _NewTile({required this.item, required this.onTap});

  final Map<String, dynamic> item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final status = item['status'];
    final res = item['result'] as Map<String, dynamic>?;
    final images = (item['images'] as List?) ?? const [];
    final code = (item['barcode'] as String?) ?? '';
    final title = status == 'processing'
        ? tr('Распознаётся…', 'Aniqlanmoqda…')
        : status == 'ready'
            ? '${res?['name'] ?? ''}'
            : tr('Не удалось распознать', 'Aniqlab boʻlmadi');
    final sub = [
      if (code.isNotEmpty) code else tr('без штрихкода', 'shtrix-kodsiz'),
      if (status == 'processing') tr('${images.length} фото', '${images.length} ta rasm'),
      if (status == 'ready') tr('готово — проверьте', 'tayyor — tekshiring'),
      if (status == 'failed') '${item['error'] ?? ''}',
    ].join(' · ');
    Widget pill(String text, Color bg, Color fg, {IconData? icon}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
            Text(text, style: AppText.caption.copyWith(fontSize: 12, color: fg)),
          ]),
        );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          ProductThumb(images.isEmpty ? null : '${images.first}', size: 48),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong.copyWith(fontSize: 14, color: status == 'processing' ? AppColors.text2 : AppColors.ink)),
              Text(sub, style: AppText.small.copyWith(fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
              // Д3: похоже, этот товар уже есть в «Новых» — сверить в карточке («Это он»).
              if (item['duplicate'] != null && status != 'processing') ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(8)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.content_copy_rounded, size: 12, color: AppColors.warningInk),
                    const SizedBox(width: 4),
                    Text(tr('Похоже на дубль', 'Dublga oʻxshaydi'), style: AppText.caption.copyWith(fontSize: 11, color: AppColors.warningInk)),
                  ]),
                ),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          if (status == 'processing')
            pill(tr('~1 мин', '~1 daq'), _purpleSoft, _purple, icon: Icons.auto_awesome_rounded)
          else if (status == 'ready')
            pill(tr('Проверить', 'Tekshirish'), AppColors.ink, AppColors.white)
          else
            pill(tr('Заполнить', 'Toʻldirish'), AppColors.errorSoft, AppColors.error),
        ]),
      ),
    );
  }
}

/// Опрос очереди «Новые», пока что-то распознаётся.
class NewItemsPoller {
  NewItemsPoller(this.load);

  final Future<void> Function() load;
  Timer? _t;

  void update(Map<String, dynamic>? data) {
    final processing = ((data?['counts'] as Map<String, dynamic>?)?['processing'] as num?)?.toInt() ?? 0;
    if (processing > 0) {
      _t ??= Timer.periodic(const Duration(seconds: 3), (_) => load());
    } else {
      _t?.cancel();
      _t = null;
    }
  }

  void dispose() {
    _t?.cancel();
    _t = null;
  }
}
