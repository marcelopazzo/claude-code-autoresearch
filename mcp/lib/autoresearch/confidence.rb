# frozen_string_literal: true

module Autoresearch
  # Session-level confidence score. A robust noise-floor estimator using
  # Median Absolute Deviation (MAD). Confidence = |best_improvement| / MAD.
  # Lifted from upstream pi-autoresearch — behavior must match.
  module Confidence
    module_function

    # Compute confidence for the current segment.
    # - `values` is an array of primary-metric readings (in order).
    # - `baseline` is the first (anchor) value of the segment.
    # - `direction` is :lower or :higher.
    # Returns a Float or nil when there's not enough data.
    def compute(values:, baseline:, direction:)
      return nil if values.length < 3 || baseline.nil?

      best = direction == :higher ? values.max : values.min
      improvement = (best - baseline).abs
      return nil if improvement.zero?

      mad = median_absolute_deviation(values)
      return nil if mad.nil? || mad.zero?

      improvement / mad
    end

    def median_absolute_deviation(values)
      return nil if values.empty?

      m = sorted_median(values)
      deviations = values.map { |v| (v - m).abs }
      sorted_median(deviations)
    end

    def sorted_median(values)
      sorted = values.sort
      n = sorted.length
      return nil if n.zero?
      return sorted[n / 2] if n.odd?

      (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    end
  end
end
