import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities.dart' show Paragraph;
import '../../state/editor_state.dart';
import '../../state/providers.dart' show editorStateProvider;

/// Upper pane: dual-mode editor.
///  - Edit mode: a single multiline text field. Paragraphs are split on
///    `\n\n`, so pressing Enter twice creates a new paragraph automatically.
///  - Select mode: tap-to-select paragraph blocks (multi-select).
class EditorPane extends ConsumerStatefulWidget {
  final EditorState editor;
  /// Extra bottom padding so the editor's scrollable content can rise above
  /// the floating agent panel in portrait (0 in landscape). Equals the panel
  /// height passed from EditorScreen.
  final double bottomInset;
  const EditorPane({super.key, required this.editor, this.bottomInset = 0});

  @override
  ConsumerState<EditorPane> createState() => _EditorPaneState();
}

class _EditorPaneState extends ConsumerState<EditorPane> {
  late TextEditingController _ctrl;
  late ScrollController _scroll;
  bool _editing = false;
  bool _wasEditMode = false;
  String _lastChapterId = '';

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _body());
    _scroll = ScrollController();
    _lastChapterId = ref.read(editorStateProvider).chapter.id;
  }

  String _body() =>
      ref.read(editorStateProvider).chapter.paragraphs.map((p) => p.text).join('\n\n');

  @override
  void didUpdateWidget(covariant EditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final editor = ref.read(editorStateProvider);
    // Resync the field when (a) the chapter changed, (b) we just entered
    // edit mode, or (c) the body changed externally (e.g. agent tool edit)
    // while we're in edit mode but the change didn't originate from typing.
    final external = editor.chapterBody;
    final chapterChanged = editor.chapter.id != _lastChapterId;
    final enteredEdit = editor.mode == EditorMode.edit && !_wasEditMode;
    if (chapterChanged || enteredEdit ||
        (editor.mode == EditorMode.edit && _ctrl.text != external && !_editing)) {
      _lastChapterId = editor.chapter.id;
      _editing = false;
      final sel = _ctrl.selection;
      _ctrl.value = TextEditingValue(
        text: external,
        selection: sel.isValid && sel.start <= external.length
            ? sel
            : TextSelection.collapsed(offset: external.length),
      );
    }
    _wasEditMode = editor.mode == EditorMode.edit;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorStateProvider);
    final notifier = ref.read(editorStateProvider.notifier);
    final isEdit = editor.mode == EditorMode.edit;
    final paragraphs = editor.chapter.paragraphs;

    if (isEdit) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + widget.bottomInset),
        child: TextField(
          controller: _ctrl,
          scrollController: _scroll,
          autofocus: true,
          minLines: null,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: '开始写作…（按两次回车分段）',
          ),
          style: Theme.of(context).textTheme.bodyLarge,
          onChanged: (v) {
            _editing = true;
            notifier.setChapterBody(v);
          },
        ),
      );
    }

    // Select mode: numbered, tappable paragraph blocks.
    if (paragraphs.isEmpty) {
      return const Center(child: Text('（空章节，切换到编辑模式开始写作）'));
    }
    return _ParagraphSelectList(
      paragraphs: paragraphs,
      selectedIds: editor.selectedParagraphIds,
      onToggle: notifier.toggleParagraphSelection,
      onSelectRange: notifier.selectParagraphRange,
      bottomInset: widget.bottomInset,
    );
  }
}

/// Select-mode list with animated selection, tap-to-toggle, and a
/// drag gesture on the numbered gutter that selects a contiguous range
/// of paragraphs (the drag auto-scrolls when reaching the top/bottom).
class _ParagraphSelectList extends StatefulWidget {
  final List<Paragraph> paragraphs;
  final Set<String> selectedIds;
  final void Function(String id) onToggle;
  final void Function(int from, int to, {required bool select}) onSelectRange;
  final double bottomInset;

  const _ParagraphSelectList({
    required this.paragraphs,
    required this.selectedIds,
    required this.onToggle,
    required this.onSelectRange,
    this.bottomInset = 0,
  });

  @override
  State<_ParagraphSelectList> createState() => _ParagraphSelectListState();
}

class _ParagraphSelectListState extends State<_ParagraphSelectList> {
  late final ScrollController _scroll;
  final Map<int, GlobalKey> _keys = {};
  final Map<int, Rect> _rects = {};

  // Drag-to-range state. Null = not dragging.
  int? _dragAnchor; // index where the drag started
  int? _dragLast; // most recent index under the pointer
  bool _dragSelect = true; // whether this drag selects or deselects
  bool _autoScrolling = false;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(int i) => _keys.putIfAbsent(i, GlobalKey.new);

  Rect? _rectFor(int i) {
    final ctx = _keyFor(i).currentContext;
    if (ctx == null) return _rects[i];
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return _rects[i];
    final r = box.localToGlobal(Offset.zero) & box.size;
    _rects[i] = r;
    return r;
  }

  int? _indexAt(double globalY) {
    for (var i = 0; i < widget.paragraphs.length; i++) {
      final r = _rectFor(i);
      if (r == null) continue;
      // Match the gutter strip: leftmost 40px of each row.
      final gutter = Rect.fromLTRB(
          r.left, r.top, r.left + 40, r.bottom);
      if (globalY >= gutter.top && globalY < gutter.bottom) {
        return i;
      }
    }
    // Fall back to nearest by vertical distance (handles gaps between rows).
    int? best;
    double bestDist = double.infinity;
    for (var i = 0; i < widget.paragraphs.length; i++) {
      final r = _rectFor(i);
      if (r == null) continue;
      final mid = r.center.dy;
      final d = (mid - globalY).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  void _startDrag(int index) {
    // If the anchor is already selected, this drag deselects; else selects.
    final id = widget.paragraphs[index].id;
    setState(() {
      _dragAnchor = index;
      _dragLast = index;
      _dragSelect = !widget.selectedIds.contains(id);
    });
    widget.onSelectRange(index, index, select: _dragSelect);
  }

  void _updateDrag(Offset globalPosition) {
    final idx = _indexAt(globalPosition.dy);
    if (idx == null) return;
    if (idx == _dragLast) return;
    final anchor = _dragAnchor ?? idx;
    setState(() => _dragLast = idx);
    widget.onSelectRange(anchor, idx, select: _dragSelect);
    _maybeAutoScroll(globalPosition.dy);
  }

  void _endDrag() {
    setState(() {
      _dragAnchor = null;
      _dragLast = null;
    });
    _autoScrolling = false;
  }

  void _maybeAutoScroll(double globalY) {
    if (_autoScrolling) return;
    final viewport = context.findRenderObject() as RenderBox?;
    if (viewport == null) return;
    final vpRect = viewport.localToGlobal(Offset.zero) & viewport.size;
    const edge = 48.0;
    double? target;
    if (globalY > vpRect.bottom - edge) {
      target = _scroll.offset + 32;
    } else if (globalY < vpRect.top + edge) {
      target = _scroll.offset - 32;
    }
    if (target == null) return;
    target = target.clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 1) return;
    _autoScrolling = true;
    _scroll.animateTo(target,
        duration: const Duration(milliseconds: 80), curve: Curves.linear).then((_) {
      _autoScrolling = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerUp: (_) => _endDrag(),
      onPointerCancel: (_) => _endDrag(),
      onPointerMove: (event) {
        if (_dragAnchor != null) _updateDrag(event.position);
      },
      child: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + widget.bottomInset),
        itemCount: widget.paragraphs.length,
        itemBuilder: (context, i) {
          final p = widget.paragraphs[i];
          final id = p.id;
          final selected = widget.selectedIds.contains(id);
          return Padding(
            key: _keyFor(i),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => widget.onToggle(id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  // No border — selection is conveyed by color + scale only.
                  color: selected
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Numbered gutter — also the drag handle.
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) => _startDrag(i),
                        onTap: () => widget.onToggle(id),
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 150),
                            transitionBuilder: (child, anim) =>
                                ScaleTransition(scale: anim, child: child),
                            child: Center(
                                    key: ValueKey('num$i'),
                                    child: Text('${i + 1}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant)),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.text.isEmpty ? '（空段落）' : p.text,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
