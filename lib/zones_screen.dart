import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'proximity_service.dart';
import 'package:h3_flutter/h3_flutter.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlong;

// ─────────────────────────────────────────────────────────────────────────────
// Zone configuration — one instance per zone type
// ─────────────────────────────────────────────────────────────────────────────

class _ZoneConfig {
  const _ZoneConfig({
    required this.table,
    required this.profileColumn,
    required this.accent,
    required this.typeLabel,
    required this.description,
    required this.icon,
  });

  final String table;
  final String profileColumn;
  final Color accent;
  final String typeLabel;
  final String description;
  final IconData icon;
}

const _safeConfig = _ZoneConfig(
  table: 'safe_zones',
  profileColumn: 'is_in_safe_zone',
  accent: Color(0xFF4DD0E1),
  typeLabel: 'Safe Zone',
  description:
      'Safe Zones are places like home or office where you become invisible to friends.',
  icon: Icons.shield,
);

const _silentConfig = _ZoneConfig(
  table: 'silent_zones',
  profileColumn: 'is_in_silent_zone',
  accent: Color(0xFF5B9BD5),
  typeLabel: 'Silent Zone',
  description:
      'Silent Zones mute all pings in both directions — you stay visible on the map, just no notifications.',
  icon: Icons.notifications_off,
);

// ─────────────────────────────────────────────────────────────────────────────
// Combined zones screen with Safe / Silent tabs
// ─────────────────────────────────────────────────────────────────────────────

class SafeZonesScreen extends StatefulWidget {
  const SafeZonesScreen({super.key});

  @override
  State<SafeZonesScreen> createState() => _SafeZonesScreenState();
}

class _SafeZonesScreenState extends State<SafeZonesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'zones.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(text: 'Safe Zones'),
            Tab(text: 'Silent Zones'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _ZoneTabView(config: _safeConfig),
          _ZoneTabView(config: _silentConfig),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab content: list + add/delete for one zone type
// ─────────────────────────────────────────────────────────────────────────────

class _ZoneTabView extends StatefulWidget {
  const _ZoneTabView({required this.config});
  final _ZoneConfig config;

  @override
  State<_ZoneTabView> createState() => _ZoneTabViewState();
}

class _ZoneTabViewState extends State<_ZoneTabView>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _zones = [];
  bool _isLoading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  Future<void> _loadZones() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final resp = await Supabase.instance.client
          .from(widget.config.table)
          .select('id, name, h3_index_res9, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      if (mounted) {
        setState(() {
          _zones = resp.cast<Map<String, dynamic>>();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[${widget.config.table}] Error loading: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading: $e')));
      }
    }
  }

  Future<void> _addZone() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => _AddZoneScreen(config: widget.config)),
    );

    if (result == null || !mounted) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final h3Indices = result['h3_indices'] as List<String>;
      await Supabase.instance.client.from(widget.config.table).insert({
        'user_id': userId,
        'name': result['name'],
        'h3_index_res9': h3Indices.join(','),
      });

      await _reevaluateStatus();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${widget.config.typeLabel} with ${h3Indices.length} '
              '${h3Indices.length == 1 ? "field" : "fields"} added! ✓',
            ),
          ),
        );
        _loadZones();
      }
    } catch (e) {
      debugPrint('[${widget.config.table}] Error adding: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error adding: $e')));
      }
    }
  }

  /// After a create or delete, re-check whether the current hex is still
  /// inside any remaining zone and update the cached profile flag.
  Future<void> _reevaluateStatus() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final profileResp = await Supabase.instance.client
          .from('profiles')
          .select('last_h3_index_res9')
          .eq('id', userId)
          .single();
      final remaining = await Supabase.instance.client
          .from(widget.config.table)
          .select('h3_index_res9')
          .eq('user_id', userId);

      final currentHex = profileResp['last_h3_index_res9'] as String?;
      bool isInZone = false;
      if (currentHex != null) {
        for (final zone in remaining) {
          final hexes = (zone['h3_index_res9'] as String).split(',');
          if (hexes.contains(currentHex)) {
            isInZone = true;
            break;
          }
        }
      }

      await Supabase.instance.client
          .from('profiles')
          .update({widget.config.profileColumn: isInZone})
          .eq('id', userId);

      if (widget.config.table == 'silent_zones') {
        ProximityService.instance.updateSilentZoneStatus(isInZone);
      }

      debugPrint(
        '[${widget.config.table}] Re-evaluated ${widget.config.profileColumn}=$isInZone',
      );
    } catch (e) {
      debugPrint('[${widget.config.table}] Error re-evaluating status: $e');
    }
  }

  Future<void> _deleteZone(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          'Delete ${widget.config.typeLabel}?',
          style: const TextStyle(color: Colors.white),
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

    if (confirmed != true) return;

    try {
      await Supabase.instance.client
          .from(widget.config.table)
          .delete()
          .eq('id', id);
      await _reevaluateStatus();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.config.typeLabel} deleted')),
        );
        _loadZones();
      }
    } catch (e) {
      debugPrint('[${widget.config.table}] Error deleting: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final accent = widget.config.accent;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // Info banner
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.1),
              border: Border.all(color: accent.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.config.description,
                    style: TextStyle(color: accent, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),

          // Zone list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _zones.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          widget.config.icon,
                          size: 64,
                          color: Colors.grey[700],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No ${widget.config.typeLabel}s yet',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tap + to add one',
                          style: TextStyle(
                            color: Colors.grey[700],
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _zones.length,
                    itemBuilder: (context, index) {
                      final zone = _zones[index];
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
                          leading: CircleAvatar(
                            backgroundColor: accent,
                            child: Icon(
                              widget.config.icon,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '$fieldCount ${fieldCount == 1 ? "field" : "fields"}',
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
                            onPressed: () => _deleteZone(id, name),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addZone,
        backgroundColor: accent,
        foregroundColor: Colors.black87,
        icon: const Icon(Icons.add),
        label: Text('Add ${widget.config.typeLabel}'),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Map screen: select H3 hexagons and name the zone
// ─────────────────────────────────────────────────────────────────────────────

class _AddZoneScreen extends StatefulWidget {
  const _AddZoneScreen({required this.config});
  final _ZoneConfig config;

  @override
  State<_AddZoneScreen> createState() => _AddZoneScreenState();
}

class _AddZoneScreenState extends State<_AddZoneScreen> {
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
      ).showSnackBar(SnackBar(content: Text('H3 error: $e')));
    }
  }

  void _save() {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter a name')));
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
    final accent = widget.config.accent;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Select ${widget.config.typeLabel}'),
        backgroundColor: Colors.black,
      ),
      body: Column(
        children: [
          // Name input
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

          // Info hint
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
                  initialCenter: const latlong.LatLng(52.5200, 13.4050),
                  initialZoom: 15,
                  minZoom: 10,
                  maxZoom: 18,
                  onTap: (_, point) => _onMapTap(point),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                    subdomains: const ['a', 'b', 'c'],
                    userAgentPackageName: 'com.example.hang',
                  ),
                  if (_hexagonPolygons.isNotEmpty)
                    PolygonLayer(
                      polygons: _hexagonPolygons.entries.map((entry) {
                        return Polygon(
                          points: entry.value,
                          color: accent.withValues(alpha: 0.4),
                          borderColor: accent,
                          borderStrokeWidth: 3,
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),

          // Selection count
          if (_selectedH3Indices.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: accent.withValues(alpha: 0.1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_selectedH3Indices.length} ${_selectedH3Indices.length == 1 ? "field" : "fields"} selected',
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap a field again to remove it',
                    style: TextStyle(
                      color: accent.withValues(alpha: 0.7),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

          // Save button
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.black87,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(
                  'Save ${widget.config.typeLabel}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
