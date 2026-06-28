/// Tool registry: function-calling JSON schema definitions + dispatch.
///
/// Each tool returns a JSON string result (echoed back to the model as a
/// `role:tool` message). Document mutations are recorded as [NovelMutation]s
/// on the [NovelDoc] so the timeline can revert them — including cross-chapter
/// paragraph writes and chapter-structure ops (add/rename/delete/move).
library;

import 'dart:convert';
import '../data/llm/llm_models.dart';
import '../domain/entities.dart';
import '../domain/novel_doc.dart';
import 'tool_specs.dart';

/// Outcome of dispatching one tool call.
class ToolDispatchResult {
  final String toolCallId;
  final String name;
  final String resultJson;

  /// Any document mutation event produced (null for read-only tools like
  /// settings/requirements list ops that don't go through NovelDoc).
  final NovelMutation? mutation;

  const ToolDispatchResult({
    required this.toolCallId,
    required this.name,
    required this.resultJson,
    this.mutation,
  });
}

/// Holds the live novel + doc so tools can read/write them. Created per
/// agent turn by the loop and shared across that turn's tool dispatches.
class ToolContext {
  final Novel novel;
  final NovelDoc novelDoc;

  /// The current chapter id (the chapter the editor is focused on).
  final String currentChapterId;
  final String chapterTitle;
  final String messageId;
  final int now;

  ToolContext({
    required this.novel,
    required this.novelDoc,
    required this.currentChapterId,
    required this.chapterTitle,
    required this.messageId,
    required this.now,
  });

  /// Resolve the target chapter for a paragraph tool. [ref] is the model's
  /// `chapter` arg (id / 1-based ordinal / null). Returns the chapter id to
  /// operate on, or null if unresolvable.
  String? resolveChapterId(Object? ref) {
    final ch = novelDoc.resolveChapter(ref, currentChapterId: currentChapterId);
    return ch?.id;
  }
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
        final cid = ctx.resolveChapterId(args['chapter']);
        if (cid == null) return _err(toolCallId, name, 'chapter not found: ${args['chapter']}');
        return _ok(toolCallId, name, {'text': ctx.novelDoc.getFullText(cid)});
      case 'edit_range':
        return _paragraphMut(ctx, toolCallId, name, args, (cid) {
          final ev = ctx.novelDoc.editParagraphs(
            chapterId: cid,
            start: args['start'] as int,
            end: args['end'] as int,
            newText: args['new_text'] as String,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          return ev;
        }, summary: (cid) =>
            '修改 ${ctx.novelDoc.chapterById(cid)?.title} 第 ${args['start']}-${args['end']} 段');
      case 'delete_range':
        return _paragraphMut(ctx, toolCallId, name, args, (cid) {
          final ev = ctx.novelDoc.deleteParagraphs(
            chapterId: cid,
            start: args['start'] as int,
            end: args['end'] as int,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          return ev;
        }, summary: (cid) =>
            '删除 ${ctx.novelDoc.chapterById(cid)?.title} 第 ${args['start']}-${args['end']} 段');
      case 'insert_at':
        return _paragraphMut(ctx, toolCallId, name, args, (cid) {
          final ev = ctx.novelDoc.insertParagraphs(
            chapterId: cid,
            index: args['index'] as int,
            newText: args['new_text'] as String,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          return ev;
        }, summary: (cid) {
          final lines = (args['new_text'] as String).split('\n\n').length;
          return '插入 $lines 段于 ${ctx.novelDoc.chapterById(cid)?.title} 第 ${args['index']} 段前';
        });

      // --- chapter management ---
      case 'get_chapter_list':
        final list = <Map<String, dynamic>>[];
        for (var i = 0; i < ctx.novel.chapters.length; i++) {
          final c = ctx.novel.chapters[i];
          list.add({
            'order': i + 1,
            'id': c.id,
            'title': c.title,
            'paragraphs': c.paragraphs.length,
          });
        }
        return _ok(toolCallId, name, {'chapters': list});
      case 'add_chapter':
        try {
          final ev = ctx.novelDoc.addChapter(
            title: args['title'] as String?,
            position: args['position'] as int?,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          final order = ctx.novel.chapters.indexWhere((c) => c.id == ev.chapterId) + 1;
          return _mutEv(toolCallId, name, ev, {
            'id': ev.chapterId,
            'order': order,
            'title': ctx.novelDoc.chapterById(ev.chapterId!)?.title,
          }, summary: '新增章节“${ctx.novelDoc.chapterById(ev.chapterId!)?.title}”');
        } on NovelDocException catch (e) {
          return _err(toolCallId, name, e.message);
        }
      case 'rename_chapter':
        try {
          final ev = ctx.novelDoc.renameChapter(
            chapter: args['chapter'],
            title: args['title'] as String,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          return _mutEv(toolCallId, name, ev, {'id': ev.chapterId},
              summary: '重命名为“${args['title']}”');
        } on NovelDocException catch (e) {
          return _err(toolCallId, name, e.message);
        }
      case 'delete_chapter':
        try {
          final ev = ctx.novelDoc.deleteChapter(
            chapter: args['chapter'],
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          return _mutEv(toolCallId, name, ev, {'deleted': ev.chapterId},
              summary: '删除章节');
        } on NovelDocException catch (e) {
          return _err(toolCallId, name, e.message);
        }
      case 'move_chapter':
        try {
          final ev = ctx.novelDoc.moveChapter(
            chapter: args['chapter'],
            toPosition: args['to_position'] as int,
            messageId: ctx.messageId,
            toolCallId: toolCallId,
          );
          final order = ctx.novel.chapters.indexWhere((c) => c.id == ev.chapterId) + 1;
          return _mutEv(toolCallId, name, ev, {'id': ev.chapterId, 'order': order},
              summary: '移动到第 $order 位');
        } on NovelDocException catch (e) {
          return _err(toolCallId, name, e.message);
        }

      // --- settings / requirements (not part of NovelDoc undo) ---
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

  /// Run a paragraph mutation on the resolved chapter, wrapping any
  /// NovelDocException as an error and recording the mutation on success.
  ToolDispatchResult _paragraphMut(
    ToolContext ctx,
    String id,
    String name,
    Map<String, dynamic> args,
    NovelMutation Function(String chapterId) apply, {
    required String Function(String chapterId) summary,
  }) {
    final cid = ctx.resolveChapterId(args['chapter']);
    if (cid == null) return _err(id, name, 'chapter not found: ${args['chapter']}');
    try {
      final ev = apply(cid);
      final ch = ctx.novelDoc.chapterById(cid)!;
      return ToolDispatchResult(
        toolCallId: id,
        name: name,
        resultJson: jsonEncode({
          'ok': true,
          'chapter': ch.title,
          'summary': summary(cid),
          'affected_range': {'start': ev.start, 'end': ev.end},
          'paragraphs_after': ch.paragraphs.length,
          'paragraphs_changed': ev.inserted.length + ev.removed.length,
        }),
        mutation: ev,
      );
    } on NovelDocException catch (e) {
      return _err(id, name, e.message);
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

  /// Wrap a chapter-structure mutation event into a result with a summary.
  ToolDispatchResult _mutEv(
    String id,
    String name,
    NovelMutation ev,
    Map<String, dynamic> data, {
    required String summary,
  }) =>
      ToolDispatchResult(
        toolCallId: id,
        name: name,
        resultJson: jsonEncode({'ok': true, 'summary': summary, ...data}),
        mutation: ev,
      );
}
