import 'package:flutter_test/flutter_test.dart';
import 'package:novelhub/domain/entities.dart';
import 'package:novelhub/domain/paragraph_doc.dart';
import 'package:novelhub/domain/timeline.dart';

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
  test('revertTo undoes events after the target message', () {
    final doc = _docWith(3);
    final timeline = Timeline(doc);

    doc.editRange(start: 1, end: 1, newText: 'A', messageId: 'm1');
    doc.editRange(start: 2, end: 2, newText: 'B', messageId: 'm2');
    doc.editRange(start: 3, end: 3, newText: 'C', messageId: 'm3');

    // After 3 edits.
    expect(doc.paragraphs.map((p) => p.text).toList(), ['A', 'B', 'C']);

    // Revert to the state right after m1 (undo m2, m3).
    timeline.revertTo('m1');
    expect(doc.paragraphs.map((p) => p.text).toList(), ['A', 'line2', 'line3']);
  });

  test('revertTo includeMessage undoes the target message too', () {
    final doc = _docWith(3);
    final timeline = Timeline(doc);

    doc.editRange(start: 1, end: 1, newText: 'A', messageId: 'm1');
    doc.editRange(start: 2, end: 2, newText: 'B', messageId: 'm2');

    timeline.revertTo('m1', includeMessage: true);
    // includeMessage undoes m1 AND m2 → back to original.
    expect(doc.paragraphs.map((p) => p.text).toList(), ['line1', 'line2', 'line3']);
  });

  test('revertTo with deletions restores count', () {
    final doc = _docWith(5);
    final timeline = Timeline(doc);
    doc.deleteRange(start: 1, end: 1, messageId: 'm1');
    doc.deleteRange(start: 1, end: 1, messageId: 'm2');
    expect(doc.length, 3);
    timeline.revertTo('m1'); // undo m2 only
    expect(doc.length, 4);
    expect(doc.paragraphs.first.text, 'line2');
  });

  test('revertTo with insertions removes inserted paragraphs', () {
    final doc = _docWith(1);
    final timeline = Timeline(doc);
    doc.insertAt(index: 1, newText: 'x\ny', messageId: 'm1');
    expect(doc.length, 3);
    timeline.revertTo('m1', includeMessage: true);
    expect(doc.length, 1);
    expect(doc.paragraphs.first.text, 'line1');
  });
}
