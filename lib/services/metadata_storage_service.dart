import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/sensor_metadata.dart';

/// Service for persisting and retrieving sensor metadata by MAC address.
/// Metadata is stored locally so the app can handle restarts without
/// requiring the ESP32 to resend metadata packets.
class MetadataStorageService {
  // Singleton pattern
  static final MetadataStorageService _instance = MetadataStorageService._internal();
  factory MetadataStorageService() => _instance;
  MetadataStorageService._internal();

  static const String _prefKeyPrefix = 'sensor_metadata_';
  static const String _prefKeyList = 'sensor_metadata_mac_list';

  // In-memory cache of metadata by MAC address
  final Map<String, SensorMetadata> _metadataCache = {};

  // Stream controller for metadata updates
  final _metadataUpdateController = StreamController<SensorMetadata>.broadcast();
  Stream<SensorMetadata> get onMetadataUpdated => _metadataUpdateController.stream;

  /// Initialize the service by loading all persisted metadata into cache
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final macList = prefs.getStringList(_prefKeyList) ?? [];

      for (final mac in macList) {
        final jsonString = prefs.getString('$_prefKeyPrefix$mac');
        if (jsonString != null) {
          try {
            final metadata = SensorMetadata.fromJsonString(jsonString);
            _metadataCache[mac] = metadata;
            debugPrint('📦 [MetadataStorage] Loaded metadata for $mac');
          } catch (e) {
            debugPrint('⚠️ [MetadataStorage] Failed to parse metadata for $mac: $e');
          }
        }
      }

      debugPrint('✅ [MetadataStorage] Initialized with ${_metadataCache.length} sensors');
    } catch (e) {
      debugPrint('❌ [MetadataStorage] Initialization error: $e');
    }
  }

  /// Store or update metadata for a sensor (identified by MAC address)
  Future<void> storeMetadata(SensorMetadata metadata) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Update the metadata in storage
      await prefs.setString(
        '$_prefKeyPrefix${metadata.macAddress}',
        metadata.toJsonString(),
      );

      // Update the MAC list if this is a new sensor
      final macList = prefs.getStringList(_prefKeyList) ?? [];
      if (!macList.contains(metadata.macAddress)) {
        macList.add(metadata.macAddress);
        await prefs.setStringList(_prefKeyList, macList);
      }

      // Update cache
      _metadataCache[metadata.macAddress] = metadata;

      // Notify listeners
      _metadataUpdateController.add(metadata);

      debugPrint('💾 [MetadataStorage] Stored metadata for ${metadata.macAddress}: ${metadata.sensorId}');
    } catch (e) {
      debugPrint('❌ [MetadataStorage] Error storing metadata: $e');
    }
  }

  /// Retrieve metadata for a specific MAC address
  SensorMetadata? getMetadata(String macAddress) {
    return _metadataCache[macAddress];
  }

  /// Check if metadata exists for a MAC address
  bool hasMetadata(String macAddress) {
    return _metadataCache.containsKey(macAddress);
  }

  /// Get all stored metadata
  List<SensorMetadata> getAllMetadata() {
    return _metadataCache.values.toList();
  }

  /// Get all known MAC addresses
  List<String> getAllMacAddresses() {
    return _metadataCache.keys.toList();
  }

  /// Remove metadata for a specific MAC address
  Future<void> removeMetadata(String macAddress) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Remove from storage
      await prefs.remove('$_prefKeyPrefix$macAddress');

      // Update MAC list
      final macList = prefs.getStringList(_prefKeyList) ?? [];
      macList.remove(macAddress);
      await prefs.setStringList(_prefKeyList, macList);

      // Remove from cache
      _metadataCache.remove(macAddress);

      debugPrint('🗑️ [MetadataStorage] Removed metadata for $macAddress');
    } catch (e) {
      debugPrint('❌ [MetadataStorage] Error removing metadata: $e');
    }
  }

  /// Clear all stored metadata
  Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final macList = prefs.getStringList(_prefKeyList) ?? [];

      for (final mac in macList) {
        await prefs.remove('$_prefKeyPrefix$mac');
      }
      await prefs.remove(_prefKeyList);

      _metadataCache.clear();

      debugPrint('🗑️ [MetadataStorage] Cleared all metadata');
    } catch (e) {
      debugPrint('❌ [MetadataStorage] Error clearing metadata: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _metadataUpdateController.close();
  }
}
