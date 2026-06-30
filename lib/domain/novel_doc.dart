/// Novel-level document model with reversible, unified mutation events.
///
/// Replaces the old single-chapter [ParagraphDoc] + [MutationEvent] design.
/// Every mutation — paragraph edits on any chapter, plus chapter-structure
/// ops (add / rename / delete / move) — is recorded as a [NovelMutation] in a
/// single global event list. Each event carries enough inverse data to undo
/// itself. The [Timeline] walks this list backwards to revert a message.
///
/// Paragraph numbers and chapter positions are 1-based. Paragraph ranges are
/// closed intervals: `editParagraphs(12, 13, "xxx\nyyy")` replaces paragraphs
/// 12 and 13 of the target chapter with "xxx", "yyy".
library;

import 'entities.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Kind of mutation. Paragraph kinds target a specific chapter; chapter kinds
/// mutate the novel's chapter list structure.
enum NovelMutationKind {
  editParagraphs,
  deleteParagraphs,
  insertParagraphs,
  addChapter,
  deleteChapter,
  renameChapter,
  moveChapter,
}

/// A reversible novel mutation. Carries enough to undo itself.
class NovelMutation {
  final String id;
  final String messageId;
  final String? toolCallId;
  final NovelMutationKind kind;

  /// Chapter this mutation targets (paragraph kinds). Null for chapter-struct
  /// kinds that don't bind to a single chapter.
  final String? chapterId;

  // --- Paragraph-kind inverse data (1-based, inclusive ranges) ---
  final int start;
  final int end;
  final List<Paragraph> removed;
  final List<Paragraph> inserted;

  // --- Chapter-struct-kind inverse data ---
  /// add_chapter inverse: delete the chapter at [chapterIndex].
  /// delete_chapter inverse: re-insert [removedChapter] at [chapterIndex].
  /// move_chapter inverse: move the chapter back to [chapterIndex].
  final int? chapterIndex;
  final Chapter? removedChapter;
  /// rename_chapter inverse: restore [oldTitle].
  final String? oldTitle;

  NovelMutation({
    required this.id,
    required this.messageId,
    this.toolCallId,
    required this.kind,
    this.chapterId,
    this.start = 0,
    this.end = 0,
    List<Paragraph>? removed,
    List<Paragraph>? inserted,
    this.chapterIndex,
    this.removedChapter,
    this.oldTitle,
  })  : removed = removed ?? [],
        inserted = inserted ?? [];

  NovelMutation copy() => NovelMutation(
        id: id,
        messageId: messageId,
        toolCallId: toolCallId,
        kind: kind,
        chapterId: chapterId,
        start: start,
        end: end,
        removed: removed.map((e) => e.copy()).toList(),
        inserted: inserted.map((e) => e.copy()).toList(),
        chapterIndex: chapterIndex,
        removedChapter: removedChapter?.copy(),
        oldTitle: oldTitle,
      );
}

/// Thrown when a paragraph range or chapter reference is out of bounds.
class NovelDocException implements Exception {
  final String message;
  NovelDocException(this.message);
  @override
  String toString() => 'NovelDocException: $message';
}

/// A mutable view over a [Novel] that records inverse mutation events for
/// every change — paragraph edits on any chapter, plus chapter-structure ops.
class NovelDoc {
  final Novel novel;
  final List<NovelMutation> _events = [];

  NovelDoc(this.novel);

  List<NovelMutation> get events => List.unmodifiable(_events);

  /// Drop recorded events by id (used by Timeline after undoing them).
  void dropEventsById(Iterable<String> ids) {
    final set = ids.toSet();
    _events.removeWhere((e) => set.contains(e.id));
  }

  /// Drop all events (clean slate).
  void clearEvents() => _events.clear();

  // --- chapter resolution ---

  Chapter? chapterById(String id) {
    for (final c in novel.chapters) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Resolve a chapter reference: id string, 1-based ordinal (int or numeric
  /// string), or null → [currentChapterId].
  Chapter? resolveChapter(Object? ref, {required String? currentChapterId}) {
    if (ref == null) {
      if (currentChapterId == null) return null;
      return chapterById(currentChapterId);
    }
    if (ref is int) {
      final i = ref - 1;
      if (i < 0 || i >= novel.chapters.length) return null;
      return novel.chapters[i];
    }
    if (ref is String) {
      // Try id first.
      final byId = chapterById(ref);
      if (byId != null) return byId;
      final n = int.tryParse(ref);
      if (n != null) return resolveChapter(n, currentChapterId: currentChapterId);
      return null;
    }
    return null;
  }

  // --- paragraph ops (1-based, closed ranges) ---

  /// Full text of [chapterId]'s paragraphs with 1-based numbers.
  String getFullText(String chapterId) {
    final ch = chapterById(chapterId);
    if (ch == null) throw NovelDocException('chapter not found: $chapterId');
    final buf = StringBuffer();
    final paras = ch.paragraphs;
    for (var i = 0; i < paras.length; i++) {
      buf.write('${i + 1} ${paras[i].text}');
      if (i < paras.length - 1) buf.writeln();
    }
    return buf.toString();
  }

  void _checkRange(List<Paragraph> paras, int start, int end) {
    if (start < 1 || end < start) {
      throw NovelDocException(
          'Invalid range start=$start end=$end (need 1 <= start <= end).');
    }
    if (end > paras.length) {
      throw NovelDocException(
          'Range end=$end exceeds paragraph count=${paras.length}.');
    }
  }

  void _applyReplace(List<Paragraph> paras, int start, int end, List<Paragraph> repl) {
    final s = start - 1;
    final removeCount = end - start + 1;
    paras.replaceRange(s, s + removeCount, repl);
  }

  NovelMutation editParagraphs({
    required String chapterId,
    required int start,
    required int end,
    required String newText,
    required String messageId,
    String? toolCallId,
  }) {
    final ch = chapterById(chapterId);
    if (ch == null) throw NovelDocException('chapter not found: $chapterId');
    final paras = ch.paragraphs;
    _checkRange(paras, start, end);
    final removed = paras
        .getRange(start - 1, end)
        .map((e) => e.copy())
        .toList(growable: false);
    final replacement = _splitToParagraphs(newText);
    _applyReplace(paras, start, end, replacement);
    final ev = NovelMutation(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: NovelMutationKind.editParagraphs,
      chapterId: chapterId,
      start: start,
      end: start + replacement.length - 1,
      removed: removed,
      inserted: replacement.map((e) => e.copy()).toList(),
    );
    _events.add(ev);
    return ev;
  }

  NovelMutation deleteParagraphs({
    required String chapterId,
    required int start,
    required int end,
    required String messageId,
    String? toolCallId,
  }) {
    final ch = chapterById(chapterId);
    if (ch == null) throw NovelDocException('chapter not found: $chapterId');
    final paras = ch.paragraphs;
    _checkRange(paras, start, end);
    final removed = paras
        .getRange(start - 1, end)
        .map((e) => e.copy())
        .toList(growable: false);
    _applyReplace(paras, start, end, const []);
    final ev = NovelMutation(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: NovelMutationKind.deleteParagraphs,
      chapterId: chapterId,
      start: start,
      end: start - 1,
      removed: removed,
      inserted: const [],
    );
    _events.add(ev);
    return ev;
  }

  NovelMutation insertParagraphs({
    required String chapterId,
    required int index,
    required String newText,
    required String messageId,
    String? toolCallId,
  }) {
    final ch = chapterById(chapterId);
    if (ch == null) throw NovelDocException('chapter not found: $chapterId');
    final paras = ch.paragraphs;
    if (index < 1 || index > paras.length + 1) {
      throw NovelDocException(
          'insertParagraphs index=$index out of range (1..${paras.length + 1}).');
    }
    final replacement = _splitToParagraphs(newText);
    paras.insertAll(index - 1, replacement);
    final ev = NovelMutation(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: NovelMutationKind.insertParagraphs,
      chapterId: chapterId,
      start: index,
      end: index + replacement.length - 1,
      removed: const [],
      inserted: replacement.map((e) => e.copy()).toList(),
    );
    _events.add(ev);
    return ev;
  }

  // --- chapter-structure ops (all reversible) ---

  /// Add a chapter. [position] is 1-based insertion index (null/omitted or
  /// length+1 → append). Returns the new chapter's id (carried on the event).
  NovelMutation addChapter({
    String? title,
    int? position,
    required String messageId,
    String? toolCallId,
  }) {
    final order = novel.chapters.length + 1;
    final ch = Chapter.create(title: title ?? '第$order章');
    final insertAt = position == null
        ? novel.chapters.length
        : (position - 1).clamp(0, novel.chapters.length).toInt();
    novel.chapters.insert(insertAt, ch);
    final ev = NovelMutation(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: NovelMutationKind.addChapter,
      chapterId: ch.id,
      chapterIndex: insertAt,
    );
    _events.add(ev);
    return ev;
  }

  /// Rename a chapter. [chapter] = id or 1-based ordinal.
  NovelMutation renameChapter({
    required Object chapter,
    required String title,
    required String messageId,
    String? toolCallId,
  }) {
    final ch = resolveChapter(chapter, currentChapterId: null);
    if (ch == null) throw NovelDocException('chapter not found: $chapter');
    final oldTitle = ch.title;
    ch.title = title;
    final ev = NovelMutation(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: NovelMutationKind.renameChapter,
      chapterId: ch.id,
      oldTitle: oldTitle,
    );
    _events.add(ev);
    return ev;
  }

  /// Delete a chapter (refuses the last remaining chapter). The removed
  /// chapter (with its paragraphs) is stored for undo.
  NovelMutation deleteChapter({
    required Object chapter,
    required String messageId,
    String? toolCallId,
  }) {
    if (novel.chapters.length <= 1) {
      throw NovelDocException('至少保留一章，不能删除。');
    }
    final idx = _chapterIndex(chapter);
    if (idx < 0) throw NovelDocException('chapter not found: $chapter');
    final removed = novel.chapters.removeAt(idx);
    final ev = NovelMutation(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: NovelMutationKind.deleteChapter,
      chapterId: removed.id,
      chapterIndex: idx,
      removedChapter: removed.copy(),
    );
    _events.add(ev);
    return ev;
  }

  /// Move a chapter to [toPosition] (1-based).
  NovelMutation moveChapter({
    required Object chapter,
    required int toPosition,
    required String messageId,
    String? toolCallId,
  }) {
    final fromIdx = _chapterIndex(chapter);
    if (fromIdx < 0) throw NovelDocException('chapter not found: $chapter');
    final clamped = (toPosition - 1).clamp(0, novel.chapters.length - 1).toInt();
    if (clamped == fromIdx) {
      // No-op event for symmetry (still records so revert count matches).
      final ev = NovelMutation(
        id: _uuid.v4(),
        messageId: messageId,
        toolCallId: toolCallId,
        kind: NovelMutationKind.moveChapter,
        chapterId: novel.chapters[fromIdx].id,
        chapterIndex: fromIdx,
      );
      _events.add(ev);
      return ev;
    }
    final ch = novel.chapters.removeAt(fromIdx);
    novel.chapters.insert(clamped, ch);
    final ev = NovelMutation(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: NovelMutationKind.moveChapter,
      chapterId: ch.id,
      chapterIndex: fromIdx,
    );
    _events.add(ev);
    return ev;
  }

  int _chapterIndex(Object ref) {
    if (ref is int) {
      final i = ref - 1;
      return (i >= 0 && i < novel.chapters.length) ? i : -1;
    }
    if (ref is String) {
      final byId = novel.chapters.indexWhere((c) => c.id == ref);
      if (byId >= 0) return byId;
      final n = int.tryParse(ref);
      if (n != null) return _chapterIndex(n);
    }
    return -1;
  }

  // --- undo ---

  /// Reverse-apply a single event (restore pre-state).
  void undo(NovelMutation ev) {
    switch (ev.kind) {
      case NovelMutationKind.editParagraphs:
        final ch = chapterById(ev.chapterId!);
        if (ch == null) return;
        _applyReplace(ch.paragraphs, ev.start, ev.start + ev.inserted.length - 1,
            ev.removed.map((e) => e.copy()).toList());
      case NovelMutationKind.deleteParagraphs:
        final ch = chapterById(ev.chapterId!);
        if (ch == null) return;
        ch.paragraphs.insertAll(ev.start - 1, ev.removed.map((e) => e.copy()));
      case NovelMutationKind.insertParagraphs:
        final ch = chapterById(ev.chapterId!);
        if (ch == null) return;
        final removeCount = ev.inserted.length;
        ch.paragraphs.replaceRange(
            ev.start - 1, ev.start - 1 + removeCount, const []);
      case NovelMutationKind.addChapter:
        // inverse: remove the chapter at chapterIndex (its id == ev.chapterId).
        final idx = novel.chapters.indexWhere((c) => c.id == ev.chapterId);
        if (idx >= 0) novel.chapters.removeAt(idx);
      case NovelMutationKind.deleteChapter:
        // inverse: re-insert removedChapter at chapterIndex.
        novel.chapters.insert(ev.chapterIndex!, ev.removedChapter!.copy());
      case NovelMutationKind.renameChapter:
        final ch = chapterById(ev.chapterId!);
        if (ch != null) ch.title = ev.oldTitle!;
      case NovelMutationKind.moveChapter:
        // inverse: move the chapter back to chapterIndex (original position).
        final idx = novel.chapters.indexWhere((c) => c.id == ev.chapterId);
        if (idx < 0) return;
        final ch = novel.chapters.removeAt(idx);
        novel.chapters.insert(ev.chapterIndex!.clamp(0, novel.chapters.length), ch);
    }
  }

  /// Split text into paragraphs on blank-line boundaries (`\n\n`), matching
  /// the editor's `setChapterBody` convention: a single `\n` is a soft wrap
  /// kept within a paragraph, only `\n\n` starts a new paragraph.
  List<Paragraph> _splitToParagraphs(String text) {
    final blocks = text.split('\n\n');
    return blocks.map((l) => Paragraph.create(l)).toList();
  }

  /// A short human-readable description of what [ev] did, used to preview
  /// what a revert would undo before the user commits to it. Includes the
  /// target chapter's title, the affected 1-based range, before/after counts,
  /// and a short snippet of the removed text.
  String describeMutation(NovelMutation ev) {
    String title() {
      final id = ev.chapterId;
      final ch = id == null ? null : chapterById(id);
      return ch == null ? '章节' : '《${ch.title}》';
    }

    String snippet() {
      if (ev.removed.isEmpty) return '';
      final first = ev.removed.first.text.trim();
      if (first.isEmpty) return '';
      return first.length > 30 ? '${first.substring(0, 30)}…' : first;
    }

    String range() {
      if (ev.kind == NovelMutationKind.deleteParagraphs) {
        // deleteParagraphs records end = start - 1 (empty range); show the
        // single start instead.
        return '第 ${ev.start} 段';
      }
      return ev.start == ev.end ? '第 ${ev.start} 段' : '第 ${ev.start}-${ev.end} 段';
    }

    switch (ev.kind) {
      case NovelMutationKind.editParagraphs:
        final before = ev.removed.length;
        final after = ev.inserted.length;
        final snip = snippet();
        return '修改 ${title()} ${range()}'
            '（$before 段→$after 段）'
            '${snip.isNotEmpty ? '："$snip"' : ''}';
      case NovelMutationKind.deleteParagraphs:
        final before = ev.removed.length;
        final snip = snippet();
        return '删除 ${title()} ${range()}'
            '（$before 段）'
            '${snip.isNotEmpty ? '："$snip"' : ''}';
      case NovelMutationKind.insertParagraphs:
        final n = ev.inserted.length;
        return '插入 $n 段于 ${title()} 第 ${ev.start} 段前';
      case NovelMutationKind.addChapter:
        final ch = ev.chapterId == null ? null : chapterById(ev.chapterId!);
        return '新增章节${ch == null ? '' : '《${ch.title}》'}';
      case NovelMutationKind.deleteChapter:
        final ch = ev.removedChapter;
        return '删除章节${ch == null ? '' : '《${ch.title}》'}';
      case NovelMutationKind.renameChapter:
        return '重命名章节${title()}（原「${ev.oldTitle ?? ''}」）';
      case NovelMutationKind.moveChapter:
        return '移动章节${title()} 顺序';
    }
  }
}
