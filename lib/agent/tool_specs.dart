/// Function-calling JSON schemas for all agent tools.
library;

import '../data/llm/llm_models.dart';

class ToolSpecs {
  static const LlmTool getChapterFullText = LlmTool(
    name: 'get_chapter_full_text',
    description: '获取当前章节的全文（带 1 起始段落号）。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {},
      'required': [],
    },
  );

  static const LlmTool editRange = LlmTool(
    name: 'edit_range',
    description: '把第 start..end 段（闭区间，1-based）替换为 new_text。'
        'new_text 按换行拆分为多段。例: edit_range(start=12, end=13, '
        'new_text="xxx\\nyyy") 把第 12、13 段替换为 "xxx"、"yyy"。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'start': {'type': 'integer', 'description': '起始段号（含）'},
        'end': {'type': 'integer', 'description': '结束段号（含）'},
        'new_text': {'type': 'string', 'description': '替换内容，按换行拆分为多段'},
      },
      'required': ['start', 'end', 'new_text'],
    },
  );

  static const LlmTool deleteRange = LlmTool(
    name: 'delete_range',
    description: '删除第 start..end 段（闭区间，1-based）。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'start': {'type': 'integer'},
        'end': {'type': 'integer'},
      },
      'required': ['start', 'end'],
    },
  );

  static const LlmTool insertAt = LlmTool(
    name: 'insert_at',
    description: '在第 index 段前插入 new_text（按换行拆分为多段）。index = 段数+1 时追加到末尾。',
    parametersJsonSchema: {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer', 'description': '插入位置（1-based）'},
        'new_text': {'type': 'string'},
      },
      'required': ['index', 'new_text'],
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
    addSetting,
    deleteSetting,
    updateSetting,
    addTextRequirement,
    deleteTextRequirement,
    updateTextRequirement,
  ];
}
