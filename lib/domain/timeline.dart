/// Timeline over a ParagraphDoc: revertTo(messageId) undoes every event
/// recorded *after* (and optionally including) that message, restoring the
/// document to the state it had at that message.
///
/// Events are appended by the doc tools (edit/delete/insert) tagged with the
/// messageId of the agent turn that caused them. Reverting a message also
/// conceptually reverts any tool calls that message produced.
library;

import 'paragraph_doc.dart';

class Timeline {
  final ParagraphDoc doc;

  Timeline(this.doc);

  /// Revert the document to the state it was in immediately AFTER the events
  /// belonging to [messageId] (i.e. undo everything recorded after that
  /// message's events). Returns the number of events undone.
  ///
  /// If [includeMessage] is true, also undo the events tagged with
  /// [messageId] itself (useful for "redo this message" before resending).
  int revertTo(String messageId, {bool includeMessage = false}) {
    // Walk from the newest event backwards, undoing until we've passed all
    // events that should be removed.
    final toUndo = <MutationEvent>[];
    for (final ev in doc.events.reversed) {
      final isTarget = ev.messageId == messageId;
      final stop = isTarget && !includeMessage;
      if (stop) break; // keep this message's own events
      toUndo.add(ev);
      if (isTarget && includeMessage) {
        // include this event and everything above
      }
    }
    for (final ev in toUndo) {
      doc.undo(ev);
    }
    doc.dropEventsById(toUndo.map((e) => e.id));
    return toUndo.length;
  }
}
