// Keeps the app alive with the screen off or another app in front.
//
// Without this, Android freezes or ends the app a few minutes after it
// leaves the screen, and the Bluetooth stream stops with it. A foreground
// service with a permanent notification tells Android that the user wants
// the app to keep running; its wake lock keeps the processor awake. The
// service does no work of its own: everything still runs in the app, the
// service only keeps it from being put to sleep.
//
// Swiping the app away in the list of recent apps still ends it, and with
// it the recording.
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class Background {
  static bool get _supported => defaultTargetPlatform == TargetPlatform.android;

  static void init() {
    if (!_supported) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'traumschreiber',
        channelName: 'Traumschreiber connection',
        channelDescription: 'Shown while the app is connected to a Traumschreiber.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
      ),
    );
  }

  static Future<void> start(String text) async {
    if (!_supported) return;
    // Android 13+: without this permission the notification stays hidden,
    // but the service runs all the same.
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (await FlutterForegroundTask.isRunningService) return update(text);
    await FlutterForegroundTask.startService(
      notificationTitle: 'Traumschreiber',
      notificationText: text,
    );
  }

  static Future<void> update(String text) async {
    if (!_supported || !await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(notificationText: text);
  }

  static Future<void> stop() async {
    if (!_supported) return;
    await FlutterForegroundTask.stopService();
  }

  /// Some phones stop apps in the background regardless, to save battery.
  /// Asks once to exempt this app, before a long recording.
  static Future<void> askToIgnoreBatteryOptimization() async {
    if (!_supported) return;
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }
}
