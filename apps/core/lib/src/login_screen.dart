import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'phone.dart';

/// Вход по номеру телефона и коду из Telegram-бота
/// (Figma «Магазин · приложение» → В1, В2).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, required this.title, this.subtitle, this.onOpenUrl, this.logo, this.note});

  final Api api;
  final String title;
  final String? subtitle;

  /// Открыть ссылку на бота (url_launcher в приложении).
  final void Function(String url)? onOpenUrl;

  /// Логотип над заголовком.
  final Widget? logo;

  /// Подсказка под кнопкой («Дальше — код из 4 цифр или Face ID»).
  final String? note;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

const _ink = Color(0xFF151515);
const _text2 = Color(0xFF6B6B70);
const _line = Color(0xFFE8E8EB);

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  bool _codeStep = false;
  bool _busy = false;
  String? _error;
  String? _botUrl;
  int _resendIn = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  String get _full => normalizeUzPhone(_phone.text) ?? '';

  void _startTimer() {
    _timer?.cancel();
    setState(() => _resendIn = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _resendIn <= 1) {
        t.cancel();
        if (mounted) setState(() => _resendIn = 0);
        return;
      }
      setState(() => _resendIn--);
    });
  }

  Future<void> _request() async {
    if (_full.isEmpty) {
      setState(() => _error = 'Введите номер полностью: 9 цифр после +998');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _botUrl = null;
    });
    try {
      await widget.api.requestCode(_full);
      if (!mounted) return;
      _code.clear();
      setState(() => _codeStep = true);
      _startTimer();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        if (e.code == 'telegram_not_linked') _botUrl = e.details['bot_url'] as String?;
        if (e.code == 'too_many_requests') _codeStep = true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_code.text.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.verifyCode(_full, _code.text);
    } on ApiError catch (e) {
      if (!mounted) return;
      _code.clear();
      setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _codeStep ? _codeView(context) : _phoneView(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _phoneView(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.logo != null) ...[Align(alignment: Alignment.centerLeft, child: widget.logo!), const SizedBox(height: 16)],
      Text(widget.title, style: const TextStyle(fontSize: 28, height: 1.2, fontWeight: FontWeight.w700, color: _ink)),
      if (widget.subtitle != null) ...[
        const SizedBox(height: 6),
        Text(widget.subtitle!, style: const TextStyle(fontSize: 15, height: 1.4, color: _text2)),
      ],
      const SizedBox(height: 24),
      const Text('Номер телефона', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: _text2)),
      const SizedBox(height: 8),
      PhoneField(
        controller: _phone,
        autofocus: true,
        enabled: !_busy,
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _request(),
      ),
      const SizedBox(height: 16),
      _Button(label: 'Получить код', icon: Icons.send_rounded, busy: _busy, onPressed: _full.isEmpty ? null : _request),
      ..._errorBlock(context),
      if (widget.note != null) ...[const SizedBox(height: 16), _Note(widget.note!)],
    ]);
  }

  Widget _codeView(BuildContext context) {
    final shown = '+998 ${formatUzLocal(_phone.text)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        IconButton.filledTonal(
          onPressed: () => setState(() {
            _codeStep = false;
            _error = null;
          }),
          style: IconButton.styleFrom(backgroundColor: Colors.white, fixedSize: const Size(44, 44)),
          icon: const Icon(Icons.arrow_back_rounded, color: _ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Вход', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _ink)),
            Text(shown, style: const TextStyle(fontSize: 13, color: _text2)),
          ]),
        ),
      ]),
      const SizedBox(height: 24),
      const Text('Код из Telegram', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _ink)),
      const SizedBox(height: 8),
      Text('Бот Super Market прислал 6 цифр на номер $shown.', style: const TextStyle(fontSize: 15, height: 1.4, color: _text2)),
      const SizedBox(height: 20),
      CodeBoxes(
        controller: _code,
        focusNode: _codeFocus,
        error: _error != null,
        onCompleted: (_) => _verify(),
        onChanged: (_) => setState(() => _error = null),
      ),
      if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: Center(child: CircularProgressIndicator())),
      ..._errorBlock(context),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: _resendIn > 0
              ? Text('Отправить ещё раз через 0:${_resendIn.toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 14, color: _text2))
              : TextButton(
                  onPressed: _busy ? null : _request,
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                  child: const Text('Отправить код ещё раз'),
                ),
        ),
      ]),
    ]);
  }

  List<Widget> _errorBlock(BuildContext context) => [
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.error)),
        ],
        if (_botUrl != null && widget.onOpenUrl != null)
          TextButton.icon(
            onPressed: () => widget.onOpenUrl!(_botUrl!),
            icon: const Icon(Icons.send),
            label: const Text('Открыть бота и поделиться номером'),
          ),
      ];
}

/// 6 клеток кода: ввод через одно скрытое поле, проверка сразу после последней цифры.
class CodeBoxes extends StatelessWidget {
  const CodeBoxes({super.key, required this.controller, required this.focusNode, this.length = 6, this.error = false, this.onCompleted, this.onChanged});

  final TextEditingController controller;
  final FocusNode focusNode;
  final int length;
  final bool error;
  final ValueChanged<String>? onCompleted;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: true,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(length)],
      showCursor: false,
      enableInteractiveSelection: false,
      decoration: const InputDecoration(border: InputBorder.none, filled: false, counterText: ''),
      onChanged: (v) {
        onChanged?.call(v);
        if (v.length == length) onCompleted?.call(v);
      },
    );
    return SizedBox(
      height: 60,
      child: Stack(fit: StackFit.expand, children: [
        ListenableBuilder(
          listenable: Listenable.merge([controller, focusNode]),
          builder: (context, _) {
            final v = controller.text;
            return Row(children: [
              for (var i = 0; i < length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: error ? theme.colorScheme.error : (focusNode.hasFocus && i == v.length ? _ink : _line),
                        width: error || (focusNode.hasFocus && i == v.length) ? 2 : 1,
                      ),
                    ),
                    child: Text(i < v.length ? v[i] : '', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _ink)),
                  ),
                ),
              ],
            ]);
          },
        ),
        // Прозрачное поле поверх клеток: тап открывает клавиатуру, работает вставка кода.
        Opacity(opacity: 0, child: field),
      ]),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.label, required this.onPressed, this.icon, this.busy = false});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton.icon(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        icon: busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)) : Icon(icon, size: 20),
        label: Text(label),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFEEF3FB), borderRadius: BorderRadius.circular(20)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_rounded, size: 20, color: Color(0xFF3B6FD8)),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.35, color: _ink))),
      ]),
    );
  }
}
