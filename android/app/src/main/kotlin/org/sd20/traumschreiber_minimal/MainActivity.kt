package org.sd20.traumschreiber_minimal

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

// The whole app (Bluetooth, recording, analysis) runs in Dart, inside a
// FlutterEngine. By default that engine belongs to this activity and dies
// with it. Android ends an activity more often than one would think: the
// Back button on the first page (Android 11 and older), or the system
// reclaiming memory while the app is in the background. The foreground
// service keeps the process alive, but without its engine the recording
// would stop all the same.
//
// So the engine is created once per process and kept here. When Android
// ends the activity, the engine keeps running; when the user opens the
// app again, the new activity attaches to the same engine and shows the
// recording that is still going on.
class MainActivity : FlutterActivity() {
    companion object {
        private var engine: FlutterEngine? = null
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        engine ?: FlutterEngine(context.applicationContext).also {
            it.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            engine = it
        }

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
