import 'package:flutter/material.dart';

import 'api.dart';

/// Вход по номеру телефона и коду из Telegram-бота.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, required this.title, this.subtitle, this.onOpenUrl});

  final Api api;
  final String title;
  final String? subtitle;

  /// Открыть ссылку на бота (url_launcher в приложении).
  final void Function(String url)? onOpenUrl;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController(text: '+998 ');
  final _code = TextEditingController();
  bool _codeStep = false;
  bool _busy = false;
  String? _error;
  String? _botUrl;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    setState(() {
      _busy = true;
      _error = null;
      _botUrl = null;
    });
    try {
      await widget.api.requestCode(_phone.text);
      setState(() => _codeStep = true);
    } on ApiError catch (e) {
      setState(() {
        _error = e.message;
        if (e.code == 'telegram_not_linked') _botUrl = e.details['bot_url'] as String?;
        if (e.code == 'too_many_requests') _codeStep = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.verifyCode(_phone.text, _code.text);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(widget.title, style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: 8),
                    Text(widget.subtitle!, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 32),
                  if (!_codeStep) ...[
                    TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Номер телефона', border: OutlineInputBorder()),
                      onSubmitted: (_) => _request(),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _request,
                      child: Text(_busy ? 'Отправляем…' : 'Получить код в Telegram'),
                    ),
                  ] else ...[
                    Text('Код отправлен в Telegram-бот на номер ${_phone.text}', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      maxLength: 6,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                      decoration: const InputDecoration(labelText: 'Код', border: OutlineInputBorder(), counterText: ''),
                      onSubmitted: (_) => _verify(),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _busy ? null : _verify, child: Text(_busy ? 'Проверяем…' : 'Войти')),
                    TextButton(onPressed: () => setState(() => _codeStep = false), child: const Text('Другой номер')),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
                  ],
                  if (_botUrl != null && widget.onOpenUrl != null)
                    TextButton.icon(
                      onPressed: () => widget.onOpenUrl!(_botUrl!),
                      icon: const Icon(Icons.send),
                      label: const Text('Открыть бота и поделиться номером'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
