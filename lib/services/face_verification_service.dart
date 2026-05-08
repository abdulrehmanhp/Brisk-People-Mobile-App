import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// Constants
const int _kModelInputSize = 112;
const double _kMatchThreshold = 0.50; // 50% match threshold for clock-in
const double _kTooFarRatio = 0.03; // Face must cover ≥ 3% of image
const double _kTooCloseRatio = 0.60; // Face must cover ≤ 60% of image

class _T {
  static const Duration network = Duration(seconds: 15);
  static const Duration detection = Duration(seconds: 20);
  static const Duration inference = Duration(seconds: 10);
}

// Result
class FaceVerificationResult {
  final bool success;
  final String message;
  final String? descriptorJson;
  final double? confidenceScore;
  final double? distanceScore;

  /// "match" | "no_match" | "no_face" | "multiple_faces" | "cancelled" |
  /// "no_profile_image" | "camera_denied" | "too_far" | "too_close" |
  /// "error_*"
  final String matchResult;

  const FaceVerificationResult({
    required this.success,
    required this.message,
    required this.descriptorJson,
    required this.confidenceScore,
    required this.distanceScore,
    required this.matchResult,
  });

  const FaceVerificationResult.failed({
    required String message,
    required String matchResult,
  }) : success = false,
       descriptorJson = null,
       confidenceScore = null,
       distanceScore = null,
       message = message,
       matchResult = matchResult;
}

// Face verification service using TFLite MobileFaceNet
class FaceVerificationService {
  // Lazy-loaded interpreter — shared across calls to avoid reload overhead.
  static Interpreter? _interpreter;

  static final ImagePicker _picker = ImagePicker();

  // ── Public entry-point ──────────────────────────────────────────────────

  static Future<FaceVerificationResult> verifyAgainstProfile(
    String profileImageUrl,
  ) async {
    // Guard: profile URL present
    if (profileImageUrl.trim().isEmpty) {
      return const FaceVerificationResult.failed(
        message:
            'No profile picture found. Please upload a clear front-facing '
            'photo in your profile settings before clocking in.',
        matchResult: 'no_profile_image',
      );
    }

    // Step 1: Camera permission
    final camStatus = await Permission.camera.request();
    if (!camStatus.isGranted) {
      return const FaceVerificationResult.failed(
        message:
            'Camera permission is required for face verification. '
            'Please allow camera access in your device settings.',
        matchResult: 'camera_denied',
      );
    }

    // Step 2: Capture selfie
    final selfie = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      imageQuality: 95,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (selfie == null) {
      return const FaceVerificationResult.failed(
        message: 'Face scan cancelled. Please try again.',
        matchResult: 'cancelled',
      );
    }

    debugPrint('[FaceVerif] Selfie captured: ${selfie.path}');

    try {
      // Step 3 & 4: Detect + validate selfie
      final selfieCheck = await _detectAndValidate(selfie.path);
      if (selfieCheck.error != null) return selfieCheck.error!;

      // Step 5 & 6: Embed selfie
      List<double>? selfieEmb;
      try {
        selfieEmb = await _embedFaceFromFile(
          selfie.path,
          selfieCheck.cropRect!,
        ).timeout(_T.inference);
      } on TimeoutException {
        return const FaceVerificationResult.failed(
          message:
              'Face scan timed out. Try again in better lighting with '
              'your face clearly centred.',
          matchResult: 'error_selfie_timeout',
        );
      }
      if (selfieEmb == null) {
        return const FaceVerificationResult.failed(
          message:
              'Could not read your facial features. Ensure good lighting, '
              'look directly at the camera, and try again.',
          matchResult: 'error_selfie_features',
        );
      }

      // Step 7: Download profile + embed
      List<double>? profileEmb;
      try {
        profileEmb = await _embedFaceFromUrl(
          profileImageUrl,
        ).timeout(_T.inference);
      } on TimeoutException {
        return const FaceVerificationResult.failed(
          message:
              'Could not download your profile photo in time. '
              'Please check your internet connection and try again.',
          matchResult: 'error_profile_timeout',
        );
      }
      if (profileEmb == null) {
        return const FaceVerificationResult.failed(
          message:
              'Could not detect a face in your profile picture. '
              'Please update it to a clear, front-facing photo.',
          matchResult: 'error_profile_no_face',
        );
      }

      // Step 8: Compare
      final similarity = _cosineSimilarity(selfieEmb, profileEmb);
      final confidencePct = (similarity * 100).clamp(0.0, 100.0);
      final distancePct = (100.0 - confidencePct).clamp(0.0, 100.0);
      final isMatch = similarity >= _kMatchThreshold;

      debugPrint(
        '[FaceVerif] similarity=${similarity.toStringAsFixed(4)} '
        'threshold=$_kMatchThreshold match=$isMatch '
        'confidence=${confidencePct.toStringAsFixed(1)}%',
      );

      if (isMatch) {
        return FaceVerificationResult(
          success: true,
          message:
              'Identity verified ✓ (${confidencePct.round()}% match). '
              'You may now clock in.',
          descriptorJson: jsonEncode(selfieEmb),
          confidenceScore: confidencePct,
          distanceScore: distancePct,
          matchResult: 'match',
        );
      } else {
        final pct = confidencePct.round();
        final msg = pct >= 35
            ? 'Face match too low ($pct%). Ensure good lighting, face the '
                  'camera directly, and remove glasses or hats. Tap Retry.'
            : 'Face does not match your profile photo ($pct%). '
                  'If this keeps failing, update your profile picture in Settings.';
        return FaceVerificationResult(
          success: false,
          message: msg,
          descriptorJson: jsonEncode(selfieEmb),
          confidenceScore: confidencePct,
          distanceScore: distancePct,
          matchResult: 'no_match',
        );
      }
    } catch (e, st) {
      debugPrint('[FaceVerif] Unexpected error: $e\n$st');
      return const FaceVerificationResult.failed(
        message:
            'Face verification encountered an unexpected error. '
            'Please try again. If the problem persists, contact support.',
        matchResult: 'error_unexpected',
      );
    }
  }

  // Detection & validation

  static Future<_DetectionResult> _detectAndValidate(String path) async {
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableContours: false,
        enableClassification: false,
        enableLandmarks: false,
      ),
    );
    try {
      final faces = await detector
          .processImage(InputImage.fromFilePath(path))
          .timeout(_T.detection);

      debugPrint('[FaceVerif] Detected ${faces.length} face(s) in selfie');

      if (faces.isEmpty) {
        return _DetectionResult.err(
          const FaceVerificationResult.failed(
            message:
                'No face detected in your selfie. Please ensure:\n'
                '• Your face is fully visible\n'
                '• Lighting is adequate (not backlit)\n'
                '• Camera is not obstructed\n'
                'Then tap Retry.',
            matchResult: 'no_face',
          ),
        );
      }
      if (faces.length > 1) {
        return _DetectionResult.err(
          FaceVerificationResult.failed(
            message:
                '${faces.length} faces detected. Only you should be in '
                'the frame. Please move away from others and tap Retry.',
            matchResult: 'multiple_faces',
          ),
        );
      }

      final face = faces.first;
      final imageBytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(imageBytes);

      if (decoded != null) {
        final faceArea = face.boundingBox.width * face.boundingBox.height;
        final imageArea = decoded.width.toDouble() * decoded.height.toDouble();
        final ratio = imageArea > 0 ? faceArea / imageArea : 0.0;

        debugPrint('[FaceVerif] Face ratio: ${ratio.toStringAsFixed(3)}');

        if (ratio < _kTooFarRatio) {
          return _DetectionResult.err(
            const FaceVerificationResult.failed(
              message:
                  'Your face is too far from the camera. Move closer until '
                  'your face fills most of the frame, then tap Retry.',
              matchResult: 'too_far',
            ),
          );
        }
        if (ratio > _kTooCloseRatio) {
          return _DetectionResult.err(
            const FaceVerificationResult.failed(
              message:
                  'Your face is too close to the camera. Move back slightly '
                  'so your full face is visible, then tap Retry.',
              matchResult: 'too_close',
            ),
          );
        }
      }

      return _DetectionResult.ok(face.boundingBox);
    } on TimeoutException {
      return _DetectionResult.err(
        const FaceVerificationResult.failed(
          message: 'Face detection timed out. Please try again.',
          matchResult: 'error_detection_timeout',
        ),
      );
    } finally {
      await detector.close();
    }
  }

  // Embedding extraction

  /// Downloads [url], detects the face in it, and returns its embedding.
  static Future<List<double>?> _embedFaceFromUrl(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(_T.network);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          '[FaceVerif] Profile image download failed: ${response.statusCode}',
        );
        return null;
      }

      final tmp = File(
        '${Directory.systemTemp.path}'
        '/fv_profile_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await tmp.writeAsBytes(response.bodyBytes, flush: true);

      try {
        // Detect face in profile photo
        final detector = FaceDetector(
          options: FaceDetectorOptions(
            performanceMode: FaceDetectorMode.accurate,
            enableContours: false,
            enableClassification: false,
            enableLandmarks: false,
          ),
        );
        final List<Face> faces;
        try {
          faces = await detector
              .processImage(InputImage.fromFilePath(tmp.path))
              .timeout(_T.detection);
        } finally {
          await detector.close();
        }

        debugPrint(
          '[FaceVerif] Profile photo: ${faces.length} face(s) detected',
        );
        if (faces.length != 1) return null;

        return await _embedFaceFromFile(tmp.path, faces.first.boundingBox);
      } finally {
        if (await tmp.exists()) await tmp.delete();
      }
    } catch (e) {
      debugPrint('[FaceVerif] _embedFaceFromUrl error: $e');
      return null;
    }
  }

  /// Crops the face region from [path] using [cropRect], resizes to
  /// 112×112, runs MobileFaceNet, and returns the L2-normalised embedding.
  static Future<List<double>?> _embedFaceFromFile(
    String path,
    Rect cropRect,
  ) async {
    try {
      final bytes = await File(path).readAsBytes();
      final original = img.decodeImage(bytes);
      if (original == null) {
        debugPrint('[FaceVerif] Could not decode image at $path');
        return null;
      }

      // Add 20% padding around the face bounding box so the model sees
      // forehead and chin, not just the tight face oval.
      final pad = 0.20;
      final x = ((cropRect.left - cropRect.width * pad)).clamp(
        0.0,
        original.width.toDouble(),
      );
      final y = ((cropRect.top - cropRect.height * pad)).clamp(
        0.0,
        original.height.toDouble(),
      );
      final w = (cropRect.width * (1 + 2 * pad)).clamp(1.0, original.width - x);
      final h = (cropRect.height * (1 + 2 * pad)).clamp(
        1.0,
        original.height - y,
      );

      final cropped = img.copyCrop(
        original,
        x: x.toInt(),
        y: y.toInt(),
        width: w.toInt(),
        height: h.toInt(),
      );

      final resized = img.copyResize(
        cropped,
        width: _kModelInputSize,
        height: _kModelInputSize,
        interpolation: img.Interpolation.linear,
      );

      final interpreter = await _getInterpreter();
      final inputTensor = interpreter.getInputTensor(0);
      final outputTensor = interpreter.getOutputTensor(0);

      final inputShape = inputTensor.shape;
      final outputShape = outputTensor.shape;

      final input = _imageToModelInput(
        image: resized,
        inputShape: inputShape,
        inputType: inputTensor.type,
      );
      final output = _createOutputBuffer(outputShape);

      debugPrint(
        '[FaceVerif] Model IO: input=$inputShape/${inputTensor.type} '
        'output=$outputShape/${outputTensor.type}',
      );

      // Run inference
      try {
        await Future(() {
          interpreter.run(input, output);
        }).timeout(_T.inference);
      } on TimeoutException {
        debugPrint('[FaceVerif] MobileFaceNet inference timed out');
        return null;
      }

      final embedding = _flattenToDouble(output);
      if (embedding.isEmpty) {
        debugPrint('[FaceVerif] Empty embedding returned from model');
        return null;
      }

      debugPrint('[FaceVerif] Embedding extracted: ${embedding.length} dims');
      return _l2Normalize(embedding);
    } catch (e, st) {
      debugPrint('[FaceVerif] _embedFaceFromFile error: $e\n$st');
      return null;
    }
  }

  // Model loading

  static Future<Interpreter> _getInterpreter() async {
    if (_interpreter != null) return _interpreter!;

    debugPrint('[FaceVerif] Loading MobileFaceNet TFLite model...');
    final modelData = await rootBundle.load(
      'assets/models/MobileFaceNet.tflite',
    );
    _interpreter = await Interpreter.fromBuffer(
      modelData.buffer.asUint8List(),
      options: InterpreterOptions()..threads = 2,
    );
    debugPrint('[FaceVerif] Model loaded');
    return _interpreter!;
  }

  // Image preprocessing - builds input for both NHWC and NCHW tensor layouts
  static Object _imageToModelInput({
    required img.Image image,
    required List<int> inputShape,
    required TensorType inputType,
  }) {
    if (inputShape.length != 4 || inputShape[0] != 1) {
      throw StateError('Unsupported model input shape: $inputShape');
    }

    final isNhwc =
        inputShape[1] == _kModelInputSize &&
        inputShape[2] == _kModelInputSize &&
        inputShape[3] == 3;
    final isNchw =
        inputShape[1] == 3 &&
        inputShape[2] == _kModelInputSize &&
        inputShape[3] == _kModelInputSize;

    if (!isNhwc && !isNchw) {
      throw StateError('Unsupported model channel layout: $inputShape');
    }

    if (inputType == TensorType.float32) {
      if (isNhwc) {
        return List.generate(
          1,
          (_) => List.generate(
            _kModelInputSize,
            (y) => List.generate(_kModelInputSize, (x) {
              final pixel = image.getPixel(x, y);
              return [
                (pixel.r / 127.5) - 1.0,
                (pixel.g / 127.5) - 1.0,
                (pixel.b / 127.5) - 1.0,
              ];
            }),
          ),
        );
      }

      return [
        [
          List.generate(
            _kModelInputSize,
            (y) => List.generate(
              _kModelInputSize,
              (x) => (image.getPixel(x, y).r / 127.5) - 1.0,
            ),
          ),
          List.generate(
            _kModelInputSize,
            (y) => List.generate(
              _kModelInputSize,
              (x) => (image.getPixel(x, y).g / 127.5) - 1.0,
            ),
          ),
          List.generate(
            _kModelInputSize,
            (y) => List.generate(
              _kModelInputSize,
              (x) => (image.getPixel(x, y).b / 127.5) - 1.0,
            ),
          ),
        ],
      ];
    }

    if (inputType == TensorType.uint8) {
      if (isNhwc) {
        return List.generate(
          1,
          (_) => List.generate(
            _kModelInputSize,
            (y) => List.generate(_kModelInputSize, (x) {
              final pixel = image.getPixel(x, y);
              return [pixel.r, pixel.g, pixel.b];
            }),
          ),
        );
      }

      return [
        [
          List.generate(
            _kModelInputSize,
            (y) =>
                List.generate(_kModelInputSize, (x) => image.getPixel(x, y).r),
          ),
          List.generate(
            _kModelInputSize,
            (y) =>
                List.generate(_kModelInputSize, (x) => image.getPixel(x, y).g),
          ),
          List.generate(
            _kModelInputSize,
            (y) =>
                List.generate(_kModelInputSize, (x) => image.getPixel(x, y).b),
          ),
        ],
      ];
    }

    throw StateError('Unsupported model input type: $inputType');
  }

  static Object _createOutputBuffer(List<int> shape) {
    if (shape.length == 1) {
      return List<double>.filled(shape[0], 0.0);
    }
    if (shape.length == 2 && shape[0] == 1) {
      return [List<double>.filled(shape[1], 0.0)];
    }
    throw StateError('Unsupported model output shape: $shape');
  }

  static List<double> _flattenToDouble(Object output) {
    if (output is List<double>) {
      return output;
    }
    if (output is List && output.length == 1 && output.first is List<double>) {
      return List<double>.from(output.first as List<double>);
    }
    if (output is List && output.length == 1 && output.first is List) {
      return (output.first as List).map((e) => (e as num).toDouble()).toList();
    }
    if (output is List) {
      return output.map((e) => (e as num).toDouble()).toList();
    }
    if (output is Float32List) {
      return output.toList();
    }
    if (output is Uint8List) {
      return output.map((e) => e.toDouble()).toList();
    }
    return const [];
  }

  // Math utilities

  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    var dot = 0.0, magA = 0.0, magB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    final denom = math.sqrt(magA) * math.sqrt(magB);
    return denom == 0 ? 0.0 : (dot / denom).clamp(0.0, 1.0);
  }

  static List<double> _l2Normalize(List<double> v) {
    final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

class _DetectionResult {
  final FaceVerificationResult? error;
  final Rect? cropRect;

  const _DetectionResult.ok(this.cropRect) : error = null;
  const _DetectionResult.err(this.error) : cropRect = null;
}
