import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' show kTabScrollDuration;

/// A pager driven by the selected destination, without a horizontal gesture.
class DestinationPages extends StatefulWidget {
  const DestinationPages({
    super.key,
    required this.index,
    required this.itemCount,
    required this.itemBuilder,
  });

  final int index;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<DestinationPages> createState() => _DestinationPagesState();
}

class _DestinationPagesState extends State<DestinationPages> {
  late final _controller = PageController(
    initialPage: widget.index,
    keepPage: false,
  );
  bool _reduceMotion = false;
  bool _syncScheduled = false;
  double? _viewportWidth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceMotion) _scheduleSync();
    _reduceMotion = reduceMotion;
  }

  @override
  void didUpdateWidget(covariant DestinationPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) _scheduleSync();
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted || !_controller.hasClients) return;
      if (_reduceMotion) {
        _controller.jumpToPage(widget.index);
      } else {
        unawaited(
          _controller.animateToPage(
            widget.index,
            duration: kTabScrollDuration,
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  bool _handleMetrics(ScrollMetricsNotification notification) {
    if (notification.depth != 0) return false;
    final width = notification.metrics.viewportDimension;
    final previousWidth = _viewportWidth;
    _viewportWidth = width;
    // The animation's pixel target belongs to the old width. Settle on the
    // selected page if the window resizes or switches navigation layouts.
    if (previousWidth != null &&
        previousWidth != width &&
        _controller.page != widget.index) {
      _controller.jumpToPage(widget.index);
    }
    return false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: _handleMetrics,
        child: PageView.builder(
          controller: _controller,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.itemCount,
          itemBuilder: (context, index) {
            final active = index == widget.index;
            return ExcludeFocus(
              excluding: !active,
              child: ExcludeSemantics(
                excluding: !active,
                child: IgnorePointer(
                  ignoring: !active,
                  child: widget.itemBuilder(context, index),
                ),
              ),
            );
          },
        ),
      );
}
