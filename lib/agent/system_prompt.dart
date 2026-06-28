/// System prompt assembly: base instructions + novel settings + character /
/// prop settings + current chapter full text (with paragraph numbers) +
/// text requirements. These are prepended to every agent turn by default.
library;

import '../domain/entities.dart';
import '../domain/paragraph_doc.dart';

class SystemPromptBuilder {
  const SystemPromptBuilder();

  String build({
    required Novel novel,
    required ParagraphDoc doc,
    required String chapterTitle,
  }) {
    final parts = <String>[];

    parts.add(_base);
    parts.add(_formatChapter(chapterTitle, doc.getFullText()));
    if (novel.textSettings.trim().isNotEmpty) {
      parts.add('【文本设定】\n${novel.textSettings.trim()}');
    }
    if (novel.characterSettings.isNotEmpty) {
      final buf = StringBuffer('【人物 / 道具设定】');
      for (final s in novel.characterSettings) {
        buf.writeln();
        buf.write('- ${s.name}：${s.description}');
      }
      parts.add(buf.toString());
    }
    if (novel.textRequirements.isNotEmpty) {
      final buf = StringBuffer('【文本要求】');
      for (final r in novel.textRequirements) {
        buf.writeln();
        buf.write('- ${r.text}');
      }
      parts.add(buf.toString());
    }
    return parts.join('\n\n');
  }

  static const String _base = '''你是一个小说写作 Agent。你通过调用工具直接修改当前章节的段落文档。

段落以 1 为起始编号。工具的 range 是闭区间，例如 edit_range(start=12, end=13, new_text="xxx\\nyyy") 会把第 12、13 段替换为 "xxx" 与 "yyy" 两段。

可用工具：
- get_chapter_full_text：获取当前章节全文（带段落号）。
- edit_range(start, end, new_text)：把 start..end 段替换为 new_text（按换行拆分为多段）。
- delete_range(start, end)：删除 start..end 段。
- insert_at(index, new_text)：在第 index 段前插入 new_text（index = 段数+1 时追加到末尾）。
- add_setting / delete_setting / update_setting：增删改人物/道具设定。
- add_text_requirement / delete_text_requirement / update_text_requirement：增删改文本要求。

请先用 get_chapter_full_text 了解当前内容，再按用户意图修改。修改后用一句话向用户说明你做了什么。''';

  String _formatChapter(String title, String fullText) {
    return '【当前章节：$title】\n$fullText';
  }
}
