import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../catalog.dart';
import '../guest.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'search_screen.dart';
import 'home_screen.dart';
import 'root_shell.dart';

export '../catalog.dart';

/// Вкладка «Каталог»: поиск, чипы разделов (нажатие прокручивает к разделу) и все
/// категории магазина плитками.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _scroll = ScrollController();
  final _specialKey = GlobalKey();
  final _keys = <String?, GlobalKey>{};
  String? _active = '_special';
  bool _showUp = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final up = _scroll.offset > 600;
      if (up != _showUp) setState(() => _showUp = up);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jump(String? id, GlobalKey key) {
    setState(() => _active = id);
    final ctx = key.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final store = state.catalogStore;
    if (store == null) {
      return Scaffold(
        body: SafeArea(
          child: Column(children: [
            PageHeader(title: 'Каталог', onBack: () => state.setTab(0)),
            Expanded(
              child: EmptyState(
                icon: Icons.storefront_outlined,
                title: state.address == null ? 'Сначала укажите адрес' : 'Рядом нет магазинов',
                text: 'Каталог зависит от того, какие магазины доставляют к вам.',
                action: 'Выбрать адрес',
                onAction: () => openAddressPicker(context),
              ),
            ),
          ]),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.white,
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          PageHeader(
            title: 'Каталог',
            onBack: () => state.setTab(0),
            trailing: RoundIconButton(icon: Icons.search_rounded, onTap: () => openSearch(context)),
          ),
          Expanded(
            child: FutureBuilder<List<CatalogCategory>>(
              future: state.categoriesOf(store),
              builder: (context, snap) {
                final sections = snap.hasData ? catalogSections(snap.data!) : const <({String? id, String title, List<CatalogCategory> tiles})>[];
                for (final s in sections) {
                  _keys.putIfAbsent(s.id, GlobalKey.new);
                }
                return SingleChildScrollView(
                  controller: _scroll,
                  padding: EdgeInsets.only(bottom: tabBottomInset(context)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: AppSearchField(hint: 'Найти во всех магазинах', onTap: () => openSearch(context)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(spacing: 8, runSpacing: 8, children: [
                        AppChip(label: 'Специальные предложения', selected: _active == '_special', onTap: () => _jump('_special', _specialKey)),
                        for (final s in sections) AppChip(label: s.title, selected: _active == s.id, onTap: () => _jump(s.id, _keys[s.id]!)),
                      ]),
                    ),
                    const SizedBox(height: 24),
                    Container(key: _specialKey, child: SpecialOffers(store: store)),
                    if (snap.connectionState != ConnectionState.done)
                      const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
                    else
                      CategorySectionsList(store: store, keys: _keys),
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
      floatingActionButton: _showUp
          ? Padding(
              padding: EdgeInsets.zero,
              child: FloatingActionButton(
                heroTag: 'catalog-up',
                backgroundColor: AppColors.white,
                foregroundColor: AppColors.ink,
                elevation: 6,
                shape: const CircleBorder(),
                onPressed: () => _scroll.animateTo(0, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic),
                child: const Icon(Icons.arrow_upward_rounded, size: 28),
              ),
            )
          : null,
    );
  }
}
