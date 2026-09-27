import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:camera/camera.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:gal/gal.dart';
import 'package:battery_plus/battery_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: CameraCctvPage(cameras: cameras),
  ));
}

class CameraCctvPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraCctvPage({super.key, required this.cameras});

  @override
  State<CameraCctvPage> createState() => _CameraCctvPageState();
}

class _CameraCctvPageState extends State<CameraCctvPage> {
  final GlobalKey _previewContainerKey = GlobalKey();
  final Battery _battery = Battery();
  CameraController? _controller;
  HttpServer? _server;
  String _localIp = 'Mencari IP...';
  bool _isStreamingActive = false;
  bool _isBlackScreen = false;
  bool _motionDetected = false;
  bool _isRecording = false;
  bool _isUiHidden = false;
  String _currentPin = '';
  StreamSubscription? _sensorSub;
  Timer? _streamTimer;
  Timer? _batteryTimer;
  bool _isProcessingFrame = false;

  // Status Baterai HP
  int _batteryLevel = 100;
  bool _isCharging = false;

  // Zoom Kamera Fisik
  double _currentZoomLevel = 1.0;
  double _minAvailableZoom = 1.0;
  double _maxAvailableZoom = 1.0;

  // --- FITUR EXPOSURE KAMERA ---
  double _currentExposureOffset = 0.0;
  double _minExposureOffset = -2.0;
  double _maxExposureOffset = 2.0;
  double _exposureStep = 0.5;

  // Kualitas Rekam & Stream
  ResolutionPreset _recordQuality = ResolutionPreset.high;
  int _streamIntervalMs = 120; // ~8 FPS

  final List<StreamController<Uint8List>> _clientStreams = [];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _detectLocalIp();
    _initBattery();
    _initCamera();
    _initMotionSensor();
  }

  Future<void> _initBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (mounted) {
        setState(() {
          _batteryLevel = level;
          _isCharging = (state == BatteryState.charging || state == BatteryState.full);
        });
      }
    } catch (_) {}

    _batteryTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      try {
        final level = await _battery.batteryLevel;
        final state = await _battery.batteryState;
        if (mounted) {
          setState(() {
            _batteryLevel = level;
            _isCharging = (state == BatteryState.charging || state == BatteryState.full);
          });
        }
      } catch (_) {}
    });
  }

  Future<void> _detectLocalIp() async {
    String foundIp = '127.0.0.1';
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback) {
            foundIp = addr.address;
            break;
          }
        }
        if (foundIp != '127.0.0.1') break;
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _localIp = foundIp);
    }
  }

  Future<void> _startServer() async {
    await _detectLocalIp();
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        8888,
        shared: true,
      );
      setState(() => _isStreamingActive = true);

      _server!.listen((HttpRequest request) async {
        request.response.headers.add('Access-Control-Allow-Origin', '*');

        // Endpoint 1: Status Realtime (Gerakan, Rekam, Baterai, Zoom, Exposure)
        if (request.uri.path == '/status') {
          request.response.headers.contentType = ContentType.json;
          final jsonStatus = jsonEncode({
            'motion': _motionDetected,
            'recording': _isRecording,
            'batteryLevel': _batteryLevel,
            'isCharging': _isCharging,
            'currentZoom': _currentZoomLevel,
            'minZoom': _minAvailableZoom,
            'maxZoom': _maxAvailableZoom,
            'currentExposure': _currentExposureOffset,
            'minExposure': _minExposureOffset,
            'maxExposure': _maxExposureOffset,
            'exposureStep': _exposureStep,
          });
          request.response.write(jsonStatus);
          request.response.close();
          return;
        }

        // Endpoint 2: Remote Rekam
        if (request.uri.path == '/record/toggle') {
          await _toggleRecord();
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'success': true,
            'recording': _isRecording,
          }));
          request.response.close();
          return;
        }

        // Endpoint 3: Remote Zoom
        if (request.uri.path == '/zoom') {
          final zoomParam = request.uri.queryParameters['level'];
          if (zoomParam != null) {
            final z = double.tryParse(zoomParam);
            if (z != null && z >= _minAvailableZoom && z <= _maxAvailableZoom) {
              await _setZoom(z);
            }
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'currentZoom': _currentZoomLevel}));
          request.response.close();
          return;
        }

        // Endpoint 4: Remote Exposure Offset
        if (request.uri.path == '/exposure') {
          final expParam = request.uri.queryParameters['offset'];
          if (expParam != null) {
            final e = double.tryParse(expParam);
            if (e != null && e >= _minExposureOffset && e <= _maxExposureOffset) {
              await _setExposure(e);
            }
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'currentExposure': _currentExposureOffset}));
          request.response.close();
          return;
        }

        // Endpoint 5: Stream Video MJPEG
        if (request.uri.path == '/stream') {
          request.response.headers.set(
            'Content-Type',
            'multipart/x-mixed-replace; boundary=--frame',
          );
          request.response.headers.set('Cache-Control', 'no-cache');
          request.response.headers.set('Connection', 'close');

          final controller = StreamController<Uint8List>();
          _clientStreams.add(controller);

          controller.stream.listen((jpegBytes) {
            try {
              request.response.write(
                '--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpegBytes.length}\r\n\r\n',
              );
              request.response.add(jpegBytes);
              request.response.write('\r\n');
            } catch (_) {}
          }, onDone: () {
            _clientStreams.remove(controller);
            request.response.close();
          });
        } else {
          // Endpoint 6: Web Dashboard Monitor Lengkap
          request.response.headers.contentType = ContentType.html;
          request.response.write('''
            <!DOCTYPE html>
            <html>
              <head>
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Monitor CCTV</title>
                <style>
                  body { 
                    background: #090d16; 
                    color: #f8fafc; 
                    font-family: system-ui, -apple-system, sans-serif; 
                    display: flex; 
                    flex-direction: column; 
                    align-items: center; 
                    justify-content: center; 
                    min-height: 100vh; 
                    margin: 0; 
                    overflow-x: hidden;
                  }
                  .container { 
                    display: flex; 
                    flex-direction: column; 
                    align-items: center; 
                    width: 96%; 
                    max-width: 1100px; 
                  }
                  
                  .video-box {
                    width: 100%;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 70vh;
                    overflow: hidden;
                    background: #000;
                    border-radius: 12px;
                    border: 2px solid #334155;
                    box-shadow: 0 10px 25px rgba(0,0,0,0.5);
                    position: relative;
                  }

                  #cctv-img { 
                    max-width: 100%; 
                    max-height: 100%; 
                    object-fit: contain; 
                    transform-origin: center center;
                    transition: transform 0.15s ease;
                  }

                  #alert-banner {
                    display: none;
                    width: 100%;
                    background: #dc2626;
                    color: white;
                    text-align: center;
                    padding: 12px;
                    border-radius: 8px;
                    font-size: 17px;
                    font-weight: bold;
                    letter-spacing: 1px;
                    margin-bottom: 10px;
                    box-shadow: 0 0 20px rgba(220, 38, 38, 0.8);
                    animation: blink 0.8s infinite alternate;
                  }

                  @keyframes blink {
                    from { opacity: 1; transform: scale(1); }
                    to { opacity: 0.6; transform: scale(0.99); }
                  }

                  .toolbar { 
                    display: flex; 
                    justify-content: space-between; 
                    align-items: center; 
                    width: 100%; 
                    margin-bottom: 10px; 
                    flex-wrap: wrap;
                    gap: 8px;
                    transition: all 0.3s;
                  }

                  .panel-controls {
                    display: flex;
                    align-items: center;
                    gap: 16px;
                    background: #1e293b;
                    padding: 8px 14px;
                    border-radius: 10px;
                    border: 1px solid #334155;
                    width: 100%;
                    margin-bottom: 10px;
                    box-sizing: border-box;
                    flex-wrap: wrap;
                  }

                  .slider-group {
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    font-size: 13px;
                    color: #cbd5e1;
                  }

                  .slider-group input[type=range] {
                    accent-color: #38bdf8;
                    cursor: pointer;
                  }

                  .status-row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
                  .badge { padding: 5px 12px; border-radius: 20px; font-size: 12px; font-weight: bold; }
                  .badge-live { background: #16a34a; }
                  .badge-rec { background: #dc2626; display: none; }
                  .badge-battery { background: #334155; border: 1px solid #475569; display: flex; align-items: center; gap: 5px; }

                  .control-row { display: flex; gap: 6px; align-items: center; }
                  
                  .btn {
                    padding: 6px 12px;
                    border-radius: 8px;
                    cursor: pointer;
                    font-weight: 600;
                    font-size: 13px;
                    display: flex;
                    align-items: center;
                    gap: 6px;
                    border: 1px solid #475569;
                    background: #1e293b;
                    color: #38bdf8;
                    transition: 0.2s;
                  }
                  .btn:hover { background: #334155; color: #fff; }

                  .btn-record { background: #991b1b; color: white; border: none; }
                  .btn-record:hover { background: #b91c1c; }
                  .btn-record.recording { background: #dc2626; box-shadow: 0 0 10px rgba(220, 38, 38, 0.6); }

                  #btn-toggle-ui {
                    position: fixed;
                    bottom: 16px;
                    right: 16px;
                    background: rgba(15, 23, 42, 0.85);
                    border: 1px solid #475569;
                    color: #f8fafc;
                    padding: 8px 14px;
                    border-radius: 20px;
                    cursor: pointer;
                    font-size: 12px;
                    font-weight: bold;
                    z-index: 100;
                    box-shadow: 0 4px 12px rgba(0,0,0,0.5);
                  }
                </style>
              </head>
              <body>
                <button id="btn-toggle-ui" onclick="toggleWebUi()">👁 Sembunyikan Tombol</button>

                <div class="container">
                  <div id="alert-banner">⚠️ PERINGATAN: HP BERGERAK / DIANGKAT!</div>
                  
                  <!-- HEADER CONTROLS -->
                  <div id="main-toolbar" class="toolbar">
                    <div class="status-row">
                      <span class="badge badge-live">● LIVE FEED</span>
                      <span id="badge-recording" class="badge badge-rec">● RECORDING</span>
                      <span id="badge-bat" class="badge badge-battery">🔋 Memuat...</span>
                      
                      <button id="btn-remote-rec" class="btn btn-record" onclick="toggleRemoteRecord()">
                        ⏺ Mulai Rekam
                      </button>
                    </div>

                    <div class="control-row">
                      <button class="btn" onclick="rotateLeft()">↺ Putar Kiri</button>
                      <button class="btn" onclick="rotateRight()">↻ Putar Kanan</button>
                      <button class="btn" onclick="resetTransforms()">Reset</button>
                    </div>
                  </div>

                  <!-- PANEL CONTROLS: ZOOM & EXPOSURE -->
                  <div id="panel-sliders" class="panel-controls">
                    <!-- Zoom Kamera Fisik -->
                    <div class="slider-group">
                      <span>📸 Zoom:</span>
                      <input id="hw-zoom-slider" type="range" min="1.0" max="5.0" step="0.1" value="1.0" oninput="changeHwZoom(this.value)" />
                      <span id="hw-zoom-val">1.0x</span>
                    </div>

                    <!-- Exposure Compensation -->
                    <div class="slider-group">
                      <span>☀️ Exposure:</span>
                      <input id="exp-slider" type="range" min="-2.0" max="2.0" step="0.1" value="0.0" oninput="changeExposure(this.value)" />
                      <span id="exp-val">0.0 EV</span>
                    </div>

                    <!-- Digital Viewport Zoom -->
                    <div class="slider-group">
                      <span>🔍 Ukuran Web:</span>
                      <input id="view-zoom-slider" type="range" min="1.0" max="3.0" step="0.05" value="1.0" oninput="changeViewZoom(this.value)" />
                      <span id="view-zoom-val">100%</span>
                    </div>
                  </div>

                  <!-- FRAME VIDEO FEED -->
                  <div class="video-box">
                    <img id="cctv-img" src="/stream" alt="Live Feed CCTV" />
                  </div>
                </div>

                <script>
                  let currentRotation = 0;
                  let viewZoomLevel = 1.0;
                  let isRecording = false;
                  let isUiVisible = true;
                  let isUserDraggingHwZoom = false;
                  let isUserDraggingExp = false;

                  function updateTransform() {
                    const img = document.getElementById('cctv-img');
                    img.style.transform = `rotate(\${currentRotation}deg) scale(\${viewZoomLevel})`;
                  }

                  function rotateRight() {
                    currentRotation = (currentRotation + 90) % 360;
                    updateTransform();
                  }

                  function rotateLeft() {
                    currentRotation = (currentRotation - 90 + 360) % 360;
                    updateTransform();
                  }

                  function changeViewZoom(val) {
                    viewZoomLevel = parseFloat(val);
                    document.getElementById('view-zoom-val').innerText = Math.round(viewZoomLevel * 100) + '%';
                    updateTransform();
                  }

                  async function changeHwZoom(val) {
                    document.getElementById('hw-zoom-val').innerText = parseFloat(val).toFixed(1) + 'x';
                    isUserDraggingHwZoom = true;
                    try {
                      await fetch(`/zoom?level=\${val}`);
                    } catch (e) {}
                    setTimeout(() => isUserDraggingHwZoom = false, 1500);
                  }

                  async function changeExposure(val) {
                    const num = parseFloat(val);
                    document.getElementById('exp-val').innerText = (num > 0 ? '+' : '') + num.toFixed(1) + ' EV';
                    isUserDraggingExp = true;
                    try {
                      await fetch(`/exposure?offset=\${val}`);
                    } catch (e) {}
                    setTimeout(() => isUserDraggingExp = false, 1500);
                  }

                  function resetTransforms() {
                    currentRotation = 0;
                    viewZoomLevel = 1.0;
                    document.getElementById('view-zoom-slider').value = 1.0;
                    document.getElementById('view-zoom-val').innerText = '100%';
                    updateTransform();
                  }

                  function toggleWebUi() {
                    isUiVisible = !isUiVisible;
                    document.getElementById('main-toolbar').style.display = isUiVisible ? 'flex' : 'none';
                    document.getElementById('panel-sliders').style.display = isUiVisible ? 'flex' : 'none';
                    document.getElementById('btn-toggle-ui').innerText = isUiVisible ? '👁 Sembunyikan Tombol' : '👁 Tampilkan Tombol';
                  }

                  async function toggleRemoteRecord() {
                    const btn = document.getElementById('btn-remote-rec');
                    btn.disabled = true;
                    try {
                      const res = await fetch('/record/toggle');
                      const data = await res.json();
                      updateRecordButtonState(data.recording);
                    } catch (e) {
                      alert('Gagal mengirim perintah ke HP!');
                    } finally {
                      btn.disabled = false;
                    }
                  }

                  function updateRecordButtonState(recording) {
                    isRecording = recording;
                    const btn = document.getElementById('btn-remote-rec');
                    const recBadge = document.getElementById('badge-recording');
                    if (isRecording) {
                      btn.innerHTML = '⏹ Stop & Simpan';
                      btn.classList.add('recording');
                      recBadge.style.display = 'inline-block';
                    } else {
                      btn.innerHTML = '⏺ Mulai Rekam';
                      btn.classList.remove('recording');
                      recBadge.style.display = 'none';
                    }
                  }

                  // Polling status dari HP
                  setInterval(async () => {
                    try {
                      const res = await fetch('/status');
                      const data = await res.json();
                      
                      document.getElementById('alert-banner').style.display = data.motion ? 'block' : 'none';

                      if (isRecording !== data.recording) {
                        updateRecordButtonState(data.recording);
                      }

                      const batBadge = document.getElementById('badge-bat');
                      const icon = data.isCharging ? '⚡' : '🔋';
                      batBadge.innerText = `\${icon} \${data.batteryLevel}%`;

                      if (!isUserDraggingHwZoom) {
                        const hwSlider = document.getElementById('hw-zoom-slider');
                        hwSlider.min = data.minZoom;
                        hwSlider.max = data.maxZoom;
                        hwSlider.value = data.currentZoom;
                        document.getElementById('hw-zoom-val').innerText = data.currentZoom.toFixed(1) + 'x';
                      }

                      if (!isUserDraggingExp) {
                        const expSlider = document.getElementById('exp-slider');
                        expSlider.min = data.minExposure;
                        expSlider.max = data.maxExposure;
                        expSlider.step = data.exposureStep;
                        expSlider.value = data.currentExposure;
                        const expVal = data.currentExposure;
                        document.getElementById('exp-val').innerText = (expVal > 0 ? '+' : '') + expVal.toFixed(1) + ' EV';
                      }
                    } catch (e) {}
                  }, 400);
                </script>
              </body>
            </html>
          ''');
          request.response.close();
        }
      });

      _startStreamingTimer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menjalankan server: $e')),
        );
      }
    }
  }

  Future<void> _stopServer() async {
    _streamTimer?.cancel();
    for (var client in _clientStreams) {
      client.close();
    }
    _clientStreams.clear();
    await _server?.close(force: true);
    _server = null;
    setState(() => _isStreamingActive = false);
  }

  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) return;

    _controller = CameraController(
      widget.cameras.first,
      _recordQuality,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await _controller!.initialize();

    // Inisialisasi Zoom Hardware
    try {
      _minAvailableZoom = await _controller!.getMinZoomLevel();
      _maxAvailableZoom = await _controller!.getMaxZoomLevel();
      if (_maxAvailableZoom > 5.0) _maxAvailableZoom = 5.0;
      _currentZoomLevel = _minAvailableZoom;
    } catch (_) {}

    // Inisialisasi Exposure Hardware
    try {
      _minExposureOffset = await _controller!.getMinExposureOffset();
      _maxExposureOffset = await _controller!.getMaxExposureOffset();
      _exposureStep = await _controller!.getExposureOffsetStepSize();
      if (_exposureStep <= 0.0) _exposureStep = 0.5;
      _currentExposureOffset = 0.0;
    } catch (_) {}

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _setZoom(double zoom) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() => _currentZoomLevel = zoom);
    await _controller!.setZoomLevel(zoom);
  }

  Future<void> _setExposure(double exposure) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() => _currentExposureOffset = exposure);
    await _controller!.setExposureOffset(exposure);
  }

  void _startStreamingTimer() {
    _streamTimer?.cancel();
    _streamTimer = Timer.periodic(Duration(milliseconds: _streamIntervalMs), (timer) async {
      if (!_isStreamingActive || _clientStreams.isEmpty) return;
      if (_controller == null || !_controller!.value.isInitialized) return;
      if (_isProcessingFrame) return;

      _isProcessingFrame = true;
      try {
        Uint8List? frameBytes;

        if (_isRecording) {
          final boundary = _previewContainerKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
          if (boundary != null) {
            final image = await boundary.toImage(pixelRatio: 0.5);
            final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
            frameBytes = byteData?.buffer.asUint8List();
          }
        } else {
          final file = await _controller!.takePicture();
          frameBytes = await file.readAsBytes();
        }

        if (frameBytes != null) {
          for (var client in _clientStreams) {
            client.add(frameBytes);
          }
        }
      } catch (_) {
      } finally {
        _isProcessingFrame = false;
      }
    });
  }

  Future<void> _changeRecordQuality(ResolutionPreset newQuality) async {
    if (_isRecording) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hentikan rekaman terlebih dahulu!')),
      );
      return;
    }

    setState(() => _recordQuality = newQuality);
    _streamTimer?.cancel();
    await _controller?.dispose();
    await _initCamera();
    if (_isStreamingActive) _startStreamingTimer();
  }

  void _changeStreamQuality(int intervalMs) {
    setState(() => _streamIntervalMs = intervalMs);
    if (_isStreamingActive) _startStreamingTimer();
  }

  void _initMotionSensor() {
    _sensorSub = userAccelerometerEventStream().listen((UserAccelerometerEvent event) {
      if (event.x.abs() > 1.5 || event.y.abs() > 1.5 || event.z.abs() > 1.5) {
        if (!_motionDetected) {
          setState(() => _motionDetected = true);
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted) setState(() => _motionDetected = false);
          });
        }
      }
    });
  }

  Future<void> _toggleRecord() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (_isRecording) {
      try {
        final file = await _controller!.stopVideoRecording();
        setState(() => _isRecording = false);
        await Gal.putVideo(file.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video tersimpan di Galeri!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Gagal menyimpan video: $e')),
          );
        }
      }
    } else {
      try {
        await _controller!.startVideoRecording();
        setState(() => _isRecording = true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Gagal memulai rekaman: $e')),
          );
        }
      }
    }
  }

  Future<void> _requestPinAndLock() async {
    final pinController = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Set PIN Keamanan'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Masukkan 4 digit PIN untuk mengunci layar:'),
            const SizedBox(height: 10),
            TextField(
              controller: pinController,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(counterText: ''),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Batal')),
          ElevatedButton(
            onPressed: () {
              if (pinController.text.length == 4) {
                Navigator.pop(ctx, pinController.text);
              }
            },
            child: const Text('Kunci Layar'),
          ),
        ],
      ),
    );

    if (pin != null && pin.length == 4) {
      setState(() {
        _currentPin = pin;
        _isBlackScreen = true;
      });
      await ScreenBrightness().setApplicationScreenBrightness(0.0);
    }
  }

  Future<void> _unlockBlackScreen() async {
    final pinController = TextEditingController();
    final enteredPin = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Masukkan PIN 4 Digit'),
        content: TextField(
          controller: pinController,
          keyboardType: TextInputType.number,
          maxLength: 4,
          autofocus: true,
          obscureText: true,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 8, color: Colors.white),
          decoration: const InputDecoration(counterText: ''),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Batal')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, pinController.text),
            child: const Text('Buka'),
          ),
        ],
      ),
    );

    if (enteredPin == _currentPin) {
      setState(() {
        _isBlackScreen = false;
        _currentPin = '';
      });
      await ScreenBrightness().resetApplicationScreenBrightness();
    } else if (enteredPin != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN Salah!'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _batteryTimer?.cancel();
    _streamTimer?.cancel();
    _sensorSub?.cancel();
    _server?.close(force: true);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isBlackScreen) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _unlockBlackScreen,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Opacity(
                opacity: 0.01,
                child: RepaintBoundary(
                  key: _previewContainerKey,
                  child: _controller != null && _controller!.value.isInitialized
                      ? CameraPreview(_controller!)
                      : const SizedBox(),
                ),
              ),
              const Center(
                child: Text(
                  'Mode Kunci Aktif\nKetuk 2x untuk memasukkan PIN',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white12, fontSize: 13),
                ),
              ),
              if (_isRecording)
                Positioned(
                  top: 36,
                  right: 20,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: _isUiHidden
          ? null
          : AppBar(
              title: const Text('CCTV Camera Server'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isCharging ? Icons.battery_charging_full : Icons.battery_std,
                            size: 16,
                            color: _batteryLevel < 20 ? Colors.redAccent : Colors.greenAccent,
                          ),
                          const SizedBox(width: 4),
                          Text('$_batteryLevel%', style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_isRecording)
                  Container(
                    margin: const EdgeInsets.only(right: 16),
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
      body: Stack(
        children: [
          Column(
            children: [
              // PANEL URL & SERVER TOGGLE
              if (!_isUiHidden)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  color: Colors.blueGrey.shade900,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isStreamingActive ? 'Stream URL (Browser):' : 'Status: NONAKTIF',
                              style: TextStyle(
                                color: _isStreamingActive ? Colors.greenAccent : Colors.grey,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SelectableText(
                              _isStreamingActive ? 'http://$_localIp:8888' : 'Tekan Start Stream',
                              style: TextStyle(
                                color: _isStreamingActive ? Colors.amberAccent : Colors.white60,
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _isStreamingActive ? _stopServer : _startServer,
                        icon: Icon(_isStreamingActive ? Icons.stop : Icons.play_arrow, size: 16),
                        label: Text(_isStreamingActive ? 'Stop' : 'Start'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isStreamingActive ? Colors.redAccent : Colors.teal,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_motionDetected)
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.redAccent,
                  width: double.infinity,
                  child: const Text(
                    'PERINGATAN: HP BERGERAK / DIGESER!',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),

              // PREVIEW KAMERA + DUAL SLIDER (ZOOM & EXPOSURE)
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      key: _previewContainerKey,
                      child: _controller != null && _controller!.value.isInitialized
                          ? CameraPreview(_controller!)
                          : const Center(child: CircularProgressIndicator()),
                    ),

                    // KONTROL SLIDER ZOOM & EXPOSURE DI HP
                    if (!_isUiHidden)
                      Positioned(
                        bottom: 12,
                        left: 16,
                        right: 16,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 1. Exposure Slider
                            if (_maxExposureOffset > _minExposureOffset)
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.wb_sunny, size: 18, color: Colors.amberAccent),
                                    Expanded(
                                      child: Slider(
                                        value: _currentExposureOffset.clamp(_minExposureOffset, _maxExposureOffset),
                                        min: _minExposureOffset,
                                        max: _maxExposureOffset,
                                        activeColor: Colors.amberAccent,
                                        inactiveColor: Colors.white24,
                                        onChanged: (val) => _setExposure(val),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 48,
                                      child: Text(
                                        '${_currentExposureOffset > 0 ? '+' : ''}${_currentExposureOffset.toStringAsFixed(1)}',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                        textAlign: TextAlign.right,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                            // 2. Zoom Slider
                            if (_maxAvailableZoom > _minAvailableZoom)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.zoom_in, size: 18, color: Colors.lightBlueAccent),
                                    Expanded(
                                      child: Slider(
                                        value: _currentZoomLevel.clamp(_minAvailableZoom, _maxAvailableZoom),
                                        min: _minAvailableZoom,
                                        max: _maxAvailableZoom,
                                        activeColor: Colors.lightBlueAccent,
                                        inactiveColor: Colors.white24,
                                        onChanged: (val) => _setZoom(val),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 48,
                                      child: Text(
                                        '${_currentZoomLevel.toStringAsFixed(1)}x',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                        textAlign: TextAlign.right,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

              // PANEL PENGATURAN KUALITAS
              if (!_isUiHidden)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  color: Colors.black45,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Kualitas Rekam:', style: TextStyle(fontSize: 11, color: Colors.grey)),
                            DropdownButton<ResolutionPreset>(
                              isExpanded: true,
                              value: _recordQuality,
                              dropdownColor: Colors.grey.shade900,
                              underline: const SizedBox(),
                              items: const [
                                DropdownMenuItem(value: ResolutionPreset.medium, child: Text('480p (Hemat)')),
                                DropdownMenuItem(value: ResolutionPreset.high, child: Text('720p HD')),
                                DropdownMenuItem(value: ResolutionPreset.veryHigh, child: Text('1080p FHD')),
                              ],
                              onChanged: (val) {
                                if (val != null) _changeRecordQuality(val);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Kualitas Stream:', style: TextStyle(fontSize: 11, color: Colors.grey)),
                            DropdownButton<int>(
                              isExpanded: true,
                              value: _streamIntervalMs,
                              dropdownColor: Colors.grey.shade900,
                              underline: const SizedBox(),
                              items: const [
                                DropdownMenuItem(value: 200, child: Text('Rendah (~5 FPS)')),
                                DropdownMenuItem(value: 120, child: Text('Sedang (~8 FPS)')),
                                DropdownMenuItem(value: 65, child: Text('Tinggi (~15 FPS)')),
                              ],
                              onChanged: (val) {
                                if (val != null) _changeStreamQuality(val);
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              // ACTION BUTTONS
              if (!_isUiHidden)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _toggleRecord,
                          icon: Icon(_isRecording ? Icons.stop : Icons.fiber_manual_record),
                          label: Text(_isRecording ? 'Stop Rekam' : 'Rekam Video'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isRecording ? Colors.red.shade800 : Colors.blueGrey.shade800,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _requestPinAndLock,
                          icon: const Icon(Icons.lock_outline),
                          label: const Text('Gelapkan Layar'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey.shade900,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),

          // FLOATING TOGGLE HIDE / SHOW UI DI HP
          Positioned(
            top: _isUiHidden ? 40 : 10,
            right: 12,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(24),
              child: IconButton(
                icon: Icon(
                  _isUiHidden ? Icons.visibility_off : Icons.visibility,
                  color: Colors.white70,
                  size: 20,
                ),
                tooltip: _isUiHidden ? 'Tampilkan Tombol' : 'Sembunyikan Tombol',
                onPressed: () => setState(() => _isUiHidden = !_isUiHidden),
              ),
            ),
          ),
        ],
      ),
    );
  }
}