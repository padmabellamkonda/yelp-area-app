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
    int limit = 50,
    int offset = 0,
  }) async {
    final res = await _dio.get(
      '/businesses/search',
      queryParameters: {
        'latitude': latitude,
        'longitude': longitude,
        // Yelp radius hard-cap: 40000
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

  // ✅ Coverage tuning
  int _gridSize = 3; // 2..5
  int _cellRadiusMeters = 12000; // will clamp to Yelp max 40000 inside service
  double _coveragePadding = 0.35; // expands visible bounds by 35% (0.0..0.8)
  int _heatRadiusPx = 40; // 10..50 (hard library constraint)
  bool _showMarkers = false;

  // ✅ Anti-429 throttling
  int _maxConcurrent = 3; // 1..4
  int _delayBetweenCallsMs = 250; // 0..800 (adds spacing between calls)

  List<YelpBusiness> _results = [];
  Set<Marker> _markers = {};
  Set<Heatmap> _heatmaps = {};

  @override
  void initState() {
    super.initState();
    _yelp = YelpService(apiKey: Keys.yelpApiKey);
  }

  Future<void> _searchThisArea() async {
    if (Keys.yelpApiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Missing Yelp key. Run with --dart-define=YELP_API_KEY=...'),
        ),
      );
      return;
    }

    final controller = _map;
    if (controller == null) return;

    setState(() => _loading = true);

    try {
      final visible = await controller.getVisibleRegion();

      // ✅ Expand the visible region to “check a larger radius”
      final padded = _expandBounds(visible, paddingFrac: _coveragePadding);

      // ✅ Grid centers inside the padded region
      final gridCenters = _gridPoints(padded, _gridSize);

      // ✅ Run requests in small batches to reduce 429 risk
      final resultsLists = await _runBatched< List<YelpBusiness> >(
        items: gridCenters,
        maxConcurrent: _maxConcurrent.clamp(1, 6),
        delayBetweenMs: _delayBetweenCallsMs.clamp(0, 2000),
        task: (p) => _yelp.search(
          latitude: p.latitude,
          longitude: p.longitude,
          radiusMeters: _cellRadiusMeters,
          categories: _categories,
          sortBy: _sortBy,
          limit: 50,
        ),
      );

      // ✅ De-dupe by business id
      final byId = <String, YelpBusiness>{};
      for (final list in resultsLists) {
        for (final b in list) {
          byId[b.id] = b;
        }
      }
      final businesses = byId.values.toList();

      final markers = businesses.map((b) {
        return Marker(
          markerId: MarkerId(b.id),
          position: LatLng(b.lat, b.lng),
          infoWindow: InfoWindow(
            title: b.name,
            snippet:
                '${b.rating} ⭐ • ${b.reviewCount} reviews${b.price != null ? ' • ${b.price}' : ''}',
          ),
        );
      }).toSet();

      // ✅ Heat points w/ weights (reviews drive intensity)
      final heatPoints = businesses.map((b) {
        final weight = 1.0 + (b.reviewCount / 600.0).clamp(0.0, 2.5);
        return WeightedLatLng(LatLng(b.lat, b.lng), weight: weight);
      }).toList();

      debugPrint(
        'Visible padded by ${(_coveragePadding * 100).round()}% | '
        'Grid: ${_gridSize}x$_gridSize=${gridCenters.length} calls | '
        'cellRadius=$_cellRadiusMeters m | '
        'Businesses: ${businesses.length} | heatPoints: ${heatPoints.length}',
      );

      final heatmap = Heatmap(
        heatmapId: const HeatmapId('yelp_heat'),
        data: heatPoints,
        radius: HeatmapRadius.fromPixels(_heatRadiusPx.clamp(10, 50)),
        opacity: 0.9,
        dissipating: true,
      );

      setState(() {
        _results = businesses;
        _markers = _showMarkers ? markers : <Marker>{};
        _heatmaps = {heatmap};
      });

      if (mounted) _showResultsSheet();
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yelp error: $code ${e.message}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search error: $e')),
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
                        child: Image.network(
                          b.imageUrl!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
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

  void _openHeatmapControls() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Heatmap Controls',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      const Expanded(child: Text('Grid (coverage/detail)')),
                      DropdownButton<int>(
                        value: _gridSize,
                        items: const [
                          DropdownMenuItem(value: 2, child: Text('2×2 (4 calls)')),
                          DropdownMenuItem(value: 3, child: Text('3×3 (9 calls)')),
                          DropdownMenuItem(value: 4, child: Text('4×4 (16 calls)')),
                          DropdownMenuItem(value: 5, child: Text('5×5 (25 calls)')),
                        ],
                        onChanged: _loading ? null : (v) => setState(() => _gridSize = v ?? 3),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  Text('Expand area beyond screen: ${(_coveragePadding * 100).round()}%'),
                  Slider(
                    value: _coveragePadding,
                    min: 0.0,
                    max: 0.8,
                    divisions: 8,
                    label: '${(_coveragePadding * 100).round()}%',
                    onChanged: _loading ? null : (v) => setState(() => _coveragePadding = v),
                  ),

                  const SizedBox(height: 8),

                  Text('Yelp search radius per grid point: $_cellRadiusMeters m (max effective 40000)'),
                  Slider(
                    value: _cellRadiusMeters.toDouble(),
                    min: 4000,
                    max: 40000,
                    divisions: 9,
                    label: '$_cellRadiusMeters m',
                    onChanged: _loading ? null : (v) => setState(() => _cellRadiusMeters = v.round()),
                  ),

                  const SizedBox(height: 8),

                  Text('Heatmap blur radius: $_heatRadiusPx px (10–50)'),
                  Slider(
                    value: _heatRadiusPx.toDouble(),
                    min: 10,
                    max: 50,
                    divisions: 8,
                    label: '$_heatRadiusPx px',
                    onChanged: _loading ? null : (v) => setState(() => _heatRadiusPx = v.round()),
                  ),

                  const SizedBox(height: 8),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show markers (slower)'),
                    value: _showMarkers,
                    onChanged: _loading ? null : (v) => setState(() => _showMarkers = v),
                  ),

                  const SizedBox(height: 8),
                  const Divider(),

                  const SizedBox(height: 8),
                  const Text(
                    'Anti-429 throttling',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),

                  Row(
                    children: [
                      const Expanded(child: Text('Max concurrent requests')),
                      DropdownButton<int>(
                        value: _maxConcurrent,
                        items: const [
                          DropdownMenuItem(value: 1, child: Text('1 (safest)')),
                          DropdownMenuItem(value: 2, child: Text('2')),
                          DropdownMenuItem(value: 3, child: Text('3')),
                          DropdownMenuItem(value: 4, child: Text('4 (riskier)')),
                        ],
                        onChanged: _loading ? null : (v) => setState(() => _maxConcurrent = v ?? 3),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  Text('Delay between calls: $_delayBetweenCallsMs ms'),
                  Slider(
                    value: _delayBetweenCallsMs.toDouble(),
                    min: 0,
                    max: 800,
                    divisions: 8,
                    label: '$_delayBetweenCallsMs ms',
                    onChanged: _loading ? null : (v) => setState(() => _delayBetweenCallsMs = v.round()),
                  ),

                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _loading
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  _searchThisArea();
                                },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Re-run search'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Yelp Area Explorer'),
        actions: [
          IconButton(
            tooltip: 'Heatmap controls',
            onPressed: _openHeatmapControls,
            icon: const Icon(Icons.tune),
          ),
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
            heatmaps: _heatmaps,
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: FilledButton.icon(
              onPressed: _loading ? null : _searchThisArea,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: Text(_loading ? 'Searching...' : 'Search this area'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Expand bounds by a fraction of its size.
/// paddingFrac=0.35 means add 35% extra in each direction.
LatLngBounds _expandBounds(LatLngBounds b, {required double paddingFrac}) {
  final south = b.southwest.latitude;
  final west = b.southwest.longitude;
  final north = b.northeast.latitude;
  final east = b.northeast.longitude;

  final latSpan = (north - south).abs();
  final lngSpan = (east - west).abs();

  final padLat = latSpan * paddingFrac;
  final padLng = lngSpan * paddingFrac;

  double clampLat(double v) => v.clamp(-85.0, 85.0);
  double clampLng(double v) => v.clamp(-179.999999, 179.999999);

  return LatLngBounds(
    southwest: LatLng(clampLat(south - padLat), clampLng(west - padLng)),
    northeast: LatLng(clampLat(north + padLat), clampLng(east + padLng)),
  );
}

/// Create grid points inside the visible region.
/// grid=3 => 3x3 => 9 calls
List<LatLng> _gridPoints(LatLngBounds b, int grid) {
  final south = b.southwest.latitude;
  final west = b.southwest.longitude;
  final north = b.northeast.latitude;
  final east = b.northeast.longitude;

  double lerp(double a, double c, double t) => a + (c - a) * t;

  final pts = <LatLng>[];
  for (int y = 0; y < grid; y++) {
    final ty = (y + 0.5) / grid;
    final lat = lerp(south, north, ty);

    for (int x = 0; x < grid; x++) {
      final tx = (x + 0.5) / grid;
      final lng = lerp(west, east, tx);
      pts.add(LatLng(lat, lng));
    }
  }
  return pts;
}

/// Run async tasks in small concurrent batches (simple throttling).
Future<List<R>> _runBatched<R>({
  required List<LatLng> items,
  required int maxConcurrent,
  required int delayBetweenMs,
  required Future<R> Function(LatLng item) task,
}) async {
  final results = <R>[];

  for (int i = 0; i < items.length; i += maxConcurrent) {
    final chunk = items.skip(i).take(maxConcurrent).toList();

    // optional spacing between batches
    if (delayBetweenMs > 0 && i != 0) {
      await Future.delayed(Duration(milliseconds: delayBetweenMs));
    }

    final chunkResults = await Future.wait(chunk.map(task));
    results.addAll(chunkResults);
  }

  return results;
}

// (kept from your original, still useful if you want it later)
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