import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/editor_state.dart';
import '../../state/providers.dart' show editorStateProvider;

/// Upper pane: dual-mode editor.
///  - Edit mode: a single multiline text field. Paragraphs are split on
///    `\n\n`, so pressing Enter twice creates a new paragraph automatically.
///  - Select mode: tap-to-select paragraph blocks (multi-select).
class EditorPane extends ConsumerStatefulWidget {
  final EditorState editor;
  const EditorPane({super.key, required this.editor});

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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: paragraphs.length,
      itemBuilder: (context, i) {
        final p = paragraphs[i];
        final selected = editor.selectedParagraphIds.contains(p.id);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => notifier.toggleParagraphSelection(p.id),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: selected
                    ? Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1.5)
                    : null,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text('${i + 1}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
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
    );
  }
}
