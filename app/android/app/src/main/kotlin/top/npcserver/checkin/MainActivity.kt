package top.npcserver.checkin

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer

// The native half of the `checkin/video` channel: a lossless range trim and an MP4
// location read, the two clip operations no Flutter package covers, plus the runtime ask
// for ACCESS_MEDIA_LOCATION a gallery photo's GPS needs on Android 10+ (see
// ensureMediaLocationPermission). Runs the work off the platform thread so a multi-second
// remux never blocks the UI, then hands the result back on the main thread the channel
// requires.
class MainActivity : FlutterActivity() {
    private val channelName = "checkin/video"
    private val mediaLocationRequestCode = 4201

    // ensureMediaLocationPermission's answer arrives later, in onRequestPermissionsResult,
    // not synchronously - so the MethodChannel Result has to be held until that callback
    // fires. Every call while one request is already in flight rides along on the same
    // dialog by queuing here instead of firing requestPermissions() again, which would
    // silently drop (clobber) the Result the first caller is waiting on.
    private val pendingMediaLocationResults = mutableListOf<MethodChannel.Result>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "trim" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "missing path", null)
                            return@setMethodCallHandler
                        }
                        val startMs = (call.argument<Number>("startMs") ?: 0).toLong()
                        val endMs = (call.argument<Number>("endMs") ?: 0).toLong()
                        Thread {
                            try {
                                val out = trim(path, startMs, endMs)
                                runOnUiThread { result.success(out) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("trim_failed", e.message, null) }
                            }
                        }.start()
                    }
                    "location" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "missing path", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            val coords = location(path)
                            runOnUiThread {
                                if (coords == null) {
                                    result.success(null)
                                } else {
                                    result.success(mapOf("lat" to coords.first, "lng" to coords.second))
                                }
                            }
                        }.start()
                    }
                    "ensureMediaLocationPermission" -> ensureMediaLocationPermission(result)
                    else -> result.notImplemented()
                }
            }
    }

    // Below Android 10 nothing is redacted, so there is no permission to hold. From 10 on,
    // this only ever un-redacts the LEGACY gallery picker (ACTION_GET_CONTENT) that
    // image_picker_android takes while ImagePickerAndroid.useAndroidPhotoPicker stays at its
    // default false - the modern Android 13+ photo picker (PickVisualMedia) enforces its own
    // redaction this permission does not reach. If that flag is ever flipped on, gallery
    // photo locations silently go back to missing; see the Dart-side regression test that
    // guards it and the matching note in AndroidManifest.xml. A photo taken with the in-app
    // camera never goes through this at all - it lands in an app-private file Android never
    // redacts, so its GPS depends only on whether the camera app wrote it.
    private fun ensureMediaLocationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(true)
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_MEDIA_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        synchronized(pendingMediaLocationResults) {
            val requestInFlight = pendingMediaLocationResults.isNotEmpty()
            pendingMediaLocationResults.add(result)
            if (requestInFlight) return
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION),
                mediaLocationRequestCode
            )
        }
        // A permanently-denied permission (the user picked "don't ask again", or Play's
        // auto-deny after repeated refusals) makes requestPermissions() answer immediately
        // through the very callback below with no dialog shown - so this never re-prompts on
        // every pick, it just quietly reports denied again each time.
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != mediaLocationRequestCode) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val waiting: List<MethodChannel.Result>
        synchronized(pendingMediaLocationResults) {
            waiting = pendingMediaLocationResults.toList()
            pendingMediaLocationResults.clear()
        }
        waiting.forEach { it.success(granted) }
    }

    // Copies the sample range [startMs, endMs) into a new mp4 by remuxing, no re-encode.
    // The muxer is told the source rotation so a portrait clip keeps its orientation
    // instead of playing sideways, the same failure the server's tkhd handling guards.
    private fun trim(path: String, startMs: Long, endMs: Long): String {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        val outFile = File(cacheDir, "trim_${System.currentTimeMillis()}.mp4")
        val muxer = MediaMuxer(outFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        // Map every source track into the muxer and remember the index mapping.
        val indexMap = HashMap<Int, Int>()
        var maxInputSize = 0
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                extractor.selectTrack(i)
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxInputSize = maxOf(maxInputSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
                indexMap[i] = muxer.addTrack(format)
            }
        }
        if (maxInputSize <= 0) maxInputSize = 1 shl 20

        // Preserve the source rotation so portrait clips are not laid down sideways.
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull()
                ?.let { muxer.setOrientationHint(it) }
        } catch (_: Exception) {
            // No rotation metadata: leave the default (0), the common landscape case.
        } finally {
            retriever.release()
        }

        val startUs = startMs * 1000
        val endUs = endMs * 1000
        muxer.start()
        val buffer = ByteBuffer.allocate(maxInputSize)
        val info = MediaCodec.BufferInfo()
        try {
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            while (true) {
                val sampleTime = extractor.sampleTime
                if (sampleTime < 0) break
                if (sampleTime > endUs) break
                if (sampleTime < startUs) {
                    extractor.advance()
                    continue
                }
                val trackIndex = extractor.sampleTrackIndex
                val dstIndex = indexMap[trackIndex]
                if (dstIndex != null) {
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    info.offset = 0
                    info.size = size
                    // Rebase timestamps so the trimmed clip starts at zero.
                    info.presentationTimeUs = sampleTime - startUs
                    info.flags = sampleFlags(extractor)
                    muxer.writeSampleData(dstIndex, buffer, info)
                }
                extractor.advance()
            }
        } finally {
            muxer.stop()
            muxer.release()
            extractor.release()
        }
        return outFile.absolutePath
    }

    // Translate the extractor's sample flags into the muxer's, carrying keyframe marks so
    // playback can seek.
    private fun sampleFlags(extractor: MediaExtractor): Int {
        var flags = 0
        if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
            flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
        }
        return flags
    }

    // The clip's recording location, read from METADATA_KEY_LOCATION as an ISO6709 string
    // (for example "+37.33-122.03/"), or null when the clip carries none.
    private fun location(path: String): Pair<Double, Double>? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val raw = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
            if (raw == null) null else parseIso6709(raw)
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    // ISO6709 packs a signed latitude then a signed longitude, sign-delimited, with an
    // optional trailing altitude and "/". Split on the sign that opens the longitude,
    // tolerating an optional leading sign on the latitude.
    private fun parseIso6709(raw: String): Pair<Double, Double>? {
        val trimmed = raw.trimEnd('/')
        val numbers = ArrayList<String>()
        val current = StringBuilder()
        for ((i, ch) in trimmed.withIndex()) {
            if ((ch == '+' || ch == '-') && i != 0 && current.isNotEmpty()) {
                numbers.add(current.toString())
                current.setLength(0)
                current.append(ch)
            } else {
                current.append(ch)
            }
        }
        if (current.isNotEmpty()) numbers.add(current.toString())
        if (numbers.size < 2) return null
        val lat = numbers[0].toDoubleOrNull() ?: return null
        val lng = numbers[1].toDoubleOrNull() ?: return null
        return Pair(lat, lng)
    }
}
