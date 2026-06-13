import 'dart:async';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:record/record.dart';

class AudioSentinelService {
  Interpreter? _interpreter;
  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription? _audioSubscription;
  DateTime? _lastInferenceAt;

  // Logic Control
  bool isListening = false;
  Function(String event, double confidence)? onDangerDetected;

  // YAMNet Specifications (DO NOT CHANGE)
  final int sampleRate = 16000;
  final int requiredSamples = 15600; // 0.975 seconds of audio
  final Duration minInferenceInterval = const Duration(milliseconds: 900);
  List<String> _labels = [];
  List<double> _audioBuffer = [];

  // 🚨 DANGER ZONES: Keywords to trigger alert
  final List<String> _dangerKeywords = [
    'Scream',
    'Shout',
    'Yell',
    'Bellow', // Deep aggressive shouting
    'Roar', // Aggressive outcome
    'Screaming',
    'Crying, sobbing',
    'Wail', // Distress signal
    'Explosion',
    'Gunshot', // High danger
    'Bang',
    'Smash', // Physical violence
    'Crash',
    'Breaking',
    'Glass',
    'Shatter',
    'Whack', // Physical impact
    'Slap',
    'Punch', // Fighting sounds (if mapped)
    'Aggressive', // Catch-all for aggressive moods
    'Siren', // Emergency context
    'Alarm'
  ];

  Future<void> initialize() async {
    try {
      // 1. Load Model
      _interpreter =
          await Interpreter.fromAsset('assets/sentinel_audio.tflite');
      print("Audio sentinel model ready");

      // 2. Load Labels
      final labelData = await rootBundle.loadString('assets/labels.txt');
      _labels = labelData.split('\n');
      print("Audio sentinel labels loaded: ${_labels.length}");
    } catch (e) {
      print("Audio sentinel init failed: $e");
    }
  }

  Future<void> startListening() async {
    if (_interpreter == null || isListening) return;

    if (await _audioRecorder.hasPermission()) {
      isListening = true;
      _audioBuffer = [];
      _lastInferenceAt = null;

      // Start streaming raw PCM data (16-bit integer)
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          iosConfig: IosRecordConfig(
            categoryOptions: [
              IosAudioCategoryOption.mixWithOthers,
              IosAudioCategoryOption.defaultToSpeaker,
              IosAudioCategoryOption.allowBluetooth,
            ],
          ),
        ),
      );

      _audioSubscription = stream.listen((data) {
        _processAudioChunk(data);
      });
    }
  }

  void stopListening() {
    isListening = false;
    _audioRecorder.stop();
    _audioSubscription?.cancel();
    _audioBuffer.clear();
  }

  // Convert bytes to float and buffer them
  void _processAudioChunk(Uint8List data) {
    // PCM16 is 2 bytes per sample.
    for (int i = 0; i < data.length; i += 2) {
      if (i + 1 < data.length) {
        int byte1 = data[i];
        int byte2 = data[i + 1];

        // Convert to 16-bit signed integer
        int s16 = (byte2 << 8) | byte1;
        if (s16 > 32767) s16 -= 65536;

        // Normalize to Float [-1.0, 1.0]
        _audioBuffer.add(s16 / 32768.0);
      }
    }

    // Check if we have enough data for inference
    if (_audioBuffer.length >= requiredSamples) {
      final now = DateTime.now();
      if (_lastInferenceAt != null &&
          now.difference(_lastInferenceAt!) < minInferenceInterval) {
        // Keep trimming stale audio while we throttle model runs.
        _audioBuffer.removeRange(0, (requiredSamples / 2).floor());
        return;
      }

      // Take exact chunk
      var inputChunk = _audioBuffer.sublist(0, requiredSamples);

      // Remove handled data (Clear 50% for overlap)
      _audioBuffer.removeRange(0, (requiredSamples / 2).floor());

      _runInference(inputChunk);
      _lastInferenceAt = now;
    }
  }

  void _runInference(List<double> inputData) {
    if (_interpreter == null) return;

    // YAMNet Input Shape: [1, 15600]
    var input = [inputData];

    // YAMNet Output Shape: [1, 521]
    var output = List.filled(521, 0.0).reshape([1, 521]);

    try {
      _interpreter!.run(input, output);

      // Analyze results
      List<double> scores = output[0];

      // Get Top 5 Predictions
      List<MapEntry<int, double>> top5 = [];

      for (int i = 0; i < scores.length; i++) {
        top5.add(MapEntry(i, scores[i]));
      }

      // Sort Descending
      top5.sort((a, b) => b.value.compareTo(a.value));
      top5 = top5.take(5).toList();

      // 🚨 DANGER CHECK (Top 5)
      for (var entry in top5) {
        int index = entry.key;
        double score = entry.value;

        // ✅ Lowered Threshold to 0.15 for higher sensitivity
        if (score > 0.15) {
          String detectedLabel =
              _labels.length > index ? _labels[index] : "Unknown";

          for (var danger in _dangerKeywords) {
            if (detectedLabel.toLowerCase().contains(danger.toLowerCase())) {
              print("Danger audio detected: $detectedLabel ($score)");
              onDangerDetected?.call(detectedLabel, score);
              return; // Trigger once per chunk
            }
          }
        }
      }
    } catch (e) {
      print("Inference Error: $e");
    }
  }
}
