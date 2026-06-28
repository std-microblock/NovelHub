import 'package:flutter/material.dart';

import '../../../domain/rich_text.dart';

/// A compact inline badge shown inside the rich-text editor / message bubble
/// for a ref-content (or future) token.
///
/// In the editable composer the badge is tappable ([onTap] opens a dialog
/// showing the referenced content) and optionally closeable ([onClose] removes
/// the token from the draft). In read-only bubbles both are null.
class RefBadge extends StatelessWidget {
  final RichToken token;
  final bool closable;
  final VoidCallback? onClose;
  final VoidCallback? onTap;
  const RefBadge({
    super.key,
    required this.token,
    this.closable = false,
    this.onClose,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final core = Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bookmark, size: 12, color: scheme.onSecondaryContainer),
          const SizedBox(width: 3),
          Text(token.label,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSecondaryContainer)),
          if (closable) ...[
            const SizedBox(width: 2),
            InkWell(
              onTap: onClose,
              child: Icon(Icons.close,
                  size: 12, color: scheme.onSecondaryContainer),
            ),
          ],
        ],
      ),
    );
    if (onTap != null) {
      // Wrap so the whole badge (label + icon) is clickable to view content.
      // The close button keeps its own tap handler and stops propagation.
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: core,
      );
    }
    return core;
  }
}
