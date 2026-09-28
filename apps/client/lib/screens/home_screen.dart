import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../map_view.dart';
import '../state.dart';
import 'addresses_screen.dart';
import 'cart_screen.dart';
import 'orders_screen.dart';
import 'store_screen.dart';

/// Магазины, которые доставляют по выбранному адресу.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<List<Map<String, dynamic>>>? _stores;
  String? _loadedFor;
  bool _map = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final state = context.read<AppState>();
    try {
      await state.loadAddresses();
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _reload(Address a) {
    _loadedFor = a.id;
    _stores = context.read<Api>().list('/client/stores/nearby', {'lat': a.lat, 'lng': a.lng});
  }

  Future<void> _addAddress() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressEditScreen()));
    if (mounted) await context.read<AppState>().loadAddresses();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final address = state.address;
    if (address != null && _loadedFor != address.id) _reload(address);

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressesScreen())),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_outlined, size: 20),
              const SizedBox(width: 4),
              Flexible(child: Text(address?.title ?? 'Адрес доставки', overflow: TextOverflow.ellipsis)),
              const Icon(Icons.expand_more),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Мои заказы',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OrdersScreen())),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') context.read<Api>().logout();
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'logout', child: Text('Выйти'))],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : address == null
              ? _NoAddress(onAdd: _addAddress)
              : FutureBuilder<List<Map<String, dynamic>>>(
                  future: _stores,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return _Retry(message: snap.error.toString(), onRetry: () => setState(() => _reload(address)));
                    }
                    final stores = snap.data!;
                    if (stores.isEmpty) {
                      return const _Empty(
                        icon: Icons.storefront_outlined,
                        text: 'По этому адресу пока никто не доставляет. Попробуйте другой адрес.',
                      );
                    }
                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, icon: Icon(Icons.list), label: Text('Списком')),
                              ButtonSegment(value: true, icon: Icon(Icons.map_outlined), label: Text('На карте')),
                            ],
                            selected: {_map},
                            onSelectionChanged: (s) => setState(() => _map = s.first),
                          ),
                        ),
                        Expanded(
                          child: _map
                              ? StoresMap(
                                  center: (lat: address.lat, lng: address.lng),
                                  markers: [
                                    for (final s in stores)
                                      MapMarker(
                                        id: s['id'] as String,
                                        lat: (s['lat'] as num).toDouble(),
                                        lng: (s['lng'] as num).toDouble(),
                                        highlight: s['recommended'] == true,
                                        onTap: () => _openStore(s),
                                      ),
                                  ],
                                )
                              : RefreshIndicator(
                                  onRefresh: () async {
                                    setState(() => _reload(address));
                                    await _stores;
                                  },
                                  child: ListView.builder(
                                    padding: const EdgeInsets.all(12),
                                    itemCount: stores.length,
                                    itemBuilder: (_, i) => _StoreCard(store: stores[i], onTap: () => _openStore(stores[i])),
                                  ),
                                ),
                        ),
                      ],
                    );
                  },
                ),
      bottomNavigationBar: const CartBar(),
    );
  }

  void _openStore(Map<String, dynamic> store) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoreScreen(store: store)));
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({required this.store, required this.onTap});
  final Map<String, dynamic> store;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = store['delivery'] as Map<String, dynamic>;
    final open = d['is_open'] == true;
    final km = ((d['distance_m'] as num) / 1000).toStringAsFixed(1);
    final fee = num.tryParse('${d['delivery_fee']}') ?? 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(store['name'] as String, style: theme.textTheme.titleMedium)),
                  if (store['recommended'] == true)
                    Chip(
                      label: const Text('Рядом'),
                      avatar: const Icon(Icons.star, size: 16),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: theme.colorScheme.primaryContainer,
                    ),
                ],
              ),
              Text('${store['network_name']} · ${store['address'] ?? ''}', style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _Info(Icons.near_me_outlined, '$km км'),
                  _Info(Icons.delivery_dining_outlined, fee == 0 ? 'Доставка бесплатно' : 'Доставка ${money(fee)}'),
                  if ((num.tryParse('${d['min_order_amount']}') ?? 0) > 0) _Info(Icons.shopping_basket_outlined, 'от ${money(d['min_order_amount'])}'),
                  _Info(open ? Icons.schedule : Icons.do_not_disturb_on_outlined, open ? 'Открыт' : 'Закрыт',
                      color: open ? null : theme.colorScheme.error),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.icon, this.text, {this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 4),
      Text(text, style: TextStyle(color: color)),
    ]);
  }
}

class _NoAddress extends StatelessWidget {
  const _NoAddress({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.add_location_alt_outlined, size: 64),
          const SizedBox(height: 16),
          const Text('Укажите адрес доставки — покажем магазины рядом', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onAdd, child: const Text('Добавить адрес')),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 64),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRetry, child: const Text('Повторить')),
      ]),
    );
  }
}

/// Полоса корзины внизу экрана.
class CartBar extends StatelessWidget {
  const CartBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.cartCount == 0) return const SizedBox.shrink();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CartScreen())),
          child: Row(children: [
            const Icon(Icons.shopping_cart_outlined),
            const SizedBox(width: 8),
            Expanded(child: Text('Корзина · ${state.cartStoreName ?? ''}', overflow: TextOverflow.ellipsis)),
            Text(money(state.cartTotal)),
          ]),
        ),
      ),
    );
  }
}
