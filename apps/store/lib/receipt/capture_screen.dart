import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/app_lock.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'processing_screen.dart';

/// П1 · Фото накладной: одна или несколько страниц → загрузка → распознавание.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _picker = ImagePicker();
  final _pages = <Uint8List>[];
  bool _busy = false;
  bool _askedCamera = false;

  static const maxPages = 5;

  @override
  void initState() {
    super.initState();
    // Сразу открываем камеру — обычно накладная в одну страницу.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_askedCamera) {
        _askedCamera = true;
        _take(ImageSource.camera);
      }
    });
  }

  Future<void> _take(ImageSource source) async {
    if (_pages.length >= maxPages) return;
    final lock = context.read<AppLock>();
    try {
      // Сжимаем на телефоне: текст накладной читается, а файл — до 1–2 МБ.
      // Камера — своё окно приложения: пока она открыта, замок кодом не включается.
      final x = await lock.hold(() => _picker.pickImage(source: source, maxWidth: 2200, maxHeight: 2200, imageQuality: 80));
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _pages.add(bytes));
    } catch (e) {
      if (mounted) showMessage(context, 'Нет доступа к камере или фото. Разрешите доступ в настройках телефона.');
    }
  }

  Future<void> _send() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    setState(() => _busy = true);
    try {
      final urls = <String>[];
      for (var i = 0; i < _pages.length; i++) {
        final res = await api.upload('/store/uploads', _pages[i], 'invoice_${i + 1}.jpg') as Map<String, dynamic>;
        urls.add(res['url'] as String);
      }
      final scan = await api.post('/store/invoice-scans', {'store_id': st.storeId, 'images': urls}) as Map<String, dynamic>;
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ProcessingScreen(id: scan['id'] as String)));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        backgroundColor: AppColors.ink,
        foregroundColor: AppColors.white,
        title: Text('Накладная', style: AppText.title.copyWith(color: AppColors.white)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _pages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.document_scanner_rounded, size: 72, color: AppColors.muted),
                        const SizedBox(height: 16),
                        Text('Сфотографируйте накладную целиком',
                            style: AppText.title.copyWith(color: AppColors.white), textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        Text('Положите лист ровно, при хорошем свете. Если страниц несколько — снимите каждую.',
                            style: AppText.small.copyWith(color: AppColors.muted), textAlign: TextAlign.center),
                      ]),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.72),
                    itemCount: _pages.length,
                    itemBuilder: (_, i) => Stack(children: [
                      Positioned.fill(
                        child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_pages[i], fit: BoxFit.cover)),
                      ),
                      Positioned(
                        left: 8,
                        top: 8,
                        child: StatusChip('Стр. ${i + 1}', tone: ChipTone.gray),
                      ),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: _busy ? null : () => setState(() => _pages.removeAt(i))),
                      ),
                    ]),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: SmallButton(
                    label: 'Из галереи',
                    icon: Icons.photo_library_rounded,
                    onPressed: _busy || _pages.length >= maxPages ? null : () => _take(ImageSource.gallery),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SmallButton(
                    label: _pages.isEmpty ? 'Снять' : '+ страница',
                    icon: Icons.photo_camera_rounded,
                    onPressed: _busy || _pages.length >= maxPages ? null : () => _take(ImageSource.camera),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              BigButton(
                label: _pages.length > 1 ? 'Распознать ${_pages.length} стр.' : 'Распознать',
                icon: Icons.auto_awesome_rounded,
                busy: _busy,
                onPressed: _pages.isEmpty ? null : _send,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
