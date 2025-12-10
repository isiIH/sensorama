import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';

class NetworkState {
  final String? ip;
  final String? wifiName;
  NetworkState({this.ip, this.wifiName});
}

class NetworkService {
  final _info = NetworkInfo();

  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Connectivity().onConnectivityChanged;

  Future<NetworkState> getCurrentNetworkInfo() async {
    String? wifiName = await _info.getWifiName();
    String? ip = await _info.getWifiIP();

    // Limpieza de comillas en Android
    if (wifiName != null && wifiName.startsWith('"') && wifiName.endsWith('"')) {
      wifiName = wifiName.substring(1, wifiName.length - 1);
    }

    return NetworkState(ip: ip, wifiName: wifiName);
  }
}