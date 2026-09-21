import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';

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
      title: 'IP Webcam',
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

  @override
  void initState() {
    super.initState();
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
<title>IP Webcam</title>
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
        } else if (request.uri.path == '/stream') {
          request.response
            ..headers.contentType = ContentType('multipart', 'x-mixed-replace', parameters: {'boundary': 'frame'})
            ..headers.add('Cache-Control', 'no-cache')
            ..headers.add('Connection', 'close')
            ..headers.add('Pragma', 'no-cache');
          
          _clients.add(request.response);
          
          request.response.done.then((_) {
            _clients.remove(request.response);
          });
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

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;

    final CameraController cameraController = CameraController(
      cameras[0],
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
    
    setState(() {
      _isStreaming = true;
    });

    while (_isStreaming) {
      if (_clients.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      if (_controller != null && _controller!.value.isInitialized) {
        try {
          final XFile file = await _controller!.takePicture();
          final Uint8List bytes = await file.readAsBytes();
          _broadcastFrame(bytes);
          File(file.path).delete().ignore();
          
          // Small delay to prevent locking up the main thread completely
          await Future.delayed(const Duration(milliseconds: 50));
        } catch (e) {
          debugPrint('Error capturing frame: $e');
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

  @override
  void dispose() {
    _isStreaming = false;
    _uiTimer?.cancel();
    _server?.close(force: true);
    for (var client in _clients) {
      client.close();
    }
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_isCameraInitialized)
            SizedBox.expand(
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
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          
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
