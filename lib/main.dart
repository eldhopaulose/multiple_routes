import 'dart:async';
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

  // List of locations
  final List<LatLng> locations = [
    const LatLng(9.898527, 76.7001913),
    const LatLng(9.888103, 76.7046459),
    const LatLng(9.9097024, 76.6984963),
  ];

  Map<MarkerId, Marker> markers = {};
  Map<PolylineId, Polyline> polylines = {};
  List<LatLng> polylineCoordinates = [];
  List<LatLng> liveRouteCoordinates = []; // For live route
  PolylinePoints polylinePoints = PolylinePoints();

  // Driver location tracking
  StreamSubscription<Position>? positionStream;
  Marker? driverMarker;
  Position? currentPosition;
  Timer? liveRouteTimer;

  @override
  void initState() {
    super.initState();
    _initializeLocation();
    _addMarkers();
    _getRoute();
  }

  Future<void> _initializeLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return;
    }

    // Get initial position
    currentPosition = await Geolocator.getCurrentPosition();
    _updateDriverMarker(currentPosition!);
    _updateLiveRoute(); // Get initial live route

    // Start listening to location updates
    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position position) {
      setState(() {
        currentPosition = position;
        _updateDriverMarker(position);
        _updateLiveRoute(); // Update live route when location changes
      });
    });

    // Update live route periodically
    liveRouteTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (currentPosition != null) {
        _updateLiveRoute();
      }
    });
  }

  Future<void> _updateLiveRoute() async {
    if (currentPosition == null) return;

    liveRouteCoordinates.clear();

    // Get route from current position to first location
    PolylineResult result = await polylinePoints.getRouteBetweenCoordinates(
      googleApiKey: googleApiKey,
      request: PolylineRequest(
        origin:
            PointLatLng(currentPosition!.latitude, currentPosition!.longitude),
        destination: PointLatLng(locations[0].latitude, locations[0].longitude),
        mode: TravelMode.driving,
      ),
    );

    if (result.points.isNotEmpty) {
      for (var point in result.points) {
        liveRouteCoordinates.add(LatLng(point.latitude, point.longitude));
      }
    }

    // Add live route polyline
    final PolylineId liveRouteId = PolylineId('live_route');
    final Polyline liveRoute = Polyline(
      polylineId: liveRouteId,
      color: Colors.green,
      points: liveRouteCoordinates,
      width: 5,
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
    for (int i = 0; i < locations.length; i++) {
      final markerId = MarkerId(i.toString());
      final marker = Marker(
        markerId: markerId,
        position: locations[i],
        icon: BitmapDescriptor.defaultMarker,
        infoWindow: InfoWindow(title: 'Location ${i + 1}'),
      );
      markers[markerId] = marker;
    }
  }

  Future<void> _getRoute() async {
    for (int i = 0; i < locations.length - 1; i++) {
      PolylineResult result = await polylinePoints.getRouteBetweenCoordinates(
        googleApiKey: googleApiKey,
        request: PolylineRequest(
          origin: PointLatLng(locations[i].latitude, locations[i].longitude),
          destination: PointLatLng(
              locations[i + 1].latitude, locations[i + 1].longitude),
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
            onPressed: _updateLiveRoute,
          ),
        ],
      ),
      body: GoogleMap(
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
    );
  }
}
