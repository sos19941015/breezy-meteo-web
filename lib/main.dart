import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const WeatherApp());
}

class WeatherApp extends StatelessWidget {
  const WeatherApp({super.key, this.autoLocate = true});

  final bool autoLocate;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Open-Meteo Weather',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8AB4F8),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Segoe UI',
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFF1F2430).withValues(alpha: 0.82),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF2A3140).withValues(alpha: 0.9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF8AB4F8), width: 1.4),
          ),
        ),
        chipTheme: ChipThemeData(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
          backgroundColor: const Color(0xFF2A3140).withValues(alpha: 0.8),
          selectedColor: const Color(0xFFFFD54F),
          labelStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      home: WeatherHomePage(autoLocate: autoLocate),
    );
  }
}

class WeatherHomePage extends StatefulWidget {
  const WeatherHomePage({super.key, this.autoLocate = true});

  final bool autoLocate;

  @override
  State<WeatherHomePage> createState() => _WeatherHomePageState();
}

class _WeatherHomePageState extends State<WeatherHomePage> {
  static const String _favoritesKey = 'favorite_locations_v1';

  final TextEditingController _searchController =
      TextEditingController(text: 'Taipei');

  bool _loading = false;
  bool _isSearching = false;
  String _status = 'Type a city and search.';
  List<GeoLocation> _searchResults = <GeoLocation>[];

  GeoLocation? _selectedLocation;
  ForecastData? _forecast;
  List<GeoLocation> _favorites = <GeoLocation>[];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _loadFavorites();
    if (widget.autoLocate) {
      await _bootstrapLocation();
    }
  }

  Future<void> _loadFavorites() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_favoritesKey);
      if (raw == null || raw.isEmpty) {
        return;
      }
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      setState(() {
        _favorites = list
            .map((dynamic e) =>
                GeoLocation.fromStorage(e as Map<String, dynamic>))
            .toList();
      });
    } catch (_) {
      // Ignore malformed local storage.
    }
  }

  Future<void> _saveFavorites() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String raw =
        jsonEncode(_favorites.map((GeoLocation e) => e.toStorage()).toList());
    await prefs.setString(_favoritesKey, raw);
  }

  bool _isFavorite(GeoLocation? loc) {
    if (loc == null) {
      return false;
    }
    return _favorites.any((GeoLocation f) => f.isSamePlace(loc));
  }

  Future<void> _toggleFavorite() async {
    final GeoLocation? loc = _selectedLocation;
    if (loc == null) {
      return;
    }

    setState(() {
      if (_isFavorite(loc)) {
        _favorites =
            _favorites.where((GeoLocation f) => !f.isSamePlace(loc)).toList();
      } else {
        _favorites = <GeoLocation>[..._favorites, loc];
      }
    });
    await _saveFavorites();
  }

  Future<void> _removeFavorite(GeoLocation loc) async {
    setState(() {
      _favorites =
          _favorites.where((GeoLocation f) => !f.isSamePlace(loc)).toList();
    });
    await _saveFavorites();
  }

  Future<void> _searchCity(String query, {bool autoLoadFirst = false}) async {
    final String q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _status = 'Please enter a city name.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = 'Searching "$q"...';
      _searchResults = <GeoLocation>[];
    });

    try {
      final Uri url =
          Uri.https('nominatim.openstreetmap.org', '/search', <String, String>{
        'q': q,
        'format': 'json',
        'addressdetails': '1',
        'accept-language': 'en',
        'limit': '5',
      });

      final http.Response response =
          await http.get(url, headers: const <String, String>{
        'User-Agent': 'OpenMeteoFlutterWeb/1.0',
      });
      if (response.statusCode != 200) {
        throw Exception('Search failed (${response.statusCode})');
      }

      final List<dynamic> rawResults =
          jsonDecode(response.body) as List<dynamic>;
      final List<GeoLocation> parsed = _parseNominatimLocations(rawResults);

      setState(() {
        _searchResults = parsed;
        _status = parsed.isEmpty
            ? 'No result found.'
            : 'Found ${parsed.length} location(s).';
      });

      if (autoLoadFirst && parsed.isNotEmpty) {
        await _loadWeather(parsed.first);
      }
    } catch (error) {
      setState(() {
        _status = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _bootstrapLocation() async {
    setState(() {
      _status = 'Locating with GPS...';
      _loading = true;
    });

    try {
      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final String name =
          await _reverseGeocode(position.latitude, position.longitude) ??
              'Current location';
      await _loadWeather(
        GeoLocation(
          name: name,
          latitude: position.latitude,
          longitude: position.longitude,
          country: '',
          admin1: null,
        ),
      );
      return;
    } catch (_) {
      // Continue with IP fallback.
    }

    setState(() {
      _status = 'GPS unavailable, trying IP location...';
    });

    final String? ipCity = await _fetchCityByIp();
    if (ipCity != null && ipCity.isNotEmpty) {
      final GeoLocation? cityLocation = await _geocodeFirstCity(ipCity);
      if (cityLocation != null) {
        await _loadWeather(cityLocation);
        return;
      }
    }

    await _loadWeather(
      GeoLocation(
        name: 'Taipei',
        latitude: 25.0330,
        longitude: 121.5654,
        country: 'Taiwan',
        admin1: null,
      ),
    );
  }

  Future<String?> _fetchCityByIp() async {
    try {
      final Uri url = Uri.parse('https://ipapi.co/json/');
      final http.Response response = await http.get(url);
      if (response.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> data =
          jsonDecode(response.body) as Map<String, dynamic>;
      final dynamic city = data['city'];
      return city is String ? city : null;
    } catch (_) {
      return null;
    }
  }

  Future<GeoLocation?> _geocodeFirstCity(String query) async {
    try {
      final Uri url =
          Uri.https('nominatim.openstreetmap.org', '/search', <String, String>{
        'q': query,
        'format': 'json',
        'addressdetails': '1',
        'accept-language': 'en',
        'limit': '1',
      });
      final http.Response response =
          await http.get(url, headers: const <String, String>{
        'User-Agent': 'OpenMeteoFlutterWeb/1.0',
      });
      if (response.statusCode != 200) {
        return null;
      }
      final List<dynamic> rawResults =
          jsonDecode(response.body) as List<dynamic>;
      final List<GeoLocation> parsed = _parseNominatimLocations(rawResults);
      if (parsed.isEmpty) {
        return null;
      }
      return parsed.first;
    } catch (_) {
      return null;
    }
  }

  List<GeoLocation> _parseNominatimLocations(List<dynamic> rawResults) {
    return rawResults
        .map((dynamic e) => e as Map<String, dynamic>)
        .map(GeoLocation.fromNominatim)
        .where((GeoLocation g) => g.latitude != 0 || g.longitude != 0)
        .toList();
  }

  Future<String?> _reverseGeocode(double lat, double lon) async {
    try {
      final Uri url =
          Uri.https('nominatim.openstreetmap.org', '/reverse', <String, String>{
        'lat': lat.toString(),
        'lon': lon.toString(),
        'format': 'json',
        'accept-language': 'en',
      });
      final http.Response response =
          await http.get(url, headers: const <String, String>{
        'User-Agent': 'OpenMeteoFlutterWeb/1.0',
      });
      if (response.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> data =
          jsonDecode(response.body) as Map<String, dynamic>;
      final Map<String, dynamic>? address =
          data['address'] as Map<String, dynamic>?;
      if (address == null) {
        return null;
      }
      final String? district = (address['suburb'] ??
              address['city_district'] ??
              address['town'] ??
              address['village'] ??
              address['city'] ??
              address['county'])
          ?.toString();
      final String? specific = (address['amenity'] ??
              address['building'] ??
              address['neighbourhood'] ??
              address['road'])
          ?.toString();
      if (specific != null && district != null && specific != district) {
        return '$district $specific';
      }
      return specific ?? district ?? address['state']?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadWeather(GeoLocation location) async {
    setState(() {
      _loading = true;
      _status = 'Loading weather for ${location.displayName}...';
      _selectedLocation = location;
      _isSearching = false;
      _searchResults = <GeoLocation>[];
    });

    try {
      final Uri url =
          Uri.https('api.open-meteo.com', '/v1/forecast', <String, String>{
        'latitude': location.latitude.toString(),
        'longitude': location.longitude.toString(),
        'current':
            'temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,is_day,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,visibility,uv_index',
        'hourly':
            'temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m',
        'daily':
            'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset,uv_index_max',
        'timezone': 'auto',
        'forecast_days': '7',
      });
      final Uri airUrl = Uri.https(
          'air-quality-api.open-meteo.com', '/v1/air-quality', <String, String>{
        'latitude': location.latitude.toString(),
        'longitude': location.longitude.toString(),
        'current': 'us_aqi',
        'timezone': 'auto',
      });

      final List<http.Response> responses =
          await Future.wait(<Future<http.Response>>[
        http.get(url),
        http.get(airUrl),
      ]);

      final http.Response response = responses[0];
      if (response.statusCode != 200) {
        throw Exception('Forecast failed (${response.statusCode})');
      }

      int? usAqi;
      final http.Response airResponse = responses[1];
      if (airResponse.statusCode == 200) {
        final Map<String, dynamic> airData =
            jsonDecode(airResponse.body) as Map<String, dynamic>;
        final dynamic aqiRaw =
            (airData['current'] as Map<String, dynamic>?)?['us_aqi'];
        if (aqiRaw is num) {
          usAqi = aqiRaw.round();
        }
      }

      final Map<String, dynamic> data =
          jsonDecode(response.body) as Map<String, dynamic>;
      setState(() {
        _forecast = ForecastData.fromJson(data, usAqi: usAqi);
        _status = 'Loaded ${location.displayName}';
      });
    } catch (error) {
      setState(() {
        _status = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _refreshCurrent() {
    if (_selectedLocation != null) {
      _loadWeather(_selectedLocation!);
    }
  }

  Future<void> _locateMe() async {
    await _bootstrapLocation();
  }

  @override
  Widget build(BuildContext context) {
    final List<Color> bg = weatherGradient(_forecast?.current.weatherCode ?? 2);
    final int bgCode = _forecast?.current.weatherCode ?? 2;
    final bool bgIsDay = (_forecast?.current.isDay ?? 1) == 1;
    final double bgWind = _forecast?.current.windSpeed.toDouble() ?? 0;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: bg,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.42,
                child: WeatherEffects(
                  code: bgCode,
                  isDay: bgIsDay,
                  windSpeed: bgWind,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    _buildHeader(),
                    const SizedBox(height: 12),
                    if (_searchResults.isNotEmpty) _buildSearchResults(),
                    if (_searchResults.isNotEmpty) const SizedBox(height: 12),
                    _buildStatusChip(),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: LinearProgressIndicator(minHeight: 3),
                      ),
                    if (_forecast != null &&
                        _selectedLocation != null) ...<Widget>[
                      const SizedBox(height: 14),
                      _glassCard(
                        child: _buildCurrentWeather(
                            _selectedLocation!, _forecast!),
                      ),
                      const SizedBox(height: 14),
                      _glassCard(child: _buildDailyForecast(_forecast!)),
                      const SizedBox(height: 14),
                      _glassCard(child: _buildHourlyForecast(_forecast!)),
                      const SizedBox(height: 14),
                      _glassCard(child: _buildFavoritesSection()),
                      const SizedBox(height: 14),
                      _buildHighlightsRow(_forecast!),
                      const SizedBox(height: 14),
                      _glassCard(child: _buildDetails(_forecast!)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    if (_isSearching) {
      return _glassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Search city',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    onSubmitted: (String value) => _searchCity(value),
                    decoration: const InputDecoration(
                      hintText: 'Taipei, Tokyo, New York...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _searchCity(_searchController.text),
                  child: const Icon(Icons.search),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _isSearching = false;
                      _searchResults = <GeoLocation>[];
                    });
                  },
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: _glassCard(
            child: Row(
              children: <Widget>[
                const Icon(Icons.place_rounded, size: 28),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _selectedLocation?.displayName ?? 'Breezy-style Weather',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: _toggleFavorite,
                  icon: Icon(
                    _isFavorite(_selectedLocation)
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: _isFavorite(_selectedLocation)
                        ? const Color(0xFFFFD54F)
                        : Colors.white,
                  ),
                  tooltip: 'Toggle favorite',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        _roundAction(Icons.navigation, _locateMe),
        const SizedBox(width: 8),
        _roundAction(Icons.refresh, _refreshCurrent),
        const SizedBox(width: 8),
        _roundAction(Icons.search, () {
          setState(() {
            _isSearching = true;
          });
        }),
      ],
    );
  }

  Widget _buildSearchResults() {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Select location',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ..._searchResults.map((GeoLocation loc) {
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.location_city),
              title: Text(loc.name),
              subtitle: Text(
                  [loc.admin1, loc.country].whereType<String>().join(', ')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _loadWeather(loc),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildStatusChip() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.85),
        shape: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            _status,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentWeather(GeoLocation location, ForecastData forecast) {
    final CurrentWeather current = forecast.current;
    final WeatherCodeInfo weatherInfo = weatherInfoForCode(current.weatherCode);

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: WeatherEffects(
                code: current.weatherCode,
                isDay: current.isDay == 1,
                windSpeed: current.windSpeed.toDouble(),
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              location.displayName,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9), fontSize: 14),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(weatherInfo.icon, style: const TextStyle(fontSize: 44)),
                const SizedBox(width: 8),
                Text(
                  '${current.temperature.round()}${forecast.currentUnits.temperature}',
                  style: const TextStyle(
                      fontSize: 66, height: 0.95, fontWeight: FontWeight.w300),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(weatherInfo.description,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'Feels ${current.apparentTemperature}${forecast.currentUnits.apparentTemperature}  ?? '
              'H:${forecast.dailyMaxTemps.first}${forecast.dailyUnits.maxTemp} '
              'L:${forecast.dailyMinTemps.first}${forecast.dailyUnits.minTemp}',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82), fontSize: 13),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _mini('Rain',
                    '${current.precipitation}${forecast.currentUnits.precipitation}'),
                _mini('Humidity',
                    '${current.humidity}${forecast.currentUnits.humidity}'),
                _mini('Wind',
                    '${current.windSpeed}${forecast.currentUnits.windSpeed}'),
                _mini(
                    'UV', current.uvIndex == null ? '-' : '${current.uvIndex}'),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHourlyForecast(ForecastData forecast) {
    final int count =
        forecast.hourlyTimes.length < 12 ? forecast.hourlyTimes.length : 12;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Hourly forecast',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 10),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: count,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (BuildContext context, int i) {
              final WeatherCodeInfo info =
                  weatherInfoForCode(forecast.hourlyCodes[i]);
              return Container(
                width: 88,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.16)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(i == 0 ? 'Now' : _hhmm(forecast.hourlyTimes[i]),
                        style: const TextStyle(fontSize: 12)),
                    Text(info.icon, style: const TextStyle(fontSize: 23)),
                    Text(
                      '${forecast.hourlyTemps[i]}${forecast.hourlyUnits.temperature}',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'Rain ${forecast.hourlyRainProb[i]}${forecast.hourlyUnits.rainProbability}',
                      style:
                          TextStyle(color: Colors.cyan.shade100, fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDailyForecast(ForecastData forecast) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Daily forecast',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        SizedBox(
          height: 122,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: forecast.dailyDates.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (BuildContext context, int i) {
              final WeatherCodeInfo info =
                  weatherInfoForCode(forecast.dailyCodes[i]);
              return Container(
                width: 92,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.14)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(
                        i == 0
                            ? 'Today'
                            : _shortWeekday(forecast.dailyDates[i]),
                        style: const TextStyle(fontSize: 12)),
                    Text(info.icon, style: const TextStyle(fontSize: 22)),
                    Text(
                      '${forecast.dailyMaxTemps[i].round()}${forecast.dailyUnits.maxTemp}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    Text(
                      '${forecast.dailyMinTemps[i].round()}${forecast.dailyUnits.minTemp}',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.78)),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFavoritesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Row(
          children: <Widget>[
            Icon(Icons.star_rounded, color: Color(0xFFFFD54F)),
            SizedBox(width: 8),
            Text('Favorite cities',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 10),
        if (_favorites.isEmpty)
          Text(
            'No favorites yet. Tap the star on current city to save it.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.8)),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _favorites.map((GeoLocation fav) {
              final bool active = _selectedLocation != null &&
                  fav.isSamePlace(_selectedLocation!);
              return InputChip(
                avatar: Icon(Icons.location_city,
                    size: 18, color: active ? Colors.black : Colors.white),
                label: Text(fav.displayName, overflow: TextOverflow.ellipsis),
                selected: active,
                selectedColor: const Color(0xFFFFD54F),
                onSelected: (_) => _loadWeather(fav),
                onDeleted: () => _removeFavorite(fav),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildDetails(ForecastData forecast) {
    final CurrentWeather c = forecast.current;
    final String sunrise = forecast.dailySunrise.isEmpty
        ? '--:--'
        : _hhmm(forecast.dailySunrise.first);
    final String sunset = forecast.dailySunset.isEmpty
        ? '--:--'
        : _hhmm(forecast.dailySunset.first);
    final String moon = forecast.dailyDates.isEmpty
        ? '-'
        : _moonPhaseLabel(DateTime.parse(forecast.dailyDates.first));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Life index',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 10),
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 1.2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          children: <Widget>[
            _metricCard(
                Icons.air,
                'Air quality',
                forecast.usAqi == null ? '-' : '${forecast.usAqi}',
                _aqiLabel(forecast.usAqi),
                progress:
                    _normalizeValue((forecast.usAqi ?? 0).toDouble(), 0, 200),
                color: const Color(0xFFF0B400),
                visual: _MetricVisual.ring),
            _metricCard(
                Icons.water_drop,
                'Humidity',
                '${c.humidity}${forecast.currentUnits.humidity}',
                _humidityLabel(c.humidity.round()),
                progress: _normalizeValue(c.humidity.toDouble(), 0, 100),
                color: const Color(0xFFD9B8FF),
                visual: _MetricVisual.wave),
            _metricCard(
                Icons.cloud,
                'Cloud cover',
                '${c.cloudCover}${forecast.currentUnits.cloudCover}',
                _cloudLabel(c.cloudCover.round()),
                progress: _normalizeValue(c.cloudCover.toDouble(), 0, 100),
                color: const Color(0xFFA8C1FF),
                visual: _MetricVisual.bar),
            _metricCard(
                Icons.remove_red_eye,
                'Visibility',
                c.visibility == null
                    ? '-'
                    : '${(c.visibility! / 1000).toStringAsFixed(1)} km',
                _visibilityLabel((c.visibility ?? 0) / 1000),
                progress: _normalizeValue((c.visibility ?? 0) / 1000, 0, 24),
                color: const Color(0xFFC9B5F6),
                visual: _MetricVisual.ring),
            _metricCard(
                Icons.compress,
                'Pressure',
                '${c.pressure}${forecast.currentUnits.pressure}',
                _pressureLabel(c.pressure.round()),
                progress: _normalizeValue(c.pressure.toDouble(), 980, 1040),
                color: const Color(0xFF4AB4EE),
                visual: _MetricVisual.ring),
            _metricCard(Icons.wb_sunny_outlined, 'Sun', '$sunrise / $sunset',
                'Sunrise / Sunset',
                progress: _dayProgress(DateTime.now(), sunrise, sunset),
                color: const Color(0xFFFFC04D),
                visual: _MetricVisual.sunArc),
            _metricCard(Icons.nights_stay_outlined, 'Moon', moon, 'Lunar phase',
                progress: ((DateTime.now().day % 29) / 29).clamp(0, 1),
                color: const Color(0xFF9EC5FF),
                visual: _MetricVisual.moonArc),
            _metricCard(
                Icons.wb_twilight,
                'UV index',
                c.uvIndex == null ? '-' : c.uvIndex!.toStringAsFixed(1),
                _uvLabel(c.uvIndex?.toDouble() ?? 0),
                progress: _normalizeValue(c.uvIndex?.toDouble() ?? 0, 0, 11),
                color: const Color(0xFFF3D98A),
                visual: _MetricVisual.dots),
          ],
        ),
      ],
    );
  }

  Widget _buildHighlightsRow(ForecastData forecast) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            children: <Widget>[
              _glassCard(
                child: _featureStatCard(
                  icon: Icons.grain,
                  title: 'Precipitation',
                  value:
                      '${forecast.current.precipitation}${forecast.currentUnits.precipitation}',
                  subtitle: 'Current rainfall',
                ),
              ),
              const SizedBox(height: 10),
              _glassCard(
                child: _featureStatCard(
                  icon: Icons.air,
                  title: 'Wind speed',
                  value:
                      '${forecast.current.windSpeed}${forecast.currentUnits.windSpeed}',
                  subtitle:
                      'Direction ${forecast.current.windDirection?.round() ?? '-'}°',
                ),
              ),
            ],
          );
        }
        return Row(
          children: <Widget>[
            Expanded(
              child: _glassCard(
                child: _featureStatCard(
                  icon: Icons.grain,
                  title: 'Precipitation',
                  value:
                      '${forecast.current.precipitation}${forecast.currentUnits.precipitation}',
                  subtitle: 'Current rainfall',
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _glassCard(
                child: _featureStatCard(
                  icon: Icons.air,
                  title: 'Wind speed',
                  value:
                      '${forecast.current.windSpeed}${forecast.currentUnits.windSpeed}',
                  subtitle:
                      'Direction ${forecast.current.windDirection?.round() ?? '-'}°',
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _featureStatCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
  }) {
    return Row(
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: Colors.white.withValues(alpha: 0.95)),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title,
                style: TextStyle(
                    fontSize: 12, color: Colors.white.withValues(alpha: 0.76))),
            const SizedBox(height: 1),
            Text(value,
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 12, color: Colors.white.withValues(alpha: 0.78))),
          ],
        ),
      ],
    );
  }

  Widget _metricCard(IconData icon, String title, String value, String subtitle,
      {required double progress,
      required Color color,
      required _MetricVisual visual}) {
    final BoxDecoration deco = BoxDecoration(
      color: visual == _MetricVisual.dots
          ? const Color(0xFFF4F6FF).withValues(alpha: 0.14)
          : Colors.white.withValues(alpha: 0.10),
      borderRadius:
          BorderRadius.circular(visual == _MetricVisual.ring ? 22 : 16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: deco,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: Colors.white.withValues(alpha: 0.9)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 900),
            tween: Tween<double>(begin: 0, end: progress.clamp(0, 1)),
            builder: (BuildContext context, double v, Widget? child) {
              return _buildMetricVisual(visual, v, color);
            },
          ),
          const SizedBox(height: 10),
          Text(value,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(subtitle,
              style: TextStyle(
                  fontSize: 11, color: Colors.white.withValues(alpha: 0.7)),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildMetricVisual(
      _MetricVisual visual, double progress, Color color) {
    switch (visual) {
      case _MetricVisual.ring:
        return SizedBox(
          height: 60,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.06),
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: CustomPaint(
                  painter: _ArcRingPainter(progress: progress, color: color),
                ),
              ),
            ),
          ),
        );
      case _MetricVisual.wave:
        return SizedBox(
          height: 54,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CustomPaint(
              painter: _WaveFillPainter(progress: progress, color: color),
            ),
          ),
        );
      case _MetricVisual.bar:
        return Column(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                minHeight: 7,
                value: progress,
                backgroundColor: Colors.white.withValues(alpha: 0.14),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List<Widget>.generate(5, (int i) {
                final double t = i / 4;
                return Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: progress >= t
                        ? color.withValues(alpha: 0.9)
                        : Colors.white.withValues(alpha: 0.25),
                  ),
                );
              }),
            ),
          ],
        );
      case _MetricVisual.dots:
        return SizedBox(
          height: 60,
          width: double.infinity,
          child: Center(
            child: SizedBox.square(
              dimension: 58,
              child: CustomPaint(
                painter: _UvDotsPainter(progress: progress, color: color),
              ),
            ),
          ),
        );
      case _MetricVisual.sunArc:
        return SizedBox(
          height: 60,
          width: double.infinity,
          child: CustomPaint(
            painter: _SunArcPainter(progress: progress, color: color),
          ),
        );
      case _MetricVisual.moonArc:
        return SizedBox(
          height: 60,
          width: double.infinity,
          child: CustomPaint(
            painter: _MoonArcPainter(progress: progress, color: color),
          ),
        );
    }
  }

  double _normalizeValue(double value, double min, double max) {
    if (max <= min) {
      return 0;
    }
    final double n = (value - min) / (max - min);
    return n.clamp(0, 1);
  }

  double _dayProgress(DateTime now, String sunrise, String sunset) {
    final DateTime? sr = _parseTodayTime(sunrise);
    final DateTime? ss = _parseTodayTime(sunset);
    if (sr == null || ss == null || !ss.isAfter(sr)) {
      return 0;
    }
    final Duration total = ss.difference(sr);
    final Duration pass = now.isBefore(sr)
        ? Duration.zero
        : now.isAfter(ss)
            ? total
            : now.difference(sr);
    return (pass.inSeconds / total.inSeconds).clamp(0, 1);
  }

  DateTime? _parseTodayTime(String hhmm) {
    if (!hhmm.contains(':')) {
      return null;
    }
    final List<String> parts = hhmm.split(':');
    if (parts.length < 2) {
      return null;
    }
    final int? h = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    if (h == null || m == null) {
      return null;
    }
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day, h, m);
  }

  String _aqiLabel(int? aqi) {
    if (aqi == null) return 'No data';
    if (aqi <= 50) return 'Good';
    if (aqi <= 100) return 'Moderate';
    if (aqi <= 150) return 'Sensitive';
    if (aqi <= 200) return 'Unhealthy';
    if (aqi <= 300) return 'Very unhealthy';
    return 'Hazardous';
  }

  String _humidityLabel(int humidity) =>
      humidity < 35 ? 'Dry' : (humidity <= 70 ? 'Comfortable' : 'Humid');
  String _cloudLabel(int cloud) =>
      cloud < 25 ? 'Mostly clear' : (cloud < 70 ? 'Partly cloudy' : 'Overcast');
  String _visibilityLabel(double km) => km >= 16
      ? 'Very clear'
      : (km >= 8 ? 'Clear' : (km >= 3 ? 'Hazy' : 'Low visibility'));
  String _pressureLabel(int pressure) => pressure < 1005
      ? 'Low pressure'
      : (pressure <= 1024 ? 'Stable' : 'High pressure');
  String _uvLabel(double uv) => uv < 3
      ? 'Low'
      : (uv < 6
          ? 'Moderate'
          : (uv < 8 ? 'High' : (uv < 11 ? 'Very high' : 'Extreme')));

  Widget _glassCard({required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  Widget _roundAction(IconData icon, VoidCallback onPressed) {
    return IconButton.filledTonal(
      onPressed: onPressed,
      icon: Icon(icon),
      tooltip: icon == Icons.search
          ? 'Search'
          : (icon == Icons.navigation ? 'Locate' : 'Refresh'),
    );
  }

  Widget _mini(String title, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('$title: ',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  String _hhmm(String value) {
    final int tIndex = value.indexOf('T');
    if (tIndex >= 0 && value.length >= tIndex + 6) {
      return value.substring(tIndex + 1, tIndex + 6);
    }
    return value;
  }

  String _shortWeekday(String isoDate) {
    try {
      final DateTime dt = DateTime.parse(isoDate);
      const List<String> names = <String>[
        'Mon',
        'Tue',
        'Wed',
        'Thu',
        'Fri',
        'Sat',
        'Sun'
      ];
      return names[dt.weekday - 1];
    } catch (_) {
      return isoDate;
    }
  }

  String _moonPhaseLabel(DateTime date) {
    final double days =
        date.toUtc().millisecondsSinceEpoch / Duration.millisecondsPerDay;
    final double synodic = 29.53058867;
    final double age = (days - 4.867) % synodic;
    if (age < 1.85) {
      return 'New Moon';
    }
    if (age < 5.54) {
      return 'Waxing Crescent';
    }
    if (age < 9.23) {
      return 'First Quarter';
    }
    if (age < 12.92) {
      return 'Waxing Gibbous';
    }
    if (age < 16.61) {
      return 'Full Moon';
    }
    if (age < 20.3) {
      return 'Waning Gibbous';
    }
    if (age < 23.99) {
      return 'Last Quarter';
    }
    if (age < 27.68) {
      return 'Waning Crescent';
    }
    return 'New Moon';
  }
}

enum _MetricVisual { ring, wave, bar, dots, sunArc, moonArc }

class _ArcRingPainter extends CustomPainter {
  const _ArcRingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);
    final Paint bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white.withValues(alpha: 0.18);
    final Paint fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4
      ..color = color;

    canvas.drawArc(rect, pi * 0.1, pi * 1.8, false, bg);
    canvas.drawArc(rect, pi * 0.1, pi * 1.8 * progress, false, fg);
  }

  @override
  bool shouldRepaint(covariant _ArcRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _WaveFillPainter extends CustomPainter {
  const _WaveFillPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint bg = Paint()..color = Colors.white.withValues(alpha: 0.08);
    canvas.drawRect(Offset.zero & size, bg);

    final double level = size.height * (1 - progress);
    final Path wave = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, level);

    for (double x = 0; x <= size.width; x += 8) {
      final double y = level + sin((x / size.width) * pi * 2) * 2.5;
      wave.lineTo(x, y);
    }

    wave
      ..lineTo(size.width, size.height)
      ..close();

    final Paint fill = Paint()..color = color.withValues(alpha: 0.55);
    canvas.drawPath(wave, fill);

    final Paint top = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, level), Offset(size.width, level), top);
  }

  @override
  bool shouldRepaint(covariant _WaveFillPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _UvDotsPainter extends CustomPainter {
  const _UvDotsPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double r = min(size.width, size.height) * 0.36;
    final int active = (progress * 8).clamp(0, 8).round();
    for (int i = 0; i < 8; i++) {
      final double a = (pi * 2 / 8) * i;
      final Offset p = c + Offset(cos(a) * r, sin(a) * r);
      final Paint dot = Paint()
        ..color = i < active
            ? color.withValues(alpha: 0.92)
            : Colors.white.withValues(alpha: 0.26);
      canvas.drawCircle(p, 4, dot);
    }
    canvas.drawCircle(c, 3.2, Paint()..color = color.withValues(alpha: 0.82));
  }

  @override
  bool shouldRepaint(covariant _UvDotsPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _SunArcPainter extends CustomPainter {
  const _SunArcPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect arcRect =
        Rect.fromLTWH(8, 10, size.width - 16, size.height - 18);
    final Paint base = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawArc(arcRect, pi, pi, false, base);
    final Paint dash = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    canvas.drawArc(arcRect, pi, pi * progress, false, dash);
    final double x = 8 + (size.width - 16) * progress;
    final double y = arcRect.bottom - sin(progress * pi) * arcRect.height;
    canvas.drawCircle(Offset(x, y), 4.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SunArcPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _MoonArcPainter extends CustomPainter {
  const _MoonArcPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect arcRect =
        Rect.fromLTWH(8, 10, size.width - 16, size.height - 18);
    final Paint line = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    canvas.drawArc(arcRect, pi, pi, false, line);
    final double x = 8 + (size.width - 16) * progress;
    final double y = arcRect.bottom - sin(progress * pi) * arcRect.height;
    canvas.drawCircle(Offset(x, y), 4.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _MoonArcPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class WeatherEffects extends StatefulWidget {
  const WeatherEffects({
    super.key,
    required this.code,
    required this.isDay,
    required this.windSpeed,
  });

  final int code;
  final bool isDay;
  final double windSpeed;

  @override
  State<WeatherEffects> createState() => _WeatherEffectsState();
}

class _WeatherEffectsState extends State<WeatherEffects>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 3000))
      ..repeat();
    final Random random = Random(7);
    _particles = List<_Particle>.generate(84, (int i) {
      final int layer = i % 3;
      return _Particle(
        x: random.nextDouble(),
        y: random.nextDouble(),
        size: 0.8 + random.nextDouble() * 2.8,
        speed: 0.45 + random.nextDouble() * 1.2,
        drift: (random.nextDouble() - 0.5) * 0.1,
        layer: layer,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _EffectType type =
        _effectTypeFromCode(widget.code, widget.isDay, widget.windSpeed);
    if (type == _EffectType.none) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double t = _controller.value;
        final double width = MediaQuery.of(context).size.width;
        final double height = MediaQuery.of(context).size.height;
        final List<Widget> layer = <Widget>[];

        double phaseForLayer(int l) {
          const List<double> starts = <double>[0.0, 0.23, 0.47];
          final double p = t - starts[l];
          if (p < 0) {
            return 0;
          }
          return p % 1.0;
        }

        void drawRain({int take = 60, bool thunder = false}) {
          for (final _Particle p in _particles.take(take)) {
            final double lp = phaseForLayer(p.layer);
            final double y =
                (p.y + lp * (1.7 + p.layer * 0.25) * p.speed) % 1.0;
            final double alpha =
                thunder ? (0.2 + p.layer * 0.08) : (0.15 + p.layer * 0.09);
            layer.add(
              Positioned(
                left: (p.x + p.drift * lp) * width,
                top: y * height,
                child: Transform.rotate(
                  angle: -0.30,
                  child: Container(
                    width: thunder ? 1.4 : 1.2 + (p.layer * 0.4),
                    height: 10 + p.size * (thunder ? 2.7 : 3.4),
                    color:
                        (thunder ? Colors.cyanAccent : Colors.lightBlueAccent)
                            .withValues(alpha: alpha),
                  ),
                ),
              ),
            );
          }
        }

        void drawSnow({int take = 66}) {
          for (final _Particle p in _particles.take(take)) {
            final double lp = phaseForLayer(p.layer);
            final double y =
                (p.y + lp * (0.30 + p.layer * 0.08) * p.speed) % 1.0;
            final double xWiggle =
                sin((lp * 2 * pi * (0.8 + p.layer * 0.2)) + (p.y * 6)) *
                    (8 + p.layer * 3);
            layer.add(
              Positioned(
                left: p.x * width + xWiggle,
                top: y * height,
                child: Container(
                  width: 1.8 + p.size + (p.layer * 0.6),
                  height: 1.8 + p.size + (p.layer * 0.6),
                  decoration: BoxDecoration(
                    color:
                        Colors.white.withValues(alpha: 0.43 + p.layer * 0.12),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }
        }

        void drawClouds({double alpha = 0.22, double speed = 0.12}) {
          for (int i = 0; i < 7; i++) {
            final double p = (t * speed + i * 0.14) % 1.2;
            final double x = ((1.2 - p) * width) - 80;
            final double y = 25 + ((i % 3) * 20).toDouble();
            final double w = 80 + (i % 3) * 22;
            layer.add(
              Positioned(
                left: x,
                top: y,
                child: Container(
                  width: w.toDouble(),
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: alpha),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            );
          }
        }

        void drawMist({double alpha = 0.18, bool warm = false}) {
          for (int i = 0; i < 5; i++) {
            final double p = (t * 0.10 + i * 0.2) % 1.3;
            final double x = ((1.3 - p) * width) - 100;
            final double y = 55 + (i * 22);
            layer.add(
              Positioned(
                left: x,
                top: y,
                child: Container(
                  width: 140,
                  height: 18,
                  decoration: BoxDecoration(
                    color: (warm ? const Color(0xFFFFE0B2) : Colors.white)
                        .withValues(alpha: alpha),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            );
          }
        }

        switch (type) {
          case _EffectType.clearDay:
            layer.add(
              Positioned(
                right: 14,
                top: 10,
                child: Transform.scale(
                  scale: 0.95 + 0.08 * sin(t * 2 * pi),
                  child: Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFFF59D).withValues(alpha: 0.26),
                    ),
                  ),
                ),
              ),
            );
            break;
          case _EffectType.clearNight:
            for (final _Particle p in _particles.take(30)) {
              final double twinkle = 0.15 +
                  0.3 *
                      (0.5 +
                          0.5 *
                              sin((t * 2 * pi * (1 + p.layer * 0.4)) +
                                  p.y * 14));
              layer.add(
                Positioned(
                  left: p.x * width,
                  top: p.y * (height * 0.55),
                  child: Container(
                    width: 1.6 + p.size * 0.3,
                    height: 1.6 + p.size * 0.3,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: twinkle),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }
            break;
          case _EffectType.partlyCloudyDay:
            drawClouds(alpha: 0.24, speed: 0.14);
            break;
          case _EffectType.partlyCloudyNight:
            drawClouds(alpha: 0.20, speed: 0.10);
            break;
          case _EffectType.cloudy:
            drawClouds(alpha: 0.26, speed: 0.09);
            drawClouds(alpha: 0.14, speed: 0.05);
            break;
          case _EffectType.fog:
            drawMist(alpha: 0.20, warm: false);
            break;
          case _EffectType.haze:
            drawMist(alpha: 0.16, warm: true);
            break;
          case _EffectType.wind:
            for (int i = 0; i < 12; i++) {
              final double p = (t * 0.9 + i * 0.09) % 1.2;
              final double x = ((1.2 - p) * width) - 70;
              final double y = 35 + (i * 14);
              layer.add(
                Positioned(
                  left: x,
                  top: y.toDouble(),
                  child: Container(
                    width: 36 + (i % 3) * 20,
                    height: 2,
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
              );
            }
            break;
          case _EffectType.rain:
            drawRain();
            break;
          case _EffectType.snow:
            drawSnow();
            break;
          case _EffectType.sleet:
            drawRain(take: 36);
            drawSnow(take: 30);
            break;
          case _EffectType.hail:
            for (final _Particle p in _particles.take(45)) {
              final double lp = phaseForLayer(p.layer);
              final double y =
                  (p.y + lp * (2.1 + p.layer * 0.2) * p.speed) % 1.0;
              layer.add(
                Positioned(
                  left: (p.x + p.drift * lp) * width,
                  top: y * height,
                  child: Container(
                    width: 2.5 + p.size * 0.5,
                    height: 2.5 + p.size * 0.5,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.72),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }
            break;
          case _EffectType.thunderstorm:
            final bool flash1 = t > 0.11 && t < 0.14;
            final bool flash2 = t > 0.36 && t < 0.39;
            final bool flash3 = t > 0.72 && t < 0.75;
            final double opacity = flash1 ? 0.28 : (flash2 || flash3 ? 0.2 : 0);
            layer.add(
              Positioned.fill(
                child:
                    Container(color: Colors.white.withValues(alpha: opacity)),
              ),
            );
            drawRain(take: 42, thunder: true);
            break;
          case _EffectType.none:
            break;
        }

        return Stack(children: layer);
      },
    );
  }
}

class _Particle {
  const _Particle({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.drift,
    required this.layer,
  });

  final double x;
  final double y;
  final double size;
  final double speed;
  final double drift;
  final int layer;
}

enum _EffectType {
  none,
  clearDay,
  clearNight,
  partlyCloudyDay,
  partlyCloudyNight,
  cloudy,
  fog,
  haze,
  wind,
  rain,
  snow,
  sleet,
  hail,
  thunderstorm,
}

_EffectType _effectTypeFromCode(int code, bool isDay, double windSpeed) {
  if (code == 0) {
    return isDay ? _EffectType.clearDay : _EffectType.clearNight;
  }
  if (code == 1 || code == 2) {
    return isDay ? _EffectType.partlyCloudyDay : _EffectType.partlyCloudyNight;
  }
  if (code == 3) {
    if (windSpeed >= 12) {
      return _EffectType.wind;
    }
    return _EffectType.cloudy;
  }
  if (code == 45) {
    return _EffectType.fog;
  }
  if (code == 48) {
    return _EffectType.haze;
  }
  if (code == 66 || code == 67) {
    return _EffectType.sleet;
  }
  if ((code >= 51 && code <= 65) || (code >= 80 && code <= 82)) {
    return _EffectType.rain;
  }
  if (code == 77) {
    return _EffectType.hail;
  }
  if ((code >= 71 && code <= 75) || code == 85 || code == 86) {
    return _EffectType.snow;
  }
  if (code >= 95) {
    return _EffectType.thunderstorm;
  }
  return _EffectType.none;
}

class GeoLocation {
  GeoLocation({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.country,
    required this.admin1,
  });

  final String name;
  final double latitude;
  final double longitude;
  final String country;
  final String? admin1;

  factory GeoLocation.fromJson(Map<String, dynamic> json) {
    return GeoLocation(
      name: json['name'] as String? ?? '-',
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      country: json['country'] as String? ?? '-',
      admin1: json['admin1'] as String?,
    );
  }

  factory GeoLocation.fromNominatim(Map<String, dynamic> json) {
    final Map<String, dynamic> address =
        (json['address'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String display = (json['display_name']?.toString() ?? '').trim();
    final String name = (json['name']?.toString().trim().isNotEmpty ?? false)
        ? json['name'].toString().trim()
        : (display.isNotEmpty ? display.split(',').first.trim() : 'Unknown');
    final String? admin1 =
        (address['state'] ?? address['county'] ?? address['region'])
            ?.toString();
    final String country = address['country']?.toString() ?? '';

    return GeoLocation(
      name: name,
      latitude: double.tryParse(json['lat']?.toString() ?? '') ?? 0,
      longitude: double.tryParse(json['lon']?.toString() ?? '') ?? 0,
      country: country,
      admin1: admin1,
    );
  }

  factory GeoLocation.fromStorage(Map<String, dynamic> json) {
    return GeoLocation(
      name: json['name']?.toString() ?? '-',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
      country: json['country']?.toString() ?? '',
      admin1: json['admin1']?.toString(),
    );
  }

  Map<String, dynamic> toStorage() {
    return <String, dynamic>{
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'country': country,
      'admin1': admin1,
    };
  }

  bool isSamePlace(GeoLocation other) {
    return (latitude - other.latitude).abs() < 0.01 &&
        (longitude - other.longitude).abs() < 0.01;
  }

  String get displayName {
    final List<String> parts = <String>[
      name,
      if (admin1 != null && admin1!.isNotEmpty) admin1!,
      if (country.isNotEmpty) country,
    ];
    return parts.join(', ');
  }
}

class ForecastData {
  ForecastData({
    required this.timezone,
    required this.current,
    required this.currentUnits,
    required this.usAqi,
    required this.hourlyTimes,
    required this.hourlyCodes,
    required this.hourlyTemps,
    required this.hourlyRainProb,
    required this.hourlyPrecip,
    required this.hourlyWind,
    required this.hourlyUnits,
    required this.dailyDates,
    required this.dailyCodes,
    required this.dailyMinTemps,
    required this.dailyMaxTemps,
    required this.dailyRainProbMax,
    required this.dailyPrecipSum,
    required this.dailySunrise,
    required this.dailySunset,
    required this.dailyUvIndexMax,
    required this.dailyUnits,
  });

  final String timezone;
  final CurrentWeather current;
  final CurrentUnits currentUnits;
  final int? usAqi;

  final List<String> hourlyTimes;
  final List<int> hourlyCodes;
  final List<num> hourlyTemps;
  final List<num> hourlyRainProb;
  final List<num> hourlyPrecip;
  final List<num> hourlyWind;
  final HourlyUnits hourlyUnits;

  final List<String> dailyDates;
  final List<int> dailyCodes;
  final List<num> dailyMinTemps;
  final List<num> dailyMaxTemps;
  final List<num> dailyRainProbMax;
  final List<num> dailyPrecipSum;
  final List<String> dailySunrise;
  final List<String> dailySunset;
  final List<num> dailyUvIndexMax;
  final DailyUnits dailyUnits;

  factory ForecastData.fromJson(Map<String, dynamic> json, {int? usAqi}) {
    final Map<String, dynamic> currentJson =
        json['current'] as Map<String, dynamic>;
    final Map<String, dynamic> currentUnitsJson =
        json['current_units'] as Map<String, dynamic>;

    final Map<String, dynamic> hourlyJson =
        json['hourly'] as Map<String, dynamic>;
    final Map<String, dynamic> hourlyUnitsJson =
        json['hourly_units'] as Map<String, dynamic>;

    final Map<String, dynamic> dailyJson =
        json['daily'] as Map<String, dynamic>;
    final Map<String, dynamic> dailyUnitsJson =
        json['daily_units'] as Map<String, dynamic>;
    final List<String> parsedDailyDates =
        List<String>.from(dailyJson['time'] as List<dynamic>);
    final List<num> parsedUvIndexMax = dailyJson['uv_index_max'] == null
        ? List<num>.filled(parsedDailyDates.length, 0)
        : List<num>.from(dailyJson['uv_index_max'] as List<dynamic>);

    return ForecastData(
      timezone: json['timezone'] as String? ?? 'auto',
      current: CurrentWeather.fromJson(currentJson),
      currentUnits: CurrentUnits.fromJson(currentUnitsJson),
      usAqi: usAqi,
      hourlyTimes: List<String>.from(hourlyJson['time'] as List<dynamic>),
      hourlyCodes: List<int>.from(hourlyJson['weather_code'] as List<dynamic>),
      hourlyTemps:
          List<num>.from(hourlyJson['temperature_2m'] as List<dynamic>),
      hourlyRainProb: List<num>.from(
          hourlyJson['precipitation_probability'] as List<dynamic>),
      hourlyPrecip:
          List<num>.from(hourlyJson['precipitation'] as List<dynamic>),
      hourlyWind: List<num>.from(hourlyJson['wind_speed_10m'] as List<dynamic>),
      hourlyUnits: HourlyUnits.fromJson(hourlyUnitsJson),
      dailyDates: parsedDailyDates,
      dailyCodes: List<int>.from(dailyJson['weather_code'] as List<dynamic>),
      dailyMinTemps:
          List<num>.from(dailyJson['temperature_2m_min'] as List<dynamic>),
      dailyMaxTemps:
          List<num>.from(dailyJson['temperature_2m_max'] as List<dynamic>),
      dailyRainProbMax: List<num>.from(
          dailyJson['precipitation_probability_max'] as List<dynamic>),
      dailyPrecipSum:
          List<num>.from(dailyJson['precipitation_sum'] as List<dynamic>),
      dailySunrise: List<String>.from(dailyJson['sunrise'] as List<dynamic>),
      dailySunset: List<String>.from(dailyJson['sunset'] as List<dynamic>),
      dailyUvIndexMax: parsedUvIndexMax,
      dailyUnits: DailyUnits.fromJson(dailyUnitsJson),
    );
  }
}

class CurrentWeather {
  CurrentWeather({
    required this.temperature,
    required this.apparentTemperature,
    required this.humidity,
    required this.precipitation,
    required this.weatherCode,
    required this.isDay,
    required this.cloudCover,
    required this.pressure,
    required this.windSpeed,
    required this.windDirection,
    required this.visibility,
    required this.uvIndex,
  });

  final num temperature;
  final num apparentTemperature;
  final num humidity;
  final num precipitation;
  final int weatherCode;
  final int isDay;
  final num cloudCover;
  final num pressure;
  final num windSpeed;
  final num? windDirection;
  final num? visibility;
  final num? uvIndex;

  factory CurrentWeather.fromJson(Map<String, dynamic> json) {
    return CurrentWeather(
      temperature: json['temperature_2m'] as num,
      apparentTemperature: json['apparent_temperature'] as num,
      humidity: json['relative_humidity_2m'] as num,
      precipitation: json['precipitation'] as num,
      weatherCode: json['weather_code'] as int,
      isDay: json['is_day'] as int? ?? 1,
      cloudCover: json['cloud_cover'] as num,
      pressure: json['pressure_msl'] as num,
      windSpeed: json['wind_speed_10m'] as num,
      windDirection: json['wind_direction_10m'] as num?,
      visibility: json['visibility'] as num?,
      uvIndex: json['uv_index'] as num?,
    );
  }
}

class CurrentUnits {
  CurrentUnits({
    required this.temperature,
    required this.apparentTemperature,
    required this.humidity,
    required this.precipitation,
    required this.cloudCover,
    required this.pressure,
    required this.windSpeed,
    required this.windDirection,
    required this.visibility,
    required this.uvIndex,
  });

  final String temperature;
  final String apparentTemperature;
  final String humidity;
  final String precipitation;
  final String cloudCover;
  final String pressure;
  final String windSpeed;
  final String? windDirection;
  final String? visibility;
  final String? uvIndex;

  factory CurrentUnits.fromJson(Map<String, dynamic> json) {
    return CurrentUnits(
      temperature: json['temperature_2m'] as String,
      apparentTemperature: json['apparent_temperature'] as String,
      humidity: json['relative_humidity_2m'] as String,
      precipitation: json['precipitation'] as String,
      cloudCover: json['cloud_cover'] as String,
      pressure: json['pressure_msl'] as String,
      windSpeed: json['wind_speed_10m'] as String,
      windDirection: json['wind_direction_10m'] as String?,
      visibility: json['visibility'] as String?,
      uvIndex: json['uv_index'] as String?,
    );
  }
}

class HourlyUnits {
  HourlyUnits({
    required this.temperature,
    required this.rainProbability,
    required this.precipitation,
    required this.wind,
  });

  final String temperature;
  final String rainProbability;
  final String precipitation;
  final String wind;

  factory HourlyUnits.fromJson(Map<String, dynamic> json) {
    return HourlyUnits(
      temperature: json['temperature_2m'] as String,
      rainProbability: json['precipitation_probability'] as String,
      precipitation: json['precipitation'] as String,
      wind: json['wind_speed_10m'] as String,
    );
  }
}

class DailyUnits {
  DailyUnits({
    required this.minTemp,
    required this.maxTemp,
    required this.rainProbabilityMax,
    required this.precipSum,
    required this.uvIndexMax,
  });

  final String minTemp;
  final String maxTemp;
  final String rainProbabilityMax;
  final String precipSum;
  final String uvIndexMax;

  factory DailyUnits.fromJson(Map<String, dynamic> json) {
    return DailyUnits(
      minTemp: json['temperature_2m_min'] as String,
      maxTemp: json['temperature_2m_max'] as String,
      rainProbabilityMax: json['precipitation_probability_max'] as String,
      precipSum: json['precipitation_sum'] as String,
      uvIndexMax: json['uv_index_max'] as String? ?? '',
    );
  }
}

class WeatherCodeInfo {
  const WeatherCodeInfo(this.icon, this.description);

  final String icon;
  final String description;
}

WeatherCodeInfo weatherInfoForCode(int code) {
  const Map<int, WeatherCodeInfo> map = <int, WeatherCodeInfo>{
    0: WeatherCodeInfo('\u2600', 'Clear sky'),
    1: WeatherCodeInfo('\u26C5', 'Mainly clear'),
    2: WeatherCodeInfo('\u26C5', 'Partly cloudy'),
    3: WeatherCodeInfo('\u2601', 'Overcast'),
    45: WeatherCodeInfo('\u301C', 'Fog'),
    48: WeatherCodeInfo('\u301C', 'Rime fog'),
    51: WeatherCodeInfo('\u2614', 'Light drizzle'),
    53: WeatherCodeInfo('\u2614', 'Drizzle'),
    55: WeatherCodeInfo('\u2614', 'Dense drizzle'),
    56: WeatherCodeInfo('\u2614', 'Freezing drizzle'),
    57: WeatherCodeInfo('\u2614', 'Dense freezing drizzle'),
    61: WeatherCodeInfo('\u2614', 'Slight rain'),
    63: WeatherCodeInfo('\u2614', 'Rain'),
    65: WeatherCodeInfo('\u2614', 'Heavy rain'),
    66: WeatherCodeInfo('\u2614', 'Freezing rain'),
    67: WeatherCodeInfo('\u2614', 'Heavy freezing rain'),
    71: WeatherCodeInfo('\u2744', 'Slight snow'),
    73: WeatherCodeInfo('\u2744', 'Snow'),
    75: WeatherCodeInfo('\u2744', 'Heavy snow'),
    77: WeatherCodeInfo('\u2744', 'Snow grains'),
    80: WeatherCodeInfo('\u2614', 'Rain showers'),
    81: WeatherCodeInfo('\u2614', 'Moderate showers'),
    82: WeatherCodeInfo('\u26C8', 'Violent showers'),
    85: WeatherCodeInfo('\u2744', 'Snow showers'),
    86: WeatherCodeInfo('\u2744', 'Heavy snow showers'),
    95: WeatherCodeInfo('\u26C8', 'Thunderstorm'),
    96: WeatherCodeInfo('\u26C8', 'Thunderstorm + hail'),
    99: WeatherCodeInfo('\u26C8', 'Severe thunderstorm + hail'),
  };

  return map[code] ?? WeatherCodeInfo('?', 'Code $code');
}

List<Color> weatherGradient(int code) {
  if (code == 0 || code == 1) {
    return <Color>[const Color(0xFF2A6EBB), const Color(0xFF5CA9E6)];
  }
  if (code == 2 || code == 3 || code == 45 || code == 48) {
    return <Color>[const Color(0xFF3E4F63), const Color(0xFF73879A)];
  }
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
    return <Color>[const Color(0xFF2C3E58), const Color(0xFF4E5F8A)];
  }
  if (code >= 71 && code <= 86) {
    return <Color>[const Color(0xFF607285), const Color(0xFF9AAFC3)];
  }
  if (code >= 95) {
    return <Color>[const Color(0xFF2F2D4D), const Color(0xFF5E59A6)];
  }
  return <Color>[const Color(0xFF2E5573), const Color(0xFF4B7A9E)];
}
