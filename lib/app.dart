import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String kDefaultBackendBaseUrl = 'http://10.0.2.2:8000';

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
  final BackendQueueService _queueSocket = BackendQueueService(
    initialBackendBaseUrl: kDefaultBackendBaseUrl,
  );
  late final TextEditingController _backendUrlController;

  StreamSubscription<QueueEvent>? _eventSubscription;
  final List<QueueEvent> _events = [];

  PreparedFrame? _preparedFrame;
  bool _isPreparing = false;
  bool _isSubmittingJob = false;
  bool _isReconnectingWs = false;
  bool _isDisconnectingWs = false;
  bool _wsConnected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _backendUrlController = TextEditingController(
      text: _queueSocket.backendBaseUrl,
    );
    _eventSubscription = _queueSocket.events.listen((event) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (event.event == 'ws.connected') {
          _wsConnected = true;
        }
        if (event.event == 'ws.closed' || event.event == 'ws.error') {
          _wsConnected = false;
        }
        _events.insert(0, event);
        if (_events.length > 60) {
          _events.removeRange(60, _events.length);
        }
      });
    });
  }

  Future<void> _disconnectWebSocket() async {
    setState(() {
      _isDisconnectingWs = true;
      _error = null;
    });

    try {
      await _queueSocket.disconnect();
      if (!mounted) {
        return;
      }
      setState(() {
        _wsConnected = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Đã ngắt kết nối WebSocket.')));
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Không thể ngắt kết nối WebSocket: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isDisconnectingWs = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _backendUrlController.dispose();
    _queueSocket.dispose();
    super.dispose();
  }

  Future<void> _reconnectWebSocket() async {
    final input = _backendUrlController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _error = 'Hãy nhập backend URL trước khi kết nối.';
      });
      return;
    }

    setState(() {
      _isReconnectingWs = true;
      _error = null;
    });

    try {
      await _queueSocket.reconnect(baseUrl: input);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã cập nhật backend: ${_queueSocket.backendBaseUrl}'),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Không thể kết nối WebSocket: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isReconnectingWs = false;
        });
      }
    }
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

  Future<void> _enqueuePreparedFrame() async {
    final frame = _preparedFrame;
    if (frame == null) {
      return;
    }

    setState(() {
      _isSubmittingJob = true;
      _error = null;
    });

    try {
      final jobId = await _queueSocket.enqueue(frame);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Đã upload và tạo job: $jobId')));
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Tạo job thất bại: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingJob = false;
        });
      }
    }
  }

  String? _formatResultSummary(Map<String, dynamic>? result) {
    if (result == null) {
      return null;
    }

    final prediction =
        result['prediction'] ?? result['label'] ?? result['class'];
    if (prediction == null) {
      return null;
    }

    final confidenceRaw = result['confidence'];
    if (confidenceRaw is num) {
      final value = confidenceRaw <= 1 ? confidenceRaw * 100 : confidenceRaw;
      return '$prediction (${value.toStringAsFixed(1)}%)';
    }
    return '$prediction';
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _queueSocket.jobs;
    final backendBaseUrl = _queueSocket.backendBaseUrl;

    return Scaffold(
      appBar: AppBar(title: const Text('Nhận diện nấm (Backend thật)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Kết nối backend',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _backendUrlController,
                    enabled:
                        !_wsConnected && !_isReconnectingWs && !_isDisconnectingWs,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Backend URL',
                      hintText: 'http://10.0.2.2:8000',
                    ),
                  ),
                  if (_wsConnected)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Ngắt kết nối trước khi thay đổi IP/URL backend.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _isReconnectingWs || _isDisconnectingWs
                            ? null
                            : _reconnectWebSocket,
                        icon: const Icon(Icons.link_outlined),
                        label: Text(
                          _wsConnected
                              ? 'Áp dụng URL mới & kết nối lại WS'
                              : 'Kết nối WebSocket',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _wsConnected && !_isDisconnectingWs
                            ? _disconnectWebSocket
                            : null,
                        icon: const Icon(Icons.link_off_outlined),
                        label: const Text('Disconnect'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _wsConnected ? _queueSocket.sendPing : null,
                        icon: const Icon(Icons.wifi_tethering_outlined),
                        label: const Text('Ping WebSocket'),
                      ),
                      Text(
                        _wsConnected ? 'WS: connected' : 'WS: disconnected',
                        style: TextStyle(
                          color: _wsConnected
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'HTTP: $backendBaseUrl',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
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
                ],
              ),
            ),
          ),
          if (_isPreparing || _isSubmittingJob)
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
                      onPressed: _isSubmittingJob
                          ? null
                          : _enqueuePreparedFrame,
                      icon: const Icon(Icons.queue_outlined),
                      label: const Text('Upload ảnh và tạo job'),
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
                        trailing: _formatResultSummary(job.result) != null
                            ? Text(
                                _formatResultSummary(job.result)!,
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
                    'Sự kiện WebSocket (server thật)',
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

class BackendQueueService {
  BackendQueueService({
    required String initialBackendBaseUrl,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _backendBaseUrl = _normalizeBaseUrl(initialBackendBaseUrl);

  final StreamController<QueueEvent> _controller =
      StreamController<QueueEvent>.broadcast();
  final Map<String, QueueJob> _jobs = {};
  final http.Client _httpClient;
  String _backendBaseUrl;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSubscription;
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  bool _wsConnected = false;
  bool _pollStarted = false;
  bool _autoReconnectEnabled = false;
  bool _disposed = false;

  String get backendBaseUrl => _backendBaseUrl;
  bool get isWebSocketConnected => _wsConnected;
  Stream<QueueEvent> get events => _controller.stream;

  Stream<QueueEvent> connect() {
    if (_disposed) {
      throw StateError('BackendQueueService đã dispose');
    }
    _autoReconnectEnabled = true;
    scheduleMicrotask(() {
      unawaited(_connectWebSocket());
    });
    if (!_pollStarted) {
      _startPolling();
    }
    return _controller.stream;
  }

  Future<void> reconnect({String? baseUrl}) async {
    if (_disposed) {
      throw StateError('BackendQueueService đã dispose');
    }

    _autoReconnectEnabled = true;

    if (baseUrl != null && baseUrl.trim().isNotEmpty) {
      _backendBaseUrl = _normalizeBaseUrl(baseUrl);
      _emit('backend.updated', {'base_url': _backendBaseUrl});
    }

    await _disconnectWebSocket();
    await _connectWebSocket();
    if (!_pollStarted) {
      _startPolling();
    }
  }

  Future<void> disconnect() async {
    if (_disposed) {
      throw StateError('BackendQueueService đã dispose');
    }

    _autoReconnectEnabled = false;
    _reconnectTimer?.cancel();
    _stopPolling();
    await _disconnectWebSocket();
    _emit('ws.closed', {'reason': 'manual_disconnect'});
  }

  List<QueueJob> get jobs {
    final list = _jobs.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<String> enqueue(PreparedFrame frame) async {
    final request = http.MultipartRequest(
      'POST',
      _httpUri('/api/images/upload'),
    );

    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        frame.bytes,
        filename: _buildUploadFilename(frame),
        contentType: MediaType('image', _detectImageSubtype(frame)),
      ),
    );

    final response = await _httpClient.send(request);
    final body = await response.stream.bytesToString();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Upload thất bại, HTTP ${response.statusCode}: ${_extractErrorText(body)}',
      );
    }

    final payload = _decodeObject(body);
    final jobId = _stringFromMap(payload, const ['job_id', 'jobId', 'id']);
    if (jobId == null || jobId.isEmpty) {
      throw Exception('Server không trả về job_id hợp lệ.');
    }

    final statusText = _stringFromMap(payload, const ['status']) ?? 'queued';
    final now = DateTime.now().toUtc();

    _jobs[jobId] = QueueJob(
      jobId: jobId,
      status: _parseStatus(statusText),
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

    _emit('job.status', {'job_id': jobId, 'status': statusText});
    unawaited(fetchJob(jobId));
    return jobId;
  }

  Future<void> fetchJob(String jobId) async {
    final response = await _httpClient.get(_httpUri('/api/jobs/$jobId'));

    if (response.statusCode == 404) {
      _upsertJob(
        jobId: jobId,
        status: JobStatus.failed,
        error: 'Job không tồn tại (404)',
      );
      _emit('job.status', {'job_id': jobId, 'status': 'failed'});
      _emit('job.result', {
        'job_id': jobId,
        'status': 'failed',
        'error': 'Job không tồn tại (404)',
      });
      return;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Không lấy được trạng thái job $jobId, HTTP ${response.statusCode}',
      );
    }

    final payload = _decodeObject(response.body);
    _applyJobPayload(
      payload,
      fallbackJobId: jobId,
      sourceEvent: 'poll',
      emitNormalizedEvent: true,
    );
  }

  void sendPing() {
    final channel = _channel;
    if (channel == null || !_wsConnected) {
      _emit('ws.error', {'message': 'WebSocket chưa kết nối'});
      return;
    }

    try {
      channel.sink.add('ping');
    } on StateError catch (error) {
      _wsConnected = false;
      _emit('ws.error', {'message': 'WebSocket đã đóng: $error'});
      _scheduleReconnect();
    } catch (error) {
      _wsConnected = false;
      _emit('ws.error', {'message': 'Không gửi được ping: $error'});
      _scheduleReconnect();
    }
  }

  Future<void> _connectWebSocket() async {
    if (_disposed) {
      return;
    }

    _reconnectTimer?.cancel();
    await _disconnectWebSocket(closeSink: false);

    try {
      final channel = WebSocketChannel.connect(_wsUri('/ws/queue'));
      _channel = channel;
      _wsSubscription = channel.stream.listen(
        _handleWsMessage,
        onError: (Object error, StackTrace stackTrace) {
          _wsConnected = false;
          _emit('ws.error', {'message': error.toString()});
          _scheduleReconnect();
        },
        onDone: () {
          _wsConnected = false;
          _emit('ws.closed', {'reason': 'closed'});
          _scheduleReconnect();
        },
      );
      _wsConnected = true;
      _emit('ws.connected', {'url': _wsUri('/ws/queue').toString()});
    } catch (e) {
      _wsConnected = false;
      _emit('ws.error', {'message': e.toString()});
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || !_autoReconnectEnabled) {
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (_disposed) {
        return;
      }
      unawaited(_connectWebSocket());
    });
  }

  Future<void> _disconnectWebSocket({bool closeSink = true}) async {
    _reconnectTimer?.cancel();
    final subscription = _wsSubscription;
    _wsSubscription = null;
    await subscription?.cancel();

    if (closeSink) {
      await _channel?.sink.close();
    }

    _channel = null;
    _wsConnected = false;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollActiveJobs());
    });
    _pollStarted = true;
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollStarted = false;
  }

  Future<void> _pollActiveJobs() async {
    if (_disposed) {
      return;
    }

    final activeJobIds = _jobs.values
        .where(
          (job) =>
              job.status == JobStatus.queued ||
              job.status == JobStatus.processing,
        )
        .map((job) => job.jobId)
        .toList(growable: false);

    for (final jobId in activeJobIds) {
      try {
        await fetchJob(jobId);
      } catch (e) {
        _emit('poll.error', {'job_id': jobId, 'error': e.toString()});
      }
    }
  }

  void _handleWsMessage(dynamic raw) {
    final now = DateTime.now().toUtc();

    if (raw is String && raw.trim().toLowerCase() == 'pong') {
      _emit('pong', {'message': 'pong'});
      return;
    }

    final map = _coerceMessageToMap(raw);
    if (map == null) {
      _emit('ws.message', {'raw': raw.toString()});
      return;
    }

    final event = _stringFromMap(map, const ['event', 'type']) ?? 'ws.message';
    final data = _extractEventData(map, event);

    _controller.add(QueueEvent(event: event, timestamp: now, data: data));

    if (event == 'job.status' || event == 'job.result') {
      _applyJobPayload(data, sourceEvent: event);
    }
  }

  Map<String, dynamic>? _coerceMessageToMap(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is! String) {
      return null;
    }

    final text = raw.trim();
    if (text.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return {'payload': decoded};
    } catch (_) {
      return {'message': text};
    }
  }

  Map<String, dynamic> _extractEventData(
    Map<String, dynamic> map,
    String event,
  ) {
    final dataRaw = map['data'];
    if (dataRaw is Map) {
      return Map<String, dynamic>.from(dataRaw);
    }

    final result = Map<String, dynamic>.from(map);
    result.remove('event');
    result.remove('type');
    if (result.isNotEmpty) {
      return result;
    }
    return {'event': event};
  }

  void _applyJobPayload(
    Map<String, dynamic> payload, {
    String? fallbackJobId,
    String sourceEvent = 'job.status',
    bool emitNormalizedEvent = false,
  }) {
    final jobId =
        _stringFromMap(payload, const ['job_id', 'jobId', 'id']) ??
        fallbackJobId;
    if (jobId == null || jobId.isEmpty) {
      return;
    }

    final fallbackStatus = sourceEvent == 'job.result'
        ? 'completed'
        : 'processing';
    final statusText =
        _stringFromMap(payload, const ['status']) ?? fallbackStatus;
    final status = _parseStatus(statusText);

    Map<String, dynamic>? result;
    final resultRaw = payload['result'];
    if (resultRaw is Map) {
      result = Map<String, dynamic>.from(resultRaw);
    }

    final error = _stringFromMap(payload, const ['error', 'message', 'detail']);

    _upsertJob(jobId: jobId, status: status, result: result, error: error);

    if (emitNormalizedEvent) {
      _emit('job.status', {
        'job_id': jobId,
        'status': statusText,
        'source': sourceEvent,
      });

      if (result != null ||
          status == JobStatus.completed ||
          status == JobStatus.failed) {
        _emit('job.result', {
          'job_id': jobId,
          'status': statusText,
          'result': result,
          'error': error,
        });
      }
    }
  }

  void _upsertJob({
    required String jobId,
    required JobStatus status,
    Map<String, dynamic>? result,
    String? error,
  }) {
    final existing = _jobs[jobId];
    final now = DateTime.now().toUtc();
    _jobs[jobId] = QueueJob(
      jobId: jobId,
      status: status,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      result: result ?? existing?.result,
      error: error ?? existing?.error,
      imageInfo: existing?.imageInfo ?? const {'source': 'backend'},
    );
  }

  String _buildUploadFilename(PreparedFrame frame) {
    final basename = frame.sourcePath.split(RegExp(r'[\\/]')).last;
    if (basename.contains('.')) {
      return basename;
    }
    final ext = _detectImageSubtype(frame);
    return 'upload-${DateTime.now().millisecondsSinceEpoch}.$ext';
  }

  String _detectImageSubtype(PreparedFrame frame) {
    final path = frame.sourcePath.toLowerCase();

    if (path.endsWith('.jpeg') || path.endsWith('.jpg')) {
      return 'jpeg';
    }
    if (path.endsWith('.png')) {
      return 'png';
    }
    if (path.endsWith('.gif')) {
      return 'gif';
    }
    if (path.endsWith('.bmp')) {
      return 'bmp';
    }
    if (path.endsWith('.webp')) {
      return 'webp';
    }
    if (path.endsWith('.tiff') || path.endsWith('.tif')) {
      return 'tiff';
    }

    final bytes = frame.bytes;
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'gif';
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'bmp';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes.length >= 4 &&
        ((bytes[0] == 0x49 &&
                bytes[1] == 0x49 &&
                bytes[2] == 0x2A &&
                bytes[3] == 0x00) ||
            (bytes[0] == 0x4D &&
                bytes[1] == 0x4D &&
                bytes[2] == 0x00 &&
                bytes[3] == 0x2A))) {
      return 'tiff';
    }

    return 'jpeg';
  }

  Uri _httpUri(String path) {
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    final base = Uri.parse(
      _backendBaseUrl.endsWith('/') ? _backendBaseUrl : '$_backendBaseUrl/',
    );
    return base.resolve(normalizedPath);
  }

  Uri _wsUri(String path) {
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    final httpBase = Uri.parse(_backendBaseUrl);
    final wsBase = httpBase.replace(
      scheme: httpBase.scheme.toLowerCase() == 'https' ? 'wss' : 'ws',
    );
    final base = Uri.parse(
      wsBase.toString().endsWith('/') ? '$wsBase' : '$wsBase/',
    );
    return base.resolve(normalizedPath);
  }

  static String _normalizeBaseUrl(String input) {
    final raw = input.trim();
    final uri = Uri.parse(raw);
    if (!uri.hasScheme || !uri.hasAuthority) {
      throw const FormatException('Backend URL phải có dạng http://host:port');
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const FormatException('Backend URL chỉ hỗ trợ http hoặc https');
    }

    final normalized = uri.replace(path: '', query: null, fragment: null);
    var text = normalized.toString();
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  Map<String, dynamic> _decodeObject(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const FormatException('Response JSON phải là object');
  }

  String _extractErrorText(String body) {
    try {
      final payload = _decodeObject(body);
      return _stringFromMap(payload, const ['detail', 'error', 'message']) ??
          body;
    } catch (_) {
      return body;
    }
  }

  String? _stringFromMap(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) {
        continue;
      }
      return '$value';
    }
    return null;
  }

  JobStatus _parseStatus(String status) {
    switch (status.trim().toLowerCase()) {
      case 'queued':
        return JobStatus.queued;
      case 'processing':
        return JobStatus.processing;
      case 'completed':
        return JobStatus.completed;
      case 'failed':
        return JobStatus.failed;
      default:
        return JobStatus.queued;
    }
  }

  void _emit(String event, Map<String, dynamic> data) {
    if (_controller.isClosed) {
      return;
    }
    _controller.add(
      QueueEvent(event: event, timestamp: DateTime.now().toUtc(), data: data),
    );
  }

  void dispose() {
    _disposed = true;
    _autoReconnectEnabled = false;
    _stopPolling();
    _reconnectTimer?.cancel();
    unawaited(_disconnectWebSocket());
    _httpClient.close();
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
