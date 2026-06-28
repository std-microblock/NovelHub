/// A [TextEditingController] that renders inline `@@${<json>}$@@` rich-text
/// tokens (from domain/rich_text.dart) as inline badge [WidgetSpan]s while
/// keeping cursor/selection/delete semantics correct.
///
/// The classic "TextEditingController + WidgetSpan" problem: a [WidgetSpan]
/// is a *placeholder* (one U+FFFC) as far as [EditableText] is concerned, but
/// the underlying token is dozens of characters. If the controller's `text`
/// holds the expanded token string, the placeholder count ≠ string length, so
/// every cursor offset, selection and backspace lands in the wrong place
/// (typing after a badge inserts into the middle of the raw token, selection
/// stops at the first `@`, backspace can't delete the whole badge).
///
/// Fix: the controller's `text` holds a *compressed* string where each badge
/// is exactly one U+FFFC character. Literal text is unchanged. We keep a
/// parallel [List<RichToken>] (`_tokens`) whose entries line up, in order, with
/// the U+FFFC characters in the compressed string. [buildTextSpan] emits a
/// [WidgetSpan] per U+FFFC and plain [TextSpan]s for the rest.
///
/// Because compressed length == placeholder count, [EditableText]'s internal
/// representation matches `text` 1:1: typing, selection, copy and backspace
/// all behave correctly. Backspace on a U+FFFC removes one character, and the
/// change-listener re-syncs `_tokens` to the surviving placeholders.
///
/// Conversion to/from the serialized form (`@@${<json>}$@@`) is explicit:
/// [setRichText] parses an expanded string into the compressed form, and
/// [toRichText] re-expands it for persistence / the agent.
library;

import 'package:flutter/widgets.dart';

import '../../../domain/rich_text.dart';

typedef TokenBuilder = Widget Function(RichToken token);

/// The single-character placeholder used to represent one badge in the
/// editable string. U+FFFC OBJECT REPLACEMENT CHARACTER — the same code point
/// [EditableText] treats as a [PlaceholderSpan] position.
const String _placeholder = '￼';

class RichTextEditingController extends TextEditingController {
  /// Builds the inline widget for a token. Required so the controller can
  /// render badges without depending on the UI theme directly.
  TokenBuilder tokenBuilder;

  /// Tokens for each placeholder in the compressed string, in order.
  /// Rebuilt whenever the value changes via [_syncTokensFromValue].
  final List<RichToken> _tokens = [];

  RichTextEditingController({
    required this.tokenBuilder,
    String richText = '',
  }) {
    // Seed value without triggering notifyListeners (no listeners yet).
    final pieces = parseRich(richText);
    final buf = StringBuffer();
    for (final p in pieces) {
      if (p is TextPiece) {
        buf.write(p.text);
      } else if (p is TokenPiece) {
        _tokens.add(p.token);
        buf.write(_placeholder);
      }
    }
    final compressed = buf.toString();
    final seed = TextEditingValue(
      text: compressed,
      selection: TextSelection.collapsed(offset: compressed.length),
    );
    _lastValue = seed;
    super.value = seed;
  }

  /// Load an expanded rich-content string (carrying `@@${<json>}$@@` tokens)
  /// into the controller, replacing the current value.
  void setRichText(String richContent) {
    final pieces = parseRich(richContent);
    final buf = StringBuffer();
    _tokens.clear();
    for (final p in pieces) {
      if (p is TextPiece) {
        buf.write(p.text);
      } else if (p is TokenPiece) {
        _tokens.add(p.token);
        buf.write(_placeholder);
      }
    }
    final compressed = buf.toString();
    final newValue = TextEditingValue(
      text: compressed,
      selection: TextSelection.collapsed(offset: compressed.length),
    );
    _lastValue = newValue; // own mutation: already aligned; skip re-sync
    value = newValue; // fires notifyListeners → no-op sync → UI rebuild
  }

  /// Re-expand the compressed value back into the serialized rich-content
  /// string (badges become `@@${<json>}$@@` again). Used for persistence and
  /// when handing the draft to the agent layer ([toAgentText]).
  String toRichText() {
    final raw = text;
    final buf = StringBuffer();
    var tokenIdx = 0;
    for (final ch in raw.runes) {
      if (ch == 0xFFFC) {
        if (tokenIdx < _tokens.length) {
          buf.write(_tokens[tokenIdx].serialize());
          tokenIdx++;
        }
      } else {
        buf.writeCharCode(ch);
      }
    }
    return buf.toString();
  }

  /// Insert a token at [offset] (compressed offset; defaults to the cursor).
  /// The badge occupies one placeholder; the caret is moved just past it so
  /// typing continues after the badge.
  void insertToken(RichToken token, [int? offset]) {
    final at = offset ??
        selection.baseOffset.clamp(0, text.length).toInt();
    final insertAt = at.clamp(0, text.length).toInt();
    // Walk to find how many placeholders precede insertAt → token slot.
    var slot = 0;
    for (final ch in text.substring(0, insertAt).runes) {
      if (ch == 0xFFFC) slot++;
    }
    _tokens.insert(slot, token);
    final newText =
        text.substring(0, insertAt) + _placeholder + text.substring(insertAt);
    final newValue = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: insertAt + 1),
    );
    _lastValue = newValue; // own mutation: already aligned; skip re-sync
    value = newValue;
  }

  /// Remove the token whose placeholder is at the given compressed index.
  void removeTokenAt(int placeholderIndex) {
    if (placeholderIndex < 0 || placeholderIndex >= _tokens.length) return;
    // Find the char position of the n-th placeholder.
    var seen = 0;
    var charPos = 0;
    for (final ch in text.runes) {
      if (ch == 0xFFFC) {
        if (seen == placeholderIndex) break;
        seen++;
      }
      charPos++;
    }
    if (seen != placeholderIndex) return;
    _tokens.removeAt(placeholderIndex);
    final newText = text.substring(0, charPos) + text.substring(charPos + 1);
    final newValue = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: charPos),
    );
    _lastValue = newValue; // own mutation: already aligned; skip re-sync
    value = newValue;
  }

  /// Remove the first token matching [test].
  void removeTokenWhere(bool Function(RichToken t) test) {
    final i = _tokens.indexWhere(test);
    if (i >= 0) removeTokenAt(i);
  }

  /// Read-only access to the current tokens (in order).
  List<RichToken> get tokens => List.unmodifiable(_tokens);

  TextEditingValue _lastValue = TextEditingValue.empty;

  @override
  void notifyListeners() {
    _syncTokensFromValue();
    super.notifyListeners();
  }

  /// Keep [_tokens] aligned with the placeholders that remain in the value
  /// after user edits. Our own mutators ([setRichText]/[insertToken]/
  /// [removeTokenAt]) update `_tokens` directly and stash the new value in
  /// [_lastValue] before notifying, so for them old==new and this is a no-op.
  /// The cases that matter here are external edits: typing/pasting plain text
  /// around badges, or backspace/delete removing a U+FFFC.
  ///
  /// We locate the changed rune span exactly via longest-common-prefix /
  /// longest-common-suffix between old and new text, then re-attribute tokens:
  /// placeholders *before* the change and *after* the change survive (re-indexed
  /// into the new string); placeholders *inside* the replaced span are gone and
  /// their tokens are dropped. This handles every edit shape correctly — typing
  /// before/after a badge (change span has no placeholder → token kept),
  /// backspace on a placeholder (change span contains exactly that placeholder
  /// → token dropped), and multi-char paste/replace.
  void _syncTokensFromValue() {
    final current = value;
    if (current.text == _lastValue.text) {
      _lastValue = current;
      return;
    }
    final oldTokens = List<RichToken>.from(_tokens);
    final oldRunes = _lastValue.text.runes.toList();
    final newRunes = current.text.runes.toList();

    // Longest common prefix.
    var prefix = 0;
    while (prefix < oldRunes.length &&
        prefix < newRunes.length &&
        oldRunes[prefix] == newRunes[prefix]) {
      prefix++;
    }
    // Longest common suffix (not overlapping the prefix).
    var suffix = 0;
    while (suffix < (oldRunes.length - prefix) &&
        suffix < (newRunes.length - prefix) &&
        oldRunes[oldRunes.length - 1 - suffix] ==
            newRunes[newRunes.length - 1 - suffix]) {
      suffix++;
    }

    // Changed region in old: [oldStart, oldEnd). Placeholders here were replaced
    // (deleted); their tokens are dropped. Prefix/suffix placeholders survive.
    final oldStart = prefix;
    final oldEnd = oldRunes.length - suffix;

    int countPh(int from, int to) {
      var c = 0;
      for (var i = from; i < to; i++) {
        if (oldRunes[i] == 0xFFFC) c++;
      }
      return c;
    }

    final prefixCount = countPh(0, oldStart);
    final middleCount = countPh(oldStart, oldEnd);
    final suffixStart = prefixCount + middleCount;

    final newTokens = <RichToken>[];
    for (var i = 0; i < prefixCount && i < oldTokens.length; i++) {
      newTokens.add(oldTokens[i]);
    }
    // Middle tokens (prefixCount .. suffixStart) are dropped.
    for (var i = suffixStart; i < oldTokens.length; i++) {
      newTokens.add(oldTokens[i]);
    }

    _tokens
      ..clear()
      ..addAll(newTokens);
    _lastValue = current;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final raw = text;
    if (_tokens.isEmpty && !raw.contains(_placeholder)) {
      return TextSpan(text: raw, style: style);
    }
    final children = <InlineSpan>[];
    var tokenIdx = 0;
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        children.add(TextSpan(text: buf.toString(), style: style));
        buf.clear();
      }
    }

    for (final ch in raw.runes) {
      if (ch == 0xFFFC) {
        flush();
        final t = tokenIdx < _tokens.length ? _tokens[tokenIdx] : null;
        tokenIdx++;
        if (t != null) {
          children.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: tokenBuilder(t),
          ));
        } else {
          // Orphan placeholder (no token): render as nothing visible.
          children.add(const WidgetSpan(child: SizedBox.shrink()));
        }
      } else {
        buf.writeCharCode(ch);
      }
    }
    flush();
    if (children.isEmpty) return TextSpan(text: '', style: style);
    return TextSpan(style: style, children: children);
  }
}
