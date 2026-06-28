/// System prompt assembly: base instructions + novel settings + character /
/// prop settings + text requirements. Prepended to every agent turn.
///
/// NOTE: the current chapter's full text is intentionally NOT injected here.
/// The agent session is decoupled from the chapter selection: chapter choice
/// only affects which paragraphs are attached as context when the user sends a
/// message (see Message.messageContext). Use the chapter tools
/// (get_chapter_full_text / get_chapter_list) to read chapter content.
library;

import '../domain/entities.dart';

class SystemPromptBuilder {
  const SystemPromptBuilder();

  String build({
    required Novel novel,
  }) {
    final parts = <String>[];

    parts.add(_base);
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

  static const String _base = '''你是一个小说写作 Agent。你通过调用工具直接修改小说的章节文档与章节结构。

段落以 1 为起始编号。工具的 range 是闭区间。段落分隔规则很重要：在 new_text 里，只有空行（\n\n，即两个换行）才算新起一段；单个 \n 是段内软换行，不会新起一段。例如 new_text="第一段\n\n第二段" 是两段，而 new_text="第一行\n第二行" 只是一段（两行同属一段）。

本会话贯穿整本书，与当前编辑器选中的章节无关。系统不会预注入任何章节正文——你需要时请用 get_chapter_full_text(chapter?) 或 get_chapter_list() 主动获取。用户消息末尾可能附带"选中段落"上下文（来自用户当时选中的章节），这是该消息的上下文，仅当轮可用。

段落工具（edit_range / delete_range / insert_at / get_chapter_full_text）支持可选的 chapter 参数：章节 id 或 1-based 序号；省略时默认当前编辑器选中章节。

可用工具：
- get_chapter_full_text(chapter?)：获取章节全文（带段落号），默认当前章节。
- edit_range(start, end, new_text, chapter?)：把 start..end 段替换为 new_text。new_text 中只有空行（\n\n）分隔为多段，单个 \n 是段内软换行。
- delete_range(start, end, chapter?)：删除 start..end 段。
- insert_at(index, new_text, chapter?)：在第 index 段前插入 new_text（index = 段数+1 时追加到末尾）。段落同样以 \n\n 分隔。
- get_chapter_list()：获取全部章节列表（序号 / id / 标题 / 段落数）。
- add_chapter(title?, position?)：新增一章（position 为 1-based 插入位置，省略=末尾）。
- rename_chapter(chapter, title)：重命名章节。
- delete_chapter(chapter)：删除章节（至少保留一章）。
- move_chapter(chapter, to_position)：调整章节顺序。
- add_setting / delete_setting / update_setting：增删改人物/道具设定。
- add_text_requirement / delete_text_requirement / update_text_requirement：增删改文本要求。

所有章节变更（含跨章节段落写入与章节增删改排序）都是可逆的，用户可按消息撤回。请先用 get_chapter_list / get_chapter_full_text 了解现状，再按用户意图修改。修改后用一句话向用户说明你做了什么。''';
}
