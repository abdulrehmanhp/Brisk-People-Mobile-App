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

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// MobileFaceNet expects 112×112 RGB input.
const int _kModelInputSize = 112;

/// Cosine similarity threshold for identity match (0–1).
/// MobileFaceNet with cosine similarity: same person typically ≥ 0.70.
/// Different people typically ≤ 0.40.
/// We use 0.50 so matches at/above 50% can pass clock-in.
const double _kMatchThreshold = 0.50;

/// Face must cover at least 3% of image area.
const double _kTooFarRatio = 0.03;

/// Face must not cover more than 60% of image area.
const double _kTooCloseRatio = 0.60;

class _T {
  static const Duration network = Duration(seconds: 15);
  static const Duration detection = Duration(seconds: 20);
  static const Duration inference = Duration(seconds: 10);
}

// ─────────────────────────────────────────────────────────────────────────────
// Result
// ─────────────────────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────────────────────
// FaceVerificationService
// ─────────────────────────────────────────────────────────────────────────────

/// Real identity verification using MobileFaceNet (TFLite, on-device).
///
/// How it works
/// ────────────
/// 1. Request camera permission.
/// 2. Capture selfie via front camera.
/// 3. Use ML Kit to detect exactly one face → guard 0 / multiple.
/// 4. Validate framing (too close / too far).
/// 5. Crop + resize face region to 112×112.
/// 6. Run MobileFaceNet TFLite to get a 192-dim identity embedding.
/// 7. Do the same for the profile photo (download → detect → embed).
/// 8. Cosine similarity of both embeddings → threshold check.
///
/// This is the same approach as face-api.js on the web (faceRecognitionNet).
/// ML Kit's landmark geometry alone (the old approach) is NOT identity-aware
/// and accepts any face that is positioned correctly — that is why any person
/// was passing.
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

  // ── Detection & validation ──────────────────────────────────────────────

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

  // ── Embedding ───────────────────────────────────────────────────────────

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

  // ── Model loading ────────────────────────────────────────────────────────

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

  // ── Image preprocessing ──────────────────────────────────────────────────

  /// Builds model input from image according to model tensor shape/type.
  /// Supports NHWC [1, H, W, 3] and NCHW [1, 3, H, W] for Float32 models.
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

  // ── Math ─────────────────────────────────────────────────────────────────

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

// import 'dart:async';
// import 'dart:convert';
// import 'dart:io';
// import 'dart:math' as math;
// import 'dart:ui' show Rect;

// import 'package:flutter/foundation.dart';
// import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
// import 'package:http/http.dart' as http;
// import 'package:image/image.dart' as img;
// import 'package:image_picker/image_picker.dart';
// import 'package:permission_handler/permission_handler.dart';

// // ─────────────────────────────────────────────────────────────────────────────
// // Thresholds & Timeouts
// // ─────────────────────────────────────────────────────────────────────────────

// /// Primary match threshold for the blended similarity score (0-1).
// /// 0.72 = balanced: not too strict to fail legitimate users, not too loose to
// /// accept anyone. The web side uses euclidean distance ≤ 0.50, which maps
// /// roughly to cosine similarity ≥ 0.75. We use 0.72 to be slightly more
// /// forgiving of natural pose/lighting variation on mobile cameras.
// const double _kSimilarityThreshold = 0.72;

// /// Minimum confidence % to surface to the user (0-100 scale).
// /// Matches backend threshold stored as 0.5 in `threshold_used` column.
// const double _kMinConfidencePercent = 50.0;

// /// Face must cover at least 3% of the image (too far check).
// const double _kTooFarRatio = 0.03;

// /// Face must not cover more than 55% of the image (too close check).
// const double _kTooCloseRatio = 0.55;

// /// Number of contour points to sample per facial feature.
// const int _kPointsPerContour = 8;

// class _Timeout {
//   static const Duration network = Duration(seconds: 15);
//   static const Duration inference = Duration(seconds: 30);
//   static const Duration detection = Duration(seconds: 25);
// }

// // ─────────────────────────────────────────────────────────────────────────────
// // Result type
// // ─────────────────────────────────────────────────────────────────────────────

// class FaceVerificationResult {
//   /// Whether the face matched the profile photo above threshold.
//   final bool success;

//   /// Human-readable message shown in the UI.
//   final String message;

//   /// JSON-encoded embedding array (sent to backend for logging).
//   final String? descriptorJson;

//   /// Similarity as 0-100 (e.g. 78.5 = 78.5%).
//   /// The backend's `CreateFaceLogAsync` divides by 100 before storing (0-1).
//   final double? confidenceScore;

//   /// Dissimilarity as 0-100. distanceScore = 100 - confidenceScore.
//   final double? distanceScore;

//   /// "match" | "no_match" | "no_face" | "multiple_faces" | "cancelled" |
//   /// "no_profile_image" | "camera_denied" | "too_far" | "too_close" |
//   /// "profile_face_invalid" | "error_*"
//   final String matchResult;

//   const FaceVerificationResult({
//     required this.success,
//     required this.message,
//     required this.descriptorJson,
//     required this.confidenceScore,
//     required this.distanceScore,
//     required this.matchResult,
//   });

//   /// Convenience: a failed result that carries no numeric data.
//   const FaceVerificationResult.failed({
//     required String message,
//     required String matchResult,
//   }) : success = false,
//        descriptorJson = null,
//        confidenceScore = null,
//        distanceScore = null,
//        message = message,
//        matchResult = matchResult;
// }

// // ─────────────────────────────────────────────────────────────────────────────
// // FaceVerificationService
// // ─────────────────────────────────────────────────────────────────────────────

// /// Compares a live camera selfie against the employee's stored profile picture.
// ///
// /// How it works
// /// ─────────────
// /// 1. Request camera permission.
// /// 2. Capture selfie via front camera.
// /// 3. Detect face(s) in selfie → guard against 0 or multiple faces.
// /// 4. Validate selfie framing (too close / too far).
// /// 5. Extract facial geometry embedding from selfie using ML Kit.
// /// 6. Download profile image and extract its embedding.
// /// 7. Compute blended similarity (cosine + L1 distance).
// /// 8. Return result with confidence score (0-100) ready for the backend.
// ///
// /// Backend expectation
// /// ───────────────────
// /// The `GeoClockInRequest` sent by `AttendanceService._geoClock()` passes:
// ///   • `confidenceScore` → already in 0-100 range (the mobile value).
// ///   • The `CreateFaceLogAsync` C# method divides by 100 before storing.
// ///   • DB function `fn_clock_in_out_geo` validates match_result = 'match'
// ///     AND confidence_score (post-divide) ≥ 0.50 (= 50%).
// class FaceVerificationService {
//   static const List<FaceContourType> _contourOrder = <FaceContourType>[
//     FaceContourType.face,
//     FaceContourType.leftEyebrowTop,
//     FaceContourType.leftEyebrowBottom,
//     FaceContourType.rightEyebrowTop,
//     FaceContourType.rightEyebrowBottom,
//     FaceContourType.leftEye,
//     FaceContourType.rightEye,
//     FaceContourType.upperLipTop,
//     FaceContourType.upperLipBottom,
//     FaceContourType.lowerLipTop,
//     FaceContourType.lowerLipBottom,
//     FaceContourType.noseBridge,
//     FaceContourType.noseBottom,
//   ];

//   static final ImagePicker _picker = ImagePicker();

//   // ── Public entry-point ──────────────────────────────────────────────────

//   /// Runs the full verification flow and returns a [FaceVerificationResult].
//   ///
//   /// [profileImageUrl] must be a reachable URL (http/https). An empty string
//   /// results in `no_profile_image` failure before any camera is opened.
//   static Future<FaceVerificationResult> verifyAgainstProfile(
//     String profileImageUrl,
//   ) async {
//     // ── Guard: profile URL present ────────────────────────────────────────
//     if (profileImageUrl.trim().isEmpty) {
//       return const FaceVerificationResult.failed(
//         message:
//             'No profile picture found. Please upload a clear front-facing '
//             'photo in your profile settings before clocking in.',
//         matchResult: 'no_profile_image',
//       );
//     }

//     // ── Step 1: Camera permission ─────────────────────────────────────────
//     final camStatus = await Permission.camera.request();
//     if (!camStatus.isGranted) {
//       return const FaceVerificationResult.failed(
//         message:
//             'Camera permission is required for face verification. '
//             'Please allow camera access in your device settings.',
//         matchResult: 'camera_denied',
//       );
//     }

//     // ── Step 2: Capture selfie ────────────────────────────────────────────
//     final selfie = await _picker.pickImage(
//       source: ImageSource.camera,
//       preferredCameraDevice: CameraDevice.front,
//       imageQuality: 95,
//       maxWidth: 1280,
//       maxHeight: 1280,
//     );
//     if (selfie == null) {
//       return const FaceVerificationResult.failed(
//         message: 'Face scan cancelled. Please try again.',
//         matchResult: 'cancelled',
//       );
//     }

//     debugPrint('[FaceVerif] Selfie captured: ${selfie.path}');

//     try {
//       // ── Step 3 & 4: Analyse selfie (count + framing) ─────────────────
//       final analysis = await _analyseSelfie(selfie.path);
//       if (analysis.failure != null) return analysis.failure!;

//       // ── Step 5: Extract selfie embedding ─────────────────────────────
//       List<double>? selfieEmb;
//       try {
//         selfieEmb = await _extractEmbedding(
//           selfie.path,
//           source: 'selfie',
//         ).timeout(_Timeout.inference);
//       } on TimeoutException {
//         return const FaceVerificationResult.failed(
//           message:
//               'Face scan timed out. Please try again in better lighting '
//               'with your face clearly visible.',
//           matchResult: 'error_selfie_timeout',
//         );
//       }

//       if (selfieEmb == null) {
//         return const FaceVerificationResult.failed(
//           message:
//               'Could not read facial features from your selfie. '
//               'Ensure good lighting, look directly at the camera, and try again.',
//           matchResult: 'error_selfie_features',
//         );
//       }

//       // ── Step 6: Download profile image + extract embedding ────────────
//       List<double>? profileEmb;
//       try {
//         profileEmb = await _extractEmbeddingFromUrl(
//           profileImageUrl,
//         ).timeout(_Timeout.inference);
//       } on TimeoutException {
//         return const FaceVerificationResult.failed(
//           message:
//               'Could not download your profile photo in time. '
//               'Please check your internet connection and try again.',
//           matchResult: 'error_profile_timeout',
//         );
//       }

//       if (profileEmb == null) {
//         return const FaceVerificationResult.failed(
//           message:
//               'Could not detect a face in your profile picture. '
//               'Please update your profile photo to a clear, front-facing image.',
//           matchResult: 'error_profile_no_face',
//         );
//       }

//       // ── Step 7: Compare embeddings ─────────────────────────────────────
//       final similarity = _blendedSimilarity(selfieEmb, profileEmb);

//       // Convert to 0-100 percentage (what the mobile sends to backend).
//       // The backend's CreateFaceLogAsync divides by 100 before storing.
//       final confidencePct = (similarity * 100).clamp(0.0, 100.0);
//       final distancePct = (100.0 - confidencePct).clamp(0.0, 100.0);
//       final isMatch = similarity >= _kSimilarityThreshold;

//       debugPrint(
//         '[FaceVerif] similarity=${similarity.toStringAsFixed(4)} '
//         'threshold=$_kSimilarityThreshold match=$isMatch '
//         'confidence=${confidencePct.toStringAsFixed(1)}%',
//       );

//       if (isMatch) {
//         return FaceVerificationResult(
//           success: true,
//           message:
//               'Identity verified ✓ (${confidencePct.round()}% match). '
//               'You may now clock in.',
//           descriptorJson: jsonEncode(selfieEmb),
//           confidenceScore: confidencePct,
//           distanceScore: distancePct,
//           matchResult: 'match',
//         );
//       } else {
//         // Friendly error: tell user their confidence so they can decide
//         // whether to retry or get help.
//         final pct = confidencePct.round();
//         final msg = pct >= 40
//             ? 'Face match too low ($pct%). Please ensure: good lighting, '
//                 'face the camera directly, and remove hats or glasses. Tap Retry.'
//             : 'Face does not match your profile photo ($pct%). '
//                 'If this keeps happening, update your profile picture in Settings.';

//         return FaceVerificationResult(
//           success: false,
//           message: msg,
//           descriptorJson: jsonEncode(selfieEmb),
//           confidenceScore: confidencePct,
//           distanceScore: distancePct,
//           matchResult: 'no_match',
//         );
//       }
//     } catch (e, st) {
//       debugPrint('[FaceVerif] Unexpected error: $e\n$st');
//       return FaceVerificationResult.failed(
//         message:
//             'Face verification encountered an unexpected error. '
//             'Please try again. If the problem persists, contact support.',
//         matchResult: 'error_unexpected',
//       );
//     }
//   }

//   // ── Private helpers ─────────────────────────────────────────────────────

//   /// Runs fast + accurate face detection on the selfie, enforces:
//   ///  • exactly 1 face present
//   ///  • face is not too far or too close
//   ///
//   /// Returns a [_AnalysisResult] with either [failure] set (stop early)
//   /// or `failure == null` (continue).
//   static Future<_AnalysisResult> _analyseSelfie(String path) async {
//     final faces = await _detectFaces(path);

//     if (faces.isEmpty) {
//       return _AnalysisResult.fail(
//         const FaceVerificationResult.failed(
//           message:
//               'No face detected in your selfie. Please ensure:\n'
//               '• Your face is fully visible\n'
//               '• Lighting is adequate (not backlit)\n'
//               '• Camera is not obstructed\n'
//               'Then tap Retry.',
//           matchResult: 'no_face',
//         ),
//       );
//     }

//     if (faces.length > 1) {
//       return _AnalysisResult.fail(
//         FaceVerificationResult.failed(
//           message:
//               '${faces.length} faces detected. Only you should be in '
//               'the frame. Please move away from others and tap Retry.',
//           matchResult: 'multiple_faces',
//         ),
//       );
//     }

//     // Framing check (requires decoding image to get dimensions).
//     final imageBytes = await File(path).readAsBytes();
//     final decoded = img.decodeImage(imageBytes);
//     if (decoded != null) {
//       final face = faces.first;
//       final faceArea = face.boundingBox.width * face.boundingBox.height;
//       final imageArea = decoded.width.toDouble() * decoded.height.toDouble();
//       final ratio = imageArea > 0 ? faceArea / imageArea : 0.0;

//       debugPrint('[FaceVerif] Face ratio: ${ratio.toStringAsFixed(3)}');

//       if (ratio < _kTooFarRatio) {
//         return _AnalysisResult.fail(
//           const FaceVerificationResult.failed(
//             message:
//                 'Your face is too far from the camera. Move closer until '
//                 'your face fills most of the frame, then tap Retry.',
//             matchResult: 'too_far',
//           ),
//         );
//       }
//       if (ratio > _kTooCloseRatio) {
//         return _AnalysisResult.fail(
//           const FaceVerificationResult.failed(
//             message:
//                 'Your face is too close to the camera. Move back slightly '
//                 'so your full face is visible, then tap Retry.',
//             matchResult: 'too_close',
//           ),
//         );
//       }
//     }

//     return const _AnalysisResult.ok();
//   }

//   /// Returns all detected faces using fast detector first, accurate second.
//   static Future<List<Face>> _detectFaces(String path) async {
//     // Fast pass
//     final fastDetector = FaceDetector(
//       options: FaceDetectorOptions(
//         performanceMode: FaceDetectorMode.fast,
//         enableContours: true,
//         enableClassification: true,
//       ),
//     );
//     try {
//       final inputImage = InputImage.fromFilePath(path);
//       final faces = await fastDetector
//           .processImage(inputImage)
//           .timeout(_Timeout.detection);
//       debugPrint('[FaceVerif] Fast detection: ${faces.length} face(s)');
//       if (faces.isNotEmpty) return faces;
//     } catch (e) {
//       debugPrint('[FaceVerif] Fast detection error: $e');
//     } finally {
//       await fastDetector.close();
//     }

//     // Accurate fallback
//     final accurateDetector = FaceDetector(
//       options: FaceDetectorOptions(
//         performanceMode: FaceDetectorMode.accurate,
//         enableContours: true,
//         enableClassification: true,
//       ),
//     );
//     try {
//       final inputImage = InputImage.fromFilePath(path);
//       final faces = await accurateDetector
//           .processImage(inputImage)
//           .timeout(_Timeout.detection);
//       debugPrint('[FaceVerif] Accurate detection: ${faces.length} face(s)');
//       return faces;
//     } catch (e) {
//       debugPrint('[FaceVerif] Accurate detection error: $e');
//       return [];
//     } finally {
//       await accurateDetector.close();
//     }
//   }

//   /// Downloads [url] to a temp file and extracts the facial geometry embedding.
//   static Future<List<double>?> _extractEmbeddingFromUrl(String url) async {
//     try {
//       final response = await http.get(Uri.parse(url)).timeout(_Timeout.network);
//       if (response.statusCode < 200 || response.statusCode >= 300) {
//         debugPrint(
//           '[FaceVerif] Profile image download failed: ${response.statusCode}',
//         );
//         return null;
//       }

//       final tmpFile = File(
//         '${Directory.systemTemp.path}'
//         '/face_profile_${DateTime.now().microsecondsSinceEpoch}.jpg',
//       );
//       await tmpFile.writeAsBytes(response.bodyBytes, flush: true);

//       try {
//         return await _extractEmbedding(tmpFile.path, source: 'profile');
//       } finally {
//         if (await tmpFile.exists()) await tmpFile.delete();
//       }
//     } catch (e) {
//       debugPrint('[FaceVerif] _extractEmbeddingFromUrl error: $e');
//       return null;
//     }
//   }

//   /// Runs ML Kit face detection on [path] and builds a normalised geometry
//   /// embedding vector.  Returns null if no single face is detected.
//   ///
//   /// The embedding encodes:
//   ///  • Normalised (x, y) coordinates sampled from 13 facial contours
//   ///    → 13 × 8 × 2 = 208 values
//   ///  • Head pose angles (Euler X/Y/Z) normalised to ±45°
//   ///  • Eye-open and smile probabilities
//   ///
//   /// Total: 214 float32 values, L2-normalised before return.
//   static Future<List<double>?> _extractEmbedding(
//     String path, {
//     required String source,
//   }) async {
//     final detector = FaceDetector(
//       options: FaceDetectorOptions(
//         performanceMode: FaceDetectorMode.accurate,
//         enableContours: true,
//         enableClassification: true,
//       ),
//     );

//     try {
//       final inputImage = InputImage.fromFilePath(path);
//       final faces = await detector
//           .processImage(inputImage)
//           .timeout(_Timeout.detection);

//       debugPrint('[FaceVerif] $source: ${faces.length} face(s) in embedding');

//       // We need exactly one face to produce a reliable embedding.
//       if (faces.length != 1) return null;

//       final face = faces.first;
//       final rect = face.boundingBox;
//       if (rect.width <= 0 || rect.height <= 0) return null;

//       final embedding = <double>[];

//       // Facial contour points
//       for (final contourType in _contourOrder) {
//         _appendContourSamples(
//           embedding: embedding,
//           contour: face.contours[contourType],
//           rect: rect,
//           sampleCount: _kPointsPerContour,
//         );
//       }

//       // Head pose (normalised to [-1, 1] for ±45° range)
//       embedding.add((face.headEulerAngleX ?? 0.0) / 45.0);
//       embedding.add((face.headEulerAngleY ?? 0.0) / 45.0);
//       embedding.add((face.headEulerAngleZ ?? 0.0) / 45.0);

//       // Facial action probabilities (-1 = unknown, 0-1 = probability)
//       embedding.add(face.leftEyeOpenProbability ?? -1.0);
//       embedding.add(face.rightEyeOpenProbability ?? -1.0);
//       embedding.add(face.smilingProbability ?? -1.0);

//       if (embedding.isEmpty) {
//         debugPrint('[FaceVerif] $source: embedding was empty');
//         return null;
//       }

//       debugPrint('[FaceVerif] $source: ${embedding.length}-dim embedding');
//       return _l2Normalise(embedding);
//     } on TimeoutException {
//       debugPrint('[FaceVerif] $source: embedding timeout');
//       return null;
//     } catch (e) {
//       debugPrint('[FaceVerif] $source: _extractEmbedding error: $e');
//       return null;
//     } finally {
//       await detector.close();
//     }
//   }

//   /// Samples [sampleCount] evenly-spaced points from [contour], normalised
//   /// to the [rect] bounding box.  If the contour is missing, fills with -1
//   /// (indicating absence without corrupting the embedding space).
//   static void _appendContourSamples({
//     required List<double> embedding,
//     required FaceContour? contour,
//     required Rect rect,
//     required int sampleCount,
//   }) {
//     if (contour == null || contour.points.isEmpty) {
//       for (var i = 0; i < sampleCount; i++) {
//         embedding
//           ..add(-1.0)
//           ..add(-1.0);
//       }
//       return;
//     }

//     final points = contour.points;
//     for (var i = 0; i < sampleCount; i++) {
//       final t = sampleCount == 1 ? 0.0 : i / (sampleCount - 1.0);
//       final idx = (t * (points.length - 1)).round().clamp(0, points.length - 1);
//       final p = points[idx];
//       embedding.add(((p.x - rect.left) / rect.width).clamp(0.0, 1.0));
//       embedding.add(((p.y - rect.top) / rect.height).clamp(0.0, 1.0));
//     }
//   }

//   // ── Similarity maths ──────────────────────────────────────────────────────

//   /// Blended similarity: 70% cosine + 30% mean-absolute-deviation similarity.
//   ///
//   /// Purely cosine is sensitive to scale; adding the MAD component captures
//   /// absolute position differences in contour points, making the score more
//   /// robust to pose variation.
//   static double _blendedSimilarity(List<double> a, List<double> b) {
//     if (a.length != b.length || a.isEmpty) return 0.0;

//     // Cosine similarity mapped to [0, 1]
//     final cosine = _cosineSimilarity(a, b).clamp(-1.0, 1.0);
//     final cosine01 = (cosine + 1.0) / 2.0;

//     // Mean-absolute-deviation similarity (1 = identical)
//     var sumAbs = 0.0;
//     for (var i = 0; i < a.length; i++) {
//       sumAbs += (a[i] - b[i]).abs();
//     }
//     final madSimilarity = (1.0 - sumAbs / a.length).clamp(0.0, 1.0);

//     return (0.70 * cosine01 + 0.30 * madSimilarity).clamp(0.0, 1.0);
//   }

//   static double _cosineSimilarity(List<double> a, List<double> b) {
//     var dot = 0.0, magA = 0.0, magB = 0.0;
//     for (var i = 0; i < a.length; i++) {
//       dot += a[i] * b[i];
//       magA += a[i] * a[i];
//       magB += b[i] * b[i];
//     }
//     final denom = math.sqrt(magA) * math.sqrt(magB);
//     return denom == 0 ? -1.0 : dot / denom;
//   }

//   static List<double> _l2Normalise(List<double> v) {
//     final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
//     if (norm == 0) return v;
//     return v.map((x) => x / norm).toList();
//   }
// }

// // ─────────────────────────────────────────────────────────────────────────────
// // Internal helper types
// // ─────────────────────────────────────────────────────────────────────────────

// class _AnalysisResult {
//   final FaceVerificationResult? failure;
//   const _AnalysisResult.ok() : failure = null;
//   const _AnalysisResult.fail(this.failure);
// }
