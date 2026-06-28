import 'package:flutter_test/flutter_test.dart';
import 'package:novelhub/domain/entities.dart';
import 'package:novelhub/domain/novel_doc.dart';
import 'package:novelhub/domain/timeline.dart';

NovelDoc _docWith(int count, {String chapterId = 'c1'}) {
  final novel = Novel.create(title: 'n');
  novel.chapters = [
    Chapter(
      id: chapterId,
      title: novel.chapters.first.title,
      paragraphs: [
        for (var i = 1; i <= count; i++) Paragraph(id: 'p$i', text: 'line$i'),
      ],
    ),
  ];
  return NovelDoc(novel);
}

List<String> _texts(NovelDoc doc, {String chapterId = 'c1'}) =>
    doc.chapterById(chapterId)!.paragraphs.map((p) => p.text).toList();

void main() {
  test('revertTo undoes events after the target message', () {
    final doc = _docWith(3);
    final timeline = Timeline(doc);

    doc.editParagraphs(chapterId: 'c1', start: 1, end: 1, newText: 'A', messageId: 'm1');
    doc.editParagraphs(chapterId: 'c1', start: 2, end: 2, newText: 'B', messageId: 'm2');
    doc.editParagraphs(chapterId: 'c1', start: 3, end: 3, newText: 'C', messageId: 'm3');

    expect(_texts(doc), ['A', 'B', 'C']);
    timeline.revertTo('m1');
    expect(_texts(doc), ['A', 'line2', 'line3']);
  });

  test('revertTo includeMessage undoes the target message too', () {
    final doc = _docWith(3);
    final timeline = Timeline(doc);
    doc.editParagraphs(chapterId: 'c1', start: 1, end: 1, newText: 'A', messageId: 'm1');
    doc.editParagraphs(chapterId: 'c1', start: 2, end: 2, newText: 'B', messageId: 'm2');
    timeline.revertTo('m1', includeMessage: true);
    expect(_texts(doc), ['line1', 'line2', 'line3']);
  });

  test('revertTo with deletions restores count', () {
    final doc = _docWith(5);
    final timeline = Timeline(doc);
    doc.deleteParagraphs(chapterId: 'c1', start: 1, end: 1, messageId: 'm1');
    doc.deleteParagraphs(chapterId: 'c1', start: 1, end: 1, messageId: 'm2');
    expect(doc.chapterById('c1')!.paragraphs.length, 3);
    timeline.revertTo('m1');
    expect(doc.chapterById('c1')!.paragraphs.length, 4);
    expect(doc.chapterById('c1')!.paragraphs.first.text, 'line2');
  });

  test('revertTo with insertions removes inserted paragraphs', () {
    final doc = _docWith(1);
    final timeline = Timeline(doc);
    doc.insertParagraphs(chapterId: 'c1', index: 1, newText: 'x\ny', messageId: 'm1');
    expect(doc.chapterById('c1')!.paragraphs.length, 3);
    timeline.revertTo('m1', includeMessage: true);
    expect(doc.chapterById('c1')!.paragraphs.length, 1);
    expect(doc.chapterById('c1')!.paragraphs.first.text, 'line1');
  });

  test('revertTo undoes cross-chapter paragraph writes', () {
    // Two chapters; agent edits both in the same turn (messageId m1).
    final novel = Novel.create(title: 'n');
    novel.chapters = [
      Chapter(id: 'c1', title: 'A', paragraphs: [Paragraph(id: 'p1', text: 'one')]),
      Chapter(id: 'c2', title: 'B', paragraphs: [Paragraph(id: 'q1', text: 'two')]),
    ];
    final doc = NovelDoc(novel);
    final timeline = Timeline(doc);

    doc.editParagraphs(chapterId: 'c1', start: 1, end: 1, newText: 'ONE', messageId: 'm1');
    doc.editParagraphs(chapterId: 'c2', start: 1, end: 1, newText: 'TWO', messageId: 'm1');

    expect(_texts(doc, chapterId: 'c1'), ['ONE']);
    expect(_texts(doc, chapterId: 'c2'), ['TWO']);

    timeline.revertTo('m1', includeMessage: true);
    expect(_texts(doc, chapterId: 'c1'), ['one']);
    expect(_texts(doc, chapterId: 'c2'), ['two']);
  });

  test('revertTo undoes chapter-structure ops in one turn', () {
    final doc = _docWith(2, chapterId: 'c1');
    final timeline = Timeline(doc);

    doc.addChapter(title: '第二章', messageId: 'm1'); // add
    doc.renameChapter(chapter: 'c1', title: '改名', messageId: 'm1'); // rename
    doc.moveChapter(chapter: 'c1', toPosition: 2, messageId: 'm1'); // move

    expect(doc.novel.chapters.length, 2);
    expect(doc.novel.chapters.first.id, isNot('c1'));

    timeline.revertTo('m1', includeMessage: true);
    // Back to single chapter c1 with original title + order.
    expect(doc.novel.chapters.length, 1);
    expect(doc.novel.chapters.first.id, 'c1');
  });

  test('revertTo with mixed paragraph + chapter-structure ops', () {
    final doc = _docWith(2, chapterId: 'c1');
    final timeline = Timeline(doc);

    doc.editParagraphs(chapterId: 'c1', start: 1, end: 1, newText: 'X', messageId: 'm1');
    doc.addChapter(title: '第二章', messageId: 'm1');
    doc.deleteChapter(chapter: 'c1', messageId: 'm1');

    // c1 deleted, second chapter remains.
    expect(doc.novel.chapters.length, 1);
    expect(doc.novel.chapters.first.id, isNot('c1'));

    timeline.revertTo('m1', includeMessage: true);
    // c1 restored with original paragraphs (edit undone + delete undone +
    // add undone → back to 2 paragraphs "line1","line2").
    expect(doc.novel.chapters.length, 1);
    expect(doc.novel.chapters.first.id, 'c1');
    expect(_texts(doc), ['line1', 'line2']);
  });
}
