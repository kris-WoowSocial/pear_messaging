import 'dart:io';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class RegionService extends GetxService {
  final Rx<String> currentRegion = 'USA'.obs;
  final Rx<String> currentCountryCode = 'US'.obs;

  Future<RegionService> init() async {
    await detectRegion();
    return this;
  }

  Future<void> detectRegion() async {
    try {
      final response = await http.get(
        Uri.parse('http://api.vant.chat/api/membership/detect-region'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final countryCode = data['countryCode'] ?? 'US';

        currentCountryCode.value = countryCode;
        currentRegion.value = _mapCountryToRegion(countryCode);

        print('🌍 IP-based country detection: $countryCode');
        print('🌍 Payment method: ${getPaymentMethod()}');
      } else {
        throw Exception('Failed to detect region: ${response.body}');
      }
    } catch (e) {
      print('❌ IP-based detection failed, falling back to device locale: $e');
      _fallbackToDeviceLocale();
    }
  }

  void _fallbackToDeviceLocale() {
    final locale = Platform.localeName;
    print('🌍 Fallback - Device locale: $locale');

    String countryCode = 'US';
    if (locale.contains('_')) {
      countryCode = locale.split('_').last.toUpperCase();
    }

    currentCountryCode.value = countryCode;
    currentRegion.value = _mapCountryToRegion(countryCode);
    print('🌍 Fallback - Detected country code: $countryCode');
    print('🌍 Payment method: ${getPaymentMethod()}');
  }

  String _mapCountryToRegion(String countryCode) {
    // Map country codes to regions
    const countryToRegion = {
      // USA
      'US': 'USA',

      // Pakistan
      'PK': 'Pakistan',

      // India
      'IN': 'India',

      // UK
      'GB': 'UK',

      // European Union countries
      'AL': 'EU', // Albania
      'IT': 'EU', // Italy
      'ME': 'EU', // Montenegro
      'XK': 'EU', // Kosovo
      'GR': 'EU', // Greece
      'DE': 'EU', // Germany
      'FR': 'EU', // France
      'ES': 'EU', // Spain
      'PT': 'EU', // Portugal
      'NL': 'EU', // Netherlands
      'BE': 'EU', // Belgium
      'AT': 'EU', // Austria
      'SE': 'EU', // Sweden
      'DK': 'EU', // Denmark
      'FI': 'EU', // Finland
      'NO': 'EU', // Norway
      'PL': 'EU', // Poland
      'CZ': 'EU', // Czech Republic
      'HU': 'EU', // Hungary
      'RO': 'EU', // Romania
      'BG': 'EU', // Bulgaria
      'HR': 'EU', // Croatia
      'SI': 'EU', // Slovenia
      'SK': 'EU', // Slovakia
      'LT': 'EU', // Lithuania
      'LV': 'EU', // Latvia
      'EE': 'EU', // Estonia
      'IE': 'EU', // Ireland
      'LU': 'EU', // Luxembourg
      'MT': 'EU', // Malta
      'CY': 'EU', // Cyprus
      'CH': 'EU', // Switzerland
    };

    return countryToRegion[countryCode] ?? 'USA'; // Fallback to USA
  }

  String get region => currentRegion.value;
  String get countryCode => currentCountryCode.value;

  String getPaymentMethod() {
    final lowPriceCountries = ['US', 'IN', 'CA', 'BD'];
    return lowPriceCountries.contains(currentCountryCode.value)
        ? 'google_play'
        : 'stripe';
  }
}
