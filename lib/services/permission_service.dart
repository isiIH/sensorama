import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  /// Obtiene la lista de permisos requeridos
  List<Permission> _getRequiredPermissions() {
    return [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ];
  }

  /// Verifica si ya tenemos todos los permisos
  Future<bool> checkPermissionsStatus() async {
    final perms = _getRequiredPermissions();
    for (var perm in perms) {
      if (!await perm.isGranted) return false;
    }
    return true;
  }

  /// Solicita los permisos y devuelve un booleano indicando éxito total
  Future<bool> requestPermissions() async {
    final perms = _getRequiredPermissions();
    Map<Permission, PermissionStatus> statuses = await perms.request();

    // Verificamos si alguno fue denegado permanentemente
    bool anyPermanentlyDenied = statuses.values.any((s) => s.isPermanentlyDenied);
    bool allGranted = statuses.values.every((s) => s.isGranted);

    if (anyPermanentlyDenied) {
      // Retornamos false, la UI deberá encargarse de mostrar el diálogo de Settings
      // para no mezclar lógica de UI aquí.
      return false;
    }

    return allGranted;
  }

  void openSettings() => openAppSettings();
}