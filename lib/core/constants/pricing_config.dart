class PricingConfig {
  // Global flat pricing: $70 for 6 months, $100 for 1 year (USD, all countries)
  static const RegionPricing globalPricing = RegionPricing(
    region: 'Global',
    currency: 'USD',
    currencySymbol: '\$',
    sixMonthPrice: 7000, // $70.00 in cents
    oneYearPrice: 10000, // $100.00 in cents
    sixMonthDisplay: '\$70 USD',
    oneYearDisplay: '\$100 USD',
  );

  static RegionPricing getPricingForRegion(String region) {
    return globalPricing;
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
