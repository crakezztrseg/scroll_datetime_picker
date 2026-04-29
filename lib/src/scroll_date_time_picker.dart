import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:scroll_datetime_picker/src/entities/date_time_picker_helper.dart';
import 'package:scroll_datetime_picker/src/entities/enums.dart';
import 'package:scroll_datetime_picker/src/widgets/picker_widget.dart';

part 'entities/date_time_picker_prefix_flex.dart';
part 'entities/date_time_picker_center_widget.dart';
part 'entities/date_time_picker_prefix_widget.dart';
part 'entities/date_time_picker_controller.dart';
part 'entities/date_time_picker_item_flex.dart';
part 'entities/date_time_picker_option.dart';
part 'entities/date_time_picker_style.dart';
part 'entities/date_time_picker_wheel_option.dart';
part 'util/date_time_picker_flex_calculator.dart';

typedef DateTimePickerItemBuilder = Widget Function(
  BuildContext context,
  String pattern,
  String text,
  bool isActive,
  bool isDisabled,
);

/// A customizable Scrollable DateTimePicker.
///
/// To set a custom datetime format, use DateFormat available in
/// `[dateOption]` param
///
/// To set styles for the picker, use `[style]` param
class ScrollDateTimePicker extends StatefulWidget {
  const ScrollDateTimePicker({
    super.key,
    required this.itemExtent,
    required this.dateOption,
    required this.onChange,
    this.controller,
    this.itemBuilder,
    this.style,
    this.visibleItem = 3,
    this.infiniteScroll = false,
    this.markOutOfRangeDateInvalid = true,
    this.itemFlex = const DateTimePickerItemFlex(),
    this.wheelOption = const DateTimePickerWheelOption(),
    this.centerWidget = const DateTimePickerCenterWidget(),
    this.prefixWidget = const DateTimePickerPrefixWidget(),
    this.prefixFlex = const DateTimePickerPrefixFlex(),
  });

  /// Optional controller for managing the picker's state.
  ///
  /// This can be used to programmatically update the selected date/time.
  final DateTimePickerController? controller;

  /// Height of every item in the picker
  ///
  /// Must not be null
  final double itemExtent;

  /// Number of item to be shown vertically
  ///
  /// Defaults to 3
  final int visibleItem;

  /// Whether to implement infinite scroll or finite scroll.
  ///
  /// Defaults to false
  final bool infiniteScroll;

  /// Callback called when the selected date and/or time changes.
  ///
  /// Must not be null.
  final void Function(DateTime datetime)? onChange;

  /// Set datetime configuration
  ///
  /// Must not be null.
  final DateTimePickerOption dateOption;

  /// Set picker styles.
  ///
  /// If [itemBuilder] is not null, this value will be omitted.
  final DateTimePickerStyle? style;

  /// Set custom appearance for the picker wheel
  ///
  /// The parameters here are based on flutter's [ListWheelScrollView]
  final DateTimePickerWheelOption wheelOption;

  /// Set custom appearance for every item in the picker wheel
  ///
  /// - If null, the appearance of every item will be based on DateTimePickerStyle [style]
  /// - If not null, the appearance of every item will be based return value of this builder
  final DateTimePickerItemBuilder? itemBuilder;

  /// Custom flex width settings for each date and time item in the picker wheel.
  ///
  /// This parameter allows you to specify different flex widths for each date and time item,
  /// such as year, month, day, hour, minute, and second, allowing for a more flexible and
  /// visually appealing layout.
  ///
  /// Defaults to `const DateTimePickerItemFlex()` with all values set to 1.
  final DateTimePickerItemFlex itemFlex;

  /// Custom center widget settings for each date and time item in the picker wheel.
  ///
  /// This parameter allows you to specify custom center widgets for each date and
  /// time item, such as year, month, day, hour, minute, and second, allowing for
  /// a more customizable layout. You can set different widgets for each
  /// date and time type or use a custom builder to customize the appearance
  /// of the center area in the picker.
  ///
  /// - If not set, the center widget will be a default layout with no customization.
  /// - Use the individual widget parameters in `DateTimePickerCenterWidget` to specify
  ///   custom widgets for each date and time type.
  final DateTimePickerCenterWidget centerWidget;

  /// Custom prefix widget settings for each date and time item in the picker wheel.
  ///
  /// This parameter allows you to specify custom prefix widgets for each date and
  /// time item, such as year, month, day, hour, minute, and second, allowing for
  /// a more customizable layout. You can set different widgets for each
  /// date and time type or use a custom builder to customize the appearance
  /// of the prefix area in the picker.
  ///
  /// - If not set, no prefix widgets will be displayed.
  /// - Use the individual widget parameters in `DateTimePickerPrefixWidget` to specify
  ///   custom widgets for each date and time type.
  final DateTimePickerPrefixWidget prefixWidget;

  /// Custom flex width settings for each prefix item in the picker wheel.
  ///
  /// This parameter allows you to specify different flex widths for each prefix item,
  /// such as year, month, day, hour, minute, and second, allowing for a more flexible and
  /// visually appealing layout.
  ///
  /// Defaults to `const DateTimePickerPrefixFlex()` with all values set to 1.
  final DateTimePickerPrefixFlex prefixFlex;

  /// Whether to mark out-of-range dates as invalid.
  ///
  /// If set to true, dates before the minimum date and after the maximum date
  /// will be considered invalid selections, and the user will not be able
  /// to choose them. If set to false, the user can still select out-of-range
  /// dates.
  final bool markOutOfRangeDateInvalid;

  @override
  State<ScrollDateTimePicker> createState() => _ScrollDateTimePickerState();
}

class _ScrollDateTimePickerState extends State<ScrollDateTimePicker> {
  late DateTime _activeDate;
  late List<ScrollController> _controllers;

  late DateTimePickerStyle _style;
  late DateTimePickerOption _option;
  late DateTimePickerHelper _helper;

  late final ValueNotifier<bool> _isRecheckingPosition;

  // ── FIX Bug 2: explicit programmatic-scroll flag ────────────────────────────
  // Shared with all PickerWidget columns.  Set to true before any programmatic
  // animateTo (_fixPosition, _driveDatePosition) and false after it completes.
  // PickerWidget reads this flag in _onNotification to decide whether a
  // ScrollEndNotification originated from user input (→ call onChange) or from
  // one of our own corrections (→ ignore).
  //
  // This replaces the fragile ScrollTypeListener approach, which relied on
  // UserScrollNotification being present in the scroll sequence.  Short
  // programmatic animations often emit no ScrollUpdateNotification at all,
  // leaving the listener's flag stale and causing phantom onChange calls.
  final ValueNotifier<bool> _programmaticScrollActive =
      ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();

    initializeDateFormatting(widget.dateOption.locale.languageCode);
    _isRecheckingPosition = ValueNotifier(false);

    _option = widget.dateOption;
    _activeDate = _option.getInitialDate;
    _helper = DateTimePickerHelper(_option, widget.itemFlex, widget.prefixFlex);
    _style = widget.style ?? DateTimePickerStyle();
    _controllers = List.generate(
      _option.patterns.length,
      (index) => ScrollController(),
    );

    /* Init controller */
    if (widget.controller != null) {
      widget.controller?.addListener(() async {
        if (widget.controller?.value.activeDate == null) return;
        return _driveDatePosition(widget.controller!.value.activeDate!);
      });
    }

    /* Init date position */
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => _driveDatePosition(_option.getInitialDate, force: true),
    );
  }

  @override
  void didUpdateWidget(covariant ScrollDateTimePicker oldWidget) {
    super.didUpdateWidget(oldWidget);

    final dateOptionChanged = widget.dateOption != _option;
    final itemFlexChanged = widget.itemFlex != oldWidget.itemFlex;
    final prefixFlexChanged = widget.prefixFlex != oldWidget.prefixFlex;

    if (dateOptionChanged) {
      setState(() {
        _option = widget.dateOption;
        _helper =
            DateTimePickerHelper(_option, widget.itemFlex, widget.prefixFlex);

        if (_option.patterns.length != _controllers.length) {
          final difference = _option.patterns.length - _controllers.length;
          if (difference.isNegative) {
            _controllers.removeRange(
              _controllers.length - difference.abs(),
              _controllers.length,
            );
          } else {
            _controllers.addAll(
              List.generate(
                difference,
                (_) => ScrollController(),
              ),
            );
          }
        }
      });
    } else if (itemFlexChanged || prefixFlexChanged) {
      setState(() {
        _helper =
            DateTimePickerHelper(_option, widget.itemFlex, widget.prefixFlex);
      });
    }

    if (widget.style != _style) {
      setState(() {
        _style = widget.style ?? _style;
      });
    }
  }

  @override
  void dispose() {
    _isRecheckingPosition.dispose();
    _programmaticScrollActive.dispose();

    for (final ctrl in _controllers) {
      ctrl.dispose();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: constraints.maxWidth,
        height: widget.itemExtent * widget.visibleItem,
        child: Stack(
          alignment: Alignment.center,
          children: [
            /* Center Decoration */
            SizedBox(
              height: widget.itemExtent,
              width: constraints.maxWidth,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final child = widget.centerWidget.hasTypeSpecificCenterWidgets
                      ? Row(
                          children: List.generate(
                            _option.patterns.length,
                            (colIndex) {
                              final pattern = _option.patterns[colIndex];
                              final type = DateTimeType.fromPattern(pattern);

                              return Expanded(
                                flex: _helper.getColumnFlex(
                                  type,
                                  widget.prefixWidget,
                                ),
                                child: Row(
                                  children: [
                                    if (_helper.hasPrefixWidget(
                                      type,
                                      widget.prefixWidget,
                                    ))
                                      SizedBox(
                                        width: _helper.getPrefixWidth(
                                          type,
                                          widget.prefixWidget,
                                          constraints.maxWidth,
                                        ),
                                      ),
                                    Expanded(
                                      child: widget.centerWidget
                                              .getCenterWidget(type) ??
                                          const SizedBox(),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        )
                      : const SizedBox();

                  return widget.centerWidget.builder
                          ?.call(context, constraints, child) ??
                      child;
                },
              ),
            ),

            /* Picker columns */
            SizedBox(
              width: constraints.maxWidth,
              height: widget.itemExtent * widget.visibleItem,
              child: Row(
                children: List.generate(
                  _option.patterns.length,
                  (colIndex) {
                    final pattern = _option.patterns[colIndex];
                    final type = DateTimeType.fromPattern(pattern);

                    return Expanded(
                      flex: _helper.getColumnFlex(type, widget.prefixWidget),
                      child: Row(
                        children: [
                          // Prefix Widget
                          if (_helper.hasPrefixWidget(
                            type,
                            widget.prefixWidget,
                          ))
                            SizedBox(
                              width: _helper.getPrefixWidth(
                                type,
                                widget.prefixWidget,
                                constraints.maxWidth,
                              ),
                              child:
                                  widget.prefixWidget.getPrefixWidget(type),
                            ),
                          Expanded(
                            child: PickerWidget(
                              itemExtent: widget.itemExtent,
                              infiniteScroll: widget.infiniteScroll,
                              controller: _controllers[colIndex],
                              onChange: (rowIndex) =>
                                  _onChange(type, rowIndex),
                              itemCount: _helper.itemCount(type),
                              wheelOption: widget.wheelOption,
                              // Pass the shared flag so PickerWidget can
                              // distinguish user scrolls from our programmatic
                              // corrections (_fixPosition / _driveDatePosition).
                              isProgrammaticScroll: _programmaticScrollActive,
                              inactiveBuilder: (rowIndex) {
                                final text =
                                    _helper.getText(type, pattern, rowIndex);
                                final isDisabled = _helper.isTextDisabled(
                                  type,
                                  _activeDate,
                                  rowIndex,
                                );

                                return widget.itemBuilder != null
                                    ? widget.itemBuilder!(
                                        context,
                                        pattern,
                                        text,
                                        false,
                                        isDisabled,
                                      )
                                    : Container(
                                        width: constraints.maxWidth,
                                        height: widget.itemExtent,
                                        alignment: Alignment.center,
                                        decoration: _style.inactiveDecoration,
                                        child: Text(
                                          text,
                                          style: isDisabled
                                              ? _style.disabledStyle
                                              : _style.inactiveStyle,
                                        ),
                                      );
                              },
                              activeBuilder: (rowIndex) {
                                final text =
                                    _helper.getText(type, pattern, rowIndex);
                                final isDisabled = _helper.isTextDisabled(
                                  type,
                                  _activeDate,
                                  rowIndex,
                                );

                                return widget.itemBuilder != null
                                    ? widget.itemBuilder!(
                                        context,
                                        pattern,
                                        text,
                                        true,
                                        isDisabled,
                                      )
                                    : Container(
                                        width: constraints.maxWidth,
                                        height: widget.itemExtent,
                                        alignment: Alignment.center,
                                        decoration: _style.activeDecoration,
                                        child: Text(
                                          text,
                                          style: isDisabled
                                              ? _style.disabledStyle
                                              : _style.activeStyle,
                                        ),
                                      );
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Programmatic positioning (controller / init)
  // ---------------------------------------------------------------------------

  Future<void> _driveDatePosition(
    DateTime targetDate, {
    bool force = false,
  }) async {
    /* 1. If target date already same, return */
    if (targetDate == _activeDate && !force) return;

    /* 2. If target date out of range, return */
    if (_isDateOutOfRange(targetDate)) throw Exception('Date is Out of Range');

    /* 3. Ensure the active date is updated before driving the scroll position */
    if (mounted) setState(() => _activeDate = targetDate);

    // ── FIX Bug 2: mark all animations as programmatic ─────────────────────
    // Without this, the ScrollEndNotification emitted by each animateTo below
    // would reach PickerWidget._onNotification, which would call onChange and
    // set _activeDate to whatever the wheel happened to land on — potentially
    // wrong if the physics hadn't finished snapping.
    _programmaticScrollActive.value = true;
    try {
      /* 4. Start drive date position */
      for (var i = 0; i < _option.dateTimeTypes.length; i++) {
        late double extent;

        switch (_option.dateTimeTypes[i]) {
          case DateTimeType.year:
            extent = _helper.years.indexOf(targetDate.year).toDouble();
            break;
          case DateTimeType.month:
            extent = targetDate.month - 1;
            break;
          case DateTimeType.day:
            extent = targetDate.day - 1;
            break;
          case DateTimeType.weekday:
            extent = targetDate.weekday - 1;
            break;
          case DateTimeType.hour24:
            extent = targetDate.hour.toDouble();
            break;
          case DateTimeType.hour12:
            extent = _helper.convertToHour12(targetDate.hour) - 1;
            break;
          case DateTimeType.minute:
            extent = targetDate.minute.toDouble();
            break;
          case DateTimeType.second:
            extent = targetDate.second.toDouble();
            break;
          case DateTimeType.amPM:
            extent = _helper.isAM(targetDate.hour) ? 0 : 1;
            break;
        }

        /* 4.1. If controller doesn't attached to any client, skip */
        if (!_controllers[i].hasClients) continue;

        /* 4.2. Fire animations in parallel (unawaited), yield between each */
        unawaited(
          _controllers[i].animateTo(
            widget.itemExtent * extent,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
          ),
        );

        /* 4.3. Yield to let each animation register before starting the next */
        await Future.microtask(() => null);
      }

      // Wait for all 500 ms animations to finish before releasing the flag.
      // Using a small buffer (550 ms) to account for frame scheduling.
      await Future.delayed(const Duration(milliseconds: 550));
    } finally {
      if (mounted) _programmaticScrollActive.value = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Range helpers
  // ---------------------------------------------------------------------------

  bool _isDateOutOfRange(DateTime date) {
    if (date.isAfter(_option.maxDate)) return true;
    if (date.isBefore(_option.minDate)) return true;
    return false;
  }

  // ---------------------------------------------------------------------------
  // User-interaction change handler
  // ---------------------------------------------------------------------------

  Future<void> _onChange(DateTimeType type, int rowIndex) async {
    if (!mounted) return;

    /* 1. Calculate new date based on rowIndex */
    var newDate = _helper.getDateFromRowIndex(
      type: type,
      rowIndex: rowIndex,
      activeDate: _activeDate,
    );

    /* 2. If date out of range, revert to existing date */
    if (widget.markOutOfRangeDateInvalid) {
      if (_isDateOutOfRange(newDate)) newDate = _activeDate;
    }

    /* 3. Refresh widget state if date changed */
    if (newDate != _activeDate && mounted) {
      setState(() => _activeDate = newDate);
    }

    /* 4. Trigger onChange callback with latest date */
    widget.onChange?.call(newDate);

    /* 5. Recheck scroll positions — snap any dependent column back into place */
    if (!_isRecheckingPosition.value) {
      _isRecheckingPosition.value = true;
      await _recheckPosition(DateTimeType.year, newDate);
      await _recheckPosition(DateTimeType.month, newDate);
      await _recheckPosition(DateTimeType.day, newDate);
      await _recheckPosition(DateTimeType.weekday, newDate);
      if (mounted) _isRecheckingPosition.value = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Position recheck
  // ---------------------------------------------------------------------------

  Future<void> _recheckPosition(DateTimeType type, DateTime date) async {
    final index = _option.dateTimeTypes.indexOf(type);
    if (index == -1) return;

    late int targetPosition;

    switch (type) {
      case DateTimeType.year:
        // ── FIX Bug 4: guard against indexOf returning -1 ────────────────────
        // If _activeDate.year is somehow outside the years list (e.g. pushed
        // there by a cascaded weekday arithmetic bug), indexOf returns -1 and
        // targetPosition would be 0.  The subsequent _fixPosition call would
        // then compute a negative endOffset, scrolling the year wheel to 0
        // (minDate.year) while _activeDate.year still held the out-of-range
        // value — creating a permanent visual / state mismatch.
        final yearIdx = _helper.years.indexOf(date.year);
        if (yearIdx == -1) return; // year is outside the allowed range; skip
        targetPosition = yearIdx + 1;
        break;

      case DateTimeType.month:
        targetPosition = date.month;
        break;

      case DateTimeType.day:
        targetPosition = date.day;
        break;

      case DateTimeType.weekday:
        targetPosition = date.weekday;
        break;

      default:
        return;
    }

    await _fixPosition(
      controller: _controllers[index],
      itemCount: _helper.itemCount(type),
      targetPosition: targetPosition,
    );
  }

  // ---------------------------------------------------------------------------
  // Position correction
  // ---------------------------------------------------------------------------

  Future<void> _fixPosition({
    required ScrollController controller,
    required int itemCount,
    required int targetPosition,
  }) async {
    if (!mounted) return;

    /* 1. If no client, skip */
    if (!controller.hasClients) return;

    /* 2. If position already correct, skip */
    final scrollPosition =
        (controller.offset / widget.itemExtent).floor() % itemCount + 1;
    if (targetPosition == scrollPosition) return;

    /* 3. If still scrolling from a previous gesture, skip */
    if (controller.position.isScrollingNotifier.value) return;

    /* 4. Calculate target offset */
    final difference = scrollPosition - targetPosition;
    final endOffset = controller.offset - (difference * widget.itemExtent);

    // ── FIX Bug 2: mark the correction scroll as programmatic ───────────────
    // The original code used Future.delayed(100ms, () => animateTo(...)).
    // That pattern had two problems:
    //   a) The Future.delayed awaited only the 100 ms delay, not the animation
    //      itself, so _isRecheckingPosition was cleared before the animation
    //      finished, allowing new user events to race with the correction.
    //   b) The animation fired a ScrollEndNotification that ScrollTypeListener
    //      might misclassify as a user scroll (if no ScrollUpdateNotification
    //      was emitted for a short travel distance), triggering another onChange.
    //
    // The fix: set the shared _programmaticScrollActive flag around the await,
    // so PickerWidget._onNotification ignores the notification; and properly
    // await the animation so the caller knows when it has settled.
    _programmaticScrollActive.value = true;
    try {
      await controller.animateTo(
        endOffset,
        duration: const Duration(milliseconds: 500),
        curve: Curves.bounceOut,
      );
    } finally {
      if (mounted) _programmaticScrollActive.value = false;
    }
  }
}