package org.sd20.traumschreiber_minimal

import android.content.Context
import android.os.Bundle
import android.util.Log
import io.reactivex.exceptions.UndeliverableException
import io.reactivex.plugins.RxJavaPlugins
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

    // The Bluetooth plugin (flutter_reactive_ble, built on RxJava 2) sometimes
    // reports an error after the connection it belonged to was already closed,
    // for example when the link drops or on Disconnect. RxJava then has nobody
    // to hand it to and, by default, ends the whole app, and with it the
    // recording. Seen on a Samsung tablet on Disconnect (18.11.2026). Such late
    // errors are harmless: log them and carry on. Errors that point at a bug
    // in the app itself are still raised.
    override fun onCreate(savedInstanceState: Bundle?) {
        RxJavaPlugins.setErrorHandler { e ->
            val cause = if (e is UndeliverableException) (e.cause ?: e) else e
            when (cause) {
                is NullPointerException, is IllegalArgumentException, is IllegalStateException ->
                    Thread.currentThread().uncaughtExceptionHandler
                        ?.uncaughtException(Thread.currentThread(), cause)
                else -> Log.w("Traumschreiber", "Ignored late Bluetooth error", cause)
            }
        }
        super.onCreate(savedInstanceState)
    }
}
