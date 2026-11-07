// Colours and small building blocks shared by all pages.
import 'package:flutter/material.dart';

import '../analysis/sleep_staging.dart';

const kAccent = Color(0xFF7C9CFF);
const kSignal = Color(0xFF5EEAD4);
const kRecord = Color(0xFFFF5370);
const kSurface = Color(0xFF151A2E);
const kBackground = Color(0xFF0B0F1E);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
    surface: kBackground,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: kBackground,
    cardTheme: CardThemeData(
      color: kSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: kSurface,
      indicatorColor: Color(0x337C9CFF),
    ),
  );
}

// Colours of the Institute of Sleep and Dream Technologies.
const kCiOrange = Color(0xFFFF9151);
const kCiPink = Color(0xFFD151FF);
const kCiYellow = Color(0xFFFFE851);
const kCiLightBlue = Color(0xFFABD5FF);
const kCiLightOrange = Color(0xFFFFC8A8);
const kCiLightPink = Color(0xFFE8A8FF);

/// Colours used in hypnograms everywhere (fixed, so plots stay comparable).
Color stageColor(SleepStage s) => switch (s) {
      SleepStage.wake => kCiYellow,
      SleepStage.rem => kCiPink,
      SleepStage.n1 => kCiLightOrange,
      SleepStage.n2 => kCiOrange,
      SleepStage.n3 => kCiLightBlue,
    };

String stageLabel(SleepStage s) => switch (s) {
      SleepStage.wake => 'Wake',
      SleepStage.rem => 'REM',
      SleepStage.n1 => 'N1',
      SleepStage.n2 => 'N2',
      SleepStage.n3 => 'N3',
    };

/// A titled card.
class Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const Section({super.key, required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(title.toUpperCase(),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      letterSpacing: 1.2, color: Colors.white54)),
              const Spacer(),
              ?trailing,
            ]),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

/// Channel 0–7 selector.
class ChannelPicker extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  /// The channels the device streams; the others carry no signal.
  final List<int> available;
  const ChannelPicker(
      {super.key, required this.value, required this.onChanged, required this.available});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final ch in available)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('CH$ch'),
                  selected: value == ch,
                  showCheckmark: false,
                  onSelected: (_) => onChanged(ch),
                ),
              ),
          ],
        ),
      );
}

/// Shown on analysis pages while no device is connected.
class NotConnected extends StatelessWidget {
  final VoidCallback onConnect;
  const NotConnected({super.key, required this.onConnect});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.bluetooth_disabled_rounded, size: 56, color: Colors.white24),
          const SizedBox(height: 12),
          const Text('No Traumschreiber connected', style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
          FilledButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.bluetooth_searching_rounded),
              label: const Text('Connect')),
        ]),
      );
}
