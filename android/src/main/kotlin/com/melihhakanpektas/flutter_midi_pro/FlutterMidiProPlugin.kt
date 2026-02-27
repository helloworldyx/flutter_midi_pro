package com.melihhakanpektas.flutter_midi_pro

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import android.media.AudioManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive

/** FlutterMidiProPlugin */
class FlutterMidiProPlugin: FlutterPlugin, MethodCallHandler {
    companion object {
        init {
            System.loadLibrary("native-lib")
        }
        @JvmStatic
        private external fun loadSoundfont(path: String, bank: Int, program: Int): Int

        @JvmStatic
        private external fun selectInstrument(sfId: Int, channel:Int, bank: Int, program: Int)

        @JvmStatic
        private external fun playNote(channel: Int, key: Int, velocity: Int, sfId: Int)

        @JvmStatic
        private external fun stopNote(channel: Int, key: Int, sfId: Int)

        @JvmStatic
        private external fun stopAllNotes(sfId: Int)

        @JvmStatic
        private external fun controlChange(sfId: Int, channel: Int, controller: Int, value: Int)

        @JvmStatic
        private external fun unloadSoundfont(sfId: Int)

        @JvmStatic
        private external fun dispose()

        // ==================== 【新增的 MIDI 文件控制 JNI 接口】 ====================
        @JvmStatic
        private external fun playMidiFile(sfId: Int, path: String, loop: Boolean)

        @JvmStatic
        private external fun isMidiPlayerPlaying(sfId: Int): Boolean

        @JvmStatic
        private external fun pauseMidiFile(sfId: Int)

        @JvmStatic
        private external fun resumeMidiFile(sfId: Int)

        @JvmStatic
        private external fun stopMidiFile(sfId: Int)

        // fluid_player_join 的 JNI 绑定：在 C 层阻塞直到播放结束
        // 比轮询 isMidiPlayerPlaying 更高效：线程在内核层挂起，0 CPU 占用
        @JvmStatic
        private external fun joinMidiFile(sfId: Int)
    }

    private lateinit var channel : MethodChannel
    private lateinit var flutterPluginBinding: FlutterPlugin.FlutterPluginBinding
    private val pollingJobs = ConcurrentHashMap<Int, Job>()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        this.flutterPluginBinding = flutterPluginBinding
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_midi_pro")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadSoundfont" -> {
                CoroutineScope(Dispatchers.IO).launch {
                    val path = call.argument<String>("path") as String
                    val bank = call.argument<Int>("bank")?:0
                    val program = call.argument<Int>("program")?:0
                    val audioManager = flutterPluginBinding.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

                    // Sesi mute yapma
                    audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)

                    // Soundfont yükleme işlemi (senkron, bloke eden çağrı)
                    val sfId = loadSoundfont(path, bank, program)
                    delay(250)

                    // Sesi tekrar açma
                    audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)

                    // Sonucu ana thread'de Flutter'a iletme
                    withContext(Dispatchers.Main) {
                        if (sfId == -1) {
                            result.error("INVALID_ARGUMENT", "Something went wrong. Check the path of the template soundfont", null)
                        } else {
                            result.success(sfId)
                        }
                    }
                }
            }
            "selectInstrument" -> {
                val sfId = call.argument<Int>("sfId")?:1
                val channel = call.argument<Int>("channel")?:0
                val bank = call.argument<Int>("bank")?:0
                val program = call.argument<Int>("program")?:0
                selectInstrument(sfId, channel, bank, program)
                result.success(null)
            }
            "playNote" -> {
                val channel = call.argument<Int>("channel")
                val key = call.argument<Int>("key")
                val velocity = call.argument<Int>("velocity")
                val sfId = call.argument<Int>("sfId")
                if (channel != null && key != null && velocity != null && sfId != null) {
                    playNote(channel, key, velocity, sfId)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "channel, key, and velocity are required", null)
                }
            }
            "stopNote" -> {
                val channel = call.argument<Int>("channel")
                val key = call.argument<Int>("key")
                val sfId = call.argument<Int>("sfId")
                if (channel != null && key != null && sfId != null) {
                    stopNote(channel, key, sfId)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "channel and key are required", null)
                }
            }
            "stopAllNotes" -> {
                val sfId = call.argument<Int>("sfId") as Int
                stopAllNotes(sfId)
                result.success(null)
            }
            "controlChange" -> {
                val sfId = call.argument<Int>("sfId") ?: 1
                val channel = call.argument<Int>("channel") ?: 0
                val controller = call.argument<Int>("controller") ?: 0
                val value = call.argument<Int>("value") ?: 0
                controlChange(sfId, channel, controller, value)
                result.success(null)
            }
            "unloadSoundfont" -> {
                val sfId = call.argument<Int>("sfId")
                if (sfId != null) {
                    unloadSoundfont(sfId)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "sfId is required", null)
                }
            }
            "dispose" -> {
                dispose()
                result.success(null)
            }

            // ==================== 【新增的 MIDI 文件控制路由】 ====================
            "playMidiFile" -> {
                val sfId = call.argument<Int>("sfId")
                val path = call.argument<String>("path")
                val loop = call.argument<Boolean>("loop") ?: true
                if (sfId != null && path != null) {
                    playMidiFile(sfId, path, loop)
                    result.success(null)

                    if (!loop) {
                        pollingJobs[sfId]?.cancel()
                        pollingJobs[sfId] = CoroutineScope(Dispatchers.IO).launch {
                            // joinMidiFile 在 C 层调用 fluid_player_join()，
                            // 协程在 IO 线程上挂起，不占用 CPU，替代 200ms while 轮询
                            joinMidiFile(sfId)
                            // 协程被 cancel（stopMidiFile 调用时）会从 joinMidiFile 返回，
                            // 此时 isActive 为 false，不触发 onMidiPlayerCompleted
                            if (isActive) {
                                withContext(Dispatchers.Main) {
                                    channel.invokeMethod("onMidiPlayerCompleted", mapOf("sfId" to sfId))
                                }
                            }
                        }
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "sfId and path are required", null)
                }
            }
            "pauseMidiFile" -> {
                val sfId = call.argument<Int>("sfId")
                if (sfId != null) {
                    pauseMidiFile(sfId)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "sfId is required", null)
                }
            }
            "resumeMidiFile" -> {
                val sfId = call.argument<Int>("sfId")
                if (sfId != null) {
                    resumeMidiFile(sfId)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "sfId is required", null)
                }
            }
            "stopMidiFile" -> {
                val sfId = call.argument<Int>("sfId")
                if (sfId != null) {
                    pollingJobs[sfId]?.cancel()
                    stopMidiFile(sfId)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "sfId is required", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}