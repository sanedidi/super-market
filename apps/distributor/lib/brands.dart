import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/start/start_screen.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'auth.dart';
import 'document_screen.dart';
import 'ui.dart';

// Бренды агента: выбранные из каталога и заявки на новые (Figma «SM Агент ·
// регистрация сам», А7 «Главная, пока бренд на рассмотрении», А8 «Заявка
// отклонена»).

/// Последняя заявка, которая ещё не одобрена (ждёт или отклонена).
Map<String, dynamic>? openRequest(Map<String, dynamic> brands) {
  for (final r in (brands['requests'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    if (r['status'] != 'approved') return r;
  }
  return null;
}

/// Главная агента, пока магазины закрыты: статус бренда и что можно делать.
class BrandPendingHome extends StatelessWidget {
  const BrandPendingHome({super.key, required this.brands, required this.onChanged});

  final Map<String, dynamic> brands;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final req = openRequest(brands);
    Future<void> open(Widget w) async {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
      onChanged();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (req == null)
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Выберите свой бренд', 'Brendingizni tanlang'), style: AppText.title),
            const SizedBox(height: 4),
            Text(tr('Магазины откроются, когда у вас будет бренд из каталога Super Market.', 'Super Market katalogidan brendingiz boʻlganda doʻkonlar ochiladi.'), style: AppText.small),
            const SizedBox(height: 12),
            BigButton(label: tr('Выбрать бренд', 'Brendni tanlash'), height: 48, onPressed: () => open(const AgentBrandScreen())),
          ]),
        )
      else if (req['status'] == 'rejected')
        AppCard(
          color: AppColors.errorSoft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.error),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Бренд «${req['name']}» не одобрен', '«${req['name']}» brendi tasdiqlanmadi'), style: AppText.bodyStrong.copyWith(color: AppColors.error)),
                  Text('${dateTime(req['decided_at'])} · Super Market', style: AppText.small),
                ]),
              ),
            ]),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Причина', 'Sabab'), style: AppText.small),
                Text('${req['reason']}', style: AppText.body),
              ]),
            ),
            const SizedBox(height: 12),
            BigButton(label: tr('Выбрать бренд из каталога', 'Katalogdan brend tanlash'), icon: Icons.check_rounded, height: 48, onPressed: () => open(const AgentBrandScreen())),
            const SizedBox(height: 8),
            BigButton(
              label: tr('Исправить заявку', 'Arizani tuzatish'),
              icon: Icons.edit_rounded,
              color: AppColors.white,
              foreground: AppColors.ink,
              height: 48,
              onPressed: () => open(BrandRequestScreen(edit: req)),
            ),
          ]),
        )
      else
        AppCard(
          color: AppColors.warningSoft,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const IconBox(Icons.hourglass_top_rounded, bg: AppColors.white, fg: AppColors.warningInk, size: 40, iconSize: 20, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Бренд «${req['name']}» на рассмотрении', '«${req['name']}» brendi koʻrib chiqilmoqda'),
                    style: AppText.bodyStrong.copyWith(color: AppColors.warningInk)),
                Text(tr('Заявка от ${dateTime(req['created_at'])} · обычно до 1 дня. Сообщим пушем',
                    '${dateTime(req['created_at'])} dagi ariza · odatda 1 kungacha. Push orqali xabar beramiz'), style: AppText.small),
              ]),
            ),
          ]),
        ),
      const SizedBox(height: 12),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Пока можно', 'Hozircha mumkin'), style: AppText.title),
          const SizedBox(height: 4),
          _Row(
            icon: Icons.qr_code_scanner_rounded,
            title: tr('Ввести свои товары', 'Mahsulotlaringizni kiritish'),
            text: tr('Начало работы: скан штрихкода → количество, отпускная цена', 'Ishni boshlash: shtrix-kod → miqdor, ulgurji narx'),
            onTap: () => open(const StartScreen()),
          ),
          const Divider(height: 1),
          _Row(
            icon: Icons.move_to_inbox_rounded,
            title: tr('Приход на склад', 'Omborga kirim'),
            text: tr('От производителя или поставщика', 'Ishlab chiqaruvchi yoki yetkazib beruvchidan'),
            onTap: () => open(const DocumentScreen.create(type: 'income')),
          ),
          const SizedBox(height: 8),
          BigButton(label: tr('Начать ввод товаров', 'Mahsulot kiritishni boshlash'), icon: Icons.play_arrow_rounded, color: AppColors.ink, height: 48, onPressed: () => open(const StartScreen())),
        ]),
      ),
      const SizedBox(height: 12),
      AppCard(
        color: AppColors.soft,
        child: Row(children: [
          const IconBox(Icons.lock_outline_rounded, bg: AppColors.white, fg: AppColors.muted, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Магазины рядом', 'Yaqindagi doʻkonlar'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
              Text(tr('Откроются после одобрения бренда: кому не хватает ваших товаров, «Договориться», заказы',
                  'Brend tasdiqlangach ochiladi: kimga mahsulotingiz yetishmayapti, «Kelishish», buyurtmalar'), style: AppText.small),
            ]),
          ),
        ]),
      ),
    ]);
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.text, required this.onTap});

  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          IconBox(icon, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong),
              Text(text, style: AppText.small),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
      ),
    );
  }
}

/// Ещё → Мои бренды: бренды агента и заявки на новые.
class MyBrandsScreen extends StatefulWidget {
  const MyBrandsScreen({super.key});

  @override
  State<MyBrandsScreen> createState() => _MyBrandsScreenState();
}

class _MyBrandsScreenState extends State<MyBrandsScreen> {
  Map<String, dynamic>? _b;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await context.read<Api>().get('/store/supply/brands') as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _b = b;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    final brands = (b?['brands'] as List? ?? const []).cast<Map<String, dynamic>>();
    final requests = (b?['requests'] as List? ?? const []).cast<Map<String, dynamic>>().where((r) => r['status'] != 'approved' || r['linked_existing'] != true).toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Мои бренды', 'Brendlarim'))),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _error != null && b == null
                ? LoadError(_error!, onRetry: _load)
                : b == null
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
                          AppCard(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                            child: Column(children: [
                              if (brands.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  child: Text(tr('Брендов пока нет — выберите свой из каталога', 'Hozircha brend yoʻq — katalogdan oʻzingiznikini tanlang'), style: AppText.small),
                                ),
                              for (var i = 0; i < brands.length; i++) ...[
                                if (i > 0) const Divider(height: 1),
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  child: Row(children: [
                                    BrandAvatar('${brands[i]['name']}'),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text('${brands[i]['name']}', style: AppText.bodyStrong),
                                        Text(
                                          [
                                            if ('${brands[i]['category'] ?? ''}'.isNotEmpty) '${brands[i]['category']}',
                                            tr('${brands[i]['products']} товаров в каталоге', 'katalogda ${brands[i]['products']} ta mahsulot'),
                                          ].join(' · '),
                                          style: AppText.small,
                                        ),
                                      ]),
                                    ),
                                  ]),
                                ),
                              ],
                            ]),
                          ),
                          if (requests.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(tr('Заявки на новые бренды', 'Yangi brendlarga arizalar'), style: AppText.title),
                            const SizedBox(height: 8),
                            for (final r in requests) ...[
                              AppCard(
                                onTap: r['status'] == 'approved' ? null : () => _open(BrandRequestScreen(edit: r)),
                                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  BrandAvatar('${r['name']}', logo: '${r['logo_url'] ?? ''}'),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text('${r['name']}', style: AppText.bodyStrong),
                                      Text(dateTime(r['created_at']), style: AppText.small),
                                      if (r['status'] == 'rejected') Text('${r['reason']}', style: AppText.small.copyWith(color: AppColors.error)),
                                    ]),
                                  ),
                                  StatusChip(
                                    switch ('${r['status']}') {
                                      'approved' => tr('Одобрена', 'Tasdiqlandi'),
                                      'rejected' => tr('Отклонена', 'Rad etildi'),
                                      _ => tr('На проверке', 'Tekshiruvda'),
                                    },
                                    tone: switch ('${r['status']}') {
                                      'approved' => ChipTone.green,
                                      'rejected' => ChipTone.red,
                                      _ => ChipTone.amber,
                                    },
                                  ),
                                ]),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ],
                          const SizedBox(height: 8),
                          Center(
                            child: TextButton.icon(
                              onPressed: () => _open(const BrandRequestScreen()),
                              icon: const Icon(Icons.add_rounded),
                              label: Text(tr('Нет моего бренда — запросить новый', 'Mening brendim yoʻq — yangisini soʻrash')),
                            ),
                          ),
                        ]),
                      ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: BigButton(label: tr('Добавить бренд из каталога', 'Katalogdan brend qoʻshish'), icon: Icons.add_rounded, onPressed: () => _open(const AgentBrandScreen())),
          ),
        ]),
      ),
    );
  }
}
