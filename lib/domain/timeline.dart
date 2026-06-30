/// Timeline over a [NovelDoc]: revertTo(messageId) undoes every event
/// recorded *after* (and optionally including) that message, restoring the
/// novel to the state it had at that message.
///
/// Events are appended by the NovelDoc tools (paragraph edits on any chapter
/// + chapter-structure ops) tagged with the messageId of the agent turn that
/// caused them. Reverting a message also conceptually reverts any tool calls
/// that message produced.
library;

import 'novel_doc.dart';

class Timeline {
  final NovelDoc doc;

  Timeline(this.doc);

  /// Collect the events that a revert of [messageId] would touch, newest
  /// first, without applying or dropping them. When [includeMessage] is true
  /// the target message's own events are included; otherwise they are kept.
  ///
  /// The walk stops at the first event whose messageId is *older* than the
  /// target, so a revert only touches the target turn (and anything recorded
  /// after it) — never earlier turns. Within the target turn every event is
  /// reverted regardless of which assistant/tool message id it carries.
  List<NovelMutation> previewRevert(String messageId,
      {bool includeMessage = false}) {
    return _collect(messageId, includeMessage: includeMessage);
  }

  /// Revert the novel to the state it was in immediately AFTER the events
  /// belonging to [messageId] (i.e. undo everything recorded after that
  /// message's events). Returns the number of events undone.
  ///
  /// If [includeMessage] is true, also undo the events tagged with
  /// [messageId] itself (useful for "redo this message" before resending).
  int revertTo(String messageId, {bool includeMessage = false}) {
    final toUndo = _collect(messageId, includeMessage: includeMessage);
    for (final ev in toUndo) {
      doc.undo(ev);
    }
    doc.dropEventsById(toUndo.map((e) => e.id));
    return toUndo.length;
  }

  /// Drop the events a revert of [messageId] would touch WITHOUT undoing
  /// them — i.e. keep the document changes but forget they are reversible
  /// from this message. Used by "only remove the conversation, keep the doc".
  /// Returns the number of events dropped.
  int dropEventsFromMessage(String messageId, {bool includeMessage = false}) {
    final toDrop = _collect(messageId, includeMessage: includeMessage);
    doc.dropEventsById(toDrop.map((e) => e.id));
    return toDrop.length;
  }

  /// Collect events to revert for [messageId], newest first.
  ///
  /// A turn may produce several events all tagged with the turn's messageId.
  /// We anchor on the *first* (earliest) such event in the append-only event
  /// list: everything at that index or later belongs to the target turn or a
  /// later turn, and is reverted when [includeMessage] is true; when false,
  /// only the strictly-later events (index > first target) are reverted and
  /// the target turn's own events are kept. Events before the anchor belong to
  /// earlier turns and are never touched.
  List<NovelMutation> _collect(String messageId, {required bool includeMessage}) {
    final events = doc.events;
    var targetStart = -1;
    for (var i = 0; i < events.length; i++) {
      if (events[i].messageId == messageId) {
        targetStart = i;
        break;
      }
    }
    if (targetStart < 0) {
      // No events recorded for this message → nothing to revert.
      return const [];
    }
    final from = includeMessage ? targetStart : targetStart + 1;
    if (from >= events.length) return const [];
    // Newest first: walk the tail backwards so undo order mirrors apply order.
    return events.sublist(from).reversed.toList(growable: false);
  }
}
