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
        'new_text 按换行拆分为多段。例: edit_range(start=12, end=13, '
        'new_text="xxx\\nyyy") 把第 12、13 段替换为 "xxx"、"yyy"。'
        '可传 chapter 指定目标章节（默认当前章节）。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'start': {'type': 'integer', 'description': '起始段号（含）'},
        'end': {'type': 'integer', 'description': '结束段号（含）'},
        'new_text': {'type': 'string', 'description': '替换内容，按换行拆分为多段'},
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
    description: '在第 index 段前插入 new_text（按换行拆分为多段）。index = 段数+1 时追加到末尾。'
        '可传 chapter 指定目标章节。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer', 'description': '插入位置（1-based）'},
        'new_text': {'type': 'string'},
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
  ];
}
