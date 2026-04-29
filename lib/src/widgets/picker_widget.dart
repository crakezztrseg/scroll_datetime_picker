import 'package:flutter/material.dart';
import 'package:scroll_datetime_picker/scroll_datetime_picker.dart';

/// A single scrollable column in the date-time picker.
///
/// Changes from the original:
///
/// **Bug 1 – rowIndex wrapping on physics overshoot (picker_widget.dart:176)**
/// The original `rowIndex = (endExtent / itemExtent).floor() % itemCount`
/// could wrap to 0 when the ballistic scroll physics momentarily pushed the
/// offset past the last item (e.g. offset = 2×itemExtent for a 2-item year
/// column → 2 % 2 = 0 = wrong year).  endExtent is now clamped to
/// [0, (itemCount-1)×itemExtent] before the division, so the computed index
/// is always in the valid range.
///
/// **Bug 2 – stale _isProgrammaticScroll causes phantom onChange calls**
/// The original ScrollTypeListener detected programmatic scrolls by watching
/// for the absence of a UserScrollNotification.  For short programmatic
/// animations no ScrollUpdateNotification is emitted, so the listener never
/// updated the flag and it kept the stale value from the previous user
/// interaction.  This caused _onNotification to treat the programmatic
/// _fixPosition correction scroll as a user gesture and call onChange with
/// the corrected position, triggering a cascading date change.
///
/// The fix replaces ScrollTypeListener with two explicit flags:
///   • _isSnapping  — set around the local grid-snap animateTo inside
///                    _onNotification, preventing re-entrant calls.
///   • widget.isProgrammaticScroll — a ValueNotifier<bool> owned by the
///                    parent (_ScrollDateTimePickerState) and set to true
///                    around every _fixPosition / _driveDatePosition call.
class PickerWidget extends StatefulWidget {
  const PickerWidget({
    super.key,
    required this.itemCount,
    required this.itemExtent,
    required this.infiniteScroll,
    required this.onChange,
    required this.controller,
    required this.activeBuilder,
    required this.inactiveBuilder,
    required this.wheelOption,
    required this.isProgrammaticScroll,
  });

  final int itemCount;
  final double itemExtent;
  final bool infiniteScroll;

  final void Function(int index) onChange;
  final ScrollController controller;
  final Widget Function(int index) activeBuilder;
  final Widget Function(int index) inactiveBuilder;

  final DateTimePickerWheelOption wheelOption;

  /// Owned by the parent; set to true before any programmatic animateTo
  /// (e.g. _fixPosition, _driveDatePosition) and false after it completes.
  /// When true, _onNotification ignores ScrollEndNotification events so that
  /// programmatic corrections do not fire onChange.
  final ValueNotifier<bool> isProgrammaticScroll;

  @override
  State<PickerWidget> createState() => _PickerWidgetState();
}

class _PickerWidgetState extends State<PickerWidget> {
  late DateTimePickerWheelOption _wheelOption;

  /// True while _onNotification is running its own grid-snap animateTo.
  /// Prevents the ScrollEndNotification emitted by that snap from re-entering
  /// _onNotification and calling onChange a second time.
  bool _isSnapping = false;

  final _centerScrollCtl = ScrollController();
  final _outerScrollCtl = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrollListener);
    _wheelOption = widget.wheelOption;
  }

  @override
  void didUpdateWidget(covariant PickerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.wheelOption != _wheelOption) {
      setState(() => _wheelOption = widget.wheelOption);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrollListener);
    _centerScrollCtl.dispose();
    _outerScrollCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        /* Outer (inactive) scrollable — visual only, pointer-ignored */
        IgnorePointer(
          child: ClipPath(
            clipper: _OuterWidgetClipper(itemExtent: widget.itemExtent),
            child: ListWheelScrollView.useDelegate(
              controller: _outerScrollCtl,
              itemExtent: widget.itemExtent,
              physics: _wheelOption.physics,
              perspective: _wheelOption.perspective,
              diameterRatio: _wheelOption.diameterRatio,
              offAxisFraction: _wheelOption.offAxisFraction,
              squeeze: _wheelOption.squeeze,
              renderChildrenOutsideViewport:
                  _wheelOption.renderChildrenOutsideViewport,
              clipBehavior: _wheelOption.clipBehavior,
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: widget.infiniteScroll ? null : widget.itemCount,
                builder: (context, index) => SizedBox(
                  height: widget.itemExtent,
                  child: widget.inactiveBuilder.call(index),
                ),
              ),
            ),
          ),
        ),

        /* Centre (active item highlight) — visual only, pointer-ignored */
        IgnorePointer(
          child: SizedBox(
            height: widget.itemExtent,
            child: ListWheelScrollView.useDelegate(
              controller: _centerScrollCtl,
              itemExtent: widget.itemExtent,
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: widget.infiniteScroll ? null : widget.itemCount,
                builder: (context, index) => SizedBox(
                  height: widget.itemExtent,
                  child: widget.activeBuilder.call(index),
                ),
              ),
            ),
          ),
        ),

        /* Interactive scrollable — transparent hit-test target */
        NotificationListener<ScrollNotification>(
          onNotification: _onNotification,
          child: ListWheelScrollView.useDelegate(
            controller: widget.controller,
            itemExtent: widget.itemExtent,
            physics: _wheelOption.physics,
            perspective: _wheelOption.perspective,
            diameterRatio: _wheelOption.diameterRatio,
            offAxisFraction: _wheelOption.offAxisFraction,
            squeeze: _wheelOption.squeeze,
            renderChildrenOutsideViewport:
                _wheelOption.renderChildrenOutsideViewport,
            clipBehavior: _wheelOption.clipBehavior,
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: widget.infiniteScroll ? null : widget.itemCount,
              builder: (_, __) => SizedBox(height: widget.itemExtent),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Scroll sync
  // ---------------------------------------------------------------------------

  void _scrollListener() {
    _centerScrollCtl.jumpTo(widget.controller.position.pixels);
    _outerScrollCtl.jumpTo(widget.controller.position.pixels);
  }

  // ---------------------------------------------------------------------------
  // Notification handling
  // ---------------------------------------------------------------------------

  bool _onNotification(ScrollNotification notification) {
    if (!widget.controller.hasClients) return true;

    // ── Guard: ignore notifications from programmatic scrolls ────────────────
    // _isSnapping:                this widget's own grid-snap animateTo
    // widget.isProgrammaticScroll: parent's _fixPosition / _driveDatePosition
    if (_isSnapping || widget.isProgrammaticScroll.value) return true;

    if (notification is ScrollEndNotification) {
      // Snap the wheel to the nearest grid position.
      final overshoot = widget.controller.offset % widget.itemExtent;
      final lowestExtent = widget.controller.offset - overshoot;
      final midExtent = widget.itemExtent / 2;
      final rawEndExtent =
          overshoot > midExtent ? lowestExtent + widget.itemExtent : lowestExtent;

      // ── FIX Bug 1: clamp before computing rowIndex ───────────────────────
      // Without clamping, a physics overshoot past the last item (e.g. offset
      // = 2×itemExtent for a 2-item year column) causes rawEndExtent to equal
      // itemCount×itemExtent, and the subsequent `% itemCount` wraps rowIndex
      // back to 0 (the first item), selecting the wrong year.
      final maxExtent =
          (widget.itemCount - 1).toDouble() * widget.itemExtent;
      final endExtent = rawEndExtent.clamp(0.0, maxExtent);

      // 0-based index of the item that will be centred after snapping.
      final rowIndex = (endExtent / widget.itemExtent).round().clamp(0, widget.itemCount - 1);

      Future.delayed(Duration.zero, () async {
        if (!mounted) return;
        if (!widget.controller.hasClients) return;

        // Bail out if the wheel is already scrolling (e.g. another gesture
        // started in the Duration.zero window).
        if (widget.controller.position.isScrollingNotifier.value) return;

        // ── FIX Bug 2: set _isSnapping before animateTo ──────────────────
        // The grid-snap animateTo below emits its own ScrollEndNotification.
        // Setting _isSnapping = true prevents _onNotification from treating
        // that notification as a new user gesture and calling onChange again.
        _isSnapping = true;
        try {
          await widget.controller.animateTo(
            endExtent,
            duration: const Duration(milliseconds: 500),
            curve: Curves.bounceOut,
          );
        } finally {
          _isSnapping = false;
        }

        // Notify parent only once, after the snap has settled.
        if (mounted) widget.onChange.call(rowIndex);
      });
    }

    return true;
  }
}

// ---------------------------------------------------------------------------
// Clip shape for the inactive items shown above and below the active slot
// ---------------------------------------------------------------------------

class _OuterWidgetClipper extends CustomClipper<Path> {
  const _OuterWidgetClipper({required this.itemExtent});

  final double itemExtent;

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => true;

  @override
  Path getClip(Size size) {
    const xMin = 0.0;
    final xMax = size.width;
    final yMin = (size.height - itemExtent) / 2;
    final yMax = yMin + itemExtent;

    final upperRect = Rect.fromPoints(Offset.zero, Offset(xMax, yMin));
    final lowerRect =
        Rect.fromPoints(Offset(xMin, yMax), Offset(size.width, size.height));

    return Path()
      ..addRect(upperRect)
      ..addRect(lowerRect)
      ..close();
  }
}