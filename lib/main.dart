import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'keys.dart';

void main() => runApp(const YelpAreaApp());

class YelpAreaApp extends StatelessWidget {
  const YelpAreaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yelp Area Explorer',
      theme: ThemeData(useMaterial3: true),
      home: const MapSearchScreen(),
    );
  }
}

class YelpBusiness {
  final String id;
  final String name;
  final double rating;
  final int reviewCount;
  final String? price;
  final String? imageUrl;
  final String? address1;
  final double lat;
  final double lng;

  YelpBusiness({
    required this.id,
    required this.name,
    required this.rating,
    required this.reviewCount,
    required this.lat,
    required this.lng,
    this.price,
    this.imageUrl,
    this.address1,
  });

  factory YelpBusiness.fromJson(Map<String, dynamic> json) {
    final coords = (json['coordinates'] as Map?)?.cast<String, dynamic>() ?? {};
    final loc = (json['location'] as Map?)?.cast<String, dynamic>() ?? {};
    final displayAddress = (loc['display_address'] as List?)?.cast<dynamic>();

    return YelpBusiness(
      id: (json['id'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      rating: ((json['rating'] ?? 0) as num).toDouble(),
      reviewCount: (json['review_count'] ?? 0) as int,
      price: json['price'] as String?,
      imageUrl: json['image_url'] as String?,
      address1: displayAddress != null && displayAddress.isNotEmpty
          ? displayAddress.first.toString()
          : (loc['address1'] as String?),
      lat: ((coords['latitude'] ?? 0) as num).toDouble(),
      lng: ((coords['longitude'] ?? 0) as num).toDouble(),
    );
  }
}

class YelpService {
  YelpService({required String apiKey})
      : _dio = Dio(
          BaseOptions(
            baseUrl: 'https://api.yelp.com/v3',
            headers: {'Authorization': 'Bearer $apiKey'},
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );

  final Dio _dio;

  Future<List<YelpBusiness>> search({
    required double latitude,
    required double longitude,
    required int radiusMeters,
    String categories = 'restaurants',
    String sortBy = 'best_match',
    int limit = 20,
    int offset = 0,
  }) async {
    final res = await _dio.get(
      '/businesses/search',
      queryParameters: {
        'latitude': latitude,
        'longitude': longitude,
        'radius': radiusMeters.clamp(100, 40000),
        'categories': categories,
        'sort_by': sortBy,
        'limit': limit.clamp(1, 50),
        'offset': offset,
      },
    );

    final data = (res.data as Map).cast<String, dynamic>();
    final businesses = (data['businesses'] as List).cast<dynamic>();

    return businesses
        .map((e) => YelpBusiness.fromJson((e as Map).cast<String, dynamic>()))
        .where((b) => b.lat != 0 && b.lng != 0)
        .toList();
  }
}

class MapSearchScreen extends StatefulWidget {
  const MapSearchScreen({super.key});

  @override
  State<MapSearchScreen> createState() => _MapSearchScreenState();
}

class _MapSearchScreenState extends State<MapSearchScreen> {
  late final YelpService _yelp;
  GoogleMapController? _map;

  CameraPosition _camera = const CameraPosition(
    target: LatLng(34.0584, -118.3090), // Koreatown-ish
    zoom: 13,
  );

  bool _loading = false;
  String _categories = 'restaurants';
  String _sortBy = 'best_match';

  List<YelpBusiness> _results = [];
  Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _yelp = YelpService(apiKey: Keys.yelpApiKey);
  }

  Future<void> _searchThisArea() async {
    if (Keys.yelpApiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missing Yelp key. Run with --dart-define=YELP_API_KEY=...')),
      );
      return;
    }
    final controller = _map;
    if (controller == null) return;

    setState(() => _loading = true);
    try {
      final bounds = await controller.getVisibleRegion();
      final center = _camera.target;

      final radius = (haversineMeters(
                center.latitude,
                center.longitude,
                bounds.northeast.latitude,
                bounds.northeast.longitude,
              ) *
              0.9)
          .round()
          .clamp(300, 40000);

      final businesses = await _yelp.search(
        latitude: center.latitude,
        longitude: center.longitude,
        radiusMeters: radius,
        categories: _categories,
        sortBy: _sortBy,
      );

      final markers = businesses.map((b) {
        return Marker(
          markerId: MarkerId(b.id),
          position: LatLng(b.lat, b.lng),
          infoWindow: InfoWindow(
            title: b.name,
            snippet: '${b.rating} ⭐ • ${b.reviewCount} reviews${b.price != null ? ' • ${b.price}' : ''}',
          ),
        );
      }).toSet();

      setState(() {
        _results = businesses;
        _markers = markers;
      });

      if (mounted) _showResultsSheet();
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yelp error: $code ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showResultsSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.55,
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: _results.length,
            separatorBuilder: (_, _) => const Divider(height: 16),
            itemBuilder: (_, i) {
              final b = _results[i];
              return ListTile(
                leading: b.imageUrl == null
                    ? const CircleAvatar(child: Icon(Icons.store))
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(b.imageUrl!, width: 56, height: 56, fit: BoxFit.cover),
                      ),
                title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${b.rating} ⭐ • ${b.reviewCount} reviews${b.price != null ? ' • ${b.price}' : ''}'
                  '${b.address1 != null ? '\n${b.address1}' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await _map?.animateCamera(
                    CameraUpdate.newLatLngZoom(LatLng(b.lat, b.lng), 15),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Yelp Area Explorer'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Sort',
            onSelected: (v) => setState(() => _sortBy = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'best_match', child: Text('Best match')),
              PopupMenuItem(value: 'rating', child: Text('Rating')),
              PopupMenuItem(value: 'review_count', child: Text('Review count')),
              PopupMenuItem(value: 'distance', child: Text('Distance')),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'Category',
            onSelected: (v) => setState(() => _categories = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'restaurants', child: Text('Restaurants')),
              PopupMenuItem(value: 'coffee', child: Text('Coffee')),
              PopupMenuItem(value: 'ramen', child: Text('Ramen')),
              PopupMenuItem(value: 'bars', child: Text('Bars')),
              PopupMenuItem(value: 'bakeries', child: Text('Bakeries')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: _camera,
            onMapCreated: (c) => _map = c,
            onCameraMove: (pos) => _camera = pos,
            markers: _markers,
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: FilledButton.icon(
              onPressed: _loading ? null : _searchThisArea,
              icon: _loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search),
              label: Text(_loading ? 'Searching...' : 'Search this area'),
            ),
          ),
        ],
      ),
    );
  }
}

int haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _deg2rad(lat2 - lat1);
  final dLon = _deg2rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_deg2rad(lat1)) *
          math.cos(_deg2rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return (r * c).round();
}

double _deg2rad(double deg) => deg * (math.pi / 180.0);