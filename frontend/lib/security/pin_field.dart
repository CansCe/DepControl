import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'pin_store.dart';

/// The one place a PIN is typed — the lock screen and the settings screen use
/// the same field, so a PIN is entered the same way wherever it is asked for.
///
/// A real text field rather than a grid of tap targets. This app runs in a
/// browser on a keyboard, and a custom keypad would mean the digits people
/// actually have under their fingers do nothing.
class PinField extends StatelessWidget {
  const PinField({
    required this.controller,
    required this.onSubmit,
    this.label = 'PIN',
    this.autofocus = true,
    this.enabled = true,
    this.errorText,
    super.key,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final String label;
  final bool autofocus;
  final bool enabled;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: enabled,
      obscureText: true,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      maxLength: PinStore.maxLength,
      // Digits only, enforced at the keystroke rather than at submit: a field
      // that silently accepts letters and rejects them afterwards is a field
      // that has wasted someone's time.
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: mono(theme.textTheme.headlineSmall).copyWith(letterSpacing: 8),
      onSubmitted: (_) => onSubmit(),
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        errorText: errorText,
        errorMaxLines: 3,
        prefixIcon: const Icon(Icons.pin_outlined, size: 20),
      ),
    );
  }
}
