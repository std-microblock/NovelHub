import 'package:flutter_test/flutter_test.dart';
import 'package:novelhub/domain/entities.dart';
import 'package:novelhub/domain/paragraph_doc.dart';

ParagraphDoc _docWith(int count) {
  final chapter = Chapter(
    id: 'c1',
    title: 'ch',
    paragraphs: [
      for (var i = 1; i <= count; i++) Paragraph(id: 'p$i', text: 'line$i'),
    ],
  );
  return ParagraphDoc(chapter);
}

void main() {
  test('getFullText numbers paragraphs 1-based', () {
    final doc = _docWith(3);
    expect(doc.getFullText(), '1 line1\n2 line2\n3 line3');
  });

  group('editRange', () {
    test('edit 12-13 "xxx\\nyyy" replaces two paragraphs with two', () {
      // Build 13 paragraphs.
      final doc = ParagraphDoc(Chapter(
        id: 'c',
        title: 't',
        paragraphs: [for (var i = 1; i <= 13; i++) Paragraph(id: 'p$i', text: 'L$i')],
      ));
      doc.editRange(start: 12, end: 13, newText: 'xxx\nyyy', messageId: 'm1');
      expect(doc.length, 13);
      expect(doc.paragraphs[11].text, 'xxx');
      expect(doc.paragraphs[12].text, 'yyy');
    });

    test('edit single paragraph', () {
      final doc = _docWith(3);
      doc.editRange(start: 2, end: 2, newText: 'replaced', messageId: 'm1');
      expect(doc.paragraphs[1].text, 'replaced');
      expect(doc.length, 3);
    });

    test('edit range can shrink/grow paragraph count', () {
      final doc = _docWith(3);
      // replace 2..3 with three lines -> length becomes 4
      doc.editRange(start: 2, end: 3, newText: 'a\nb\nc', messageId: 'm1');
      expect(doc.length, 4);
      expect(doc.paragraphs.map((p) => p.text).toList(), ['line1', 'a', 'b', 'c']);
    });

    test('out-of-range throws', () {
      final doc = _docWith(3);
      expect(() => doc.editRange(start: 3, end: 5, newText: 'x', messageId: 'm1'),
          throwsA(isA<ParagraphDocException>()));
      expect(() => doc.editRange(start: 0, end: 1, newText: 'x', messageId: 'm1'),
          throwsA(isA<ParagraphDocException>()));
    });
  });

  group('deleteRange', () {
    test('delete middle range', () {
      final doc = _docWith(5);
      doc.deleteRange(start: 2, end: 3, messageId: 'm1');
      expect(doc.length, 3);
      expect(doc.paragraphs.map((p) => p.text).toList(), ['line1', 'line4', 'line5']);
    });
    test('delete first', () {
      final doc = _docWith(3);
      doc.deleteRange(start: 1, end: 1, messageId: 'm1');
      expect(doc.paragraphs.first.text, 'line2');
    });
    test('delete last', () {
      final doc = _docWith(3);
      doc.deleteRange(start: 3, end: 3, messageId: 'm1');
      expect(doc.length, 2);
      expect(doc.paragraphs.last.text, 'line2');
    });
  });

  group('insertAt', () {
    test('insert at 1 prepends', () {
      final doc = _docWith(2);
      doc.insertAt(index: 1, newText: 'head1\nhead2', messageId: 'm1');
      expect(doc.paragraphs.map((p) => p.text).toList(),
          ['head1', 'head2', 'line1', 'line2']);
    });
    test('insert at length+1 appends', () {
      final doc = _docWith(2);
      doc.insertAt(index: 3, newText: 'tail', messageId: 'm1');
      expect(doc.paragraphs.last.text, 'tail');
    });
    test('out-of-range throws', () {
      final doc = _docWith(2);
      expect(() => doc.insertAt(index: 5, newText: 'x', messageId: 'm1'),
          throwsA(isA<ParagraphDocException>()));
    });
  });
}
