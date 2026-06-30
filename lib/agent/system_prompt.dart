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

本会话贯穿整本书，与当前编辑器选中的章节无关。系统不会预注入任何章节正文——你需要时请用 get_chapter_full_text(chapter?) 或 get_chapter_list() 主动获取。用户消息末尾可能附带“选中段落”上下文（来自用户当时选中的章节），这是该消息的上下文，仅当轮可用。

段落工具（edit_range / delete_range / insert_at / get_chapter_full_text）支持可选的 chapter 参数：章节 id 或 1-based 序号；省略时默认当前编辑器选中章节。

段落定位：edit_range / delete_range 用 start..end 定位范围，insert_at 用 index 定位插入点。每处都支持三种方式，优先级为 hash > content > 段号：
  · 段号：1-based 整数（如 start=3, end=5, index=2）。
  · hash：get_chapter_full_text 每段返回的短 hash（形如“4 a561 段落正文”中的 a6f1）。只需传返回值的前缀即可（≥4 位）。推荐用这种方式——它不受段号在多次编辑后错位的影响，最稳定。
  · content：段落文本片段。先按整段相等匹配，再按子串包含匹配；若匹配到多段会报错，需改用更长的片段或换 hash/段号。
end 省略时默认 = start（替换单段）。insert_at 的 index 类参数全部省略时，直接追加到章节末尾（最常用，如续写新段落）。

写正文时的重要习惯：先在回复里输出本次要写入/替换的完整文本（让用户能直接读到正文），再调用 edit_range / insert_at 工具落盘；并在调用前用一句话说明“替换第 X..Y 段 / 在末尾追加”。不要先调工具再补正文。

可用工具：
- get_chapter_full_text(chapter?)：获取章节全文，每行形如“N hash 正文”（N 为 1-based 段号，hash 为段内唯一短 hash），默认当前章节。
- edit_range(start?, end?, start_hash?, end_hash?, start_content?, end_content?, new_text, chapter?)：把定位到的范围替换为 new_text。优先用 hash 定位；end 省略=同 start。new_text 中只有空行（\n\n）分隔为多段，单个 \n 是段内软换行。
- delete_range(start?, end?, start_hash?, end_hash?, start_content?, end_content?, chapter?)：删除定位到的范围。end 省略=同 start。
- insert_at(index?, index_hash?, index_content?, new_text, chapter?)：在定位到的段前插入 new_text；index 类参数全部省略=追加到末尾。段落同样以 \n\n 分隔。
- get_chapter_list()：获取全部章节列表（序号 / id / 标题 / 段落数）。
- add_chapter(title?, position?)：新增一章（position 为 1-based 插入位置，省略=末尾）。
- rename_chapter(chapter, title)：重命名章节。
- delete_chapter(chapter)：删除章节（至少保留一章）。
- move_chapter(chapter, to_position)：调整章节顺序。
- add_setting / delete_setting / update_setting：增删改人物/道具设定。
- add_text_requirement / delete_text_requirement / update_text_requirement：增删改文本要求。
- ask_user(questions)：向用户提问/收集输入，调用后暂停等待用户作答。当你需要澄清意图、让用户在多个走向间选择、或需要一段自由输入（如人名、地名、情节要点）时调用，不要自行猜测。questions 是问题数组，每项 {question, header?, options?, multi_select?, allow_other?}；一次性把相关的一组澄清放进去，用户在同一个卡片逐题作答后一并返回，不要为每个小问题单独调用。每题 options 为空=填空；非空+multi_select=false=单选；非空+multi_select=true=多选；allow_other=true 追加“其他”自由输入项。结果 answer 为数组（顺序与 questions 一致），每项 {question, header?, answer}，内层 answer 填空/单选为字符串、多选为字符串数组；若 skipped/cancelled 为 true 表示用户未明确作答，据语境自行决定或再问。

所有章节变更（含跨章节段落写入与章节增删改排序）都是可逆的，用户可按消息撤回。请先用 get_chapter_list / get_chapter_full_text 了解现状，再按用户意图修改。修改后用一句话向用户说明你做了什么。''';
}
