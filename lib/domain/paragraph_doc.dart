/// Paragraph document model + range mutation ops with inverses for timeline.
///
/// Paragraph numbers are 1-based. Range ops are closed intervals:
/// `editRange(12, 13, "xxx\nyyy")` replaces paragraphs 12 and 13 with the
/// two paragraphs "xxx", "yyy".
library;

import 'entities.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// What kind of mutation was applied (so the timeline/UI can label it).
enum MutationKind { edit, delete, insert }

/// A reversible document mutation. Carries enough to undo itself.
///
/// Inverse is encoded as another mutation descriptor: applying `inverse` to
/// the post-state restores the pre-state. The timeline appends events and
/// walks them backwards to revertTo.
class MutationEvent {
  final String id;
  final String messageId;
  final String? toolCallId;
  final MutationKind kind;

  /// Range this mutation affected (1-based, inclusive).
  final int start;
  final int end;

  /// Paragraphs removed/replaced (pre-state), in order — for undo.
  final List<Paragraph> removed;

  /// Paragraphs inserted (post-state), in order — for undo of delete/insert.
  final List<Paragraph> inserted;

  MutationEvent({
    required this.id,
    required this.messageId,
    this.toolCallId,
    required this.kind,
    required this.start,
    required this.end,
    List<Paragraph>? removed,
    List<Paragraph>? inserted,
  })  : removed = removed ?? [],
        inserted = inserted ?? [];

  MutationEvent copy() => MutationEvent(
        id: id,
        messageId: messageId,
        toolCallId: toolCallId,
        kind: kind,
        start: start,
        end: end,
        removed: removed.map((e) => e.copy()).toList(),
        inserted: inserted.map((e) => e.copy()).toList(),
      );
}

/// Thrown when a range op is out of bounds or malformed.
class ParagraphDocException implements Exception {
  final String message;
  ParagraphDocException(this.message);
  @override
  String toString() => 'ParagraphDocException: $message';
}

/// A mutable view over a chapter's paragraphs that records inverse events.
class ParagraphDoc {
  final Chapter chapter;
  final List<MutationEvent> _events = [];

  ParagraphDoc(this.chapter);

  List<Paragraph> get paragraphs => chapter.paragraphs;
  int get length => paragraphs.length;

  List<MutationEvent> get events => List.unmodifiable(_events);

  /// Drop recorded events by id (used by Timeline after undoing them).
  void dropEventsById(Iterable<String> ids) {
    final set = ids.toSet();
    _events.removeWhere((e) => set.contains(e.id));
  }

  /// Drop all events whose messageId is strictly after [messageId] (for the
  /// "resend from here" case where we want a clean slate going forward).
  void clearEvents() => _events.clear();

  /// Full text with 1-based paragraph numbers: `"1 foo\n2 bar\n..."`.
  String getFullText() {
    final buf = StringBuffer();
    for (var i = 0; i < paragraphs.length; i++) {
      buf.write('${i + 1} ${paragraphs[i].text}');
      if (i < paragraphs.length - 1) buf.writeln();
    }
    return buf.toString();
  }

  /// Validate a closed 1-based range [start, end].
  void _checkRange(int start, int end) {
    if (start < 1 || end < start) {
      throw ParagraphDocException(
          'Invalid range start=$start end=$end (need 1 <= start <= end).');
    }
    if (end > length) {
      throw ParagraphDocException(
          'Range end=$end exceeds paragraph count=$length.');
    }
  }

  void _applyReplace(int start, int end, List<Paragraph> replacement) {
    final s = start - 1; // 0-based inclusive start
    final removeCount = end - start + 1;
    paragraphs.replaceRange(s, s + removeCount, replacement);
  }

  /// Edit paragraphs [start..end] to `newText` split on newlines.
  /// Returns the recorded MutationEvent (inverse baked in).
  MutationEvent editRange({
    required int start,
    required int end,
    required String newText,
    required String messageId,
    String? toolCallId,
  }) {
    _checkRange(start, end);
    final removed = paragraphs
        .getRange(start - 1, end)
        .map((e) => e.copy())
        .toList(growable: false);
    final replacement = _splitToParagraphs(newText);
    _applyReplace(start, end, replacement);
    final ev = MutationEvent(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: MutationKind.edit,
      start: start,
      end: start + replacement.length - 1,
      removed: removed,
      inserted: replacement.map((e) => e.copy()).toList(),
    );
    _events.add(ev);
    return ev;
  }

  /// Delete paragraphs [start..end].
  MutationEvent deleteRange({
    required int start,
    required int end,
    required String messageId,
    String? toolCallId,
  }) {
    _checkRange(start, end);
    final removed = paragraphs
        .getRange(start - 1, end)
        .map((e) => e.copy())
        .toList(growable: false);
    _applyReplace(start, end, const []);
    final ev = MutationEvent(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: MutationKind.delete,
      start: start,
      end: start - 1, // empty range after deletion
      removed: removed,
      inserted: const [],
    );
    _events.add(ev);
    return ev;
  }

  /// Insert `newText` (split on newlines) BEFORE paragraph [index]
  /// (1-based). index = length+1 appends at the end.
  MutationEvent insertAt({
    required int index,
    required String newText,
    required String messageId,
    String? toolCallId,
  }) {
    if (index < 1 || index > length + 1) {
      throw ParagraphDocException(
          'insertAt index=$index out of range (1..${length + 1}).');
    }
    final replacement = _splitToParagraphs(newText);
    final pos = index - 1; // 0-based insertion point
    paragraphs.insertAll(pos, replacement);
    final ev = MutationEvent(
      id: _uuid.v4(),
      messageId: messageId,
      toolCallId: toolCallId,
      kind: MutationKind.insert,
      start: index,
      end: index + replacement.length - 1,
      removed: const [],
      inserted: replacement.map((e) => e.copy()).toList(),
    );
    _events.add(ev);
    return ev;
  }

  /// Reverse-apply a single event (restore pre-state).
  void undo(MutationEvent ev) {
    switch (ev.kind) {
      case MutationKind.edit:
        // Currently the inserted block occupies [ev.start..ev.end]; put back
        // ev.removed at ev.start.
        _applyReplace(ev.start, ev.start + ev.inserted.length - 1,
            ev.removed.map((e) => e.copy()).toList());
      case MutationKind.delete:
        // Re-insert removed at ev.start (ev.end is start-1 / empty).
        paragraphs.insertAll(ev.start - 1, ev.removed.map((e) => e.copy()));
      case MutationKind.insert:
        // Remove inserted block [ev.start..ev.end].
        final removeCount = ev.inserted.length;
        paragraphs.replaceRange(ev.start - 1, ev.start - 1 + removeCount, const []);
    }
  }

  List<Paragraph> _splitToParagraphs(String text) {
    final lines = text.split('\n');
    return lines.map((l) => Paragraph.create(l)).toList();
  }
}
