import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:h3_flutter/h3_flutter.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlong;

class SafeZonesScreen extends StatefulWidget {
  const SafeZonesScreen({super.key});

  @override
  State<SafeZonesScreen> createState() => _SafeZonesScreenState();
}

class _SafeZonesScreenState extends State<SafeZonesScreen> {
  List<Map<String, dynamic>> _safeZones = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSafeZones();
  }

  Future<void> _loadSafeZones() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final resp = await Supabase.instance.client
          .from('safe_zones')
          .select('id, name, h3_index_res9, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      if (mounted) {
        setState(() {
          _safeZones = resp.cast<Map<String, dynamic>>();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[safe_zones] Error loading: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Fehler beim Laden: $e')));
      }
    }
  }

  Future<void> _addSafeZone() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (context) => const _AddSafeZoneScreen()),
    );

    if (result != null && mounted) {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      try {
        // Join multiple H3 indices with comma
        final h3Indices = result['h3_indices'] as List<String>;
        final h3IndexStr = h3Indices.join(',');

        await Supabase.instance.client.from('safe_zones').insert({
          'user_id': userId,
          'name': result['name'],
          'h3_index_res9': h3IndexStr,
        });

        await _reevaluateSafeZoneStatus();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Safe Zone with ${h3Indices.length} ${h3Indices.length == 1 ? "field" : "fields"} added! ✓',
              ),
            ),
          );
          _loadSafeZones();
        }
      } catch (e) {
        debugPrint('[safe_zones] Error adding: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error adding: $e')));
        }
      }
    }
  }

  /// After deleting a safe zone, re-check whether the user's current hex is
  /// still inside any *remaining* zone and patch profiles.is_in_safe_zone.
  Future<void> _reevaluateSafeZoneStatus() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      // Fetch current hex and remaining safe zones sequentially (different return types).
      final profileResp = await Supabase.instance.client
          .from('profiles')
          .select('last_h3_index_res9')
          .eq('id', userId)
          .single();
      final remainingZones = await Supabase.instance.client
          .from('safe_zones')
          .select('h3_index_res9')
          .eq('user_id', userId);

      final currentHex = profileResp['last_h3_index_res9'] as String?;

      bool isInSafeZone = false;
      if (currentHex != null) {
        for (final zone in remainingZones) {
          final hexes = (zone['h3_index_res9'] as String).split(',');
          if (hexes.contains(currentHex)) {
            isInSafeZone = true;
            break;
          }
        }
      }

      await Supabase.instance.client
          .from('profiles')
          .update({'is_in_safe_zone': isInSafeZone})
          .eq('id', userId);

      debugPrint('[safe_zones] Re-evaluated is_in_safe_zone=$isInSafeZone');
    } catch (e) {
      debugPrint('[safe_zones] Error re-evaluating safe zone status: $e');
    }
  }

  Future<void> _deleteSafeZone(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'Delete Safe Zone?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Do you really want to delete "$name"?',
          style: const TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await Supabase.instance.client.from('safe_zones').delete().eq('id', id);
        await _reevaluateSafeZoneStatus();

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Safe Zone deleted')));
          _loadSafeZones();
        }
      } catch (e) {
        debugPrint('[safe_zones] Error deleting: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error deleting: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'safe zones.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: Column(
        children: [
          // Info Banner
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF4DD0E1).withValues(alpha: 0.1),
              border: Border.all(
                color: const Color(0xFF4DD0E1).withValues(alpha: 0.3),
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Color(0xFF4DD0E1)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Safe Zones are places like home, office or gym where you don\'t want to be visible to friends.',
                    style: TextStyle(
                      color: const Color(0xFF4DD0E1),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // List of Safe Zones
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _safeZones.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 64,
                          color: Colors.grey[700],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Noch keine Safe Zones',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Add a Safe Zone',
                          style: TextStyle(
                            color: Colors.grey[700],
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _safeZones.length,
                    itemBuilder: (context, index) {
                      final zone = _safeZones[index];
                      final name = zone['name'] as String;
                      final h3Index = zone['h3_index_res9'] as String;
                      final id = zone['id'] as String;
                      final fieldCount = h3Index.split(',').length;

                      return Card(
                        color: Colors.grey[900],
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Color(0xFF4DD0E1),
                            child: Icon(Icons.shield, color: Colors.white),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '$fieldCount ${fieldCount == 1 ? "Feld" : "Felder"}',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () => _deleteSafeZone(id, name),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addSafeZone,
        backgroundColor: const Color(0xFF4DD0E1),
        foregroundColor: Colors.black87,
        icon: const Icon(Icons.add),
        label: const Text('Add Safe Zone'),
      ),
    );
  }
}

class _AddSafeZoneScreen extends StatefulWidget {
  const _AddSafeZoneScreen();

  @override
  State<_AddSafeZoneScreen> createState() => _AddSafeZoneScreenState();
}

class _AddSafeZoneScreenState extends State<_AddSafeZoneScreen> {
  final _nameController = TextEditingController();
  final MapController _mapController = MapController();
  H3? _h3;
  final Set<String> _selectedH3Indices = {};
  final Map<String, List<latlong.LatLng>> _hexagonPolygons = {};

  @override
  void initState() {
    super.initState();
    try {
      _h3 = H3Factory().load();
    } catch (e) {
      debugPrint('[h3] Error loading: $e');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _onMapTap(latlong.LatLng position) {
    if (_h3 == null) return;

    try {
      final h3Index = _h3!.geoToCell(
        GeoCoord(lat: position.latitude, lon: position.longitude),
        9,
      );
      final indexStr = h3Index.toRadixString(16);
      final boundary = _h3!.cellToBoundary(h3Index);
      final points = boundary
          .map((coord) => latlong.LatLng(coord.lat, coord.lon))
          .toList();

      setState(() {
        // Toggle: remove if already selected, add if new
        if (_selectedH3Indices.contains(indexStr)) {
          _selectedH3Indices.remove(indexStr);
          _hexagonPolygons.remove(indexStr);
        } else {
          _selectedH3Indices.add(indexStr);
          _hexagonPolygons[indexStr] = points;
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Fehler bei H3-Berechnung: $e')));
    }
  }

  void _save() {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte einen Namen eingeben')),
      );
      return;
    }

    if (_selectedH3Indices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one field')),
      );
      return;
    }

    Navigator.pop(context, {
      'name': _nameController.text.trim(),
      'h3_indices': _selectedH3Indices.toList(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Select Safe Zone'),
        backgroundColor: Colors.black,
      ),
      body: Column(
        children: [
          // Name Input
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Name (e.g. Home, Office, Gym)',
                labelStyle: const TextStyle(color: Colors.grey),
                filled: true,
                fillColor: Colors.grey[900],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Info
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tap on the map to select fields (multiple possible)',
                      style: TextStyle(color: Colors.blue[200], fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Map
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: const latlong.LatLng(
                    52.5200,
                    13.4050,
                  ), // Berlin
                  initialZoom: 15,
                  minZoom: 10,
                  maxZoom: 18,
                  onTap: (tapPosition, point) => _onMapTap(point),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                    subdomains: const ['a', 'b', 'c'],
                    userAgentPackageName: 'com.example.hang',
                  ),
                  // Selected H3 Hexagons
                  if (_hexagonPolygons.isNotEmpty)
                    PolygonLayer(
                      polygons: _hexagonPolygons.entries.map((entry) {
                        return Polygon(
                          points: entry.value,
                          color: const Color(0xFF4DD0E1).withValues(alpha: 0.4),
                          borderColor: const Color(0xFF4DD0E1),
                          borderStrokeWidth: 3,
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),

          // Selected H3 Info
          if (_selectedH3Indices.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF4DD0E1).withValues(alpha: 0.1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_selectedH3Indices.length} ${_selectedH3Indices.length == 1 ? "field" : "fields"} selected',
                    style: const TextStyle(
                      color: Color(0xFF4DD0E1),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap a field again to remove it',
                    style: const TextStyle(
                      color: Color(0xFF80DEEA),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

          // Save Button
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4DD0E1),
                  foregroundColor: Colors.black87,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text(
                  'Save Safe Zone',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
