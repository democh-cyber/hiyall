import 'package:geolocator/geolocator.dart';

/// Why a position couldn't be read; each has its own plain-language message.
enum LocationProblem { denied, deniedForever, servicesOff, unavailable }

extension LocationProblemText on LocationProblem {
  String get message => LocationFailure(this).message;
}

class LocationFailure implements Exception {
  final LocationProblem problem;
  const LocationFailure(this.problem);
  String get message => switch (problem) {
    LocationProblem.denied =>
      'Location access is off. Allow it to see people near you.',
    LocationProblem.deniedForever => 'Location access is blocked. Turn it on for Hiyall in your device settings.',
    LocationProblem.servicesOff =>
      'Location services are off. Turn them on to see people near you.',
    LocationProblem.unavailable =>
      'Couldn’t work out where you are. Try again in a moment.',
  };
  @override
  String toString() => message;
}

class LocationFix {
  final double latitude, longitude;
  const LocationFix(this.latitude, this.longitude);
}

/// The device's position, behind an interface so screens can be tested without
/// a GPS. Only an approximate fix is requested; the server rounds it further.
abstract class LocationService {
  /// Asks for permission if needed, then reads one approximate position.
  Future<LocationFix> current();

  /// Opens the system page where the person can change location permission.
  Future<void> openSettings(LocationProblem problem);
}

class DeviceLocationService implements LocationService {
  const DeviceLocationService();

  @override
  Future<LocationFix> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationFailure(LocationProblem.servicesOff);
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationFailure(LocationProblem.deniedForever);
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      throw const LocationFailure(LocationProblem.denied);
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return LocationFix(position.latitude, position.longitude);
    } catch (_) {
      throw const LocationFailure(LocationProblem.unavailable);
    }
  }

  @override
  Future<void> openSettings(LocationProblem problem) async {
    if (problem == LocationProblem.servicesOff) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }
}
