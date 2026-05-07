class PricingConfig {
  static const Map<String, RegionPricing> regionPricing = {
    'USA': RegionPricing(
      region: 'USA',
      currency: 'USD',
      currencySymbol: '\$',
      sixMonthPrice: 999, // in cents
      oneYearPrice: 1299, // in cents
      sixMonthDisplay: '\$9.99 USD',
      oneYearDisplay: '\$12.99 USD',
    ),
    'Pakistan': RegionPricing(
      region: 'Pakistan',
      currency: 'PKR',
      currencySymbol: 'PKR',
      sixMonthPrice: 119900, // in paisa (PKR 1,199)
      oneYearPrice: 159900, // in paisa (PKR 1,599)
      sixMonthDisplay: 'PKR 1,199',
      oneYearDisplay: 'PKR 1,599',
    ),
    'India': RegionPricing(
      region: 'India',
      currency: 'INR',
      currencySymbol: '₹',
      sixMonthPrice: 59900, // in paisa (₹599)
      oneYearPrice: 79900, // in paisa (₹799)
      sixMonthDisplay: '₹599',
      oneYearDisplay: '₹799',
    ),
    'UK': RegionPricing(
      region: 'UK',
      currency: 'GBP',
      currencySymbol: '£',
      sixMonthPrice: 799, // in pence (£7.99)
      oneYearPrice: 999, // in pence (£9.99)
      sixMonthDisplay: '£7.99',
      oneYearDisplay: '£9.99',
    ),
    'EU': RegionPricing(
      region: 'EU',
      currency: 'EUR',
      currencySymbol: '€',
      sixMonthPrice: 20000, // in cents (€600.00)
      oneYearPrice: 30000, // in cents (€800.00)
      sixMonthDisplay: '€200.00',
      oneYearDisplay: '€300.00',
    ),
    'HighPrice': RegionPricing(
      region: 'HighPrice',
      currency: 'USD',
      currencySymbol: '\$',
      sixMonthPrice: 20000, // $700 in cents
      oneYearPrice: 30000, // $900 in cents
      sixMonthDisplay: '\$200 USD',
      oneYearDisplay: '\$300 USD',
    ),
  };

  static RegionPricing getPricingForRegion(String region) {
    return regionPricing[region] ?? regionPricing['USA']!;
  }
}

class RegionPricing {
  final String region;
  final String currency;
  final String currencySymbol;
  final int
      sixMonthPrice; // Amount in smallest currency unit (cents, paisa, etc.)
  final int oneYearPrice; // Amount in smallest currency unit
  final String sixMonthDisplay; // Formatted display string
  final String oneYearDisplay; // Formatted display string

  const RegionPricing({
    required this.region,
    required this.currency,
    required this.currencySymbol,
    required this.sixMonthPrice,
    required this.oneYearPrice,
    required this.sixMonthDisplay,
    required this.oneYearDisplay,
  });

  int getPriceForPlan(String planId) {
    return planId == '1_year' ? oneYearPrice : sixMonthPrice;
  }

  String getDisplayForPlan(String planId) {
    return planId == '1_year' ? oneYearDisplay : sixMonthDisplay;
  }
}
