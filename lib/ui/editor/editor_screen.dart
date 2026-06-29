import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/editor_state.dart';
import '../../state/providers.dart';
import 'editor_pane.dart';
import 'agent/agent_pane.dart';
import 'novel_list/novel_drawer.dart';
import 'novel_settings/novel_settings_page.dart';
import 'prompt_string.dart';

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
  // Raw pixel height of the agent panel (portrait only). Tracked directly off
  // the finger's absolute position — no delta accumulation — so the handle
  // follows the finger 1:1 regardless of gesture-arena delta coalescing.
  double? _agentH;
  // Anchors captured on drag start: global Y and height at that moment.
  double _dragStartY = 0;
  double _dragStartH = 0;

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
          // Manually add a new chapter (mirrors the agent's add_chapter tool).
          IconButton(
            icon: const Icon(Icons.post_add),
            tooltip: '新增章节',
            onPressed: () => _promptNewChapter(context),
          ),
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
      // Pad the bottom so content clears the edge-to-edge system navigation
      // bar (gesture handle); otherwise the agent pane renders behind it.
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
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
          // Vertical split: editor on top, a floating agent panel docked to
          // the bottom edge with rounded top corners + shadow. The drag handle
          // is an overlay that takes no layout space and only shows on hover or
          // while dragging.
          final total = constraints.maxHeight;
          final agentH = (_agentH ?? total * 0.45)
              .clamp(120.0, total - 80)
              .toDouble();
          return Stack(
            // No clip so the shadow can spread above the panel onto the editor.
            clipBehavior: Clip.none,
            children: [
              // Upper editor fills everything; the floating panel overlaps its
              // lower portion (the shadow sits on top of the editor).
              Positioned.fill(
                child: EditorPane(editor: editor),
              ),
              // Floating agent panel: top rounded corners + drop shadow; the
              // bottom edge is flush with the screen bottom (square corners).
              // BoxShadow (not Material.elevation) so it paints even though the
              // panel body itself is colored by AgentPane — and it survives the
              // transparent-background rendering path.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: agentH,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 16,
                        spreadRadius: -2,
                        offset: const Offset(0, -3),
                      ),
                    ],
                  ),
                  child: ClipPath(
                    clipper: const _TopRoundClipper(top: 16),
                    child: AgentPane(editor: editor),
                  ),
                ),
              ),
              // Drag handle: overlay straddling the panel's top edge, no layout
              // footprint. Kept thin and mostly inside the panel's top padding
              // so it doesn't block the header's tap targets.
              Positioned(
                left: 0,
                right: 0,
                bottom: agentH - 6,
                height: 14,
                child: _AgentHandle(
                  // Absolute-position based: recompute height from the finger's
                  // global Y every frame instead of accumulating deltas. Delta
                  // accumulation was losing ~1/3 of the motion (fixed ratio),
                  // likely from gesture-arena delta coalescing. Position-based
                  // dragging is immune to that — the panel tracks the finger 1:1.
                  onStart: (startGlobalY) {
                    _dragStartY = startGlobalY;
                    _dragStartH = agentH;
                  },
                  onUpdate: (globalY) {
                    setState(() {
                      final dragDistance = _dragStartY - globalY;
                      _agentH = (_dragStartH + dragDistance)
                          .clamp(120.0, total - 80)
                          .toDouble();
                    });
                  },
                ),
              ),
            ],
          );
        },
        ),
      ),
    );
  }

  Future<void> _promptNewChapter(BuildContext context) async {
    final chapters = ref.read(editorStateProvider).novel.chapters;
    final initial = '第${chapters.length + 1}章';
    final title = await promptString(
      context,
      title: '新增章节',
      hint: '章节标题',
      initial: initial,
      confirmLabel: '创建',
    );
    if (title != null && title.isNotEmpty && context.mounted) {
      await ref.read(editorStateProvider.notifier).addChapter(title);
    }
  }

  Widget _chapterSwitch(EditorState editor) {
    final chapter = editor.chapter;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: TextButton(
        onPressed: () => _openChapterManager(context, editor),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '${chapter.title} · ${chapter.paragraphs.length}段',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  Future<void> _openChapterManager(
      BuildContext context, EditorState editor) async {
    await showDialog<void>(
      context: context,
      builder: (c) => _ChapterManagerDialog(
        editor: editor,
        notifier: ref.read(editorStateProvider.notifier),
      ),
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

/// The floating agent panel's drag handle. Takes no layout space (it's an
/// overlay) and the grip bar only appears on hover or while dragging.
class _AgentHandle extends StatefulWidget {
  final void Function(double startGlobalY) onStart;
  final void Function(double globalY) onUpdate;
  const _AgentHandle({required this.onStart, required this.onUpdate});

  @override
  State<_AgentHandle> createState() => _AgentHandleState();
}

class _AgentHandleState extends State<_AgentHandle> {
  bool _hover = false;
  bool _dragging = false;

  bool get _active => _hover || _dragging;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // Opaque so the handle wins the vertical-drag gesture outright —
        // otherwise the ListView below it competes in the arena and swallows
        // part of every drag, which makes the panel lag behind the finger.
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (d) {
          setState(() => _dragging = true);
          // Hand the starting global Y to the parent so it can anchor the
          // absolute-position-based height computation.
          widget.onStart(d.globalPosition.dy);
        },
        // Recompute the target height from the finger's *absolute* position
        // every update — immune to delta coalescing/loss that broke
        // delta-based dragging (it tracked at ~2/3 speed).
        onVerticalDragUpdate: (d) => widget.onUpdate(d.globalPosition.dy),
        onVerticalDragEnd: (_) => setState(() => _dragging = false),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _active ? 1 : 0,
          child: Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clips only the top corners rounded, leaving the bottom edge square so the
/// floating panel sits flush against the screen bottom while the [Material]
/// above paints the matching rounded shadow.
class _TopRoundClipper extends CustomClipper<Path> {
  final double top;
  const _TopRoundClipper({required this.top});

  @override
  Path getClip(Size size) {
    final r = Radius.circular(top);
    return Path()
      ..moveTo(0, top)
      ..arcToPoint(Offset(top, 0), radius: r)
      ..lineTo(size.width - top, 0)
      ..arcToPoint(Offset(size.width, top), radius: r)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_TopRoundClipper old) => old.top != top;
}

/// Chapter management dialog: lists every chapter with inline rename /
/// reorder / delete actions plus a header button to add a new chapter.
/// Tapping a row switches to that chapter and closes the dialog.
///
/// It rebuilds from the live [EditorState] on every notifier change so the
/// list reflects renames / reorders / deletions immediately.
class _ChapterManagerDialog extends ConsumerWidget {
  final EditorState editor;
  final EditorStateNotifier notifier;

  const _ChapterManagerDialog({required this.editor, required this.notifier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Re-read the live state so mutations performed from within the dialog
    // (rename / move / delete) are reflected without reopening it.
    final live = ref.watch(editorStateProvider);
    final chapters = live.novel.chapters;
    final currentId = live.chapter.id;
    final canDelete = chapters.length > 1;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('章节管理'),
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('新增'),
            onPressed: () async {
              final initial = '第${chapters.length + 1}章';
              final title = await promptString(
                context,
                title: '新增章节',
                hint: '章节标题',
                initial: initial,
                confirmLabel: '创建',
              );
              if (title != null && title.isNotEmpty) {
                await notifier.addChapter(title);
              }
            },
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: chapters.length,
          itemBuilder: (c, i) {
            final ch = chapters[i];
            final selected = ch.id == currentId;
            return ListTile(
              selected: selected,
              leading: Text('${i + 1}',
                  style: const TextStyle(color: Colors.grey)),
              title: Text(ch.title,
                  overflow: TextOverflow.ellipsis, maxLines: 1),
              subtitle: Text('${ch.paragraphs.length}段'),
              onTap: () {
                notifier.selectChapter(ch.id);
                Navigator.pop(c);
              },
              trailing: PopupMenuButton<String>(
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'rename', child: Text('重命名')),
                  PopupMenuItem(
                    value: 'up',
                    enabled: i > 0,
                    child: const Text('上移'),
                  ),
                  PopupMenuItem(
                    value: 'down',
                    enabled: i < chapters.length - 1,
                    child: const Text('下移'),
                  ),
                  PopupMenuItem(
                    value: 'del',
                    enabled: canDelete,
                    child: const Text('删除'),
                  ),
                ],
                onSelected: (v) async {
                  if (v == 'rename') {
                    final title = await promptString(
                      context,
                      title: '重命名章节',
                      initial: ch.title,
                      confirmLabel: '保存',
                    );
                    if (title != null && title.isNotEmpty) {
                      await notifier.renameChapter(ch.id, title);
                    }
                  } else if (v == 'up') {
                    await notifier.moveChapter(ch.id, i);
                  } else if (v == 'down') {
                    await notifier.moveChapter(ch.id, i + 2);
                  } else if (v == 'del') {
                    final ok = await showDialog<bool>(
                          context: context,
                          builder: (cc) => AlertDialog(
                            title: const Text('删除章节'),
                            content: Text(
                                '删除「${ch.title}」及其全部段落？此操作不可撤销。'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(cc, false),
                                  child: const Text('取消')),
                              FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(cc, true),
                                  child: const Text('删除')),
                            ],
                          ),
                        ) ??
                        false;
                    if (ok) await notifier.deleteChapter(ch.id);
                  }
                },
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
