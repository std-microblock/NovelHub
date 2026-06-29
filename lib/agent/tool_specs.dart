/// Function-calling JSON schemas for all agent tools.
library;

import '../data/llm/llm_models.dart';

/// Optional `chapter` param spec, shared by paragraph tools.
const Map<String, dynamic> _chapterParam = {
  'type': 'string',
  'description': '目标章节 id 或 1-based 序号；省略=当前章节',
};

class ToolSpecs {
  static const LlmTool getChapterFullText = LlmTool(
    name: 'get_chapter_full_text',
    description: '获取章节的全文（带 1 起始段落号）。省略 chapter 时为当前章节。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'chapter': _chapterParam,
      },
      'required': [],
    },
  );

  static const LlmTool editRange = LlmTool(
    name: 'edit_range',
    description: '把第 start..end 段（闭区间，1-based）替换为 new_text。'
        '段落分隔规则：仅空行（\\n\\n，即两个换行）才算一段；单个 \\n 是段内软换行，不会新起一段。'
        '例: new_text="第一段\\n\\n第二段" = 两段；new_text="第一行\\n第二行" = 一段（两行同属一段）。'
        '可传 chapter 指定目标章节（默认当前章节）。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'start': {'type': 'integer', 'description': '起始段号（含）'},
        'end': {'type': 'integer', 'description': '结束段号（含）'},
        'new_text': {
          'type': 'string',
          'description': '替换内容。仅 \\n\\n（空行）分隔为多段；单个 \\n 是段内软换行。',
        },
        'chapter': _chapterParam,
      },
      'required': ['start', 'end', 'new_text'],
    },
  );

  static const LlmTool deleteRange = LlmTool(
    name: 'delete_range',
    description: '删除第 start..end 段（闭区间，1-based）。可传 chapter 指定目标章节。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'start': {'type': 'integer'},
        'end': {'type': 'integer'},
        'chapter': _chapterParam,
      },
      'required': ['start', 'end'],
    },
  );

  static const LlmTool insertAt = LlmTool(
    name: 'insert_at',
    description: '在第 index 段前插入 new_text。index = 段数+1 时追加到末尾。'
        '段落分隔规则：仅空行（\\n\\n，即两个换行）才算一段；单个 \\n 是段内软换行，不会新起一段。'
        '可传 chapter 指定目标章节。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer', 'description': '插入位置（1-based）'},
        'new_text': {
          'type': 'string',
          'description': '插入内容。仅 \\n\\n（空行）分隔为多段；单个 \\n 是段内软换行。',
        },
        'chapter': _chapterParam,
      },
      'required': ['index', 'new_text'],
    },
  );

  // --- Chapter management ---

  static const LlmTool getChapterList = LlmTool(
    name: 'get_chapter_list',
    description: '获取全部章节列表（序号 / id / 标题 / 段落数）。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {},
      'required': [],
    },
  );

  static const LlmTool addChapter = LlmTool(
    name: 'add_chapter',
    description: '新增一章。title 省略时默认“第 N 章”；position 为 1-based 插入位置，省略=末尾追加。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'position': {'type': 'integer', 'description': '1-based 插入位置；省略=末尾'},
      },
      'required': [],
    },
  );

  static const LlmTool renameChapter = LlmTool(
    name: 'rename_chapter',
    description: '重命名章节。chapter 为章节 id 或 1-based 序号。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'chapter': {
          'type': 'string',
          'description': '章节 id 或 1-based 序号',
        },
        'title': {'type': 'string'},
      },
      'required': ['chapter', 'title'],
    },
  );

  static const LlmTool deleteChapter = LlmTool(
    name: 'delete_chapter',
    description: '删除章节（至少保留一章）。chapter 为章节 id 或 1-based 序号。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'chapter': {
          'type': 'string',
          'description': '章节 id 或 1-based 序号',
        },
      },
      'required': ['chapter'],
    },
  );

  static const LlmTool moveChapter = LlmTool(
    name: 'move_chapter',
    description: '调整章节顺序。chapter 为章节 id 或 1-based 序号；to_position 为目标 1-based 序号。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'chapter': {
          'type': 'string',
          'description': '章节 id 或 1-based 序号',
        },
        'to_position': {'type': 'integer', 'description': '目标 1-based 序号'},
      },
      'required': ['chapter', 'to_position'],
    },
  );

  static const LlmTool addSetting = LlmTool(
    name: 'add_setting',
    description: '新增一个人物/道具设定。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'description': {'type': 'string'},
      },
      'required': ['name'],
    },
  );

  static const LlmTool deleteSetting = LlmTool(
    name: 'delete_setting',
    description: '按 id 删除一个人物/道具设定。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
    },
  );

  static const LlmTool updateSetting = LlmTool(
    name: 'update_setting',
    description: '按 id 修改一个人物/道具设定的 name/description。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'name': {'type': 'string'},
        'description': {'type': 'string'},
      },
      'required': ['id'],
    },
  );

  static const LlmTool addTextRequirement = LlmTool(
    name: 'add_text_requirement',
    description: '新增一条文本要求。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
    },
  );

  static const LlmTool deleteTextRequirement = LlmTool(
    name: 'delete_text_requirement',
    description: '按 id 删除一条文本要求。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
    },
  );

  static const LlmTool updateTextRequirement = LlmTool(
    name: 'update_text_requirement',
    description: '按 id 修改一条文本要求的内容。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'text': {'type': 'string'},
      },
      'required': ['id'],
    },
  );

  static const LlmTool askUser = LlmTool(
    name: 'ask_user',
    description: '向用户提问/收集输入，暂停等待用户作答后再继续。'
        '当你需要澄清意图、让用户在多个走向间选择、或需要一段自由输入'
        '（如人名、地名、情节要点）时调用，而不是自行猜测。'
        '调用后本工具会阻塞，直到用户提交或跳过。\n'
        '模式由参数决定：\n'
        '  · options 为空 → 填空（让用户自由输入一段文本）；\n'
        '  · options 非空且 multi_select=false（默认）→ 单选；\n'
        '  · options 非空且 multi_select=true → 多选；\n'
        '  · allow_other=true → 在 options 之外追加一个“其他”自由输入项。'
        '结果 JSON：{ok, answer, skipped, cancelled}，用户答案在 answer 字段。'
        'answer 在填空模式下为字符串；单选为字符串；多选为字符串数组。'
        '若 skipped/cancelled 为 true 则用户未给出明确答案，请据语境自行决定或再问。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'question': {
          'type': 'string',
          'description': '要问用户的问题/提示语。',
        },
        'header': {
          'type': 'string',
          'description': '可选的简短标签（如“叙事人称”），显示为标题。',
        },
        'options': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '可选项列表。为空时是填空模式；非空时按 multi_select 决定单选/多选。',
        },
        'multi_select': {
          'type': 'boolean',
          'description': '是否允许多选。仅 options 非空时生效。默认 false（单选）。',
        },
        'allow_other': {
          'type': 'boolean',
          'description': '是否追加一个“其他”自由输入项。默认 false。',
        },
      },
      'required': ['question'],
    },
  );

  static const List<LlmTool> all = [
    getChapterFullText,
    editRange,
    deleteRange,
    insertAt,
    getChapterList,
    addChapter,
    renameChapter,
    deleteChapter,
    moveChapter,
    addSetting,
    deleteSetting,
    updateSetting,
    addTextRequirement,
    deleteTextRequirement,
    updateTextRequirement,
    askUser,
  ];
}
