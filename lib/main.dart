import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  runApp(const MaterialApp(home: RouteMapScreen()));
}

class RouteMapScreen extends StatefulWidget {
  const RouteMapScreen({Key? key}) : super(key: key);

  @override
  State<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends State<RouteMapScreen> {
  late GoogleMapController mapController;
  final String googleApiKey = "AIzaSyCi5g39Fzethf0tfwn3WesaeRAHOcrGVOQ";

  final List<LatLng> locations = [
    const LatLng(9.956714, 76.2928582),
    const LatLng(9.6332441, 76.4825775),
    const LatLng(11.2745235, 75.8362916),
    const LatLng(9.8426903, 77.3727078),
    const LatLng(11.0830611, 76.059088),
  ];

  Map<MarkerId, Marker> markers = {};
  Map<PolylineId, Polyline> polylines = {};
  List<LatLng> polylineCoordinates = [];
  List<LatLng> liveRouteCoordinates = [];
  PolylinePoints polylinePoints = PolylinePoints();
  List<LatLng> optimizedLocations = [];
  String currentDestinationText = '';
  double? nextLocationDistance;

  StreamSubscription<Position>? positionStream;
  Position? currentPosition;
  Timer? liveRouteTimer;
  int currentDestinationIndex = 0;

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  Future<void> _initializeLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    currentPosition = await Geolocator.getCurrentPosition();
    _updateDriverMarker(currentPosition!);
    _findNearestLocationAndOptimizeRoute();

    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position position) {
      setState(() {
        currentPosition = position;
        _updateDriverMarker(position);
        _updateLiveRoute();
        _updateDistanceToNextLocation();
      });
    });

    liveRouteTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (currentPosition != null) {
        _updateLiveRoute();
        _updateDistanceToNextLocation();
      }
    });
  }

  void _findNearestLocationAndOptimizeRoute() {
    if (currentPosition == null || locations.isEmpty) return;

    List<LatLng> unvisitedLocations = List.from(locations);
    optimizedLocations = [];
    LatLng currentLoc =
        LatLng(currentPosition!.latitude, currentPosition!.longitude);

    while (unvisitedLocations.isNotEmpty) {
      int nearestIndex = 0;
      double nearestDistance = double.infinity;

      for (int i = 0; i < unvisitedLocations.length; i++) {
        double distance = Geolocator.distanceBetween(
          currentLoc.latitude,
          currentLoc.longitude,
          unvisitedLocations[i].latitude,
          unvisitedLocations[i].longitude,
        );

        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearestIndex = i;
        }
      }

      optimizedLocations.add(unvisitedLocations[nearestIndex]);
      currentLoc = unvisitedLocations[nearestIndex];
      unvisitedLocations.removeAt(nearestIndex);
    }

    _addMarkers();
    _getRoute();
    _updateLiveRoute();
  }

  void _updateDistanceToNextLocation() {
    if (currentPosition == null ||
        currentDestinationIndex >= optimizedLocations.length) return;

    nextLocationDistance = Geolocator.distanceBetween(
      currentPosition!.latitude,
      currentPosition!.longitude,
      optimizedLocations[currentDestinationIndex].latitude,
      optimizedLocations[currentDestinationIndex].longitude,
    );

    setState(() {
      currentDestinationText =
          'Next Stop: Location ${currentDestinationIndex + 1}\n'
          'Distance: ${(nextLocationDistance! / 1000).toStringAsFixed(2)} km';
    });
  }

  Future<void> _updateLiveRoute() async {
    if (currentPosition == null || optimizedLocations.isEmpty) return;

    liveRouteCoordinates.clear();

    PolylineResult result = await polylinePoints.getRouteBetweenCoordinates(
      googleApiKey: googleApiKey,
      request: PolylineRequest(
        origin:
            PointLatLng(currentPosition!.latitude, currentPosition!.longitude),
        destination: PointLatLng(
          optimizedLocations[currentDestinationIndex].latitude,
          optimizedLocations[currentDestinationIndex].longitude,
        ),
        mode: TravelMode.driving,
      ),
    );

    if (result.points.isNotEmpty) {
      for (var point in result.points) {
        liveRouteCoordinates.add(LatLng(point.latitude, point.longitude));
      }
    }

    final PolylineId liveRouteId = PolylineId('live_route');
    final Polyline liveRoute = Polyline(
      polylineId: liveRouteId,
      color: Colors.green,
      points: liveRouteCoordinates,
      width: 15,
    );

    setState(() {
      polylines[liveRouteId] = liveRoute;
    });
  }

  void _updateDriverMarker(Position position) {
    final MarkerId markerId = const MarkerId('driver');
    final marker = Marker(
      markerId: markerId,
      position: LatLng(position.latitude, position.longitude),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      infoWindow: const InfoWindow(title: 'Driver Location'),
      rotation: position.heading,
    );

    setState(() {
      markers[markerId] = marker;
    });
  }

  void _addMarkers() {
    for (int i = 0; i < optimizedLocations.length; i++) {
      final markerId = MarkerId(i.toString());
      final marker = Marker(
        markerId: markerId,
        position: optimizedLocations[i],
        icon: BitmapDescriptor.defaultMarker,
        infoWindow: InfoWindow(
          title: 'Location ${i + 1}',
          snippet: i == currentDestinationIndex ? 'Next Stop' : '',
        ),
      );
      markers[markerId] = marker;
    }
  }

  Future<void> _getRoute() async {
    polylineCoordinates.clear();

    for (int i = 0; i < optimizedLocations.length - 1; i++) {
      PolylineResult result = await polylinePoints.getRouteBetweenCoordinates(
        googleApiKey: googleApiKey,
        request: PolylineRequest(
          origin: PointLatLng(
              optimizedLocations[i].latitude, optimizedLocations[i].longitude),
          destination: PointLatLng(optimizedLocations[i + 1].latitude,
              optimizedLocations[i + 1].longitude),
          mode: TravelMode.driving,
        ),
      );

      if (result.points.isNotEmpty) {
        for (var point in result.points) {
          polylineCoordinates.add(LatLng(point.latitude, point.longitude));
        }
      }
    }

    final PolylineId id = PolylineId('route');
    final Polyline polyline = Polyline(
      polylineId: id,
      color: Colors.blue,
      points: polylineCoordinates,
      width: 3,
    );

    setState(() {
      polylines[id] = polyline;
    });
  }

  @override
  void dispose() {
    positionStream?.cancel();
    liveRouteTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Route Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: () {
              if (currentPosition != null) {
                mapController.animateCamera(
                  CameraUpdate.newLatLngZoom(
                    LatLng(
                        currentPosition!.latitude, currentPosition!.longitude),
                    15,
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _findNearestLocationAndOptimizeRoute();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: locations[0],
              zoom: 13,
            ),
            onMapCreated: (GoogleMapController controller) {
              mapController = controller;
            },
            markers: Set<Marker>.of(markers.values),
            polylines: Set<Polyline>.of(polylines.values),
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            mapType: MapType.normal,
            zoomGesturesEnabled: true,
            zoomControlsEnabled: true,
          ),
          if (currentDestinationText.isNotEmpty)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Card(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    currentDestinationText,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
