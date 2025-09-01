import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui';
import 'package:fl_chart/fl_chart.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Food Safety Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF00D4FF),
        scaffoldBackgroundColor: const Color(0xFF0A0E27),
        fontFamily: 'SF Pro Display',
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D4FF),
          secondary: Color(0xFF00FFA3),
          surface: Color(0xFF1A1F3A),
          error: Color(0xFFFF006E),
        ),
        useMaterial3: true,
      ),
      home: const GasMonitorScreen(),
    );
  }
}

class GasData {
  final double nh3Ppm;
  final double h2sPpm;
  final double co2Ppm;
  final double ch4Ppm;
  final int stage;
  final double confidence;
  final double temperature;
  final double humidity;
  final DateTime timestamp;

  GasData({
    required this.nh3Ppm,
    required this.h2sPpm,
    required this.co2Ppm,
    required this.ch4Ppm,
    required this.stage,
    required this.confidence,
    required this.temperature,
    required this.humidity,
    required this.timestamp,
  });

  factory GasData.fromJson(Map<String, dynamic> json) {
    var gas = json['gas'] ?? json['gases'] ?? {};
    
    return GasData(
      nh3Ppm: (gas['nh3'] ?? 0).toDouble(),
      h2sPpm: (gas['h2s'] ?? 0).toDouble(),
      co2Ppm: (gas['co2'] ?? 0).toDouble(),
      ch4Ppm: (gas['ch4'] ?? gas['methane'] ?? 0).toDouble(),
      stage: json['stage'] ?? 0,
      confidence: (json['confidence'] ?? 0).toDouble(),
      temperature: (json['temp'] ?? json['temperature'] ?? 20.0).toDouble(),
      humidity: (json['humidity'] ?? 65.0).toDouble(),
      timestamp: DateTime.now(),
    );
  }

  String getSpoilageText() {
    switch (stage) {
      case 0: return 'Fresh';
      case 1: return 'Warning';
      case 2: return 'Spoiling';
      case 3: return 'Spoiled';
      default: return 'Unknown';
    }
  }
}

// Simplified connection states
enum BLEConnectionState {
  disconnected,
  connecting,
  connected,
  ready,
  error
}

class ESP32Device {
  final int id;
  final String name;
  final BluetoothDevice device;
  BluetoothCharacteristic? txCharacteristic;
  StreamSubscription<List<int>>? subscription;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  
  BLEConnectionState connectionState;
  bool get isReady => connectionState == BLEConnectionState.ready;
  bool get isConnected => [
    BLEConnectionState.connected,
    BLEConnectionState.ready,
  ].contains(connectionState);
  bool get isConnecting => connectionState == BLEConnectionState.connecting;
  
  // Gas data
  GasData? gasData;
  List<GasData> gasHistory = [];
  
  // Connection management
  DateTime lastUpdate;
  String? errorMessage;
  int connectionAttempts;
  Timer? connectionTimeoutTimer;

  ESP32Device({
    required this.id,
    required this.name,
    required this.device,
    this.txCharacteristic,
    this.subscription,
    this.connectionSubscription,
    this.connectionState = BLEConnectionState.disconnected,
    this.gasData,
    DateTime? lastUpdate,
    this.errorMessage,
    this.connectionAttempts = 0,
    this.connectionTimeoutTimer,
  }) : lastUpdate = lastUpdate ?? DateTime.now();

  void dispose() {
    connectionTimeoutTimer?.cancel();
    subscription?.cancel();
    connectionSubscription?.cancel();
  }

  String getConnectionStateText() {
    switch (connectionState) {
      case BLEConnectionState.disconnected:
        return 'Disconnected';
      case BLEConnectionState.connecting:
        return 'Connecting...';
      case BLEConnectionState.connected:
        return 'Connected';
      case BLEConnectionState.ready:
        return 'Receiving Data';
      case BLEConnectionState.error:
        return 'Error';
    }
  }
}

class GasMonitorScreen extends StatefulWidget {
  const GasMonitorScreen({super.key});

  @override
  State<GasMonitorScreen> createState() => _GasMonitorScreenState();
}

class _GasMonitorScreenState extends State<GasMonitorScreen> 
    with TickerProviderStateMixin {
  // BLE Configuration - Only TX needed for one-way communication
  static const String serviceUUID = "12345678-1234-5678-9abc-def123456789";
  static const String txCharUUID = "87654321-4321-1234-5678-abc123456789";  // ESP32 -> App
  
  // Connection timeouts
  static const Duration connectionTimeout = Duration(seconds: 15);
  static const Duration serviceDiscoveryDelay = Duration(milliseconds: 500);
  static const Duration characteristicAccessDelay = Duration(milliseconds: 300);
  static const int maxConnectionAttempts = 3;
  
  // App state
  List<ScanResult> availableDevices = [];
  Map<String, ESP32Device> connectedDevicesMap = {};
  List<ESP32Device> get connectedDevices => connectedDevicesMap.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  List<ESP32Device> get readyDevices => 
    connectedDevices.where((d) => d.isReady).toList();
  
  bool isScanning = false;
  bool bluetoothEnabled = false;
  bool showAllDevices = false;
  bool debugMode = true;
  
  // UI state
  late TabController _tabController;
  late AnimationController _scanAnimationController;
  late AnimationController _pulseAnimationController;
  
  // Subscriptions
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _scanAnimationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
    _pulseAnimationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _initializeBluetooth();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scanAnimationController.dispose();
    _pulseAnimationController.dispose();
    _adapterStateSubscription?.cancel();
    _scanSubscription?.cancel();
    
    for (ESP32Device device in connectedDevices) {
      device.dispose();
      try {
        device.device.disconnect();
      } catch (e) {
        _debugPrint('Error disconnecting device ${device.id}: $e');
      }
    }
    super.dispose();
  }

  void _debugPrint(String message) {
    if (debugMode) {
      debugPrint('[BLE_DEBUG] $message');
    }
  }

  Future<void> _initializeBluetooth() async {
    _debugPrint('Initializing Bluetooth...');
    await _requestPermissions();
    
    try {
      if (await FlutterBluePlus.isSupported == false) {
        _showSnackBar('Bluetooth not supported by this device', isError: true);
        return;
      }

      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
        _debugPrint('Bluetooth adapter state: $state');
        setState(() {
          bluetoothEnabled = state == BluetoothAdapterState.on;
        });
      });

      BluetoothAdapterState adapterState = await FlutterBluePlus.adapterState.first;
      _debugPrint('Current Bluetooth state: $adapterState');
      setState(() {
        bluetoothEnabled = adapterState == BluetoothAdapterState.on;
      });

      if (!bluetoothEnabled && mounted) {
        if (defaultTargetPlatform == TargetPlatform.android) {
          _debugPrint('Attempting to turn on Bluetooth...');
          await FlutterBluePlus.turnOn();
          await Future.delayed(const Duration(seconds: 2));
          adapterState = await FlutterBluePlus.adapterState.first;
          setState(() {
            bluetoothEnabled = adapterState == BluetoothAdapterState.on;
          });
        }
      }
      
      _debugPrint('Bluetooth initialization complete. Enabled: $bluetoothEnabled');
    } catch (e) {
      _debugPrint('Error initializing Bluetooth: $e');
      _showSnackBar('Error initializing Bluetooth: $e', isError: true);
    }
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.locationWhenInUse,
      Permission.location,
    ].request();
    
    _debugPrint('Permission statuses:');
    statuses.forEach((permission, status) {
      _debugPrint('  $permission: $status');
    });
  }

  Future<void> _startScanning() async {
    if (!bluetoothEnabled) {
      _showSnackBar('Please enable Bluetooth', isError: true);
      return;
    }

    setState(() {
      isScanning = true;
      availableDevices.clear();
    });

    try {
      await FlutterBluePlus.stopScan();
      await Future.delayed(const Duration(milliseconds: 500));
      
      _debugPrint('Starting BLE scan...');
      
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        _debugPrint('Scan results received: ${results.length} devices');
        
        for (ScanResult result in results) {
          String deviceName = result.device.platformName;
          if (deviceName.isEmpty) {
            deviceName = result.advertisementData.advName;
          }
          if (deviceName.isEmpty) {
            deviceName = result.advertisementData.localName;
          }
          if (deviceName.isEmpty) {
            deviceName = 'Unknown Device';
          }
          
          _debugPrint('Discovered: $deviceName (${result.device.remoteId}) RSSI: ${result.rssi}');
          
          bool alreadyInList = availableDevices.any((d) => 
            d.device.remoteId == result.device.remoteId);
          bool alreadyConnected = connectedDevicesMap.containsKey(
            result.device.remoteId.str);
          
          if (!alreadyInList && !alreadyConnected) {
            if (showAllDevices && deviceName != 'Unknown Device') {
              _debugPrint('Adding device (debug mode): $deviceName');
              setState(() {
                availableDevices.add(result);
              });
            }
            else if (deviceName.toUpperCase().contains('ESP') ||
                deviceName.toUpperCase().contains('SPOILAGE') ||
                deviceName.toUpperCase().contains('GAS') ||
                deviceName.toUpperCase().contains('SENSOR') ||
                result.advertisementData.serviceUuids.any((uuid) => 
                  uuid.toString().toLowerCase().contains('12345678'))) {
              
              _debugPrint('Adding ESP32 device: $deviceName');
              setState(() {
                availableDevices.add(result);
              });
            }
          }
        }
      }, onError: (error) {
        _debugPrint('Scan stream error: $error');
      });
      
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true,
        withServices: [],
        withNames: [],
      );
      
      await Future.delayed(const Duration(seconds: 15));
      await FlutterBluePlus.stopScan();
      
      setState(() {
        isScanning = false;
      });

      _debugPrint('Scan complete. Found ${availableDevices.length} devices');
      
      if (availableDevices.isEmpty) {
        _showSnackBar('No devices found. Make sure ESP32 is powered on and advertising.', isError: true);
      } else {
        _showSnackBar('Found ${availableDevices.length} device(s)');
      }
    } catch (e) {
      _debugPrint('Scan error: $e');
      _showSnackBar('Error scanning: $e', isError: true);
      setState(() {
        isScanning = false;
      });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    String deviceName = device.platformName.isNotEmpty 
        ? device.platformName 
        : 'Unknown';
    
    String deviceIdStr = _extractDeviceId(deviceName);
    int deviceId = int.tryParse(deviceIdStr) ?? 0;
    
    if (connectedDevicesMap.containsKey(device.remoteId.str)) {
      _showSnackBar('Device $deviceId already connected');
      return;
    }
    
    ESP32Device esp32Device = ESP32Device(
      id: deviceId,
      name: deviceName,
      device: device,
      connectionState: BLEConnectionState.connecting,
    );
    
    setState(() {
      connectedDevicesMap[device.remoteId.str] = esp32Device;
    });

    // Start connection timeout timer
    esp32Device.connectionTimeoutTimer = Timer(connectionTimeout, () {
      _debugPrint('Connection timeout for device $deviceId');
      _handleConnectionError(esp32Device, 'Connection timeout');
    });

    try {
      await _performSimpleConnection(esp32Device);
    } catch (e) {
      _debugPrint('Connection error for device $deviceId: $e');
      _handleConnectionError(esp32Device, e.toString());
    }
  }

  Future<void> _performSimpleConnection(ESP32Device esp32Device) async {
    _debugPrint('=== SIMPLE CONNECTION START for Device ${esp32Device.id} ===');
    
    try {
      // Step 1: Connect to device
      _debugPrint('Step 1: Connecting to device...');
      _updateDeviceState(esp32Device, BLEConnectionState.connecting);
      
      await esp32Device.device.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );
      
      _debugPrint('Step 1: Connection established');
      _updateDeviceState(esp32Device, BLEConnectionState.connected);
      
      // Step 2: Wait for connection to stabilize
      _debugPrint('Step 2: Waiting for connection to stabilize...');
      await Future.delayed(serviceDiscoveryDelay);
      
      // Step 3: Discover services
      _debugPrint('Step 3: Discovering services...');
      List<BluetoothService> services = await esp32Device.device.discoverServices();
      
      if (services.isEmpty) {
        throw Exception('No services discovered');
      }
      
      _debugPrint('Found ${services.length} services');
      
      // Step 4: Find target service
      _debugPrint('Step 4: Finding target service...');
      BluetoothService? targetService;
      for (BluetoothService service in services) {
        _debugPrint('Service found: ${service.uuid}');
        if (service.uuid.toString().toLowerCase() == serviceUUID.toLowerCase()) {
          targetService = service;
          _debugPrint('Target service found!');
          break;
        }
      }
      
      if (targetService == null) {
        throw Exception('Target service $serviceUUID not found');
      }
      
      // Step 5: Wait before accessing characteristics
      _debugPrint('Step 5: Waiting before accessing characteristics...');
      await Future.delayed(characteristicAccessDelay);
      
      // Step 6: Find TX characteristic (only need TX for one-way communication)
      _debugPrint('Step 6: Finding TX characteristic...');
      BluetoothCharacteristic? txChar;
      
      _debugPrint('Found ${targetService.characteristics.length} characteristics:');
      for (BluetoothCharacteristic characteristic in targetService.characteristics) {
        String charUuid = characteristic.uuid.toString().toLowerCase();
        _debugPrint('  - $charUuid');
        _debugPrint('    Properties: Read=${characteristic.properties.read} '
                   'Write=${characteristic.properties.write} '
                   'Notify=${characteristic.properties.notify}');
        
        if (charUuid == txCharUUID.toLowerCase()) {
          txChar = characteristic;
          _debugPrint('    TX Characteristic found');
          break;
        }
      }
      
      if (txChar == null) {
        throw Exception('TX characteristic not found');
      }
      
      // Step 7: Set up TX characteristic
      _debugPrint('Step 7: Setting up TX characteristic...');
      esp32Device.txCharacteristic = txChar;
      
      // Step 8: Enable notifications
      _debugPrint('Step 8: Enabling notifications...');
      await txChar.setNotifyValue(true);
      await Future.delayed(const Duration(milliseconds: 200));
      
      // Step 9: Set up data listener
      _debugPrint('Step 9: Setting up data listener...');
      await _setupDataListener(esp32Device);
      
      // Step 10: Set up connection state listener
      _debugPrint('Step 10: Setting up connection state listener...');
      _setupConnectionStateListener(esp32Device);
      
      // Step 11: Update state and show success
      _debugPrint('Step 11: Connection complete - ready to receive data!');
      _updateDeviceState(esp32Device, BLEConnectionState.ready);
      
      // Cancel timeout timer
      esp32Device.connectionTimeoutTimer?.cancel();
      esp32Device.connectionAttempts = 0;
      
      _showSnackBar('Connected to Device ${esp32Device.id} - Ready for data!');
      
      _debugPrint('=== SIMPLE CONNECTION COMPLETE for Device ${esp32Device.id} ===');
      
    } catch (e) {
      _debugPrint('Simple connection failed: $e');
      rethrow;
    }
  }

  void _updateDeviceState(ESP32Device device, BLEConnectionState newState) {
    setState(() {
      device.connectionState = newState;
      device.errorMessage = null;
      device.lastUpdate = DateTime.now();
    });
    _debugPrint('Device ${device.id} state: ${device.getConnectionStateText()}');
  }

  Future<void> _setupDataListener(ESP32Device esp32Device) async {
    if (esp32Device.txCharacteristic == null) return;
    
    esp32Device.subscription = esp32Device.txCharacteristic!.onValueReceived.listen(
      (List<int> value) {
        String received = String.fromCharCodes(value);
        _debugPrint('Received from Device ${esp32Device.id}: $received');
        _processReceivedData(esp32Device, received);
      },
      onError: (error) {
        _debugPrint('Data listener error for Device ${esp32Device.id}: $error');
        _handleConnectionError(esp32Device, 'Data error: $error');
      },
    );
    
    _debugPrint('Data listener setup complete for Device ${esp32Device.id}');
  }

  void _setupConnectionStateListener(ESP32Device esp32Device) {
    esp32Device.connectionSubscription = esp32Device.device.connectionState.listen((state) {
      _debugPrint('Device ${esp32Device.id} connection state changed to: $state');
      
      if (state == BluetoothConnectionState.disconnected) {
        _debugPrint('Device ${esp32Device.id} disconnected unexpectedly');
        _handleDisconnection(esp32Device);
      }
    });
  }

  void _handleConnectionError(ESP32Device device, String error) {
    _debugPrint('Handling connection error for Device ${device.id}: $error');
    
    device.connectionTimeoutTimer?.cancel();
    
    setState(() {
      device.connectionState = BLEConnectionState.error;
      device.errorMessage = error;
      device.connectionAttempts++;
    });
    
    _showSnackBar('Error connecting to Device ${device.id}: $error', isError: true);
    
    // Auto-retry logic
    if (device.connectionAttempts < maxConnectionAttempts) {
      _debugPrint('Will retry connection for Device ${device.id} (attempt ${device.connectionAttempts + 1}/$maxConnectionAttempts)');
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          _connectToDevice(device.device);
        }
      });
    } else {
      _debugPrint('Max connection attempts reached for Device ${device.id}');
      // Remove device from connected list after max attempts
      Timer(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() {
            connectedDevicesMap.remove(device.device.remoteId.str);
          });
        }
      });
    }
  }

  void _handleDisconnection(ESP32Device device) {
    _debugPrint('Handling disconnection for Device ${device.id}');
    
    setState(() {
      device.connectionState = BLEConnectionState.disconnected;
      device.errorMessage = 'Disconnected unexpectedly';
    });
    
    _showSnackBar('Device ${device.id} disconnected');
    
    // Clean up resources
    device.subscription?.cancel();
    device.connectionSubscription?.cancel();
    device.connectionTimeoutTimer?.cancel();
  }

  Future<void> _disconnectDevice(ESP32Device device) async {
    _debugPrint('Manually disconnecting Device ${device.id}');
    
    try {
      // Disable notifications first
      if (device.txCharacteristic != null) {
        try {
          await device.txCharacteristic!.setNotifyValue(false);
          _debugPrint('Notifications disabled for Device ${device.id}');
        } catch (e) {
          _debugPrint('Error disabling notifications: $e');
        }
      }
      
      // Wait a moment for cleanup
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Clean up subscriptions
      device.dispose();
      
      // Disconnect
      await device.device.disconnect();
      
      // Remove from connected devices
      setState(() {
        connectedDevicesMap.remove(device.device.remoteId.str);
      });
      
      _showSnackBar('Disconnected from Device ${device.id}');
      _debugPrint('Device ${device.id} disconnected successfully');
      
    } catch (e) {
      _debugPrint('Error disconnecting Device ${device.id}: $e');
      _showSnackBar('Error disconnecting: $e', isError: true);
    }
  }

  String _extractDeviceId(String deviceName) {
    RegExp regExp = RegExp(r'ESP32_(?:SPOILAGE|GAS)_(\d+)', caseSensitive: false);
    Match? match = regExp.firstMatch(deviceName);
    if (match != null) {
      return match.group(1) ?? '1';
    }
    
    regExp = RegExp(r'ESP32[_-]?(\d+)', caseSensitive: false);
    match = regExp.firstMatch(deviceName);
    if (match != null) {
      return match.group(1) ?? '1';
    }
    
    RegExp numberRegExp = RegExp(r'(\d+)');
    Match? numberMatch = numberRegExp.firstMatch(deviceName);
    if (numberMatch != null) {
      return numberMatch.group(1) ?? '1';
    }
    
    return '1';
  }

  void _processReceivedData(ESP32Device device, String data) {
    try {
      // Process sensor data
      if (data.contains('{') && data.contains('}')) {
        int start = data.indexOf('{');
        int end = data.lastIndexOf('}') + 1;
        String jsonStr = data.substring(start, end);
        
        Map<String, dynamic> json = jsonDecode(jsonStr);
        
        setState(() {
          device.lastUpdate = DateTime.now();
          device.errorMessage = null;
          
          GasData gasData = GasData.fromJson(json);
          device.gasData = gasData;
          device.gasHistory.add(gasData);
          
          if (device.gasHistory.length > 50) {
            device.gasHistory.removeAt(0);
          }
        });
        
        _debugPrint('Sensor data updated for Device ${device.id}');
      }
    } catch (e) {
      _debugPrint('Parse error for Device ${device.id}: $e');
      setState(() {
        device.errorMessage = 'Parse error: $e';
      });
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? const Color(0xFFFF006E) : const Color(0xFF00FFA3),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0A0E27),
              Color(0xFF151B3D),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildTabBar(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildOverviewTab(),
                    _buildGasLevelsTab(),
                    _buildDevicesTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _tabController.index == 2 && !isScanning
          ? _buildFuturisticFAB()
          : null,
    );
  }

  Widget _buildConnectedDeviceItem(ESP32Device device) {
    Color statusColor = device.isReady 
        ? const Color(0xFF00FFA3) 
        : device.connectionState == BLEConnectionState.error
            ? const Color(0xFFFF006E)
            : const Color(0xFFFFB700);
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.05),
            Colors.white.withValues(alpha: 0.02),
          ],
        ),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                device.isReady 
                    ? Icons.sensors 
                    : device.connectionState == BLEConnectionState.error
                        ? Icons.error
                        : Icons.bluetooth_connected,
                color: statusColor,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DEVICE ${device.id}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        device.getConnectionStateText(),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  if (device.errorMessage != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      device.errorMessage!,
                      style: const TextStyle(
                        color: Color(0xFFFF006E),
                        fontSize: 10,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (device.connectionState == BLEConnectionState.error)
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Color(0xFFFFB700)),
                    onPressed: () => _connectToDevice(device.device),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, color: Color(0xFFFF006E)),
                  onPressed: () => _disconnectDevice(device),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF00D4FF), Color(0xFF00FFA3)],
              ),
              borderRadius: BorderRadius.circular(15),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00D4FF).withValues(alpha: 0.3),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.biotech,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'FOOD SAFETY',
                style: TextStyle(
                  color: Color(0xFF00D4FF),
                  fontSize: 12,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Text(
                'Monitor System',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'Connected Devices: ${readyDevices.length}',
                style: const TextStyle(
                  color: Color(0xFF00FFA3),
                  fontSize: 10,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: bluetoothEnabled 
                  ? const Color(0xFF00FFA3).withValues(alpha: 0.2)
                  : Colors.red.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: bluetoothEnabled 
                    ? const Color(0xFF00FFA3) 
                    : Colors.red,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  bluetoothEnabled ? Icons.bluetooth : Icons.bluetooth_disabled,
                  color: bluetoothEnabled ? const Color(0xFF00FFA3) : Colors.red,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  bluetoothEnabled ? 'ON' : 'OFF',
                  style: TextStyle(
                    color: bluetoothEnabled ? const Color(0xFF00FFA3) : Colors.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF00D4FF), Color(0xFF00FFA3)],
          ),
          borderRadius: BorderRadius.circular(15),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white54,
        tabs: const [
          Tab(icon: Icon(Icons.dashboard), text: 'Overview'),
          Tab(icon: Icon(Icons.show_chart), text: 'Analysis'),
          Tab(icon: Icon(Icons.device_hub), text: 'Devices'),
        ],
      ),
    );
  }

  Widget _buildOverviewTab() {
    if (readyDevices.isEmpty) {
      return _buildEmptyState(
        icon: Icons.sensors_off,
        title: 'No Connected Devices',
        subtitle: 'Connect ESP32 devices to monitor food safety',
        actionText: 'Add Device',
        onAction: () => _tabController.animateTo(2),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ...readyDevices.map((device) => _buildFuturisticDeviceCard(device)),
      ],
    );
  }

  Widget _buildFuturisticDeviceCard(ESP32Device device) {
    if (device.gasData == null) {
      return _buildLoadingCard(device);
    }

    Color statusColor = _getSpoilageColor(device.gasData!.stage);
    IconData statusIcon = _getSpoilageIcon(device.gasData!.stage);
    
    return AnimatedBuilder(
      animation: _pulseAnimationController,
      builder: (context, child) {
        return Container(
          margin: const EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.05),
                Colors.white.withValues(alpha: 0.02),
              ],
            ),
            border: Border.all(
              color: statusColor.withValues(alpha: 0.3 + (_pulseAnimationController.value * 0.2)),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: statusColor.withValues(alpha: 0.2 * _pulseAnimationController.value),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.all(20),
                childrenPadding: const EdgeInsets.all(20),
                leading: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor, width: 2),
                  ),
                  child: Icon(statusIcon, color: statusColor, size: 24),
                ),
                title: Row(
                  children: [
                    Text(
                      'DEVICE ${device.id}',
                      style: const TextStyle(
                        fontSize: 12,
                        letterSpacing: 2,
                        color: Color(0xFF00D4FF),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: statusColor),
                      ),
                      child: Text(
                        device.gasData!.getSpoilageText().toUpperCase(),
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    _buildProgressBar(
                      label: 'Confidence',
                      value: device.gasData!.confidence,
                      color: statusColor,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Updated ${_formatTime(device.lastUpdate)}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                children: [
                  _buildGasDataGrid(device.gasData!),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoadingCard(ESP32Device device) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.05),
            Colors.white.withValues(alpha: 0.02),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                const Color(0xFF00D4FF).withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DEVICE ${device.id}',
                style: const TextStyle(
                  fontSize: 12,
                  letterSpacing: 2,
                  color: Color(0xFF00D4FF),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                device.getConnectionStateText(),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGasDataGrid(GasData data) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildGasIndicator('NH₃', data.nh3Ppm, 10.0, Colors.green)),
            const SizedBox(width: 12),
            Expanded(child: _buildGasIndicator('H₂S', data.h2sPpm, 5.0, Colors.red)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildGasIndicator('CO₂', data.co2Ppm, 5000.0, Colors.blue)),
            const SizedBox(width: 12),
            Expanded(child: _buildGasIndicator('CH₄', data.ch4Ppm, 2000.0, Colors.orange)),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildEnvironmentValue(Icons.thermostat, '${data.temperature.toStringAsFixed(1)}°C'),
              _buildEnvironmentValue(Icons.water_drop, '${data.humidity.toStringAsFixed(1)}%'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGasIndicator(String gas, double value, double maxValue, Color color) {
    double percentage = (value / maxValue).clamp(0.0, 1.0);
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                gas,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              Text(
                '${value.toStringAsFixed(1)} ppm',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: percentage,
            backgroundColor: Colors.white.withValues(alpha: 0.1),
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 4,
          ),
        ],
      ),
    );
  }

  Widget _buildEnvironmentValue(IconData icon, String value) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF00D4FF), size: 20),
        const SizedBox(width: 8),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBar({
    required String label,
    required double value,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
            Text(
              '${(value * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: value,
          backgroundColor: Colors.white.withValues(alpha: 0.1),
          valueColor: AlwaysStoppedAnimation<Color>(color),
          minHeight: 3,
        ),
      ],
    );
  }

  Widget _buildGasLevelsTab() {
    if (readyDevices.isEmpty) {
      return _buildEmptyState(
        icon: Icons.analytics_outlined,
        title: 'No Data Available',
        subtitle: 'Connect devices to view gas level analysis',
        actionText: 'Add Device',
        onAction: () => _tabController.animateTo(2),
      );
    }

    return DefaultTabController(
      length: readyDevices.length,
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: TabBar(
              isScrollable: true,
              indicator: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF00FFA3)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              tabs: readyDevices.map((device) => 
                Tab(text: 'Device ${device.id}')).toList(),
            ),
          ),
          Expanded(
            child: TabBarView(
              children: readyDevices.map((device) => 
                _buildGasCharts(device)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGasCharts(ESP32Device device) {
    if (device.gasHistory.isEmpty) {
      return Center(
        child: Text(
          'Collecting data...',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        _buildFuturisticChart('Ammonia (NH₃)', device.gasHistory
            .map((d) => d.nh3Ppm).toList(), const Color(0xFF00FFA3)),
        _buildFuturisticChart('Hydrogen Sulfide (H₂S)', device.gasHistory
            .map((d) => d.h2sPpm).toList(), const Color(0xFFFF006E)),
        _buildFuturisticChart('Carbon Dioxide (CO₂)', device.gasHistory
            .map((d) => d.co2Ppm).toList(), const Color(0xFF00D4FF)),
        _buildFuturisticChart('Methane (CH₄)', device.gasHistory
            .map((d) => d.ch4Ppm).toList(), const Color(0xFFFFB700)),
      ],
    );
  }

  Widget _buildFuturisticChart(String title, List<double> data, Color color) {
    if (data.isEmpty) return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.05),
            Colors.white.withValues(alpha: 0.02),
          ],
        ),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${data.last.toStringAsFixed(2)} PPM',
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 150,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 1,
                  getDrawingHorizontalLine: (value) {
                    return FlLine(
                      color: Colors.white.withValues(alpha: 0.05),
                      strokeWidth: 1,
                    );
                  },
                ),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: data.asMap().entries.map((e) => 
                      FlSpot(e.key.toDouble(), e.value)).toList(),
                    isCurved: true,
                    color: color,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          color.withValues(alpha: 0.3),
                          color.withValues(alpha: 0.0),
                        ],
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

  Widget _buildDevicesTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Show All BLE Devices',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              Switch(
                value: showAllDevices,
                onChanged: (value) {
                  setState(() {
                    showAllDevices = value;
                    availableDevices.clear();
                  });
                  if (value) {
                    _showSnackBar('Debug mode: Showing all BLE devices');
                  } else {
                    _showSnackBar('Showing only ESP32 devices');
                  }
                },
                activeColor: const Color(0xFF00D4FF),
              ),
            ],
          ),
        ),
        if (isScanning) _buildScanningIndicator(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (availableDevices.isNotEmpty) ...[
                _buildSectionHeader('DISCOVERED DEVICES', availableDevices.length),
                ...availableDevices.map((scanResult) => _buildDeviceListItem(
                  scanResult: scanResult,
                  onTap: () => _connectToDevice(scanResult.device),
                )),
              ] else if (!isScanning) ...[
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 50),
                      Icon(
                        Icons.bluetooth_searching,
                        size: 64,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No devices found',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        showAllDevices 
                          ? 'Tap scan to find all BLE devices'
                          : 'Tap scan to find ESP32 devices',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.3),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (connectedDevices.isNotEmpty) ...[
                const SizedBox(height: 20),
                _buildSectionHeader('CONNECTED DEVICES', connectedDevices.length),
                ...connectedDevices.map((device) => _buildConnectedDeviceItem(device)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF00D4FF),
              fontSize: 12,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF00D4FF).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              count.toString(),
              style: const TextStyle(
                color: Color(0xFF00D4FF),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceListItem({
    required ScanResult scanResult,
    required VoidCallback onTap,
  }) {
    String deviceName = scanResult.device.platformName.isNotEmpty 
        ? scanResult.device.platformName 
        : scanResult.advertisementData.advName.isNotEmpty
            ? scanResult.advertisementData.advName
            : 'Unknown Device';
    
    bool isLikelyESP32 = deviceName.toUpperCase().contains('ESP') ||
                         deviceName.toUpperCase().contains('SPOILAGE') ||
                         deviceName.toUpperCase().contains('GAS') ||
                         scanResult.advertisementData.serviceUuids.any((uuid) => 
                           uuid.toString().toLowerCase().contains('12345678'));
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.05),
            Colors.white.withValues(alpha: 0.02),
          ],
        ),
        border: Border.all(
          color: isLikelyESP32 
              ? const Color(0xFF00D4FF).withValues(alpha: 0.5)
              : const Color(0xFF00D4FF).withValues(alpha: 0.2),
          width: isLikelyESP32 ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isLikelyESP32
                        ? const Color(0xFF00D4FF).withValues(alpha: 0.3)
                        : const Color(0xFF00D4FF).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isLikelyESP32 ? Icons.sensors : Icons.bluetooth,
                    color: const Color(0xFF00D4FF),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceName,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: isLikelyESP32 ? FontWeight.bold : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: ${scanResult.device.remoteId}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.signal_cellular_4_bar,
                            size: 12,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Signal: ${scanResult.rssi} dBm',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                          if (isLikelyESP32) ...[
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00FFA3).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'ESP32',
                                style: TextStyle(
                                  color: Color(0xFF00FFA3),
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.touch_app,
                  color: const Color(0xFF00D4FF).withValues(alpha: 0.7),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanningIndicator() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF00D4FF).withValues(alpha: 0.1),
            const Color(0xFF00FFA3).withValues(alpha: 0.1),
          ],
        ),
      ),
      child: Row(
        children: [
          RotationTransition(
            turns: _scanAnimationController,
            child: const Icon(
              Icons.radar,
              color: Color(0xFF00D4FF),
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'Scanning for devices...',
            style: TextStyle(
              color: Color(0xFF00D4FF),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFuturisticFAB() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00D4FF).withValues(alpha: 0.3),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: FloatingActionButton.extended(
        onPressed: _startScanning,
        backgroundColor: const Color(0xFF00D4FF),
        icon: const Icon(
          Icons.bluetooth_searching,
          color: Colors.black,
        ),
        label: const Text(
          'SCAN',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    required String actionText,
    required VoidCallback onAction,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00D4FF).withValues(alpha: 0.2),
                  const Color(0xFF00FFA3).withValues(alpha: 0.2),
                ],
              ),
            ),
            child: Icon(
              icon,
              size: 48,
              color: const Color(0xFF00D4FF),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: onAction,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D4FF),
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            child: Text(
              actionText,
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getSpoilageColor(int level) {
    switch (level) {
      case 0: return const Color(0xFF00FFA3);
      case 1: return const Color(0xFFFFB700);
      case 2: return const Color(0xFFFF6B00);
      case 3: return const Color(0xFFFF006E);
      default: return Colors.grey;
    }
  }

  IconData _getSpoilageIcon(int level) {
    switch (level) {
      case 0: return Icons.check_circle;
      case 1: return Icons.warning;
      case 2: return Icons.warning_amber;
      case 3: return Icons.error;
      default: return Icons.help;
    }
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }
}
