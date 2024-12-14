import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MaterialApp(home: RouteMapScreen()));
}

class PlaceSearchResult {
  final String placeId;
  final String description;
  final LatLng? location;

  PlaceSearchResult({
    required this.placeId,
    required this.description,
    this.location,
  });
}

class CustomSearchDelegate extends SearchDelegate<PlaceSearchResult?> {
  final String apiKey;
  Timer? _debounce;

  CustomSearchDelegate({required this.apiKey});

  Future<List<PlaceSearchResult>> _getPlaceSuggestions(String query) async {
    if (query.isEmpty) return [];

    final url =
        Uri.parse('https://maps.googleapis.com/maps/api/place/autocomplete/json'
            '?input=$query'
            '&key=$apiKey');

    final response = await http.get(url);
    final data = json.decode(response.body);

    if (data['status'] == 'OK') {
      return (data['predictions'] as List).map((prediction) {
        return PlaceSearchResult(
          placeId: prediction['place_id'],
          description: prediction['description'],
        );
      }).toList();
    }
    return [];
  }

  Future<LatLng?> _getPlaceDetails(String placeId) async {
    final url =
        Uri.parse('https://maps.googleapis.com/maps/api/place/details/json'
            '?place_id=$placeId'
            '&fields=geometry'
            '&key=$apiKey');

    final response = await http.get(url);
    final data = json.decode(response.body);

    if (data['status'] == 'OK') {
      final location = data['result']['geometry']['location'];
      return LatLng(location['lat'], location['lng']);
    }
    return null;
  }

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
        },
      ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () {
        close(context, null);
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return Container();
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (_debounce?.isActive ?? false) _debounce?.cancel();

    return FutureBuilder<List<PlaceSearchResult>>(
      future: _getPlaceSuggestions(query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No results found'));
        }

        return ListView.builder(
          itemCount: snapshot.data!.length,
          itemBuilder: (context, index) {
            final place = snapshot.data![index];
            return ListTile(
              title: Text(place.description),
              onTap: () async {
                final location = await _getPlaceDetails(place.placeId);
                if (location != null) {
                  close(
                      context,
                      PlaceSearchResult(
                        placeId: place.placeId,
                        description: place.description,
                        location: location,
                      ));
                }
              },
            );
          },
        );
      },
    );
  }
}

class RouteMapScreen extends StatefulWidget {
  const RouteMapScreen({Key? key}) : super(key: key);

  @override
  State<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends State<RouteMapScreen> {
  late GoogleMapController mapController;
  final String googleApiKey = "AIzaSyCi5g39Fzethf0tfwn3WesaeRAHOcrGVOQ";

  List<LatLng> locations = [
    const LatLng(9.898527, 76.7001913),
    const LatLng(9.888103, 76.7046459),
    const LatLng(9.9097024, 76.6984963),
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

  void _showPlaceSearch() async {
    final result = await showSearch<PlaceSearchResult?>(
      context: context,
      delegate: CustomSearchDelegate(apiKey: googleApiKey),
    );

    if (result != null && result.location != null) {
      setState(() {
        locations.add(result.location!);
        _findNearestLocationAndOptimizeRoute();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added: ${result.description}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
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
    markers.clear();
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

    if (currentPosition != null) {
      _updateDriverMarker(currentPosition!);
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
    mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Route Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _showPlaceSearch,
          ),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        currentDestinationText,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Total Locations: ${locations.length}',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showPlaceSearch,
        child: const Icon(Icons.add_location),
        tooltip: 'Add Location',
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }
}
