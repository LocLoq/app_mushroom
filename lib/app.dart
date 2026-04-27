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
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String kDefaultBackendBaseUrl = 'http://10.0.2.2:8000';
const String _kPrefBackendBaseUrl = 'backend_base_url';
const String _kPrefDarkMode = 'dark_mode';
const String _kPrefBackendConfigured = 'backend_configured';

class MushroomRecognizerApp extends StatefulWidget {
  const MushroomRecognizerApp({super.key});

  @override
  State<MushroomRecognizerApp> createState() => _MushroomRecognizerAppState();
}

class _MushroomRecognizerAppState extends State<MushroomRecognizerApp> {
  final AppPreferencesService _preferences = AppPreferencesService();

  AppConfig _config = const AppConfig(
    backendBaseUrl: kDefaultBackendBaseUrl,
    darkMode: false,
  );
  BackendQueueService? _queueService;
  RecognitionHistoryService? _historyService;
  StreamSubscription<QueueEvent>? _queueEventSubscription;

  bool _wsConnected = false;
  bool _isReady = false;
  String? _initError;
  bool _isStartupConnecting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _queueEventSubscription?.cancel();
    _queueService?.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final loaded = await _preferences.load();
      final queue = BackendQueueService(
        initialBackendBaseUrl: loaded.backendBaseUrl,
      );
      final history = RecognitionHistoryService();
      await history.init();

      _queueEventSubscription = queue.events.listen((event) {
        if (!mounted) {
          return;
        }
        if (event.event == 'ws.connected') {
          setState(() {
            _wsConnected = true;
            _isStartupConnecting = false;
          });
        }
        if (event.event == 'ws.closed' || event.event == 'ws.error') {
          setState(() {
            _wsConnected = false;
          });
        }
      });

      setState(() {
        _config = loaded;
        _queueService = queue;
        _historyService = history;
        _isReady = true;
        _initError = null;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(_handleStartupBackendFlow(queue));
      });
    } catch (e) {
      setState(() {
        _initError = 'Không thể khởi tạo ứng dụng: $e';
        _isReady = true;
      });
    }
  }

  Future<void> _handleStartupBackendFlow(BackendQueueService queue) async {
    final configured = await _preferences.isBackendConfigured();
    if (!mounted) {
      return;
    }

    if (!configured) {
      await _showFirstRunBackendDialog(queue);
      return;
    }

    await _connectBackendWithTimeout(queue, queue.backendBaseUrl);
  }

  Future<void> _connectBackendWithTimeout(
    BackendQueueService queue,
    String baseUrl,
  ) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _isStartupConnecting = true;
    });

    try {
      await queue.reconnectWithTimeout(
        baseUrl: baseUrl,
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isStartupConnecting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Không thể kết nối backend trong 15 giây: $e'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isStartupConnecting = false;
        });
      }
    }
  }

  Future<void> _showFirstRunBackendDialog(BackendQueueService queue) async {
    final controller = TextEditingController(text: queue.backendBaseUrl);
    var isConnecting = false;
    String? errorText;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Thiết lập backend lần đầu'),
              content: SizedBox(
                width: min(420, MediaQuery.of(context).size.width * 0.9),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Vui lòng nhập địa chỉ IP/URL backend để bắt đầu sử dụng ứng dụng.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      enabled: !isConnecting,
                      decoration: const InputDecoration(
                        labelText: 'Backend URL',
                        hintText: 'http://10.0.2.2:8000',
                      ),
                    ),
                    if (isConnecting) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                    if (errorText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          errorText!,
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: isConnecting
                      ? null
                      : () async {
                          setDialogState(() {
                            isConnecting = true;
                            errorText = null;
                          });

                          try {
                            final value = controller.text.trim();
                            await _saveBackendBaseUrl(value);
                            await queue.reconnectWithTimeout(
                              baseUrl: value,
                              timeout: const Duration(seconds: 15),
                            );
                            await _preferences.markBackendConfigured();
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          } catch (e) {
                            setDialogState(() {
                              isConnecting = false;
                              errorText = 'Không thể kết nối trong 15 giây: $e';
                            });
                          }
                        },
                  child: const Text('Lưu và kết nối'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
  }

  Future<void> _saveBackendBaseUrl(String input) async {
    final normalized = BackendQueueService.normalizeBaseUrl(input);
    setState(() {
      _config = _config.copyWith(backendBaseUrl: normalized);
    });
    _queueService?.updateBackendBaseUrl(normalized);
    await _preferences.saveBackendBaseUrl(normalized);
    await _preferences.markBackendConfigured();
  }

  Future<void> _setDarkMode(bool isDarkMode) async {
    setState(() {
      _config = _config.copyWith(darkMode: isDarkMode);
    });
    await _preferences.saveDarkMode(isDarkMode);
  }

  ThemeData _buildTheme({required bool dark}) {
    final seed = dark ? const Color(0xFF90A955) : const Color(0xFF4F772D);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: dark ? Brightness.dark : Brightness.light,
    );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      cardTheme: CardThemeData(
        elevation: dark ? 0 : 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    if (_initError != null || _queueService == null || _historyService == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _initError ?? 'Khởi tạo thất bại.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(dark: false),
      darkTheme: _buildTheme(dark: true),
      themeMode: _config.darkMode ? ThemeMode.dark : ThemeMode.light,
      home: MainMenuPage(
        queueService: _queueService!,
        historyService: _historyService!,
        config: _config,
        wsConnected: _wsConnected,
        isConnectingBackend: _isStartupConnecting,
        onSaveBackendBaseUrl: _saveBackendBaseUrl,
        onToggleDarkMode: _setDarkMode,
      ),
    );
  }
}

class MainMenuPage extends StatelessWidget {
  const MainMenuPage({
    super.key,
    required this.queueService,
    required this.historyService,
    required this.config,
    required this.wsConnected,
    required this.isConnectingBackend,
    required this.onSaveBackendBaseUrl,
    required this.onToggleDarkMode,
  });

  final BackendQueueService queueService;
  final RecognitionHistoryService historyService;
  final AppConfig config;
  final bool wsConnected;
  final bool isConnectingBackend;
  final Future<void> Function(String) onSaveBackendBaseUrl;
  final Future<void> Function(bool) onToggleDarkMode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colors.primaryContainer.withAlpha(200),
              colors.surface,
              colors.tertiaryContainer.withAlpha(120),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: colors.surface.withAlpha(220),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'App Nhận Diện Nấm',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Chọn chức năng để xem danh mục, cài đặt kết nối và bắt đầu nhận diện.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Chip(
                          avatar: Icon(
                            Icons.storage_outlined,
                            size: 18,
                            color: colors.primary,
                          ),
                          label: Text('Backend: ${config.backendBaseUrl}'),
                        ),
                        Chip(
                          avatar: Icon(
                            isConnectingBackend
                                ? Icons.sync
                                : wsConnected
                                ? Icons.wifi_tethering
                                : Icons.wifi_tethering_error,
                            size: 18,
                            color: isConnectingBackend
                                ? Colors.orange.shade700
                                : wsConnected
                                ? Colors.green.shade700
                                : colors.error,
                          ),
                          label: Text(
                            isConnectingBackend
                                ? 'WS đang kết nối...'
                                : wsConnected
                                ? 'WS đang kết nối'
                                : 'WS đang ngắt',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _MenuActionCard(
                icon: Icons.play_circle_fill_outlined,
                title: 'Bắt đầu nhận diện',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MushroomRecognitionPage(
                        queueService: queueService,
                        historyService: historyService,
                      ),
                    ),
                  );
                },
              ),
              _MenuActionCard(
                icon: Icons.history,
                title: 'Lịch sử nhận diện',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RecognitionHistoryPage(
                        historyService: historyService,
                      ),
                    ),
                  );
                },
              ),
              _MenuActionCard(
                icon: Icons.menu_book_outlined,
                title: 'Xem danh sách nấm trong bộ dữ liệu',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MushroomCatalogPage(
                        backendBaseUrl: config.backendBaseUrl,
                      ),
                    ),
                  );
                },
              ),
              _MenuActionCard(
                icon: Icons.settings_outlined,
                title: 'Cài đặt',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SettingsPage(
                        queueService: queueService,
                        backendBaseUrl: config.backendBaseUrl,
                        darkMode: config.darkMode,
                        wsConnected: wsConnected,
                        onSaveBackendBaseUrl: onSaveBackendBaseUrl,
                        onToggleDarkMode: onToggleDarkMode,
                      ),
                    ),
                  );
                },
              ),
              _MenuActionCard(
                icon: Icons.info_outline,
                title: 'Giới thiệu',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const IntroPage()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuActionCard extends StatelessWidget {
  const _MenuActionCard({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: colors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_ios_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class IntroPage extends StatelessWidget {
  const IntroPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Giới thiệu')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _IntroBlock(
            title: 'Mục tiêu ứng dụng',
            content:
                'Ứng dụng hỗ trợ nhận diện nấm từ ảnh chụp, ảnh thư viện hoặc frame trích từ video. Kết quả được xếp hàng qua backend và cập nhật theo job.',
          ),
          _IntroBlock(
            title: 'Cách sử dụng nhanh',
            content:
                '1) Vào Cài đặt để nhập địa chỉ backend và kết nối WebSocket.\n2) Vào Bắt đầu nhận diện để chọn dữ liệu ảnh/video và gửi job.\n3) Theo dõi trạng thái job và kết quả trong màn hình nhận diện.',
          ),
          _IntroBlock(
            title: 'Ý nghĩa kết quả',
            content:
                'prediction là kết quả cuối cùng sau khi backend đánh giá ngưỡng tin cậy. raw_prediction là nhãn model dự đoán ban đầu. accepted_prediction cho biết kết quả có đạt ngưỡng để chấp nhận hay không. decision_reason giải thích vì sao backend trả kết quả đó.',
          ),
          _IntroBlock(
            title: 'Lưu ý an toàn',
            content:
                'Dự đoán chỉ mang tính tham khảo. Không sử dụng app để xác định khả năng ăn được của nấm trong tình huống thực tế.',
          ),
        ],
      ),
    );
  }
}

class _IntroBlock extends StatelessWidget {
  const _IntroBlock({required this.title, required this.content});

  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(content),
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.queueService,
    required this.backendBaseUrl,
    required this.darkMode,
    required this.wsConnected,
    required this.onSaveBackendBaseUrl,
    required this.onToggleDarkMode,
  });

  final BackendQueueService queueService;
  final String backendBaseUrl;
  final bool darkMode;
  final bool wsConnected;
  final Future<void> Function(String) onSaveBackendBaseUrl;
  final Future<void> Function(bool) onToggleDarkMode;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _backendController;
  StreamSubscription<QueueEvent>? _eventSubscription;

  final List<QueueEvent> _events = [];
  bool _wsConnected = false;
  bool _isSaving = false;
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  bool _darkMode = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _backendController = TextEditingController(text: widget.backendBaseUrl);
    _darkMode = widget.darkMode;
    _wsConnected = widget.wsConnected;

    _eventSubscription = widget.queueService.events.listen((event) {
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
        if (_events.length > 20) {
          _events.removeRange(20, _events.length);
        }
      });
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _backendController.dispose();
    super.dispose();
  }

  Future<void> _saveBackendOnly() async {
    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      await widget.onSaveBackendBaseUrl(_backendController.text.trim());
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã lưu địa chỉ backend.')),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Không thể lưu backend URL: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _saveAndReconnectWs() async {
    setState(() {
      _isConnecting = true;
      _error = null;
    });

    try {
      final value = _backendController.text.trim();
      await widget.onSaveBackendBaseUrl(value);
      await widget.queueService.reconnectWithTimeout(
        baseUrl: value,
        timeout: const Duration(seconds: 15),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Đã kết nối WS tới ${widget.queueService.backendBaseUrl}',
          ),
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
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _disconnectWs() async {
    setState(() {
      _isDisconnecting = true;
      _error = null;
    });

    try {
      await widget.queueService.disconnect();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã ngắt kết nối WebSocket.')),
      );
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
          _isDisconnecting = false;
        });
      }
    }
  }

  Future<void> _toggleDarkMode(bool value) async {
    setState(() {
      _darkMode = value;
    });

    try {
      await widget.onToggleDarkMode(value);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _darkMode = !value;
        _error = 'Không thể đổi chế độ giao diện: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Backend và WebSocket',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _backendController,
                    decoration: const InputDecoration(
                      labelText: 'Backend URL',
                      hintText: 'http://10.0.2.2:8000',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        _wsConnected
                            ? Icons.wifi_tethering
                            : Icons.wifi_tethering_error,
                        color: _wsConnected
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text(_wsConnected ? 'WS đang kết nối' : 'WS đang ngắt'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _isSaving ? null : _saveBackendOnly,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Lưu backend'),
                      ),
                      FilledButton.icon(
                        onPressed: _isConnecting ? null : _saveAndReconnectWs,
                        icon: const Icon(Icons.link_outlined),
                        label: const Text('Kết nối WS'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isDisconnecting || !_wsConnected
                            ? null
                            : _disconnectWs,
                        icon: const Icon(Icons.link_off_outlined),
                        label: const Text('Ngắt WS'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _wsConnected
                            ? widget.queueService.sendPing
                            : null,
                        icon: const Icon(Icons.network_ping),
                        label: const Text('Ping'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              value: _darkMode,
              onChanged: _toggleDarkMode,
              title: const Text('Chế độ tối'),
              subtitle: const Text('Bật tắt giao diện sáng/tối trong ứng dụng.'),
              secondary: Icon(_darkMode ? Icons.dark_mode : Icons.light_mode),
            ),
          ),
          if (_isSaving || _isConnecting || _isDisconnecting)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sự kiện WebSocket gần đây',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_events.isEmpty)
                    const Text('Chưa có sự kiện nào.'),
                  if (_events.isNotEmpty)
                    ..._events.take(8).map(
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

class MushroomCatalogPage extends StatefulWidget {
  const MushroomCatalogPage({super.key, required this.backendBaseUrl});

  final String backendBaseUrl;

  @override
  State<MushroomCatalogPage> createState() => _MushroomCatalogPageState();
}

class _MushroomCatalogPageState extends State<MushroomCatalogPage> {
  bool _isLoading = false;
  String? _error;
  MushroomCatalogResponse? _catalog;

  @override
  void initState() {
    super.initState();
    unawaited(_fetchCatalog());
  }

  Future<void> _fetchCatalog() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final uri = Uri.parse(widget.backendBaseUrl).resolve('/api/mushrooms/catalog');
      final response = await http.get(uri);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('JSON catalog không hợp lệ.');
      }

      final parsed = MushroomCatalogResponse.fromJson(decoded);
      setState(() {
        _catalog = parsed;
      });
    } catch (e) {
      setState(() {
        _error = 'Không thể tải danh mục nấm: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;

    return Scaffold(
      appBar: AppBar(title: const Text('Danh mục nấm trong dữ liệu')),
      body: RefreshIndicator(
        onRefresh: _fetchCatalog,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_sync_outlined),
                title: const Text('API endpoint'),
                subtitle: Text('${widget.backendBaseUrl}/api/mushrooms/catalog'),
                trailing: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        onPressed: _fetchCatalog,
                        icon: const Icon(Icons.refresh),
                      ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (catalog == null && !_isLoading)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Chưa có dữ liệu danh mục.'),
                ),
              ),
            if (catalog != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _StatChip(
                        icon: Icons.dataset,
                        label: 'Tổng',
                        value: '${catalog.total}',
                      ),
                      _StatChip(
                        icon: Icons.shield_outlined,
                        label: 'An toàn',
                        value: '${catalog.safeCount}',
                        color: Colors.green.shade700,
                      ),
                      _StatChip(
                        icon: Icons.warning_amber_rounded,
                        label: 'Độc',
                        value: '${catalog.poisonousCount}',
                        color: Colors.red.shade700,
                      ),
                      _StatChip(
                        icon: Icons.source_outlined,
                        label: 'Nguồn',
                        value: catalog.source,
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          'Danh sách nấm',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...catalog.mushrooms.map((item) {
                        final danger = item.isPoisonous;
                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: danger
                                ? Colors.red.withAlpha(20)
                                : Colors.green.withAlpha(20),
                          ),
                          child: ListTile(
                            leading: Icon(
                              danger
                                  ? Icons.warning_amber_rounded
                                  : Icons.eco_outlined,
                              color: danger
                                  ? Colors.red.shade700
                                  : Colors.green.shade700,
                            ),
                            title: Text(item.name),
                            subtitle: Text(item.scientificName),
                            trailing: Text(
                              danger ? 'Độc' : 'An toàn',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: danger
                                    ? Colors.red.shade700
                                    : Colors.green.shade700,
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effective = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: effective.withAlpha(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: effective),
          const SizedBox(width: 6),
          Text('$label: $value'),
        ],
      ),
    );
  }
}

class MushroomRecognitionPage extends StatefulWidget {
  const MushroomRecognitionPage({
    super.key,
    required this.queueService,
    required this.historyService,
  });

  final BackendQueueService queueService;
  final RecognitionHistoryService historyService;

  @override
  State<MushroomRecognitionPage> createState() => _MushroomRecognitionPageState();
}

class _MushroomRecognitionPageState extends State<MushroomRecognitionPage> {
  final ImagePicker _picker = ImagePicker();
  final FrameSelectorService _frameSelector = FrameSelectorService();

  StreamSubscription<QueueEvent>? _eventSubscription;
  final List<QueueEvent> _events = [];

  PreparedFrame? _preparedFrame;
  bool _isPreparing = false;
  bool _isSubmittingJob = false;
  bool _wsConnected = false;
  String? _error;
  final Set<String> _shownResultDialogJobs = <String>{};
  final Set<String> _popupEligibleJobIds = <String>{};

  @override
  void initState() {
    super.initState();
    _wsConnected = widget.queueService.isWebSocketConnected;
    _eventSubscription = widget.queueService.events.listen((event) {
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

      final jobId = _stringFromMap(event.data, const ['job_id', 'jobId', 'id']);
      if (jobId != null && jobId.isNotEmpty) {
        unawaited(_syncHistoryAndMaybePopup(jobId));
      }
    });

    for (final job in widget.queueService.jobs) {
      unawaited(_syncHistoryAndMaybePopup(job.jobId, allowPopup: false));
    }
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
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
      final jobId = await widget.queueService.enqueue(frame);
      _popupEligibleJobIds.add(jobId);
      await _syncHistoryAndMaybePopup(jobId);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã upload và tạo job: $jobId')),
      );
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

  Future<void> _syncHistoryAndMaybePopup(
    String jobId, {
    bool allowPopup = true,
  }) async {
    final job = widget.queueService.getJobById(jobId);
    if (job == null) {
      return;
    }

    await widget.historyService.upsertFromJob(
      job: job,
      backendBaseUrl: widget.queueService.backendBaseUrl,
    );

    final isFinished =
        job.status == JobStatus.completed || job.status == JobStatus.failed;
    if (!allowPopup || !_popupEligibleJobIds.contains(jobId)) {
      return;
    }

    if (!isFinished || _shownResultDialogJobs.contains(jobId) || !mounted) {
      return;
    }

    _shownResultDialogJobs.add(jobId);
    await _showResultPopup(job);
  }

  Future<void> _showResultPopup(QueueJob job) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Kết quả nhận diện'),
          content: SizedBox(
            width: min(420, MediaQuery.of(context).size.width * 0.9),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (job.previewBytes != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(
                        job.previewBytes!,
                        width: double.infinity,
                        height: 180,
                        fit: BoxFit.cover,
                      ),
                    ),
                  if (job.previewBytes != null) const SizedBox(height: 10),
                  Text('Job ID: ${job.jobId}'),
                  Text('Trạng thái: ${job.status.label}'),
                  if (job.result != null) ...[
                    const SizedBox(height: 10),
                    _ResultPayloadView(result: job.result!),
                  ],
                  if (job.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Lỗi: ${job.error}',
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Đóng'),
            ),
          ],
        );
      },
    );
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

  @override
  Widget build(BuildContext context) {
    final jobs = widget.queueService.jobs;
    final backendBaseUrl = widget.queueService.backendBaseUrl;

    return Scaffold(
      appBar: AppBar(title: const Text('Nhận diện nấm')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Trạng thái kết nối',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('HTTP: $backendBaseUrl'),
                  const SizedBox(height: 4),
                  Text(
                    _wsConnected ? 'WebSocket: connected' : 'WebSocket: disconnected',
                    style: TextStyle(
                      color: _wsConnected
                          ? Colors.green.shade700
                          : Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Nếu cần đổi backend IP hoặc kết nối WS, hãy vào màn hình Cài đặt trong menu chính.',
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
                  Text(
                    'Dữ liệu ảnh đã chuẩn bị',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_preparedFrame == null)
                    const Text('Chưa có ảnh nào. Hãy upload ảnh hoặc quay video.'),
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
                    Text('Kích thước ảnh: ${_preparedFrame!.bytes.lengthInBytes} bytes'),
                    Text(
                      'Điểm chất lượng: ${(_preparedFrame!.qualityScore * 100).toStringAsFixed(1)} / 100',
                    ),
                    if (_preparedFrame!.selectedFrameMs != null)
                      Text('Frame được chọn: ${_preparedFrame!.selectedFrameMs} ms'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _isSubmittingJob ? null : _enqueuePreparedFrame,
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
                  Text(
                    'Hàng chờ công việc',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (jobs.isEmpty) const Text('Chưa có job.'),
                  if (jobs.isNotEmpty)
                    ...jobs.map(
                      (job) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _JobResultCard(job: job),
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
                  Text(
                    'Sự kiện WebSocket gần đây',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_events.isEmpty) const Text('Chưa có sự kiện.'),
                  if (_events.isNotEmpty)
                    ..._events.take(10).map(
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

class _JobResultCard extends StatelessWidget {
  const _JobResultCard({required this.job});

  final QueueJob job;

  @override
  Widget build(BuildContext context) {
    final result = job.result;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: job.status.color.withAlpha(90)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: job.status.color.withAlpha(35),
                  child: Icon(
                    Icons.memory_outlined,
                    size: 16,
                    color: job.status.color,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Job: ${job.jobId}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  job.status.label,
                  style: TextStyle(
                    color: job.status.color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (job.previewBytes != null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  job.previewBytes!,
                  width: double.infinity,
                  height: 150,
                  fit: BoxFit.cover,
                ),
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 10),
              _ResultPayloadView(result: result),
            ],
            if (job.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Lỗi: ${job.error}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Cập nhật lúc: ${job.updatedAt.toLocal()}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultPayloadView extends StatelessWidget {
  const _ResultPayloadView({required this.result});

  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final prediction = _toStringValue(result['prediction']) ?? 'unknown';
    final predictionLower = prediction.trim().toLowerCase();
    final name = predictionLower == 'unknown'
        ? 'unknown'
        : (_toStringValue(result['mushroom_name']) ?? 'unknown');
    final rawPrediction = _toStringValue(result['raw_prediction']) ?? 'N/A';
    final acceptedPrediction = _toBool(result['accepted_prediction']);
    final confidence = _formatPercent(result['confidence']) ?? 'N/A';
    final confidenceThreshold =
        _formatPercent(result['confidence_threshold']) ?? 'N/A';
    final poisonous = _toBool(result['is_poisonous']);
    final poisonText = poisonous == null
      ? 'Chưa rõ'
        : poisonous
        ? 'Nấm độc'
        : 'Nấm an toàn';
    final reason = _toStringValue(result['decision_reason']) ?? 'N/A';
    final imageType = _toStringValue(result['image_type']) ?? 'N/A';
    final sizeBytes = _toStringValue(result['size_bytes']) ?? 'N/A';
    final sha = _toStringValue(result['sha256']) ?? 'N/A';
    final inferenceTime = _formatSeconds(result['inference_time_seconds']) ?? 'N/A';

    Color chipColor;
    if (poisonous == true) {
      chipColor = Colors.red.shade700;
    } else if (poisonous == false) {
      chipColor = Colors.green.shade700;
    }
     else {
      chipColor = Colors.orange.shade700;
    }
    if (prediction.toLowerCase() == 'unknown') {
      chipColor = Colors.orange.shade700;
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: chipColor.withAlpha(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                label: Text('name: $name'),
                avatar: const Icon(Icons.label, size: 18),
              ),
              Chip(
                label: Text('prediction: $prediction'),
                avatar: const Icon(Icons.psychology_alt_outlined, size: 18),
              ),
              Chip(
                label: Text('confidence: $confidence'),
                avatar: const Icon(Icons.analytics_outlined, size: 18),
              ),
              Chip(
                label: Text(poisonText),
                avatar: const Icon(Icons.health_and_safety_outlined, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _ResultRow(label: 'raw_prediction', value: rawPrediction),
          _ResultRow(
            label: 'accepted_prediction',
            value: acceptedPrediction == true
                ? 'true'
                : acceptedPrediction == false
                    ? 'false'
                    : 'null',
          ),
          _ResultRow(label: 'confidence_threshold', value: confidenceThreshold),
          _ResultRow(label: 'decision_reason', value: reason),
          _ResultRow(label: 'image_type', value: imageType),
          _ResultRow(label: 'size_bytes', value: sizeBytes),
          _ResultRow(label: 'sha256', value: sha),
          _ResultRow(label: 'inference_time_seconds', value: inferenceTime),
        ],
      ),
    );
  }

  static bool? _toBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') {
        return true;
      }
      if (normalized == 'false' || normalized == '0') {
        return false;
      }
    }
    return null;
  }

  static String? _toStringValue(dynamic value) {
    if (value == null) {
      return null;
    }
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  static String? _formatPercent(dynamic value) {
    final number = _toDouble(value);
    if (number == null) {
      return null;
    }
    final resolved = number <= 1 ? number * 100 : number;
    return '${resolved.toStringAsFixed(2)}%';
  }

  static String? _formatSeconds(dynamic value) {
    final number = _toDouble(value);
    if (number == null) {
      return null;
    }
    return '${number.toStringAsFixed(3)} s';
  }

  static double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class RecognitionHistoryPage extends StatefulWidget {
  const RecognitionHistoryPage({
    super.key,
    required this.historyService,
  });

  final RecognitionHistoryService historyService;

  @override
  State<RecognitionHistoryPage> createState() => _RecognitionHistoryPageState();
}

class _RecognitionHistoryPageState extends State<RecognitionHistoryPage> {
  bool _loading = true;
  String? _error;
  List<RecognitionHistoryItem> _items = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadHistory());
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await widget.historyService.reload();
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Không thể tải lịch sử: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _showHistoryDetail(RecognitionHistoryItem item) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final statusColor = _statusColor(item.status);
        final hasPreview = item.previewImagePath != null &&
            File(item.previewImagePath!).existsSync();

        return AlertDialog(
          title: const Text('Chi tiết lịch sử nhận diện'),
          content: SizedBox(
            width: min(420, MediaQuery.of(context).size.width * 0.9),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasPreview)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        File(item.previewImagePath!),
                        width: double.infinity,
                        height: 180,
                        fit: BoxFit.cover,
                      ),
                    ),
                  if (hasPreview) const SizedBox(height: 10),
                  Text('Job ID: ${item.jobId}'),
                  Text(
                    'Trạng thái: ${item.status}',
                    style: TextStyle(color: statusColor, fontWeight: FontWeight.w700),
                  ),
                  Text('Nguồn media: ${item.sourceMediaType ?? 'N/A'}'),
                  Text('Thời điểm: ${item.updatedAt.toLocal()}'),
                  if (item.sourceMediaPath != null)
                    Text('File media: ${item.sourceMediaPath}'),
                  if (item.result != null) ...[
                    const SizedBox(height: 10),
                    _ResultPayloadView(result: item.result!),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Đóng'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lịch sử nhận diện')),
      body: RefreshIndicator(
        onRefresh: _loadHistory,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!_loading && _items.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Chưa có lịch sử nhận diện.'),
                ),
              ),
            ..._items.map((item) {
              final statusColor = _statusColor(item.status);
              final previewExists = item.previewImagePath != null &&
                  File(item.previewImagePath!).existsSync();

              return Card(
                child: ListTile(
                  onTap: () => _showHistoryDetail(item),
                  leading: previewExists
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(item.previewImagePath!),
                            width: 52,
                            height: 52,
                            fit: BoxFit.cover,
                          ),
                        )
                      : const CircleAvatar(
                          child: Icon(Icons.image_not_supported_outlined),
                        ),
                  title: Text(item.mushroomName ?? 'unknown'),
                  subtitle: Text(
                    'Job: ${item.jobId}\nNhãn: ${item.prediction ?? 'unknown'}\n${item.updatedAt.toLocal()}',
                  ),
                  trailing: Text(
                    item.status,
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  isThreeLine: true,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
        return Colors.green.shade700;
      case 'failed':
        return Colors.red.shade700;
      case 'processing':
        return Colors.blue.shade700;
      default:
        return Colors.amber.shade800;
    }
  }
}

class RecognitionHistoryService {
  static const String _kPrefRecognitionHistory = 'recognition_history_v1';
  static const int _kMaxHistoryItems = 200;

  late SharedPreferences _prefs;
  late Directory _historyDir;
  late Directory _mediaDir;
  bool _initialized = false;
  List<RecognitionHistoryItem> _items = const [];

  List<RecognitionHistoryItem> get items => List.unmodifiable(_items);

  Future<void> init() async {
    if (_initialized) {
      return;
    }

    _prefs = await SharedPreferences.getInstance();
    final docsDir = await getApplicationDocumentsDirectory();
    _historyDir = Directory('${docsDir.path}/recognition_history');
    _mediaDir = Directory('${_historyDir.path}/media');

    if (!await _historyDir.exists()) {
      await _historyDir.create(recursive: true);
    }
    if (!await _mediaDir.exists()) {
      await _mediaDir.create(recursive: true);
    }

    _items = _loadItemsFromPrefs();
    _initialized = true;
  }

  Future<List<RecognitionHistoryItem>> reload() async {
    await init();
    _items = _loadItemsFromPrefs();
    return items;
  }

  Future<void> upsertFromJob({
    required QueueJob job,
    required String backendBaseUrl,
  }) async {
    await init();

    final existingIndex = _items.indexWhere((item) => item.jobId == job.jobId);
    final existing = existingIndex >= 0 ? _items[existingIndex] : null;

    final previewImagePath = await _resolvePreviewImagePath(
      job: job,
      existingPath: existing?.previewImagePath,
    );

    final sourceMediaPath = await _resolveSourceMediaPath(
      job: job,
      existingPath: existing?.sourceMediaPath,
    );

    final result = job.result;
    final prediction = _asString(result?['prediction']) ?? 'unknown';
    final predictionLower = prediction.trim().toLowerCase();
    final mushroomName = predictionLower == 'unknown'
        ? 'unknown'
        : (_asString(result?['mushroom_name']) ?? 'unknown');

    final item = RecognitionHistoryItem(
      id: existing?.id ?? '${job.jobId}_${DateTime.now().millisecondsSinceEpoch}',
      jobId: job.jobId,
      status: job.status.label,
      createdAt: existing?.createdAt ?? job.createdAt,
      updatedAt: job.updatedAt,
      backendBaseUrl: backendBaseUrl,
      mushroomName: mushroomName,
      prediction: prediction,
      rawPrediction: _asString(result?['raw_prediction']),
      confidence: _asDouble(result?['confidence']),
      isPoisonous: _asBool(result?['is_poisonous']),
      decisionReason: _asString(result?['decision_reason']),
      previewImagePath: previewImagePath,
      sourceMediaPath: sourceMediaPath,
      sourceMediaType: job.originalMediaType ?? existing?.sourceMediaType,
      result: result,
      error: job.error,
    );

    final updated = List<RecognitionHistoryItem>.from(_items);
    if (existingIndex >= 0) {
      updated[existingIndex] = item;
    } else {
      updated.insert(0, item);
    }

    updated.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (updated.length > _kMaxHistoryItems) {
      updated.removeRange(_kMaxHistoryItems, updated.length);
    }

    _items = updated;
    await _persist();
  }

  Future<String?> _resolvePreviewImagePath({
    required QueueJob job,
    required String? existingPath,
  }) async {
    if (existingPath != null && File(existingPath).existsSync()) {
      return existingPath;
    }
    if (job.previewBytes == null) {
      return null;
    }

    final filePath = '${_mediaDir.path}/preview_${_safeName(job.jobId)}.jpg';
    final file = File(filePath);
    await file.writeAsBytes(job.previewBytes!, flush: true);
    return file.path;
  }

  Future<String?> _resolveSourceMediaPath({
    required QueueJob job,
    required String? existingPath,
  }) async {
    if (existingPath != null && File(existingPath).existsSync()) {
      return existingPath;
    }

    final sourcePath = job.originalMediaPath;
    if (sourcePath == null || sourcePath.isEmpty) {
      return null;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      return null;
    }

    final ext = _extractExtension(sourcePath);
    final targetPath = '${_mediaDir.path}/source_${_safeName(job.jobId)}$ext';
    final copied = await sourceFile.copy(targetPath);
    return copied.path;
  }

  String _extractExtension(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot).toLowerCase();
  }

  String _safeName(String raw) {
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  Future<void> _persist() async {
    final payload = _items.map((item) => item.toJson()).toList(growable: false);
    await _prefs.setString(_kPrefRecognitionHistory, jsonEncode(payload));
  }

  List<RecognitionHistoryItem> _loadItemsFromPrefs() {
    final raw = _prefs.getString(_kPrefRecognitionHistory);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }

      return decoded
          .whereType<Map>()
          .map((entry) => RecognitionHistoryItem.fromJson(Map<String, dynamic>.from(entry)))
          .toList(growable: false)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (_) {
      return const [];
    }
  }

  String? _asString(dynamic value) {
    if (value == null) {
      return null;
    }
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  double? _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim());
    }
    return null;
  }

  bool? _asBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') {
        return true;
      }
      if (normalized == 'false' || normalized == '0') {
        return false;
      }
    }
    return null;
  }
}

class RecognitionHistoryItem {
  RecognitionHistoryItem({
    required this.id,
    required this.jobId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.backendBaseUrl,
    required this.mushroomName,
    required this.prediction,
    required this.rawPrediction,
    required this.confidence,
    required this.isPoisonous,
    required this.decisionReason,
    required this.previewImagePath,
    required this.sourceMediaPath,
    required this.sourceMediaType,
    required this.result,
    required this.error,
  });

  final String id;
  final String jobId;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String backendBaseUrl;
  final String? mushroomName;
  final String? prediction;
  final String? rawPrediction;
  final double? confidence;
  final bool? isPoisonous;
  final String? decisionReason;
  final String? previewImagePath;
  final String? sourceMediaPath;
  final String? sourceMediaType;
  final Map<String, dynamic>? result;
  final String? error;

  factory RecognitionHistoryItem.fromJson(Map<String, dynamic> json) {
    final resultRaw = json['result'];
    return RecognitionHistoryItem(
      id: '${json['id'] ?? ''}',
      jobId: '${json['job_id'] ?? ''}',
      status: '${json['status'] ?? 'queued'}',
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}') ?? DateTime.now().toUtc(),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}') ?? DateTime.now().toUtc(),
      backendBaseUrl: '${json['backend_base_url'] ?? ''}',
      mushroomName: _asString(json['mushroom_name']),
      prediction: _asString(json['prediction']),
      rawPrediction: _asString(json['raw_prediction']),
      confidence: _asDouble(json['confidence']),
      isPoisonous: _asBool(json['is_poisonous']),
      decisionReason: _asString(json['decision_reason']),
      previewImagePath: _asString(json['preview_image_path']),
      sourceMediaPath: _asString(json['source_media_path']),
      sourceMediaType: _asString(json['source_media_type']),
      result: resultRaw is Map ? Map<String, dynamic>.from(resultRaw) : null,
      error: _asString(json['error']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'job_id': jobId,
      'status': status,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'backend_base_url': backendBaseUrl,
      'mushroom_name': mushroomName,
      'prediction': prediction,
      'raw_prediction': rawPrediction,
      'confidence': confidence,
      'is_poisonous': isPoisonous,
      'decision_reason': decisionReason,
      'preview_image_path': previewImagePath,
      'source_media_path': sourceMediaPath,
      'source_media_type': sourceMediaType,
      'result': result,
      'error': error,
    };
  }

  static String? _asString(dynamic value) {
    if (value == null) {
      return null;
    }
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  static double? _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim());
    }
    return null;
  }

  static bool? _asBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') {
        return true;
      }
      if (normalized == 'false' || normalized == '0') {
        return false;
      }
    }
    return null;
  }
}

class AppConfig {
  const AppConfig({required this.backendBaseUrl, required this.darkMode});

  final String backendBaseUrl;
  final bool darkMode;

  AppConfig copyWith({String? backendBaseUrl, bool? darkMode}) {
    return AppConfig(
      backendBaseUrl: backendBaseUrl ?? this.backendBaseUrl,
      darkMode: darkMode ?? this.darkMode,
    );
  }
}

class AppPreferencesService {
  Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final backend = prefs.getString(_kPrefBackendBaseUrl) ??
        kDefaultBackendBaseUrl;
    final darkMode = prefs.getBool(_kPrefDarkMode) ?? false;

    final normalized = BackendQueueService.normalizeBaseUrl(backend);
    return AppConfig(backendBaseUrl: normalized, darkMode: darkMode);
  }

  Future<void> saveBackendBaseUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefBackendBaseUrl, value);
  }

  Future<void> saveDarkMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefDarkMode, enabled);
  }

  Future<bool> isBackendConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    final configured = prefs.getBool(_kPrefBackendConfigured);
    if (configured != null) {
      return configured;
    }

    final backend = prefs.getString(_kPrefBackendBaseUrl)?.trim() ?? '';
    return backend.isNotEmpty;
  }

  Future<void> markBackendConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefBackendConfigured, true);
  }
}

class MushroomCatalogResponse {
  MushroomCatalogResponse({
    required this.source,
    required this.total,
    required this.poisonousCount,
    required this.safeCount,
    required this.mushrooms,
    required this.poisonousMushrooms,
  });

  final String source;
  final int total;
  final int poisonousCount;
  final int safeCount;
  final List<MushroomCatalogItem> mushrooms;
  final List<MushroomCatalogItem> poisonousMushrooms;

  factory MushroomCatalogResponse.fromJson(Map<String, dynamic> json) {
    final allList = _parseCatalogItems(json['mushrooms']);
    final poisonousList = _parseCatalogItems(json['poisonous_mushrooms']);

    return MushroomCatalogResponse(
      source: _asString(json['source']) ?? 'unknown',
      total: _asInt(json['total']) ?? allList.length,
      poisonousCount: _asInt(json['poisonous_count']) ?? poisonousList.length,
      safeCount: _asInt(json['safe_count']) ??
          max(0, (_asInt(json['total']) ?? allList.length) - poisonousList.length),
      mushrooms: allList,
      poisonousMushrooms: poisonousList,
    );
  }

  static List<MushroomCatalogItem> _parseCatalogItems(dynamic raw) {
    if (raw is! List) {
      return const [];
    }

    return raw
        .whereType<Map>()
        .map((entry) => MushroomCatalogItem.fromJson(Map<String, dynamic>.from(entry)))
        .toList(growable: false);
  }

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  static String? _asString(dynamic value) {
    if (value == null) {
      return null;
    }
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }
}

class MushroomCatalogItem {
  MushroomCatalogItem({
    required this.name,
    required this.scientificName,
    required this.isPoisonous,
  });

  final String name;
  final String scientificName;
  final bool isPoisonous;

  factory MushroomCatalogItem.fromJson(Map<String, dynamic> json) {
    return MushroomCatalogItem(
      name: _asString(json['name']) ?? 'Unknown',
      scientificName: _asString(json['scientific_name']) ?? 'Unknown',
      isPoisonous: _asBool(json['is_poisonous']) ?? false,
    );
  }

  static String? _asString(dynamic value) {
    if (value == null) {
      return null;
    }
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  static bool? _asBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') {
        return true;
      }
      if (normalized == 'false' || normalized == '0') {
        return false;
      }
    }
    return null;
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
      mediaType: 'image',
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
      mediaType: 'video',
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
       _backendBaseUrl = normalizeBaseUrl(initialBackendBaseUrl);

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

  void updateBackendBaseUrl(String baseUrl) {
    if (_disposed) {
      throw StateError('BackendQueueService đã dispose');
    }
    _backendBaseUrl = normalizeBaseUrl(baseUrl);
    _emit('backend.updated', {'base_url': _backendBaseUrl});
  }

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
      _backendBaseUrl = normalizeBaseUrl(baseUrl);
      _emit('backend.updated', {'base_url': _backendBaseUrl});
    }

    await _disconnectWebSocket();
    await _connectWebSocket();
    if (!_pollStarted) {
      _startPolling();
    }
  }

  Future<void> reconnectWithTimeout({
    String? baseUrl,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_disposed) {
      throw StateError('BackendQueueService đã dispose');
    }

    String? lastError;
    final connectedCompleter = Completer<void>();

    late final StreamSubscription<QueueEvent> subscription;
    subscription = events.listen((event) {
      if (event.event == 'ws.connected' && !connectedCompleter.isCompleted) {
        connectedCompleter.complete();
        return;
      }

      if (event.event == 'ws.error') {
        lastError =
            _stringFromMap(event.data, const ['message', 'error', 'detail']) ??
            'Không thể kết nối backend';
      }
    });

    try {
      await reconnect(baseUrl: baseUrl);

      if (_wsConnected && !connectedCompleter.isCompleted) {
        connectedCompleter.complete();
      }

      await connectedCompleter.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          lastError ??
              'Không thể kết nối backend trong ${timeout.inSeconds} giây',
        ),
      );
    } finally {
      await subscription.cancel();
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
  
  QueueJob? getJobById(String jobId) => _jobs[jobId];

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
      previewBytes: frame.bytes,
      originalMediaPath: frame.sourcePath,
      originalMediaType: frame.mediaType,
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
      previewBytes: existing?.previewBytes,
      originalMediaPath: existing?.originalMediaPath,
      originalMediaType: existing?.originalMediaType,
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

  static String normalizeBaseUrl(String input) {
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
    required this.previewBytes,
    required this.originalMediaPath,
    required this.originalMediaType,
    required this.imageInfo,
  });

  final String jobId;
  final JobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? result;
  final String? error;
  final Uint8List? previewBytes;
  final String? originalMediaPath;
  final String? originalMediaType;
  final Map<String, dynamic> imageInfo;

  QueueJob copyWith({
    JobStatus? status,
    DateTime? updatedAt,
    Map<String, dynamic>? result,
    String? error,
    Uint8List? previewBytes,
    String? originalMediaPath,
    String? originalMediaType,
  }) {
    return QueueJob(
      jobId: jobId,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      result: result ?? this.result,
      error: error ?? this.error,
      previewBytes: previewBytes ?? this.previewBytes,
      originalMediaPath: originalMediaPath ?? this.originalMediaPath,
      originalMediaType: originalMediaType ?? this.originalMediaType,
      imageInfo: imageInfo,
    );
  }
}

class PreparedFrame {
  PreparedFrame({
    required this.bytes,
    required this.sourcePath,
    required this.sourceLabel,
    required this.mediaType,
    required this.qualityScore,
    required this.selectedFrameMs,
  });

  final Uint8List bytes;
  final String sourcePath;
  final String sourceLabel;
  final String mediaType;
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