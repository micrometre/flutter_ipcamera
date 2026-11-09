import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('CameraError: ${e.description}');
  }
  runApp(const CameraApp());
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IP Camera',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const CameraScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  bool _isCameraInitialized = false;
  
  HttpServer? _server;
  final List<HttpResponse> _clients = [];
  String _serverIp = 'Starting server...';
  String _publicIp = 'Fetching public IP...';
  bool _isStreaming = false;
  Timer? _uiTimer;

  // Latest captured JPEG frame, shared between /stream and /snapshot.
  Uint8List? _latestFrame;
  DateTime? _latestFrameTime;
  Future<Uint8List?>? _inFlightCapture;

  // Clean "stream mode": full-screen preview with no overlays/buttons.
  bool _cleanMode = false;

  // Push mode: POST each frame (multipart/form-data) to a backend / ANPR URL.
  final HttpClient _pushClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  bool _pushEnabled = false;
  String _pushUrl = '';
  String _pushField = 'file';
  int _pushIntervalMs = 500;
  bool _pushInFlight = false;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  int _pushOk = 0;
  int _pushFailed = 0;
  String? _pushLastError;

  @override
  void initState() {
    super.initState();
    // Keep the phone awake while acting as a camera.
    WakelockPlus.enable().catchError((_) {});
    _initializeCamera();
    _startServer();
    
    // Update UI periodically to show client count
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<String?> _getPublicIp() async {
    try {
      final request = await HttpClient().getUrl(Uri.parse('https://api.ipify.org'));
      final response = await request.close();
      final publicIp = await response.transform(utf8.decoder).join();
      return publicIp;
    } catch (e) {
      debugPrint('Error getting public IP: $e');
      return null;
    }
  }

  Future<void> _startServer() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      String ip = 'localhost';
      
      // Prioritize Wi-Fi interfaces: 'wlan' for Android, 'en0' for iOS
      for (var interface in interfaces) {
        if (interface.name.toLowerCase().contains('wlan') || 
            interface.name.toLowerCase().contains('en0')) {
          ip = interface.addresses.first.address;
          break;
        }
      }
      
      // Fallback if Wi-Fi interface isn't explicitly found
      if (ip == 'localhost' && interfaces.isNotEmpty) {
        ip = interfaces.first.addresses.first.address;
      }
      
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      if (mounted) {
        setState(() {
          _serverIp = 'http://$ip:8080 (Local)';
        });
      }

      _getPublicIp().then((publicIp) {
        if (mounted) {
          setState(() {
            _publicIp = publicIp != null 
              ? 'http://$publicIp:8080 (Public)' 
              : 'Public IP unavailable';
          });
        }
      });

      _server!.listen((HttpRequest request) {
        if (request.uri.path == '/') {
          final html = '''
<!DOCTYPE html>
<html>
<head>
<title>IP Camera</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { margin: 0; background: #111; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; color: white; font-family: sans-serif; }
  #stream { max-width: 100%; max-height: 80vh; border: 2px solid #333; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 4px 12px rgba(0,0,0,0.5); }
  button { padding: 14px 28px; font-size: 18px; background: #2196F3; color: white; border: none; border-radius: 8px; cursor: pointer; font-weight: bold; box-shadow: 0 4px 6px rgba(0,0,0,0.3); transition: background 0.2s; }
  button:hover { background: #1976D2; }
</style>
</head>
<body>
  <img id="stream" src="/stream" crossorigin="anonymous" />
  <button onclick="takeSnapshot()">📸 Take Snapshot</button>

  <script>
    function takeSnapshot() {
      const img = document.getElementById('stream');
      const canvas = document.createElement('canvas');
      canvas.width = img.naturalWidth || img.width;
      canvas.height = img.naturalHeight || img.height;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      
      const link = document.createElement('a');
      link.download = 'snapshot-' + new Date().getTime() + '.jpg';
      link.href = canvas.toDataURL('image/jpeg', 1.0);
      link.click();
    }
  </script>
</body>
</html>
''';
          request.response
            ..headers.contentType = ContentType.html
            ..write(html)
            ..close();
        } else if (request.uri.path == '/snapshot' ||
            request.uri.path == '/shot.jpg' ||
            request.uri.path == '/frame.jpg') {
          // Raw single JPEG frame - ideal for ANPR / backends that poll images.
          _handleSnapshot(request);
        } else if (request.uri.path == '/stream' ||
            request.uri.path == '/video' ||
            request.uri.path == '/mjpeg') {
          // Raw MJPEG stream (no HTML/UI). Usable directly by OpenCV, ffmpeg,
          // VLC, Frigate, ANPR engines, etc.
          // Auto-start capturing so no button press is needed in the app.
          if (!_isStreaming) _streamLoop();
          request.response
            ..headers.contentType = ContentType('multipart', 'x-mixed-replace', parameters: {'boundary': 'frame'})
            ..headers.add('Cache-Control', 'no-cache')
            ..headers.add('Connection', 'close')
            ..headers.add('Pragma', 'no-cache');
          
          _clients.add(request.response);
          
          request.response.done.then((_) {
            _clients.remove(request.response);
          }, onError: (_) {
            _clients.remove(request.response);
          });
        } else if (request.uri.path == '/status') {
          // Machine-readable health/status for backends.
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'camera_ready': _isCameraInitialized,
              'streaming': _isStreaming,
              'clients': _clients.length,
              'last_frame_at': _latestFrameTime?.toIso8601String(),
              'push': {
                'enabled': _pushEnabled,
                'url': _pushUrl,
                'ok': _pushOk,
                'failed': _pushFailed,
                'last_error': _pushLastError,
              },
            }))
            ..close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.close();
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _serverIp = 'Error: $e';
        });
      }
    }
  }

  /// Captures a single JPEG frame. Concurrent callers share the same
  /// in-flight capture, since the camera can't take two pictures at once.
  Future<Uint8List?> _captureFrame() {
    final inFlight = _inFlightCapture;
    if (inFlight != null) return inFlight;

    final future = () async {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return null;
      try {
        final XFile file = await controller.takePicture();
        final Uint8List bytes = await file.readAsBytes();
        File(file.path).delete().ignore();
        _latestFrame = bytes;
        _latestFrameTime = DateTime.now();
        return bytes;
      } catch (e) {
        debugPrint('Error capturing frame: $e');
        return null;
      }
    }();

    _inFlightCapture = future;
    future.whenComplete(() => _inFlightCapture = null);
    return future;
  }

  Future<void> _handleSnapshot(HttpRequest request) async {
    final response = request.response;
    try {
      Uint8List? bytes;
      // Reuse the latest streamed frame if it's fresh, otherwise capture one.
      final latest = _latestFrame;
      final latestTime = _latestFrameTime;
      if (latest != null &&
          latestTime != null &&
          DateTime.now().difference(latestTime) <
              const Duration(milliseconds: 500)) {
        bytes = latest;
      } else {
        bytes = await _captureFrame();
      }

      if (bytes == null) {
        response
          ..statusCode = HttpStatus.serviceUnavailable
          ..write('Camera not ready');
      } else {
        response
          ..headers.contentType = ContentType('image', 'jpeg')
          ..headers.contentLength = bytes.length
          ..headers.add('Cache-Control', 'no-cache, no-store, must-revalidate')
          ..headers.add('Pragma', 'no-cache')
          ..add(bytes);
      }
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close();
    }
  }

  void _broadcastFrame(Uint8List bytes) {
    if (_clients.isEmpty) return;
    
    final boundary = '\r\n--frame\r\n';
    final header = 'Content-Type: image/jpeg\r\nContent-Length: ${bytes.length}\r\n\r\n';
    
    final List<HttpResponse> deadClients = [];
    
    for (var client in _clients) {
      try {
        client.add(Uint8List.fromList(boundary.codeUnits));
        client.add(Uint8List.fromList(header.codeUnits));
        client.add(bytes);
      } catch (e) {
        deadClients.add(client);
      }
    }
    
    for (var client in deadClients) {
      _clients.remove(client);
    }
  }

  /// POSTs a frame to the configured backend as multipart/form-data.
  /// Frames are dropped (not queued) while a previous upload is in flight,
  /// so a slow backend never causes a growing backlog.
  void _maybePushFrame(Uint8List bytes) {
    if (!_pushEnabled || _pushUrl.isEmpty || _pushInFlight) return;
    final now = DateTime.now();
    if (now.difference(_lastPush).inMilliseconds < _pushIntervalMs) return;
    _lastPush = now;
    _pushInFlight = true;

    () async {
      try {
        final uri = Uri.parse(_pushUrl);
        final boundary = '----ipcamera${now.microsecondsSinceEpoch}';
        final head = utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="$_pushField"; '
          'filename="frame_${now.millisecondsSinceEpoch}.jpg"\r\n'
          'Content-Type: image/jpeg\r\n\r\n',
        );
        final tail = utf8.encode(
          '\r\n--$boundary\r\n'
          'Content-Disposition: form-data; name="timestamp"\r\n\r\n'
          '${now.toUtc().toIso8601String()}\r\n'
          '--$boundary--\r\n',
        );

        final request = await _pushClient.postUrl(uri);
        request.headers.contentType = ContentType(
          'multipart',
          'form-data',
          parameters: {'boundary': boundary},
        );
        request.contentLength = head.length + bytes.length + tail.length;
        request.add(head);
        request.add(bytes);
        request.add(tail);
        final response =
            await request.close().timeout(const Duration(seconds: 10));
        await response.drain<void>();
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _pushOk++;
          _pushLastError = null;
        } else {
          _pushFailed++;
          _pushLastError = 'HTTP ${response.statusCode}';
        }
      } catch (e) {
        _pushFailed++;
        _pushLastError = e.toString();
      } finally {
        _pushInFlight = false;
      }
    }();
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;

    final selectedCamera = cameras.firstWhere(
      (c) =>
          c.lensDirection == CameraLensDirection.back ||
          c.lensDirection == CameraLensDirection.external,
      orElse: () => cameras.first,
    );

    final CameraController cameraController = CameraController(
      selectedCamera,
      ResolutionPreset.medium, // Medium resolution for faster streaming
      enableAudio: false,
    );

    _controller = cameraController;

    try {
      await cameraController.initialize();
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } on CameraException catch (e) {
      debugPrint('Camera error: ${e.description}');
    }
  }

  Future<void> _streamLoop() async {
    if (_isStreaming) return;
    
    _isStreaming = true;
    if (mounted) setState(() {});

    while (_isStreaming) {
      final bool pushActive = _pushEnabled && _pushUrl.isNotEmpty;
      if (_clients.isEmpty && !pushActive) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      if (_controller != null && _controller!.value.isInitialized) {
        final Uint8List? bytes = await _captureFrame();
        if (bytes != null) {
          _broadcastFrame(bytes);
          _maybePushFrame(bytes);
          // Small delay to prevent locking up the main thread completely
          await Future.delayed(const Duration(milliseconds: 50));
        } else {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } else {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  void _toggleStream() {
    if (_isStreaming) {
      setState(() {
        _isStreaming = false;
      });
    } else {
      _streamLoop();
    }
  }

  void _enterCleanMode() {
    // Clean mode always streams - no button needed.
    if (!_isStreaming) _streamLoop();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setState(() => _cleanMode = true);
  }

  void _exitCleanMode() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    setState(() => _cleanMode = false);
  }

  Future<void> _openPushSettings() async {
    final urlCtrl = TextEditingController(text: _pushUrl);
    final fieldCtrl = TextEditingController(text: _pushField);
    final intervalCtrl = TextEditingController(text: '$_pushIntervalMs');
    bool enabled = _pushEnabled;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Push frames to backend'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable push'),
                  value: enabled,
                  onChanged: (v) => setDialogState(() => enabled = v),
                ),
                TextField(
                  controller: urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Backend URL (POST)',
                    hintText: 'http://192.168.1.10:8000/upload',
                  ),
                ),
                TextField(
                  controller: fieldCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Multipart file field name',
                  ),
                ),
                TextField(
                  controller: intervalCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Min interval between frames (ms)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      setState(() {
        _pushUrl = urlCtrl.text.trim();
        _pushField =
            fieldCtrl.text.trim().isEmpty ? 'file' : fieldCtrl.text.trim();
        _pushIntervalMs = int.tryParse(intervalCtrl.text.trim()) ?? 500;
        _pushEnabled = enabled && _pushUrl.isNotEmpty;
        _pushOk = 0;
        _pushFailed = 0;
        _pushLastError = null;
      });
      if (_pushEnabled && !_isStreaming) _streamLoop();
    }
  }

  @override
  void dispose() {
    _isStreaming = false;
    _uiTimer?.cancel();
    _server?.close(force: true);
    for (var client in _clients) {
      client.close();
    }
    _pushClient.close(force: true);
    _controller?.dispose();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  Widget _buildPreview() {
    if (!_isCameraInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: MediaQuery.of(context).orientation == Orientation.portrait
              ? 100
              : 100 * _controller!.value.aspectRatio,
          height: MediaQuery.of(context).orientation == Orientation.portrait
              ? 100 * _controller!.value.aspectRatio
              : 100,
          child: CameraPreview(_controller!),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Clean stream mode: preview only, no IP overlay, no buttons.
    // Long-press anywhere to return to the normal screen.
    if (_cleanMode) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exitCleanMode();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: _exitCleanMode,
            child: _buildPreview(),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildPreview(),
          
          // IP Address Overlay
          Positioned(
            top: MediaQuery.of(context).padding.top + 40,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Access stream at:',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _serverIp,
                      style: const TextStyle(
                        color: Colors.white, 
                        fontSize: 16, 
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _publicIp,
                      style: const TextStyle(
                        color: Colors.cyanAccent, 
                        fontSize: 16, 
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                    if (_pushEnabled) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Push: ✓$_pushOk  ✗$_pushFailed'
                        '${_pushLastError != null ? '  ($_pushLastError)' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          
          // Client count overlay
          Positioned(
            top: MediaQuery.of(context).padding.top + 40,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _clients.isNotEmpty ? Colors.green.withOpacity(0.8) : Colors.black.withOpacity(0.7),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                '${_clients.length}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ),

          // Mode buttons: clean stream mode + backend push settings
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Push to backend / ANPR',
                  onPressed: _openPushSettings,
                  icon: Icon(
                    Icons.cloud_upload,
                    color: _pushEnabled ? Colors.greenAccent : null,
                  ),
                ),
                const SizedBox(height: 8),
                IconButton.filledTonal(
                  tooltip: 'Clean stream mode (long-press to exit)',
                  onPressed: _enterCleanMode,
                  icon: const Icon(Icons.fullscreen),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleStream,
        backgroundColor: _isStreaming ? Colors.redAccent : Colors.white,
        icon: Icon(
          _isStreaming ? Icons.stop : Icons.sensors,
          color: _isStreaming ? Colors.white : Colors.black,
        ),
        label: Text(
          _isStreaming ? 'Stop Streaming' : 'Start Streaming',
          style: TextStyle(
            color: _isStreaming ? Colors.white : Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
