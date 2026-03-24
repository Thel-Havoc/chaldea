/// Shared UI helpers for roster input pages.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A TextField that selects all text when it gains focus (via tap or tab).
/// Saves the user from having to triple-click to replace a value.
class IntField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final int min;
  final int max;

  const IntField(
    this.controller,
    this.label, {
    super.key,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        helperText: '$min–$max',
      ),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onTap: () => controller.selection =
          TextSelection(baseOffset: 0, extentOffset: controller.text.length),
    );
  }
}
