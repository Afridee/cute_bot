import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

export 'theme.dart';
export 'tokens.dart';

/// Space Mono ALL CAPS instrument label.
class NdLabel extends StatelessWidget {
  const NdLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Text(
      text.toUpperCase(),
      style: nd.typography.label.copyWith(color: color ?? nd.colors.textSecondary),
    );
  }
}

/// Inline bracket status: `[LOADING]`, `[ERROR: …]`, `[READY]`.
class NdStatusText extends StatelessWidget {
  const NdStatusText(this.text, {super.key, this.color});

  const NdStatusText.loading({super.key})
      : text = '[LOADING]',
        color = null;

  const NdStatusText.ready({super.key})
      : text = '[READY]',
        color = null;

  factory NdStatusText.error(String message) =>
      NdStatusText('[ERROR: $message]', color: CuteBotSignal.error);

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Text(
      text.toUpperCase(),
      style: nd.typography.caption.copyWith(color: color ?? nd.colors.textSecondary),
    );
  }
}

enum NdButtonVariant { primary, secondary, ghost, destructive }

class NdButton extends StatelessWidget {
  const NdButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = NdButtonVariant.primary,
    this.expand = false,
  });

  const NdButton.primary({
    super.key,
    required this.label,
    this.onPressed,
    this.expand = false,
  }) : variant = NdButtonVariant.primary;

  const NdButton.secondary({
    super.key,
    required this.label,
    this.onPressed,
    this.expand = false,
  }) : variant = NdButtonVariant.secondary;

  const NdButton.ghost({
    super.key,
    required this.label,
    this.onPressed,
    this.expand = false,
  }) : variant = NdButtonVariant.ghost;

  const NdButton.destructive({
    super.key,
    required this.label,
    this.onPressed,
    this.expand = false,
  }) : variant = NdButtonVariant.destructive;

  final String label;
  final VoidCallback? onPressed;
  final NdButtonVariant variant;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final c = nd.colors;
    final enabled = onPressed != null;

    final Color bg;
    final Color fg;
    final Color borderColor;
    final bool outlined;
    switch (variant) {
      case NdButtonVariant.primary:
        bg = c.textDisplay;
        fg = c.canvas;
        borderColor = Colors.transparent;
        outlined = false;
      case NdButtonVariant.secondary:
        bg = Colors.transparent;
        fg = c.textPrimary;
        borderColor = c.borderVisible;
        outlined = true;
      case NdButtonVariant.ghost:
        bg = Colors.transparent;
        fg = c.textSecondary;
        borderColor = Colors.transparent;
        outlined = false;
      case NdButtonVariant.destructive:
        bg = Colors.transparent;
        fg = CuteBotSignal.accent;
        borderColor = CuteBotSignal.accent;
        outlined = true;
    }

    Widget child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Text(
        label.toUpperCase(),
        textAlign: TextAlign.center,
        style: nd.typography.button.copyWith(color: fg),
      ),
    );
    if (expand) {
      child = SizedBox(width: double.infinity, child: Center(child: child));
    }

    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: bg,
        shape: StadiumBorder(
          side: outlined ? BorderSide(color: borderColor) : BorderSide.none,
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: child,
          ),
        ),
      ),
    );
  }
}

class NdTag extends StatelessWidget {
  const NdTag(this.text, {super.key, this.active = false});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final c = nd.colors;
    final color = active ? c.textDisplay : c.borderVisible;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text.toUpperCase(),
        style: nd.typography.caption.copyWith(
          color: active ? c.textDisplay : c.textSecondary,
        ),
      ),
    );
  }
}

class NdStatRow extends StatelessWidget {
  const NdStatRow({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.valueColor,
  });

  final String label;
  final String value;
  final String? unit;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: NdLabel(label)),
          Text(
            value,
            style: nd.typography.data.copyWith(
              color: valueColor ?? nd.colors.textPrimary,
            ),
          ),
          if (unit != null) ...[
            const SizedBox(width: 4),
            Text(
              unit!.toUpperCase(),
              style: nd.typography.label,
            ),
          ],
        ],
      ),
    );
  }
}

class NdHairline extends StatelessWidget {
  const NdHairline({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: context.nd.colors.border);
  }
}

/// Discrete mechanical progress. [value] is 0–1.
class NdSegmentedProgress extends StatelessWidget {
  const NdSegmentedProgress({
    super.key,
    required this.value,
    this.segments = 20,
    this.height = 10,
    this.fill,
  });

  final double value;
  final int segments;
  final double height;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final filled = (value.clamp(0.0, 1.0) * segments).round();
    final color = fill ?? nd.colors.textDisplay;
    return Row(
      children: [
        for (var i = 0; i < segments; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          Expanded(
            child: Container(
              height: height,
              color: i < filled ? color : nd.colors.border,
            ),
          ),
        ],
      ],
    );
  }
}

class NdToggle extends StatelessWidget {
  const NdToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final c = nd.colors;
    final enabled = onChanged != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: SizedBox(
          width: 52,
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: CuteBotSignal.durationMicro,
              curve: CuteBotSignal.curve,
              width: 44,
              height: 24,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: value ? c.textDisplay : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: value ? c.textDisplay : c.borderVisible,
                ),
              ),
              child: AnimatedAlign(
                duration: CuteBotSignal.durationMicro,
                curve: CuteBotSignal.curve,
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: value ? c.canvas : c.textDisabled,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NdSegmentedControl<T> extends StatelessWidget {
  const NdSegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final c = nd.colors;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border.all(color: c.borderVisible),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (key, label) in segments)
            GestureDetector(
              onTap: () => onChanged(key),
              child: AnimatedContainer(
                duration: CuteBotSignal.durationMicro,
                curve: CuteBotSignal.curve,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: key == value ? c.textDisplay : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label.toUpperCase(),
                  style: nd.typography.label.copyWith(
                    color: key == value ? c.canvas : c.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Circular 40px back control — thin chevron, no fill icon.
class NdBackButton extends StatelessWidget {
  const NdBackButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Material(
      color: nd.colors.surface,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed ?? () => Navigator.of(context).maybePop(),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: CustomPaint(
              size: const Size(12, 12),
              painter: _ChevronPainter(color: nd.colors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  _ChevronPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * 0.7, size.height * 0.1)
      ..lineTo(size.width * 0.25, size.height * 0.5)
      ..lineTo(size.width * 0.7, size.height * 0.9);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ChevronPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Tertiary group: ALL CAPS label, then children. Spacing, not a card.
class NdGroup extends StatelessWidget {
  const NdGroup({
    super.key,
    required this.label,
    required this.children,
    this.trailing,
  });

  final String label;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            NdLabel(label),
            if (trailing != null) ...[
              const Spacer(),
              trailing!,
            ],
          ],
        ),
        const SizedBox(height: CuteBotSpace.sm),
        ...children,
      ],
    );
  }
}

class NdMetricTriple extends StatelessWidget {
  const NdMetricTriple({super.key, required this.items});

  final List<(String label, String value, String unit, Color? color)> items;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: CuteBotSpace.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NdLabel(items[i].$1),
                const SizedBox(height: CuteBotSpace.xs),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        items[i].$2,
                        style: nd.typography.data.copyWith(
                          color: items[i].$4 ?? nd.colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(items[i].$3.toUpperCase(), style: nd.typography.label),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Technical 4px LED square plus ALL CAPS label.
class NdLedControl extends StatelessWidget {
  const NdLedControl({
    super.key,
    required this.color,
    required this.label,
    this.onPressed,
  });

  final Color color;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: nd.colors.borderVisible),
          borderRadius: BorderRadius.circular(4),
        ),
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: nd.colors.borderVisible),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  label.toUpperCase(),
                  style: nd.typography.button.copyWith(color: nd.colors.textPrimary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NdActionWrap extends StatelessWidget {
  const NdActionWrap({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: CuteBotSpace.sm,
      runSpacing: CuteBotSpace.sm,
      children: children,
    );
  }
}
