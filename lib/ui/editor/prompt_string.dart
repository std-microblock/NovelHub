import 'package:flutter/material.dart';

/// A small reusable string-input dialog. Returns the trimmed value, or null
/// if the user cancels / submits empty.
///
/// Used by the chapter- and novel-management popups (rename, create) so they
/// share one consistent input affordance instead of duplicating the
/// AlertDialog + TextField boilerplate.
Future<String?> promptString(
  BuildContext context, {
  required String title,
  String? hint,
  String? initial,
  String confirmLabel = '确定',
  int? minLines,
  int? maxLines,
  bool selectAll = true,
}) async {
  final ctrl = TextEditingController(text: initial ?? '');
  if (selectAll && initial != null && initial.isNotEmpty) {
    ctrl.selection =
        TextSelection(baseOffset: 0, extentOffset: initial.length);
  }
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        minLines: minLines,
        maxLines: maxLines,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, ctrl.text.trim()),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}
