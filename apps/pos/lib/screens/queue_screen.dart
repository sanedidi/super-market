import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../pos_state.dart';

/// Продажи, которые ещё не дошли до сервера.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Не отправленные продажи'),
        actions: [
          IconButton(
            tooltip: 'Отправить сейчас',
            icon: pos.syncing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync),
            onPressed: pos.syncing ? null : pos.sync,
          ),
        ],
      ),
      body: pos.queue.isEmpty
          ? const Center(child: Text('Все продажи отправлены'))
          : ListView(children: [
              for (final q in pos.queue)
                ListTile(
                  title: Text('${dateTime(q.body['sold_at'])} · ${money(addMoney((q.body['payments'] as List).map((p) => (p as Map)['amount'] as String)))}'),
                  subtitle: Text(q.error ?? 'Ждёт связи', style: TextStyle(color: q.error != null ? Theme.of(context).colorScheme.error : null)),
                  trailing: q.error == null
                      ? null
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(tooltip: 'Повторить', icon: const Icon(Icons.refresh), onPressed: () => pos.retry(q)),
                          IconButton(
                            tooltip: 'Удалить',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Удалить продажу?'),
                                  content: const Text('Сервер её отклонил. Деньги по ней нужно учесть вручную.'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Нет')),
                                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
                                  ],
                                ),
                              );
                              if (ok == true) await pos.drop(q);
                            },
                          ),
                        ]),
                ),
            ]),
    );
  }
}
