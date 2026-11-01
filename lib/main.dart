import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:torch_light/torch_light.dart';

// ============================================================================
// 1. ENTRY POINT & APPLICATION SETUP
// ============================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Lock to portrait mode for emergency stability
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const GuardianApp());
}

class GuardianApp extends StatelessWidget {
  const GuardianApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Guardian AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
        primaryColor: const Color(0xFFEF4444),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFEF4444),
          secondary: Color(0xFF06B6D4),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const SosScreen(),
    );
  }
}

// ============================================================================
// 2. HARDWARE STATE & EVIDENCE MODELS
// ============================================================================
class EmergencyHardwareState {
  final bool isEmergencyActive;
  final bool isSirenPlaying;
  final bool isStrobeFlashing;
  final bool isEvidenceCapturing;
  final int capturedPhotosCount;
  final String? lastCapturedFilePath;
  final String? lastSha256Hash;
  final List<EvidenceItem> evidenceHistory;

  const EmergencyHardwareState({
    required this.isEmergencyActive,
    required this.isSirenPlaying,
    required this.isStrobeFlashing,
    required this.isEvidenceCapturing,
    required this.capturedPhotosCount,
    this.lastCapturedFilePath,
    this.lastSha256Hash,
    this.evidenceHistory = const [],
  });

  EmergencyHardwareState copyWith({
    bool? isEmergencyActive,
    bool? isSirenPlaying,
    bool? isStrobeFlashing,
    bool? isEvidenceCapturing,
    int? capturedPhotosCount,
    String? lastCapturedFilePath,
    String? lastSha256Hash,
    List<EvidenceItem>? evidenceHistory,
  }) {
    return EmergencyHardwareState(
      isEmergencyActive: isEmergencyActive ?? this.isEmergencyActive,
      isSirenPlaying: isSirenPlaying ?? this.isSirenPlaying,
      isStrobeFlashing: isStrobeFlashing ?? this.isStrobeFlashing,
      isEvidenceCapturing: isEvidenceCapturing ?? this.isEvidenceCapturing,
      capturedPhotosCount: capturedPhotosCount ?? this.capturedPhotosCount,
      lastCapturedFilePath: lastCapturedFilePath ?? this.lastCapturedFilePath,
      lastSha256Hash: lastSha256Hash ?? this.lastSha256Hash,
      evidenceHistory: evidenceHistory ?? this.evidenceHistory,
    );
  }

  factory EmergencyHardwareState.initial() => const EmergencyHardwareState(
        isEmergencyActive: false,
        isSirenPlaying: false,
        isStrobeFlashing: false,
        isEvidenceCapturing: false,
        capturedPhotosCount: 0,
        evidenceHistory: [],
      );
}

class EvidenceItem {
  final String filePath;
  final String sha256;
  final DateTime timestamp;
  final int fileSizeBytes;

  EvidenceItem({
    required this.filePath,
    required this.sha256,
    required this.timestamp,
    required this.fileSizeBytes,
  });
}

// ============================================================================
// 3. HARDWARE SERVICE (CONCURRENCY COORDINATOR)
// ============================================================================
class HardwareService {
  static final HardwareService _instance = HardwareService._internal();
  factory HardwareService() => _instance;
  HardwareService._internal();

  AudioPlayer? _audioPlayer;
  CameraController? _cameraController;
  Timer? _strobeTimer;
  Timer? _cameraIntervalTimer;
  bool _isTorchOn = false;
  bool _isCapturingSingleFrame = false;

  final _stateController = StreamController<EmergencyHardwareState>.broadcast();
  Stream<EmergencyHardwareState> get stateStream => _stateController.stream;

  EmergencyHardwareState _currentState = EmergencyHardwareState.initial();
  EmergencyHardwareState get currentState => _currentState;

  void _updateState(EmergencyHardwareState newState) {
    _currentState = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Pre-warm hardware and route to Android STREAM_ALARM (bypasses silent switch)
  Future<void> initialize() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.sonification,
          flags: AndroidAudioFlags.audibilityEnforced,
          usage: AndroidAudioUsage.alarm, // High priority STREAM_ALARM
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ));

      _audioPlayer = AudioPlayer();
      await _audioPlayer?.setAsset('assets/audio/emergency_siren.mp3');
      await _audioPlayer?.setLoopMode(LoopMode.one);
      await _audioPlayer?.setVolume(1.0);

      await _initCamera();
    } catch (e) {
      debugPrint('[HardwareService] Init warning: $e');
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      final backCamera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize();
      if (_cameraController!.value.isInitialized) {
        await _cameraController!.setFlashMode(FlashMode.off);
      }
    } catch (e) {
      debugPrint('[HardwareService] Camera init error: $e');
    }
  }

  /// Concurrently executes Siren, LED Strobe, and Camera Evidence without UI freezing
  Future<void> triggerEmergencySequence() async {
    if (_currentState.isEmergencyActive) return;

    _updateState(_currentState.copyWith(isEmergencyActive: true));
    HapticFeedback.vibrate();

    // Fire all three hardware components concurrently on the Event Loop
    await Future.wait([
      _startAlarmSiren(),
      _startFlashlightStrobe(),
      _startSilentEvidenceCapture(),
    ]);
  }

  Future<void> _startAlarmSiren() async {
    try {
      if (_audioPlayer == null) {
        _audioPlayer = AudioPlayer();
        await _audioPlayer!.setAsset('assets/audio/emergency_siren.mp3');
        await _audioPlayer!.setLoopMode(LoopMode.one);
      }
      await _audioPlayer!.setVolume(1.0);
      await _audioPlayer!.seek(Duration.zero);
      unawaited(_audioPlayer!.play());
      _updateState(_currentState.copyWith(isSirenPlaying: true));
    } catch (e) {
      debugPrint('[HardwareService] Siren error: $e');
    }
  }

  Future<void> _startFlashlightStrobe({int intervalMs = 150}) async {
    try {
      _strobeTimer?.cancel();
      _isTorchOn = false;

      _strobeTimer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) async {
        if (!_currentState.isEmergencyActive) {
          timer.cancel();
          return;
        }
        try {
          if (_isTorchOn) {
            await TorchLight.disableTorch();
            _isTorchOn = false;
          } else {
            await TorchLight.enableTorch();
            _isTorchOn = true;
          }
        } catch (_) {}
      });

      _updateState(_currentState.copyWith(isStrobeFlashing: true));
    } catch (e) {
      debugPrint('[HardwareService] Strobe error: $e');
    }
  }

  Future<void> _startSilentEvidenceCapture({Duration interval = const Duration(seconds: 4)}) async {
    try {
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        await _initCamera();
      }

      _updateState(_currentState.copyWith(isEvidenceCapturing: true));

      // Immediate zero-second proof frame
      await _captureEvidenceFrame();

      _cameraIntervalTimer?.cancel();
      _cameraIntervalTimer = Timer.periodic(interval, (timer) async {
        if (!_currentState.isEmergencyActive) {
          timer.cancel();
          return;
        }
        await _captureEvidenceFrame();
      });
    } catch (e) {
      debugPrint('[HardwareService] Evidence timer error: $e');
    }
  }

  Future<void> _captureEvidenceFrame() async {
    if (_isCapturingSingleFrame || _cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    _isCapturingSingleFrame = true;
    try {
      final XFile photo = await _cameraController!.takePicture();
      final Uint8List imageBytes = await photo.readAsBytes();

      // Cryptographic SHA-256 Checksum for Court FIR Legal Chain of Custody
      final sha256Digest = sha256.convert(imageBytes).toString();

      final appDir = await getApplicationDocumentsDirectory();
      final evidenceDir = Directory('${appDir.path}/guardian_evidence');
      if (!await evidenceDir.exists()) {
        await evidenceDir.create(recursive: true);
      }

      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final secureFilePath = '${evidenceDir.path}/FIR_PROOF_${timestamp}_${_currentState.capturedPhotosCount + 1}.jpg';

      final savedFile = await File(photo.path).copy(secureFilePath);

      final newItem = EvidenceItem(
        filePath: savedFile.path,
        sha256: sha256Digest,
        timestamp: DateTime.now(),
        fileSizeBytes: imageBytes.length,
      );

      final updatedHistory = List<EvidenceItem>.from(_currentState.evidenceHistory)..insert(0, newItem);

      _updateState(_currentState.copyWith(
        capturedPhotosCount: _currentState.capturedPhotosCount + 1,
        lastCapturedFilePath: savedFile.path,
        lastSha256Hash: sha256Digest,
        evidenceHistory: updatedHistory,
      ));
    } catch (e) {
      debugPrint('[HardwareService] Photo snap error: $e');
    } finally {
      _isCapturingSingleFrame = false;
    }
  }

  /// SECURE STOP: Cleanly silences alarm, halts strobe, and cancels background tasks
  Future<void> stopEmergencySequence({bool keepSilentRecording = false}) async {
    _strobeTimer?.cancel();
    _strobeTimer = null;

    if (!keepSilentRecording) {
      _cameraIntervalTimer?.cancel();
      _cameraIntervalTimer = null;
    }

    try {
      await TorchLight.disableTorch();
      _isTorchOn = false;
    } catch (_) {}

    if (_audioPlayer != null && _audioPlayer!.playing) {
      await _audioPlayer!.stop();
    }

    _updateState(_currentState.copyWith(
      isEmergencyActive: keepSilentRecording,
      isSirenPlaying: false,
      isStrobeFlashing: false,
      isEvidenceCapturing: keepSilentRecording,
    ));

    HapticFeedback.mediumImpact();
  }

  void dispose() {
    _strobeTimer?.cancel();
    _cameraIntervalTimer?.cancel();
    _audioPlayer?.dispose();
    _cameraController?.dispose();
    _stateController.close();
  }
}

// ============================================================================
// 4. UI SCREEN: SOS TRIGGER & SECURE STOP INTERFACE
// ============================================================================
class SosScreen extends StatefulWidget {
  const SosScreen({Key? key}) : super(key: key);

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> with TickerProviderStateMixin {
  final HardwareService _hardwareService = HardwareService();
  StreamSubscription<EmergencyHardwareState>? _hardwareSubscription;
  EmergencyHardwareState _state = EmergencyHardwareState.initial();

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // 3-Second Hold-to-Stop Controller
  late AnimationController _stopHoldController;
  bool _isHoldingStop = false;
  static const Duration _requiredHoldDuration = Duration(milliseconds: 3000);

  final String _masterPin = "1234";
  final String _duressPin = "9999";

  @override
  void initState() {
    super.initState();
    _hardwareService.initialize();

    _hardwareSubscription = _hardwareService.stateStream.listen((newState) {
      setState(() => _state = newState);
    });

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _stopHoldController = AnimationController(
      vsync: this,
      duration: _requiredHoldDuration,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _onHoldToStopCompleted();
        }
      });
  }

  @override
  void dispose() {
    _hardwareSubscription?.cancel();
    _pulseController.dispose();
    _stopHoldController.dispose();
    super.dispose();
  }

  Future<void> _handleTriggerSos() async {
    HapticFeedback.heavyImpact();
    await _hardwareService.triggerEmergencySequence();
  }

  void _onStopHoldStart(TapDownDetails details) {
    if (!_state.isEmergencyActive) return;
    setState(() => _isHoldingStop = true);
    HapticFeedback.selectionClick();
    _stopHoldController.forward(from: 0.0);
  }

  void _onStopHoldEnd() {
    if (!_isHoldingStop) return;
    setState(() => _isHoldingStop = false);
    _stopHoldController.reverse();
  }

  void _onHoldToStopCompleted() {
    setState(() => _isHoldingStop = false);
    _stopHoldController.reset();
    _showPinVerificationDialog();
  }

  Future<void> _showPinVerificationDialog() async {
    final TextEditingController pinController = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: const [
                  Icon(Icons.shield_rounded, color: Colors.amberAccent, size: 28),
                  SizedBox(width: 10),
                  Text('Disarm Authorization', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Enter Master PIN to disarm, or Duress PIN under coercion.', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 4,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                    decoration: InputDecoration(
                      hintText: '••••',
                      hintStyle: const TextStyle(color: Colors.white24),
                      errorText: errorText,
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Resume SOS', style: TextStyle(color: Colors.white54)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () async {
                    final entered = pinController.text.trim();
                    if (entered == _masterPin) {
                      Navigator.of(dialogContext).pop();
                      await _hardwareService.stopEmergencySequence();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✓ Guardian AI Disarmed. All evidence sealed.')),
                      );
                    } else if (entered == _duressPin) {
                      // DURESS MODE: Silence siren and torch, BUT continue background silent camera!
                      Navigator.of(dialogContext).pop();
                      await _hardwareService.stopEmergencySequence(keepSilentRecording: true);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Standby mode activated.')),
                      );
                    } else {
                      setDialogState(() => errorText = 'Invalid PIN.');
                      HapticFeedback.heavyImpact();
                    }
                  },
                  child: const Text('Confirm PIN', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showEvidenceVaultModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.between,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.folder_special_rounded, color: Colors.cyanAccent),
                      SizedBox(width: 8),
                      Text('FIR Legal Evidence Locker', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Text('${_state.evidenceHistory.length} Sealed', style: const TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 14),
              if (_state.evidenceHistory.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24.0),
                  child: Center(child: Text('No evidence frames captured yet.', style: TextStyle(color: Colors.white54))),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _state.evidenceHistory.length,
                    itemBuilder: (context, index) {
                      final item = _state.evidenceHistory[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.between,
                              children: [
                                Text('PROOF #${_state.evidenceHistory.length - index}', style: const TextStyle(color: Colors.emeraldAccent, fontWeight: FontWeight.bold, fontSize: 11)),
                                Text('${item.timestamp.toIso8601String().substring(11, 19)} UTC', style: const TextStyle(color: Colors.white54, fontSize: 10)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text('SHA-256: ${item.sha256}', style: const TextStyle(color: Colors.amberAccent, fontSize: 9, fontFamily: 'monospace')),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isActive = _state.isEmergencyActive;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isActive ? Colors.redAccent.withOpacity(0.2) : Colors.cyan.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.security_rounded, color: isActive ? Colors.redAccent : Colors.cyanAccent, size: 20),
            ),
            const SizedBox(width: 10),
            const Text('GUARDIAN AI', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_special_rounded, color: Colors.cyanAccent),
            tooltip: 'Evidence Locker',
            onPressed: _showEvidenceVaultModal,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildStatusBar(isActive),
            const Spacer(),
            Center(
              child: isActive ? _buildActiveEmergencyDisplay() : _buildIdleSosButton(),
            ),
            const Spacer(),
            _buildHardwareTelemetryHud(),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
              child: isActive ? _buildSecureStopButton() : _buildInstantTriggerButton(),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar(bool isActive) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFFEF4444).withOpacity(0.15) : const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isActive ? const Color(0xFFEF4444) : Colors.white12, width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(shape: BoxShape.circle, color: isActive ? Colors.redAccent : const Color(0xFF10B981)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isActive ? 'EMERGENCY PROTOCOL ACTIVE' : 'GUARDIAN ARMED & READY',
                  style: TextStyle(color: isActive ? Colors.redAccent : Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  isActive ? 'Simultaneous Siren + Strobe + Background Evidence Loop Running' : 'STREAM_ALARM: Ready | 150ms Strobe: Ready | Camera: Standby',
                  style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdleSosButton() {
    return ScaleTransition(
      scale: _pulseAnimation,
      child: GestureDetector(
        onTap: _handleTriggerSos,
        child: Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const RadialGradient(colors: [Color(0xFFEF4444), Color(0xFF991B1B)]),
            boxShadow: [
              BoxShadow(color: const Color(0xFFEF4444).withOpacity(0.5), blurRadius: 36, spreadRadius: 8),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.warning_amber_rounded, size: 64, color: Colors.white),
              SizedBox(height: 8),
              Text('TAP FOR SOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 22)),
              SizedBox(height: 4),
              Text('Instant Siren + Strobe + Cam', style: TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveEmergencyDisplay() {
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 230,
              height: 230,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.redAccent.withOpacity(0.5), width: 2),
              ),
            ),
            Container(
              width: 170,
              height: 170,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [Color(0xFFDC2626), Color(0xFF7F1D1D)]),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.emergency_rounded, size: 54, color: Colors.white),
                  const SizedBox(height: 6),
                  Text('${_state.capturedPhotosCount} PROOFS', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  const Text('FIR RECORDING', style: TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHardwareTelemetryHud() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF1E293B).withOpacity(0.8), borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _telemetryItem(Icons.volume_up_rounded, 'Alarm Stream', _state.isSirenPlaying ? '100% LOUD' : 'STANDBY', _state.isSirenPlaying, Colors.orangeAccent),
          _telemetryItem(Icons.flash_on_rounded, 'Torch Strobe', _state.isStrobeFlashing ? '150ms BURST' : 'OFF', _state.isStrobeFlashing, Colors.amberAccent),
          _telemetryItem(Icons.camera_alt_rounded, 'FIR Camera', '${_state.capturedPhotosCount} Snaps', _state.isEvidenceCapturing, Colors.cyanAccent),
        ],
      ),
    );
  }

  Widget _telemetryItem(IconData icon, String label, String status, bool active, Color color) {
    return Column(
      children: [
        Icon(icon, color: active ? color : Colors.white38, size: 22),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        Text(status, style: TextStyle(color: active ? color : Colors.white38, fontWeight: FontWeight.bold, fontSize: 11)),
      ],
    );
  }

  Widget _buildInstantTriggerButton() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton.icon(
        icon: const Icon(Icons.bolt_rounded, color: Colors.white),
        label: const Text('ACTIVATE EMERGENCY HARDWARE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFDC2626),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: _handleTriggerSos,
      ),
    );
  }

  Widget _buildSecureStopButton() {
    return GestureDetector(
      onTapDown: _onStopHoldStart,
      onTapUp: (_) => _onStopHoldEnd(),
      onTapCancel: _onStopHoldEnd,
      child: AnimatedBuilder(
        animation: _stopHoldController,
        builder: (context, child) {
          final progress = _stopHoldController.value;
          return Container(
            height: 60,
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24, width: 1.5),
            ),
            child: Stack(
              children: [
                FractionallySizedBox(
                  widthFactor: progress,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withOpacity(0.35),
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 3,
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF10B981)),
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _isHoldingStop
                            ? 'HOLD TO STOP (${(3.0 * (1.0 - progress)).toStringAsFixed(1)}s)'
                            : 'HOLD FOR 3 SECONDS TO STOP',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.8),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
