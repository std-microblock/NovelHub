import 'package:flutter_test/flutter_test.dart';
import 'package:novelhub/domain/rich_text.dart';

void main() {
  group('rich_text', () {
    test('plain text round-trips', () {
      const content = '把这几段重写了';
      expect(toAgentText(content), '把这几段重写了');
    });

    test('ref token becomes inline marker + appended content', () {
      final token = RichToken.refContent(
        chapter: '第一章',
        start: 3,
        end: 6,
        content: '3 aaa\n4 bbb\n5 ccc\n6 ddd',
      ).serialize();
      final content = '把$token这几段重写了，注意要回收'
          '${RichToken.refContent(chapter: '第一章', start: 1, end: 2, content: '1 xxx\n2 yyy').serialize()}'
          '的伏笔';
      final out = toAgentText(content);
      // Inline tokens become readable markers.
      expect(out, contains('[ref: 第一章 3~6 段]'));
      expect(out, contains('[ref: 第一章 1~2 段]'));
      // Actual referenced content appended at the end.
      expect(out, contains('第一章 3~6 段：\n3 aaa\n4 bbb\n5 ccc\n6 ddd'));
      expect(out, contains('第一章 1~2 段：\n1 xxx\n2 yyy'));
      // Ordering: inline text first, appended content after the trailing text.
      final inlineEnd = out.lastIndexOf('的伏笔');
      final appendedStart = out.indexOf('第一章 3~6 段：');
      expect(appendedStart, greaterThan(inlineEnd));
    });

    test('parseRich + serializeRich round-trip', () {
      final token = RichToken.refContent(
        chapter: 'C', start: 1, end: 1, content: 'x',
      ).serialize();
      final content = 'a${token}b';
      final out = serializeRich(parseRich(content));
      expect(out, content);
    });
  });
}
