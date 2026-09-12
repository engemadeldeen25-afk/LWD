import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:csv/csv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:vibration/vibration.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const GeoMacLabApp());

class GeoMacLabApp extends StatelessWidget {
  const GeoMacLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GEO.MACLAB_2050',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF0A192F),
        scaffoldBackgroundColor: const Color(0xFF0A192F),
        cardColor: const Color(0xFF112240),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A192F),
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  // BLE State
  BluetoothDevice? _device;
  bool _isScanning = false;
  bool _isConnected = false;
  String _connectionStatus = "Disconnected";

  // Test Data
  Map<String, double> _lastReading = {"evd": 0, "def": 0, "lat": 0, "lng": 0};
  int _satellites = 0;
  int _testCounter = 0;
  final List<double> _deflectionHistory = List.filled(30, 0.0);

  // CSV Logging
  final List<List<dynamic>> _csvData = [
    ["Test #", "Timestamp", "Evd (MN/m²)", "Def (mm)", "Latitude", "Longitude", "Satellites"]
  ];

  // Animation
  late AnimationController _pulseController;
  final ValueNotifier<double> _gaugeValue = ValueNotifier(0.0);

  // GPS Caching
  double _lastKnownLat = 0.0;
  double _lastKnownLng = 0.0;

  // Calibration
  double _calibrationFactor = 1.0;
  String _calibrationDate = 'Never';
  final String _password = 'admin123';
  late SharedPreferences _prefs;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 1));
    _loadCalibration();
    _requestPermissions();
    _startScanning();
    _checkGpsService();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _gaugeValue.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await Permission.location.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
  }

  void _startScanning() {
    setState(() => _isScanning = true);
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.name.contains("LWD-BMI160-Probe")) {
          _connectToDevice(r.device);
          FlutterBluePlus.stopScan();
          setState(() => _isScanning = false);
          return;
        }
      }
    });
    Future.delayed(const Duration(seconds: 5), () => setState(() => _isScanning = false));
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _device = device;
      _connectionStatus = "Connecting...";
    });
    try {
      await device.connect();
      await device.discoverServices();
      var char = device.services
          .expand((s) => s.characteristics)
          .firstWhere((c) => c.uuid.toString() == "6e400002-b5a3-f393-e0a9-e50e24dcca9e");
      await char.setNotifyValue(true);
      char.onValueReceived.listen((event) {
        String raw = String.fromCharCodes(event.value);
        _parseIncomingData(raw);
      });
      setState(() {
        _isConnected = true;
        _connectionStatus = "Online";
      });
      _pulseController.repeat(reverse: true);
      Vibration.vibrate(duration: 50);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("✅ Connected to LWD Probe!")),
      );
    } catch (e) {
      setState(() {
        _isConnected = false;
        _connectionStatus = "Failed";
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("❌ Connection error: $e")),
      );
    }
  }

  void _parseIncomingData(String jsonStr) {
    try {
      Map<String, dynamic> data = {};
      jsonStr.replaceAll("{", "").replaceAll("}", "").split(",").forEach((pair) {
        var kv = pair.split(":");
        if (kv.length == 2) {
          data[kv[0].replaceAll('"', '').trim()] = double.tryParse(kv[1].trim()) ?? 0.0;
        }
      });

      double rawEvd = data["evd"] ?? 0;
      double def = data["def"] ?? 0;
      double calibratedEvd = rawEvd * _calibrationFactor;

      setState(() {
        _lastReading["evd"] = calibratedEvd;
        _lastReading["def"] = def;
        _gaugeValue.value = (calibratedEvd / 80.0).clamp(0.0, 1.0);
        _deflectionHistory.add(def);
        if (_deflectionHistory.length > 30) _deflectionHistory.removeAt(0);
      });

      Vibration.vibrate(duration: 20);

      if (calibratedEvd > 0.5) {
        _logTestWithPhoneGps(calibratedEvd, def);
      }
    } catch (e) {
      print("Parse Error: $e");
    }
  }

  Future<void> _logTestWithPhoneGps(double evd, double def) async {
    double lat = _lastKnownLat;
    double lng = _lastKnownLng;
    int satCount = 0;

    try {
      Position? pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 3),
      ).timeout(const Duration(seconds: 3));
      if (pos != null) {
        lat = pos.latitude;
        lng = pos.longitude;
        satCount = pos.satellite ?? 0;
        _lastKnownLat = lat;
        _lastKnownLng = lng;
      }
    } catch (e) {
      print("GPS error, using cached position: $e");
    }

    if (mounted) {
      setState(() {
        _lastReading["lat"] = lat;
        _lastReading["lng"] = lng;
        _satellites = satCount;
        _testCounter++;
        _csvData.add([
          _testCounter,
          DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
          evd.toStringAsFixed(1),
          def.toStringAsFixed(3),
          lat.toStringAsFixed(6),
          lng.toStringAsFixed(6),
          satCount,
        ]);
      });
    }
  }

  // Calibration Persistence
  Future<void> _loadCalibration() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _calibrationFactor = _prefs.getDouble('calibrationFactor') ?? 1.0;
      _calibrationDate = _prefs.getString('calibrationDate') ?? 'Never';
    });
  }

  Future<void> _saveCalibration(double factor) async {
    await _prefs.setDouble('calibrationFactor', factor);
    await _prefs.setString('calibrationDate', DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()));
    setState(() {
      _calibrationFactor = factor;
      _calibrationDate = _prefs.getString('calibrationDate')!;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ Calibration saved: ${factor.toStringAsFixed(3)}')),
    );
  }

  void _showCalibrationDialog() {
    TextEditingController passwordController = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('🔐 Calibration Unlock'),
        content: TextField(
          controller: passwordController,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: 'Enter password',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (passwordController.text == _password) {
                Navigator.pop(context);
                _showCalibrationEditor();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('❌ Wrong password')),
                );
              }
            },
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }

  void _showCalibrationEditor() {
    TextEditingController factorController =
        TextEditingController(text: _calibrationFactor.toStringAsFixed(3));
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Adjust Calibration Factor'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Multiplier applied to raw EVD:'),
            const SizedBox(height: 8),
            TextField(
              controller: factorController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'e.g. 1.000',
                prefixText: '× ',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.calendar_today, size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                Text('Last calibration: $_calibrationDate',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              double? newFactor = double.tryParse(factorController.text);
              if (newFactor != null && newFactor > 0) {
                _saveCalibration(newFactor);
                Navigator.pop(context);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('❌ Enter a valid positive number')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _checkGpsService() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ Please enable GPS for accurate test locations.')),
        );
      }
    });
  }

  Future<void> _exportCSV() async {
    String csv = const ListToCsvConverter().convert(_csvData);
    try {
      String path = "/storage/emulated/0/Download/LWD_Report_${DateTime.now().millisecondsSinceEpoch}.csv";
      File file = File(path);
      await file.writeAsString(csv);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("📁 Report saved to Downloads!")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("⚠️ CSV Data ready, but save failed: $e")),
      );
    }
  }

  void _disconnect() {
    _device?.disconnect();
    setState(() {
      _isConnected = false;
      _connectionStatus = "Disconnected";
      _pulseController.stop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.science, color: Color(0xFF00E5FF)),
            const SizedBox(width: 10),
            const Text(
              "GEO.MACLAB_2050",
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 18),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.lock_outline, color: Colors.amber),
              onPressed: _showCalibrationDialog,
              tooltip: 'Calibration',
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _isConnected ? Colors.green.shade900 : Colors.red.shade900,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _connectionStatus,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: _isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bluetooth_searching),
              onPressed: _isConnected ? null : _startScanning,
            ),
            IconButton(
              icon: const Icon(Icons.power_settings_new),
              onPressed: _isConnected ? _disconnect : null,
              color: _isConnected ? Colors.red : Colors.grey,
            ),
          ],
        ),
        backgroundColor: const Color(0xFF0A192F),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Dashboard Card
            Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF112240), Color(0xFF1A365D)],
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.1),
                    blurRadius: 20,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'CALIBRATION',
                        style: TextStyle(color: Colors.grey, fontSize: 10, letterSpacing: 1),
                      ),
                      Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            'Factor: ${_calibrationFactor.toStringAsFixed(3)}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Updated: $_calibrationDate',
                            style: const TextStyle(color: Colors.grey, fontSize: 10),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "EVD MODULUS",
                            style: TextStyle(color: Colors.grey, fontSize: 12, letterSpacing: 1),
                          ),
                          Row(
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                child: Text(
                                  "${_lastReading["evd"]?.toStringAsFixed(1) ?? "0.0"}",
                                  key: ValueKey(_lastReading["evd"]),
                                  style: const TextStyle(
                                    fontSize: 48,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF00E5FF),
                                  ),
                                ),
                              ),
                              const Text(
                                " MN/m²",
                                style: TextStyle(color: Colors.grey, fontSize: 16),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text(
                            "DEFLECTION",
                            style: TextStyle(color: Colors.grey, fontSize: 12, letterSpacing: 1),
                          ),
                          Row(
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                child: Text(
                                  "${_lastReading["def"]?.toStringAsFixed(3) ?? "0.000"}",
                                  key: ValueKey(_lastReading["def"]),
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orangeAccent,
                                  ),
                                ),
                              ),
                              const Text(
                                " mm",
                                style: TextStyle(color: Colors.grey, fontSize: 14),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: (_lastReading["evd"] ?? 0) >= 40
                              ? Colors.green.shade900
                              : Colors.red.shade900,
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              (_lastReading["evd"] ?? 0) >= 40
                                  ? Icons.check_circle
                                  : Icons.cancel,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              (_lastReading["evd"] ?? 0) >= 40 ? "PASS" : "FAIL",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          children: [
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                value: _gaugeValue.value.clamp(0.0, 1.0),
                                minHeight: 8,
                                backgroundColor: Colors.grey.shade800,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _gaugeValue.value > 0.5 ? Colors.green : Colors.red,
                                ),
                              ),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("0", style: TextStyle(color: Colors.grey.shade500, fontSize: 10)),
                                Text("Target 40", style: TextStyle(color: Colors.grey.shade500, fontSize: 10)),
                                Text("80 MN/m²", style: TextStyle(color: Colors.grey.shade500, fontSize: 10)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.location_on,
                            color: _lastKnownLat != 0 ? Colors.green : Colors.grey,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _lastKnownLat != 0
                                ? "${_lastKnownLat.toStringAsFixed(5)}, ${_lastKnownLng.toStringAsFixed(5)}"
                                : "No Fix",
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Icon(
                            Icons.satellite,
                            color: _satellites > 3 ? Colors.green : Colors.grey,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            "$_satellites SAT",
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Icon(
                            Icons.format_list_numbered,
                            color: Colors.grey.shade400,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            "#$_testCounter",
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Waveform Chart
            Expanded(
              flex: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF112240),
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "DEFLECTION WAVEFORM",
                      style: TextStyle(color: Colors.grey, fontSize: 10, letterSpacing: 1),
                    ),
                    Expanded(
                      child: LineChart(
                        LineChartData(
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: false,
                            horizontalInterval: 0.2,
                          ),
                          titlesData: const FlTitlesData(show: false),
                          borderData: FlBorderData(show: false),
                          minX: 0,
                          maxX: 30,
                          minY: -0.5,
                          maxY: 1.5,
                          lineBarsData: [
                            LineChartBarData(
                              spots: _deflectionHistory
                                  .asMap()
                                  .entries
                                  .map((e) => FlSpot(e.key.toDouble(), e.value))
                                  .toList(),
                              isCurved: true,
                              color: const Color(0xFF00E5FF),
                              barWidth: 2.5,
                              belowBarData: BarAreaData(
                                show: true,
                                color: const Color(0xFF00E5FF).withOpacity(0.1),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _exportCSV,
                    icon: const Icon(Icons.save_alt),
                    label: const Text("EXPORT REPORT"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A365D),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _deflectionHistory.fillRange(0, _deflectionHistory.length, 0.0);
                        _lastReading = {"evd": 0, "def": 0, "lat": 0, "lng": 0};
                        _gaugeValue.value = 0;
                      });
                      Vibration.vibrate(duration: 30);
                    },
                    icon: const Icon(Icons.clear_all),
                    label: const Text("CLEAR DATA"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade900,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.all(4),
              child: Text(
                _isConnected ? "🟢 Live Data Streaming" : "⚪ Waiting for Connection...",
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}