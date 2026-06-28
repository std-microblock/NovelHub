import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/editor_state.dart';
import '../../state/providers.dart';
import 'editor_pane.dart';
import 'agent/agent_pane.dart';
import 'novel_list/novel_drawer.dart';
import 'novel_settings/novel_settings_page.dart';

/// The main screen: top bar (chapter switch + edit/select toggle),
/// upper editor pane, lower agent pane. Left drawer = novel list; right
/// swipe = novel settings.
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  double _agentFraction = 0.45;

  @override
  Widget build(BuildContext context) {
    final novelAv = ref.watch(currentNovelProvider);
    final novel = novelAv.valueOrNull;
    final editor = ref.watch(editorStateProvider);

    if (novel == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('NovelHub')),
        drawer: const NovelDrawer(),
        body: const Center(child: Text('左上角菜单 → 新建小说 开始写作')),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: '小说列表',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: _chapterSwitch(editor),
        actions: [
          // Right-swipe affordance -> novel settings.
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '小说设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => NovelSettingsPage(novelId: novel.id)),
            ),
          ),
          _modeSwitch(editor),
        ],
      ),
      drawer: const NovelDrawer(),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 900;
          if (wide) {
            return Row(
              children: [
                Expanded(flex: 1, child: EditorPane(editor: editor)),
                const VerticalDivider(width: 1),
                Expanded(flex: 1, child: AgentPane(editor: editor)),
              ],
            );
          }
          // Vertical split with a draggable handle controlling the agent
          // panel height.
          const handleH = 10.0;
          final total = constraints.maxHeight;
          final agentH = (total * _agentFraction)
              .clamp(120.0, total - 120 - handleH)
              .toDouble();
          return Column(
            children: [
              SizedBox(
                  height: total - agentH - handleH,
                  child: EditorPane(editor: editor)),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) {
                  setState(() {
                    _agentFraction = (agentH - d.delta.dy) / total;
                    _agentFraction = _agentFraction.clamp(0.15, 0.85);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeRow,
                  child: Container(
                    height: handleH,
                    color:
                        Theme.of(context).colorScheme.surfaceContainerLow,
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outline,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: agentH, child: AgentPane(editor: editor)),
            ],
          );
        },
      ),
    );
  }

  Widget _chapterSwitch(EditorState editor) {
    final chapters = editor.novel.chapters;
    return DropdownButton<String>(
      value: editor.chapter.id,
      underline: const SizedBox(),
      items: [
        for (final c in chapters)
          DropdownMenuItem(
            value: c.id,
            child: Text('${c.title} · ${c.paragraphs.length}段'),
          ),
      ],
      onChanged: (id) {
        if (id != null) {
          ref.read(currentNovelProvider.notifier).selectChapter(id);
        }
      },
    );
  }

  Widget _modeSwitch(EditorState editor) {
    final isEdit = editor.mode == EditorMode.edit;
    return IconButton(
      icon: Icon(isEdit ? Icons.edit : Icons.check_box),
      tooltip: isEdit ? '当前：编辑模式' : '当前：选择模式',
      onPressed: () => ref.read(editorStateProvider.notifier).setMode(
            isEdit ? EditorMode.select : EditorMode.edit,
          ),
    );
  }
}
