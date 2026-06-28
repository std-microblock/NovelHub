/// Tool registry: function-calling JSON schema definitions + dispatch.
///
/// Each tool returns a JSON string result (echoed back to the model as a
/// `role:tool` message). Doc mutations are recorded as [MutationEvent]s on
/// the [ParagraphDoc] so the timeline can revert them.
library;

import 'dart:convert';
import '../data/llm/llm_models.dart';
import '../domain/entities.dart';
import '../domain/paragraph_doc.dart';
import 'tool_specs.dart';

/// Outcome of dispatching one tool call.
class ToolDispatchResult {
  final String toolCallId;
  final String name;
  final String resultJson;

  /// Any document mutation event produced (null for read-only tools).
  final MutationEvent? mutation;

  const ToolDispatchResult({
    required this.toolCallId,
    required this.name,
    required this.resultJson,
    this.mutation,
  });
}

/// Holds the live document + novel so tools can read/write them. Created per
/// agent turn by the loop and shared across that turn's tool dispatches.
class ToolContext {
  final Novel novel;
  final ParagraphDoc doc;
  final String chapterTitle;
  final String messageId;
  final int now;

  ToolContext({
    required this.novel,
    required this.doc,
    required this.chapterTitle,
    required this.messageId,
    required this.now,
  });
}

class ToolRegistry {
  /// All tools exposed to the model, as OpenAI function specs.
  static const List<LlmTool> tools = ToolSpecs.all;

  /// Dispatch a tool call. [argumentsJson] is the model's args string.
  ToolDispatchResult dispatch({
    required ToolContext ctx,
    required String toolCallId,
    required String name,
    required String argumentsJson,
  }) {
    final args = _decodeArgs(argumentsJson);
    switch (name) {
      case 'get_chapter_full_text':
        return _ok(toolCallId, name, {'text': ctx.doc.getFullText()});
      case 'edit_range':
        return _mut(ctx, toolCallId, name, () {
          final ev = ctx.doc.editRange(
            start: args['start'] as int,
            end: args['end'] as int,
            newText: args['new_text'] as String,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          return ev;
        }, summary: '修改第 ${args['start']}-${args['end']} 段为 ${args['new_text'].toString().split('\n').length} 段');
      case 'delete_range':
        return _mut(ctx, toolCallId, name, () {
          final ev = ctx.doc.deleteRange(
            start: args['start'] as int,
            end: args['end'] as int,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          return ev;
        }, summary: '删除第 ${args['start']}-${args['end']} 段');
      case 'insert_at':
        return _mut(ctx, toolCallId, name, () {
          final ev = ctx.doc.insertAt(
            index: args['index'] as int,
            newText: args['new_text'] as String,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          return ev;
        },
            summary:
                'inserted ${args['new_text'].toString().split('\n').length} 段于第 ${args['index']} 段前');
      case 'add_setting':
        final s = SettingEntry.create(
            name: args['name'] as String,
            description: (args['description'] as String?) ?? '');
        ctx.novel.characterSettings.add(s);
        return _ok(toolCallId, name, {'id': s.id});
      case 'delete_setting':
        final id = args['id'] as String;
        ctx.novel.characterSettings.removeWhere((e) => e.id == id);
        return _ok(toolCallId, name, {'deleted': id});
      case 'update_setting':
        final id = args['id'] as String;
        final idx = ctx.novel.characterSettings.indexWhere((e) => e.id == id);
        if (idx < 0) return _err(toolCallId, name, 'setting not found: $id');
        final s = ctx.novel.characterSettings[idx];
        if (args['name'] != null) s.name = args['name'] as String;
        if (args['description'] != null) {
          s.description = args['description'] as String;
        }
        return _ok(toolCallId, name, {'updated': id});
      case 'add_text_requirement':
        final r = TextRequirement.create(args['text'] as String);
        ctx.novel.textRequirements.add(r);
        return _ok(toolCallId, name, {'id': r.id});
      case 'delete_text_requirement':
        final id = args['id'] as String;
        ctx.novel.textRequirements.removeWhere((e) => e.id == id);
        return _ok(toolCallId, name, {'deleted': id});
      case 'update_text_requirement':
        final id = args['id'] as String;
        final idx =
            ctx.novel.textRequirements.indexWhere((e) => e.id == id);
        if (idx < 0) return _err(toolCallId, name, 'requirement not found: $id');
        if (args['text'] != null) {
          ctx.novel.textRequirements[idx].text = args['text'] as String;
        }
        return _ok(toolCallId, name, {'updated': id});
      default:
        return _err(toolCallId, name, 'unknown tool: $name');
    }
  }

  Map<String, dynamic> _decodeArgs(String json) {
    if (json.trim().isEmpty) return {};
    try {
      return (jsonDecode(json) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  ToolDispatchResult _ok(String id, String name, Map<String, dynamic> data) =>
      ToolDispatchResult(
        toolCallId: id,
        name: name,
        resultJson: jsonEncode({'ok': true, ...data}),
      );

  ToolDispatchResult _err(String id, String name, String message) =>
      ToolDispatchResult(
        toolCallId: id,
        name: name,
        resultJson: jsonEncode({'ok': false, 'error': message}),
      );

  ToolDispatchResult _mut(
    ToolContext ctx,
    String id,
    String name,
    MutationEvent Function() apply, {
    required String summary,
  }) {
    try {
      final ev = apply();
      final totalAfter = ctx.doc.length;
      return ToolDispatchResult(
        toolCallId: id,
        name: name,
        resultJson: jsonEncode({
          'ok': true,
          'summary': summary,
          'affected_range': {'start': ev.start, 'end': ev.end},
          'paragraphs_after': totalAfter,
          'paragraphs_changed': ev.inserted.length + ev.removed.length,
        }),
        mutation: ev,
      );
    } on ParagraphDocException catch (e) {
      return _err(id, name, e.message);
    }
  }
}
