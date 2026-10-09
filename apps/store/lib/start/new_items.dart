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
        content: Text(tr('Отправлено Super Market — карточка будет готова через минуту во вкладке «Новые»',
            'Super Market’ga yuborildi — kartochka bir daqiqada «Yangilar» boʻlimida tayyor boʻladi')),
      ));
  } else if (r == 'failed') {
    showMessage(context, tr('Фото сохранены — заполните карточку во вкладке «Новые»', 'Rasmlar saqlandi — kartochkani «Yangilar» boʻlimida toʻldiring'));
  }
  return true;
}

/// Р3 · Вкладка «Новые»: карточки Super Market. Пока что-то распознаётся —
/// список обновляется сам. onChanged — после подтверждения или удаления.
class NewItemsTab extends StatefulWidget {
  const NewItemsTab({super.key, required this.start, required this.data, required this.onChanged});

  final StartApi start;
  final Map<String, dynamic>? data;
  final Future<void> Function() onChanged;

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
    return RefreshIndicator(
      onRefresh: widget.onChanged,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Text(tr('Super Market заполняет карточки по фото — можно работать дальше', 'Super Market rasmlar boʻyicha kartochkalarni toʻldiradi — ishni davom ettirish mumkin'),
            style: AppText.caption),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Text(tr('Пока пусто. Нет товара ни в базе, ни в каталоге ИКПУ — нажмите «+» и сфотографируйте его.', 'Hozircha boʻsh. Mahsulot na bazada, na MXIK katalogida boʻlsa — «+»ni bosing va uni suratga oling.'),
              style: AppText.small)
        else
          AppCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 72, color: AppColors.line),
                _NewTile(item: items[i], onTap: items[i]['status'] == 'processing' ? null : () => _open(items[i])),
              ],
            ]),
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
                tr('Товар попадёт в «Мои товары» только после вашего подтверждения. Новые товары уйдут на проверку в общую базу после «Инвентаризации».',
                    'Mahsulot «Mahsulotlarim»ga faqat siz tasdiqlaganingizdan soʻng tushadi. Yangi mahsulotlar «Inventarizatsiya»dan soʻng umumiy bazaga tekshiruvga yuboriladi.'),
                style: AppText.small.copyWith(fontSize: 12, color: AppColors.blue),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
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
