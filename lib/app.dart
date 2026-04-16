import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class MushroomRecognizerApp extends StatelessWidget {
  const MushroomRecognizerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF33691E)),
        useMaterial3: true,
      ),
      home: const MushroomHomePage(),
    );
  }
}

class MushroomHomePage extends StatefulWidget {
  const MushroomHomePage({super.key});

  @override
  State<MushroomHomePage> createState() => _MushroomHomePageState();
}

class _MushroomHomePageState extends State<MushroomHomePage> {
  final ImagePicker _picker = ImagePicker();
  final FrameSelectorService _frameSelector = FrameSelectorService();
  final MockQueueWebSocketService _queueSocket = MockQueueWebSocketService();

  StreamSubscription<QueueEvent>? _eventSubscription;
  final List<QueueEvent> _events = [];

  PreparedFrame? _preparedFrame;
  bool _isPreparing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _eventSubscription = _queueSocket.connect().listen((event) {
      if (!mounted) {
        return;
      }
      setState(() {
        _events.insert(0, event);
        if (_events.length > 60) {
          _events.removeRange(60, _events.length);
        }
      });
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _queueSocket.dispose();
    super.dispose();
  }

  Future<void> _prepareFromImageGallery() async {
    await _prepareMedia(
      picker: () => _picker.pickImage(source: ImageSource.gallery),
      parser: _frameSelector.prepareFromImage,
    );
  }

  Future<void> _prepareFromCameraImage() async {
    await _prepareMedia(
      picker: () => _picker.pickImage(source: ImageSource.camera),
      parser: _frameSelector.prepareFromImage,
    );
  }

  Future<void> _prepareFromCameraVideo() async {
    await _prepareMedia(
      picker: () => _picker.pickVideo(source: ImageSource.camera),
      parser: _frameSelector.prepareFromVideo,
    );
  }

  Future<void> _prepareMedia({
    required Future<XFile?> Function() picker,
    required Future<PreparedFrame> Function(XFile file) parser,
  }) async {
    setState(() {
      _isPreparing = true;
      _error = null;
    });

    try {
      final file = await picker();
      if (file == null) {
        setState(() {
          _isPreparing = false;
        });
        return;
      }

      final prepared = await parser(file);
      setState(() {
        _preparedFrame = prepared;
        _isPreparing = false;
      });
    } catch (e) {
      setState(() {
        _isPreparing = false;
        _error = 'Không thể chuẩn bị dữ liệu ảnh: $e';
      });
    }
  }

  void _enqueuePreparedFrame() {
    final frame = _preparedFrame;
    if (frame == null) {
      return;
    }

    final jobId = _queueSocket.enqueue(frame);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Đã thêm vào hàng chờ: $jobId')));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _queueSocket.jobs;

    return Scaffold(
      appBar: AppBar(title: const Text('Nhận diện nấm (Mock Queue + WS)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _isPreparing ? null : _prepareFromImageGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Upload ảnh'),
                  ),
                  FilledButton.icon(
                    onPressed: _isPreparing ? null : _prepareFromCameraImage,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Chụp ảnh'),
                  ),
                  FilledButton.icon(
                    onPressed: _isPreparing ? null : _prepareFromCameraVideo,
                    icon: const Icon(Icons.videocam_outlined),
                    label: const Text('Quay video'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _queueSocket.sendClientMessage('ping'),
                    icon: const Icon(Icons.wifi_tethering_outlined),
                    label: const Text('Ping WebSocket'),
                  ),
                ],
              ),
            ),
          ),
          if (_isPreparing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Dữ liệu ảnh đã chuẩn bị',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  if (_preparedFrame == null)
                    const Text(
                      'Chưa có ảnh nào. Hãy upload ảnh hoặc quay video.',
                    ),
                  if (_preparedFrame != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _preparedFrame!.bytes,
                        width: double.infinity,
                        height: 220,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('Nguồn: ${_preparedFrame!.sourceLabel}'),
                    Text(
                      'Kích thước ảnh: ${_preparedFrame!.bytes.lengthInBytes} bytes',
                    ),
                    Text(
                      'Điểm chất lượng: ${(_preparedFrame!.qualityScore * 100).toStringAsFixed(1)} / 100',
                    ),
                    if (_preparedFrame!.selectedFrameMs != null)
                      Text(
                        'Frame được chọn: ${_preparedFrame!.selectedFrameMs} ms',
                      ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _enqueuePreparedFrame,
                      icon: const Icon(Icons.queue_outlined),
                      label: const Text('Đưa vào hàng chờ (mock)'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Hàng chờ công việc',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  if (jobs.isEmpty) const Text('Chưa có job.'),
                  if (jobs.isNotEmpty)
                    ...jobs.map(
                      (job) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: job.status.color.withAlpha(35),
                          child: Icon(
                            Icons.memory_outlined,
                            color: job.status.color,
                          ),
                        ),
                        title: Text('Job: ${job.jobId}'),
                        subtitle: Text(job.status.label),
                        trailing: job.result != null
                            ? Text(
                                '${job.result!['prediction']} (${(job.result!['confidence'] as double).toStringAsFixed(1)}%)',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sự kiện WebSocket (mô phỏng theo server.py)',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  if (_events.isEmpty) const Text('Chưa có sự kiện.'),
                  if (_events.isNotEmpty)
                    ..._events
                        .take(10)
                        .map(
                          (event) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              '[${event.timestamp.toIso8601String()}] ${event.event}: ${event.data}',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FrameSelectorService {
  Future<PreparedFrame> prepareFromImage(XFile file) async {
    final bytes = await file.readAsBytes();
    final quality = _scoreFrameQuality(bytes);

    return PreparedFrame(
      bytes: bytes,
      sourcePath: file.path,
      sourceLabel: 'Ảnh tĩnh',
      qualityScore: quality,
      selectedFrameMs: null,
    );
  }

  Future<PreparedFrame> prepareFromVideo(XFile file) async {
    final duration = await _probeDuration(file.path);
    final samplePoints = _buildSamplePoints(duration);

    Uint8List? bestBytes;
    double bestScore = -1;
    int? bestFrameMs;

    for (final frameMs in samplePoints) {
      final thumbBytes = await VideoThumbnail.thumbnailData(
        video: file.path,
        imageFormat: ImageFormat.JPEG,
        quality: 95,
        maxWidth: 720,
        timeMs: frameMs,
      );

      if (thumbBytes == null || thumbBytes.isEmpty) {
        continue;
      }

      final score = _scoreFrameQuality(thumbBytes);
      if (score > bestScore) {
        bestScore = score;
        bestBytes = thumbBytes;
        bestFrameMs = frameMs;
      }
    }

    if (bestBytes == null) {
      throw Exception('Không lấy được frame hợp lệ từ video.');
    }

    return PreparedFrame(
      bytes: bestBytes,
      sourcePath: file.path,
      sourceLabel: 'Video (đã chọn frame tốt nhất)',
      qualityScore: bestScore,
      selectedFrameMs: bestFrameMs,
    );
  }

  Future<Duration> _probeDuration(String path) async {
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      return controller.value.duration;
    } finally {
      await controller.dispose();
    }
  }

  List<int> _buildSamplePoints(Duration duration) {
    final totalMs = duration.inMilliseconds;
    if (totalMs <= 0) {
      return const [0];
    }

    const sampleCount = 8;
    final safeEnd = max(1, totalMs - 1);
    final step = safeEnd / (sampleCount + 1);

    final points = <int>[];
    for (var i = 1; i <= sampleCount; i++) {
      points.add((step * i).round());
    }
    return points;
  }

  double _scoreFrameQuality(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return 0;
    }

    final resized = decoded.width > 320
        ? img.copyResize(decoded, width: 320)
        : decoded;

    final width = resized.width;
    final height = resized.height;
    if (width < 3 || height < 3) {
      return 0;
    }

    final gray = List<double>.filled(width * height, 0);
    var sumLum = 0.0;

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = resized.getPixel(x, y);
        final lum = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
        final idx = y * width + x;
        gray[idx] = lum;
        sumLum += lum;
      }
    }

    final meanLum = sumLum / gray.length;

    var gradientEnergy = 0.0;
    var count = 0;
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final idx = y * width + x;
        final gx = gray[idx + 1] - gray[idx - 1];
        final gy = gray[idx + width] - gray[idx - width];
        gradientEnergy += sqrt(gx * gx + gy * gy);
        count++;
      }
    }

    final avgGradient = gradientEnergy / max(1, count);
    final sharpnessScore = (avgGradient / 60).clamp(0.0, 1.0);
    final exposureScore = (1 - ((meanLum - 128).abs() / 128)).clamp(0.0, 1.0);

    return (sharpnessScore * 0.8 + exposureScore * 0.2).clamp(0.0, 1.0);
  }
}

class MockQueueWebSocketService {
  final StreamController<QueueEvent> _controller =
      StreamController<QueueEvent>.broadcast();
  final Queue<String> _jobQueue = Queue<String>();
  final Map<String, QueueJob> _jobs = {};
  final Map<String, PreparedFrame> _payloads = {};
  final Random _random = Random();

  bool _isProcessing = false;

  Stream<QueueEvent> connect() {
    scheduleMicrotask(() {
      _emit('queue.snapshot', _buildQueueSnapshot());
    });
    return _controller.stream;
  }

  List<QueueJob> get jobs {
    final list = _jobs.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  String enqueue(PreparedFrame frame) {
    final id = _newId();
    final now = DateTime.now().toUtc();

    _jobs[id] = QueueJob(
      jobId: id,
      status: JobStatus.queued,
      createdAt: now,
      updatedAt: now,
      result: null,
      error: null,
      imageInfo: {
        'source': frame.sourceLabel,
        'size_bytes': frame.bytes.lengthInBytes,
        'quality_score': frame.qualityScore,
        'selected_frame_ms': frame.selectedFrameMs,
      },
    );

    _payloads[id] = frame;
    _jobQueue.add(id);

    _emit('job.status', {'job_id': id, 'status': 'queued'});
    _emit('queue.status', _buildQueueSnapshot());

    unawaited(_pumpQueue());
    return id;
  }

  void sendClientMessage(String text) {
    if (text.trim().toLowerCase() == 'ping') {
      _emit('pong', {'status': 'ok'});
    }
  }

  Future<void> _pumpQueue() async {
    if (_isProcessing) {
      return;
    }
    _isProcessing = true;

    while (_jobQueue.isNotEmpty) {
      final id = _jobQueue.removeFirst();
      final processingJob = _jobs[id];
      if (processingJob == null) {
        continue;
      }

      _jobs[id] = processingJob.copyWith(
        status: JobStatus.processing,
        updatedAt: DateTime.now().toUtc(),
      );
      _emit('job.status', {'job_id': id, 'status': 'processing'});
      _emit('queue.status', _buildQueueSnapshot());

      await Future.delayed(Duration(milliseconds: 900 + _random.nextInt(1200)));

      final frame = _payloads.remove(id);
      if (frame == null) {
        final failedAt = DateTime.now().toUtc();
        _jobs[id] = _jobs[id]!.copyWith(
          status: JobStatus.failed,
          error: 'Missing frame payload',
          updatedAt: failedAt,
        );
        _emit('job.result', {
          'job_id': id,
          'status': 'failed',
          'error': 'Missing frame payload',
        });
        _emit('queue.status', _buildQueueSnapshot());
        continue;
      }

      final result = _fakeInference(frame);
      final completedAt = DateTime.now().toUtc();
      _jobs[id] = _jobs[id]!.copyWith(
        status: JobStatus.completed,
        result: result,
        updatedAt: completedAt,
      );

      _emit('job.result', {
        'job_id': id,
        'status': 'completed',
        'result': result,
      });
      _emit('queue.status', _buildQueueSnapshot());
    }

    _isProcessing = false;
  }

  Map<String, dynamic> _buildQueueSnapshot() {
    var queued = 0;
    var processing = 0;
    var completed = 0;
    var failed = 0;

    for (final job in _jobs.values) {
      switch (job.status) {
        case JobStatus.queued:
          queued++;
        case JobStatus.processing:
          processing++;
        case JobStatus.completed:
          completed++;
        case JobStatus.failed:
          failed++;
      }
    }

    return {
      'queue_size': _jobQueue.length,
      'queued': queued,
      'processing': processing,
      'completed': completed,
      'failed': failed,
      'total': _jobs.length,
    };
  }

  Map<String, dynamic> _fakeInference(PreparedFrame frame) {
    final image = img.decodeImage(frame.bytes);
    var meanLum = 128.0;
    if (image != null) {
      final resized = image.width > 120
          ? img.copyResize(image, width: 120)
          : image;
      var lumSum = 0.0;
      var count = 0;
      for (var y = 0; y < resized.height; y++) {
        for (var x = 0; x < resized.width; x++) {
          final p = resized.getPixel(x, y);
          lumSum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          count++;
        }
      }
      meanLum = lumSum / max(1, count);
    }

    final prediction = meanLum >= 120 ? 'nam_huong' : 'nam_kim_cham';
    final confidence =
        (0.55 +
            min(0.44, frame.qualityScore * 0.45 + _random.nextDouble() * 0.1)) *
        100;

    return {
      'prediction': prediction,
      'confidence': confidence,
      'source': frame.sourceLabel,
      'size_bytes': frame.bytes.lengthInBytes,
      'selected_frame_ms': frame.selectedFrameMs,
      'quality_score': frame.qualityScore,
    };
  }

  void _emit(String event, Map<String, dynamic> data) {
    if (_controller.isClosed) {
      return;
    }
    _controller.add(
      QueueEvent(event: event, timestamp: DateTime.now().toUtc(), data: data),
    );
  }

  String _newId() {
    final millis = DateTime.now().millisecondsSinceEpoch;
    final randomPart = _random.nextInt(999999).toString().padLeft(6, '0');
    return 'job-$millis-$randomPart';
  }

  void dispose() {
    _controller.close();
  }
}

enum JobStatus { queued, processing, completed, failed }

extension JobStatusX on JobStatus {
  String get label {
    switch (this) {
      case JobStatus.queued:
        return 'queued';
      case JobStatus.processing:
        return 'processing';
      case JobStatus.completed:
        return 'completed';
      case JobStatus.failed:
        return 'failed';
    }
  }

  Color get color {
    switch (this) {
      case JobStatus.queued:
        return Colors.amber.shade800;
      case JobStatus.processing:
        return Colors.blue.shade700;
      case JobStatus.completed:
        return Colors.green.shade700;
      case JobStatus.failed:
        return Colors.red.shade700;
    }
  }
}

class QueueJob {
  QueueJob({
    required this.jobId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.result,
    required this.error,
    required this.imageInfo,
  });

  final String jobId;
  final JobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? result;
  final String? error;
  final Map<String, dynamic> imageInfo;

  QueueJob copyWith({
    JobStatus? status,
    DateTime? updatedAt,
    Map<String, dynamic>? result,
    String? error,
  }) {
    return QueueJob(
      jobId: jobId,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      result: result ?? this.result,
      error: error ?? this.error,
      imageInfo: imageInfo,
    );
  }
}

class PreparedFrame {
  PreparedFrame({
    required this.bytes,
    required this.sourcePath,
    required this.sourceLabel,
    required this.qualityScore,
    required this.selectedFrameMs,
  });

  final Uint8List bytes;
  final String sourcePath;
  final String sourceLabel;
  final double qualityScore;
  final int? selectedFrameMs;
}

class QueueEvent {
  QueueEvent({
    required this.event,
    required this.timestamp,
    required this.data,
  });

  final String event;
  final DateTime timestamp;
  final Map<String, dynamic> data;
}
