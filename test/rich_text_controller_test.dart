import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelhub/domain/rich_text.dart';
import 'package:novelhub/ui/editor/agent/rich_text_controller.dart';

RichToken _ref(String label) => RichToken.refContent(
      chapter: 'C',
      start: 1,
      end: 1,
      content: '1 $label',
      id: label,
    );

void main() {
  group('RichTextEditingController', () {
    test('setRichText / toRichText round-trip', () {
      final token = _ref('t1').serialize();
      final content = '前$token 后';
      final c = RichTextEditingController(
        richText: content,
        tokenBuilder: (t) => const SizedBox.shrink(),
      );
      expect(c.toRichText(), content);
      // Compressed string has exactly one placeholder per token.
      expect(c.text.length, '前'.length + 1 + ' 后'.length);
    });

    test('insertToken places caret after badge and offsets are compressed', () {
      final c = RichTextEditingController(
        richText: 'ab',
        tokenBuilder: (t) => const SizedBox.shrink(),
      );
      c.insertToken(_ref('x'), 1); // between 'a' and 'b'
      // Compressed: a ￼ b → length 3, caret at 2 (after the badge).
      expect(c.text, 'a￼b');
      expect(c.selection.baseOffset, 2);
      expect(c.toRichText(), 'a${_ref('x').serialize()}b');
      // The serialized token (dozens of chars) does NOT inflate the
      // compressed length: this is the property that keeps cursor/selection
      // offsets correct.
      expect(c.text.length, 3);
    });

    test('backspace on a placeholder drops the token via sync', () {
      final c = RichTextEditingController(
        richText: 'a${_ref('t1').serialize()}b${_ref('t2').serialize()}c',
        tokenBuilder: (t) => const SizedBox.shrink(),
      );
      expect(c.tokens.length, 2);
      // Compressed form is 'a￼b￼c'; deleting the first placeholder → 'ab￼c'.
      final compressed = c.text;
      expect(compressed, 'a￼b￼c');
      final phIndex = compressed.indexOf('￼'); // index 1
      c.value = TextEditingValue(
        text: compressed.substring(0, phIndex) + compressed.substring(phIndex + 1),
        selection: TextSelection.collapsed(offset: phIndex),
      );
      // First token is dropped; second survives.
      expect(c.tokens.length, 1);
      expect(c.tokens.single.data['id'], 't2');
      expect(c.toRichText(), 'ab${_ref('t2').serialize()}c');
    });

    test('typing plain text before a badge keeps the token', () {
      final c = RichTextEditingController(
        richText: '${_ref('t1').serialize()}b',
        tokenBuilder: (t) => const SizedBox.shrink(),
      );
      // Compressed '￼b', caret at 0 (just before the badge). Type 'X' → 'X￼b'.
      final compressed = c.text; // '￼b'
      c.value = TextEditingValue(
        text: 'X$compressed',
        selection: const TextSelection.collapsed(offset: 1),
      );
      expect(c.tokens.length, 1);
      expect(c.tokens.single.data['id'], 't1');
      expect(c.toRichText(), 'X${_ref('t1').serialize()}b');
    });

    test('typing plain text around badges keeps tokens aligned', () {
      final c = RichTextEditingController(
        richText: 'a${_ref('t1').serialize()}b',
        tokenBuilder: (t) => const SizedBox.shrink(),
      );
      // Insert plain text 'XY' right after the badge (compressed pos 2).
      final compressed = c.text; // 'a￼b'
      c.value = TextEditingValue(
        text: '${compressed.substring(0, 2)}XY${compressed.substring(2)}',
        selection: const TextSelection.collapsed(offset: 4),
      );
      expect(c.tokens.length, 1);
      expect(c.tokens.single.data['id'], 't1');
      expect(c.toRichText(), 'a${_ref('t1').serialize()}XYb');
    });

    test('removeTokenAt removes the right badge', () {
      final c = RichTextEditingController(
        richText: '${_ref('a').serialize()}${_ref('b').serialize()}',
        tokenBuilder: (t) => const SizedBox.shrink(),
      );
      expect(c.tokens.map((t) => t.data['id']), ['a', 'b']);
      c.removeTokenAt(0);
      expect(c.tokens.single.data['id'], 'b');
      expect(c.toRichText(), _ref('b').serialize());
    });

    test('backspace before a badge deletes preceding text, keeps badge', () {
      // 'x￼' → caret after badge, backspace deletes badge? No: start with
      // 'xy￼' and delete the 'y' before the badge. Change region is just 'y'.
      final c = RichTextEditingController(
        richText: 'xy${_ref('t1').serialize()}',
        tokenBuilder: (t) => const SizedBox.shrink(),
      );
      // Compressed 'xy￼'; delete the 'y' (index 1) → 'x￼'.
      final compressed = c.text;
      c.value = TextEditingValue(
        text: 'x${compressed.substring(2)}',
        selection: const TextSelection.collapsed(offset: 1),
      );
      expect(c.tokens.length, 1);
      expect(c.tokens.single.data['id'], 't1');
      expect(c.toRichText(), 'x${_ref('t1').serialize()}');
    });

    test('insert between two badges keeps both', () {
      final c = RichTextEditingController(
        richText: '${_ref('a').serialize()}${_ref('b').serialize()}',
        tokenBuilder: (t) => const SizedBox.shrink(),
      );
      // Compressed '￼￼'; insert 'Z' between the two badges.
      c.value = const TextEditingValue(
        text: '￼Z￼',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(c.tokens.map((t) => t.data['id']), ['a', 'b']);
      expect(c.toRichText(), '${_ref('a').serialize()}Z${_ref('b').serialize()}');
    });
  });
}
