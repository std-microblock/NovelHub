import 'package:flutter_test/flutter_test.dart';
import 'package:novelhub/domain/entities.dart';
import 'package:novelhub/domain/novel_doc.dart';

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

void main() {
  test('getFullText prefixes each line with number + display hash', () {
    final doc = _docWith(3);
    // Each line is "N hash text" where hash is the >=4-char unique prefix of
    // hashText(text). Verify the shape and that the numbers + texts survive.
    final out = doc.getFullText('c1');
    final lines = out.split('\n');
    expect(lines.length, 3);
    for (var i = 0; i < lines.length; i++) {
      final m = RegExp(r'^(\d+) ([0-9a-f]{4,}) (.*)$').firstMatch(lines[i])!;
      expect(m.group(1), '${i + 1}');
      expect(m.group(3), 'line${i + 1}');
      // The displayed hash is a prefix of the full hash of the text.
      final full = NovelDoc.hashText('line${i + 1}');
      expect(full.startsWith(m.group(2)!), isTrue);
    }
  });

  test('getFullText hashes are unique within a chapter', () {
    final doc = _docWith(3);
    final hashes = doc.displayHashes('c1');
    expect(hashes.length, 3);
    expect(hashes.toSet().length, 3);
    for (final h in hashes) {
      expect(h.length, greaterThanOrEqualTo(4));
    }
  });

  test('hashText is stable and 8 hex chars', () {
    expect(NovelDoc.hashText('hello'), NovelDoc.hashText('hello'));
    expect(NovelDoc.hashText('hello').length, 8);
    expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(NovelDoc.hashText('hello')), isTrue);
    // Different text → different hash.
    expect(NovelDoc.hashText('hello'), isNot(NovelDoc.hashText('world')));
  });

  group('editParagraphs', () {
    test('edit 12-13 "xxx\\nyyy" replaces two paragraphs with two', () {
      final novel = Novel.create(title: 'n');
      novel.chapters = [
        Chapter(
          id: 'c',
          title: novel.chapters.first.title,
          paragraphs: [
            for (var i = 1; i <= 13; i++) Paragraph(id: 'p$i', text: 'L$i'),
          ],
        ),
      ];
      final doc = NovelDoc(novel);
      doc.editParagraphs(
          chapterId: 'c', start: 12, end: 13, newText: 'xxx\n\nyyy', messageId: 'm1');
      final paras = doc.chapterById('c')!.paragraphs;
      expect(paras.length, 13);
      expect(paras[11].text, 'xxx');
      expect(paras[12].text, 'yyy');
    });

    test('edit single paragraph', () {
      final doc = _docWith(3);
      doc.editParagraphs(
          chapterId: 'c1', start: 2, end: 2, newText: 'replaced', messageId: 'm1');
      final paras = doc.chapterById('c1')!.paragraphs;
      expect(paras[1].text, 'replaced');
      expect(paras.length, 3);
    });

    test('edit range can shrink/grow paragraph count', () {
      final doc = _docWith(3);
      doc.editParagraphs(
          chapterId: 'c1', start: 2, end: 3, newText: 'a\n\nb\n\nc', messageId: 'm1');
      final paras = doc.chapterById('c1')!.paragraphs;
      expect(paras.length, 4);
      expect(paras.map((p) => p.text).toList(), ['line1', 'a', 'b', 'c']);
    });

    test('single newline is a soft wrap, not a paragraph break', () {
      // `\n` alone stays inside one paragraph; only `\n\n` splits.
      final doc = _docWith(2);
      doc.editParagraphs(
          chapterId: 'c1', start: 1, end: 1, newText: 'line one\nstill one', messageId: 'm1');
      final paras = doc.chapterById('c1')!.paragraphs;
      expect(paras.length, 2);
      expect(paras[0].text, 'line one\nstill one');
    });

    test('out-of-range throws', () {
      final doc = _docWith(3);
      expect(
          () => doc.editParagraphs(
              chapterId: 'c1',
              start: 3,
              end: 5,
              newText: 'x',
              messageId: 'm1'),
          throwsA(isA<NovelDocException>()));
      expect(
          () => doc.editParagraphs(
              chapterId: 'c1',
              start: 0,
              end: 1,
              newText: 'x',
              messageId: 'm1'),
          throwsA(isA<NovelDocException>()));
    });
  });

  group('deleteParagraphs', () {
    test('delete middle range', () {
      final doc = _docWith(5);
      doc.deleteParagraphs(chapterId: 'c1', start: 2, end: 3, messageId: 'm1');
      final paras = doc.chapterById('c1')!.paragraphs;
      expect(paras.length, 3);
      expect(paras.map((p) => p.text).toList(), ['line1', 'line4', 'line5']);
    });
    test('delete first', () {
      final doc = _docWith(3);
      doc.deleteParagraphs(chapterId: 'c1', start: 1, end: 1, messageId: 'm1');
      expect(doc.chapterById('c1')!.paragraphs.first.text, 'line2');
    });
    test('delete last', () {
      final doc = _docWith(3);
      doc.deleteParagraphs(chapterId: 'c1', start: 3, end: 3, messageId: 'm1');
      final paras = doc.chapterById('c1')!.paragraphs;
      expect(paras.length, 2);
      expect(paras.last.text, 'line2');
    });
  });

  group('insertParagraphs', () {
    test('insert at 1 prepends', () {
      final doc = _docWith(2);
      doc.insertParagraphs(
          chapterId: 'c1', index: 1, newText: 'head1\n\nhead2', messageId: 'm1');
      expect(doc.chapterById('c1')!.paragraphs.map((p) => p.text).toList(),
          ['head1', 'head2', 'line1', 'line2']);
    });
    test('insert at length+1 appends', () {
      final doc = _docWith(2);
      doc.insertParagraphs(
          chapterId: 'c1', index: 3, newText: 'tail', messageId: 'm1');
      expect(doc.chapterById('c1')!.paragraphs.last.text, 'tail');
    });
    test('null index appends after the last paragraph', () {
      final doc = _docWith(2);
      doc.insertParagraphs(
          chapterId: 'c1', index: null, newText: 'tail1\n\ntail2', messageId: 'm1');
      expect(doc.chapterById('c1')!.paragraphs.map((p) => p.text).toList(),
          ['line1', 'line2', 'tail1', 'tail2']);
    });
    test('out-of-range throws', () {
      final doc = _docWith(2);
      expect(
          () => doc.insertParagraphs(
              chapterId: 'c1', index: 5, newText: 'x', messageId: 'm1'),
          throwsA(isA<NovelDocException>()));
    });
  });

  group('resolveParagraph', () {
    test('by number', () {
      final doc = _docWith(3);
      expect(doc.resolveParagraph(chapterId: 'c1', number: 2), 2);
      expect(() => doc.resolveParagraph(chapterId: 'c1', number: 0),
          throwsA(isA<NovelDocException>()));
      expect(() => doc.resolveParagraph(chapterId: 'c1', number: 4),
          throwsA(isA<NovelDocException>()));
    });

    test('by unique hash prefix', () {
      final doc = _docWith(3);
      final hashes = doc.displayHashes('c1');
      // The hash for paragraph 2 should resolve back to 2.
      expect(doc.resolveParagraph(chapterId: 'c1', hash: hashes[1]), 2);
      // A longer prefix of the same hash also works.
      final full = NovelDoc.hashText('line2');
      expect(doc.resolveParagraph(chapterId: 'c1', hash: full), 2);
    });

    test('by content (exact then substring)', () {
      final doc = _docWith(3);
      // Exact trimmed equality.
      expect(doc.resolveParagraph(chapterId: 'c1', content: 'line2'), 2);
      // Substring containment when not exact.
      expect(doc.resolveParagraph(chapterId: 'c1', content: 'ine3'), 3);
    });

    test('ambiguous content throws', () {
      // line1 / line2 / line3 all contain "line".
      final doc = _docWith(3);
      expect(() => doc.resolveParagraph(chapterId: 'c1', content: 'line'),
          throwsA(isA<NovelDocException>()));
    });

    test('hash matching multiple paragraphs throws', () {
      // Two identical paragraphs → same full hash → no unique prefix.
      final novel = Novel.create(title: 'n');
      novel.chapters = [
        Chapter(
          id: 'c1',
          title: novel.chapters.first.title,
          paragraphs: [
            Paragraph(id: 'p1', text: 'same'),
            Paragraph(id: 'p2', text: 'same'),
          ],
        ),
      ];
      final doc = NovelDoc(novel);
      // displayHashes collapses both to the full 8-char hash (no unique prefix).
      final h = doc.displayHashes('c1').first;
      expect(() => doc.resolveParagraph(chapterId: 'c1', hash: h),
          throwsA(isA<NovelDocException>()));
    });

    test('hash priority over content and number', () {
      final doc = _docWith(3);
      final hashes = doc.displayHashes('c1');
      // Even with a wrong number, hash wins.
      expect(doc.resolveParagraph(
          chapterId: 'c1', hash: hashes[0], number: 3), 1);
    });

    test('nothing provided returns 0', () {
      final doc = _docWith(3);
      expect(doc.resolveParagraph(chapterId: 'c1'), 0);
    });

    test('unknown hash / content throws', () {
      final doc = _docWith(3);
      expect(() => doc.resolveParagraph(chapterId: 'c1', hash: 'zzzzzzzz'),
          throwsA(isA<NovelDocException>()));
      expect(() => doc.resolveParagraph(chapterId: 'c1', content: 'nope-nope'),
          throwsA(isA<NovelDocException>()));
    });
  });

  group('chapter-structure ops', () {
    test('addChapter appends and undo removes', () {
      final doc = _docWith(1);
      final ev = doc.addChapter(title: '第二章', messageId: 'm1');
      expect(doc.novel.chapters.length, 2);
      expect(doc.novel.chapters.last.title, '第二章');
      expect(doc.novel.chapters.last.id, ev.chapterId);
      doc.undo(ev);
      expect(doc.novel.chapters.length, 1);
    });

    test('renameChapter undo restores old title', () {
      final doc = _docWith(1);
      final old = doc.novel.chapters.first.title;
      final ev = doc.renameChapter(chapter: 1, title: '新名', messageId: 'm1');
      expect(doc.novel.chapters.first.title, '新名');
      doc.undo(ev);
      expect(doc.novel.chapters.first.title, old);
    });

    test('deleteChapter refuses last chapter', () {
      final doc = _docWith(1);
      expect(() => doc.deleteChapter(chapter: 1, messageId: 'm1'),
          throwsA(isA<NovelDocException>()));
    });

    test('deleteChapter undo restores chapter + paragraphs', () {
      final doc = _docWith(3, chapterId: 'c1');
      doc.addChapter(title: '第二章', messageId: 'm0');
      expect(doc.novel.chapters.length, 2);
      final ev = doc.deleteChapter(chapter: 'c1', messageId: 'm1');
      expect(doc.novel.chapters.length, 1);
      expect(doc.novel.chapters.first.id, isNot('c1'));
      doc.undo(ev);
      expect(doc.novel.chapters.length, 2);
      expect(doc.novel.chapters.first.id, 'c1');
      expect(doc.novel.chapters.first.paragraphs.length, 3);
    });

    test('moveChapter reorders and undo restores', () {
      final novel = Novel.create(title: 'n');
      novel.chapters = [
        Chapter(id: 'a', title: 'A', paragraphs: [Paragraph.create('')]),
        Chapter(id: 'b', title: 'B', paragraphs: [Paragraph.create('')]),
        Chapter(id: 'c', title: 'C', paragraphs: [Paragraph.create('')]),
      ];
      final doc = NovelDoc(novel);
      final ev = doc.moveChapter(chapter: 'a', toPosition: 3, messageId: 'm1');
      expect(doc.novel.chapters.map((c) => c.id).toList(), ['b', 'c', 'a']);
      doc.undo(ev);
      expect(doc.novel.chapters.map((c) => c.id).toList(), ['a', 'b', 'c']);
    });

    test('resolveChapter accepts id, ordinal, and null', () {
      final doc = _docWith(2, chapterId: 'c1');
      expect(doc.resolveChapter(null, currentChapterId: 'c1')?.id, 'c1');
      expect(doc.resolveChapter(1, currentChapterId: 'c1')?.id, 'c1');
      expect(doc.resolveChapter('c1', currentChapterId: 'c1')?.id, 'c1');
      expect(doc.resolveChapter('nope', currentChapterId: 'c1'), isNull);
    });
  });
}
