const int defaultMaxOutputTokens = 4096;
const int maxConfiguredOutputTokens = 131072;

int normalizeMaxOutputTokens(Object? value) {
  if (value is int && value >= 1 && value <= maxConfiguredOutputTokens) {
    return value;
  }
  return defaultMaxOutputTokens;
}