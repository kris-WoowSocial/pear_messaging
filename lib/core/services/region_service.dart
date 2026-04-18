import 'dart:io';
import 'package:get/get.dart';

class RegionService extends GetxService {
  final Rx<String> currentRegion = 'USA'.obs;
  final Rx<String> currentCountryCode = 'US'.obs;

  Future<RegionService> init() async {
    _detectRegion();
    return this;
  }

  void _detectRegion() {
    try {
      // Get device locale
      final locale = Platform.localeName;
      final countryCode = locale.split('_').last.toUpperCase();

      currentCountryCode.value = countryCode;
      currentRegion.value = _mapCountryToRegion(countryCode);

      print(
          '🌍 Region detected: ${currentRegion.value} (Country: $countryCode)');
    } catch (e) {
      print('⚠️ Region detection failed, using fallback: $e');
      currentRegion.value = 'USA';
      currentCountryCode.value = 'US';
    }
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
}
