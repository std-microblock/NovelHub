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

  Widget _chapterSwitch(EditorState editor) {
    final chapters = editor.novel.chapters;
    return ConstrainedBox(
      // Bound the dropdown width so a long chapter title can't blow up the
      // AppBar layout — it ellipsizes instead.
      constraints: const BoxConstraints(maxWidth: 220),
      child: DropdownButton<String>(
        value: editor.chapter.id,
        underline: const SizedBox(),
        isExpanded: true,
        items: [
          for (final c in chapters)
            DropdownMenuItem(
              value: c.id,
              child: Text(
                '${c.title} · ${c.paragraphs.length}段',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
        ],
        onChanged: (id) {
          if (id != null) {
            ref.read(editorStateProvider.notifier).selectChapter(id);
          }
        },
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
