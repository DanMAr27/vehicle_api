# app/services/vehicle_kms/confidence_calculator_service.rb
module VehicleKms
  class ConfidenceCalculatorService
    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @company = vehicle_km.company
    end

    def call
      neighbors = count_neighbors
      variability = calculate_variability

      level = determine_confidence_level(neighbors, variability)

      {
        level: level,
        neighbors_before: neighbors[:before],
        neighbors_after: neighbors[:after],
        variability_percentage: variability
      }
    end

    private

    def count_neighbors
      before_count = VehicleKm.kept
                              .where(vehicle_id: @vehicle_km.vehicle_id)
                              .where("input_date < ?", @vehicle_km.input_date)
                              .count

      after_count = VehicleKm.kept
                             .where(vehicle_id: @vehicle_km.vehicle_id)
                             .where("input_date > ?", @vehicle_km.input_date)
                             .count

      {
        before: before_count,
        after: after_count,
        total: before_count + after_count
      }
    end

    def calculate_variability
      # Obtener últimos 10 registros para calcular variabilidad
      records = VehicleKm.kept
                        .where(vehicle_id: @vehicle_km.vehicle_id)
                        .where("input_date < ?", @vehicle_km.input_date)
                        .order(input_date: :desc)
                        .limit(10)

      return 100.0 if records.count < 3 # Sin datos suficientes = alta variabilidad

      # Calcular incrementos diarios entre registros consecutivos
      daily_increments = []
      records.each_cons(2) do |newer, older|
        days = (newer.input_date - older.input_date).to_i
        next if days <= 0

        km_diff = newer.effective_km - older.effective_km
        daily_avg = km_diff.to_f / days
        daily_increments << daily_avg if daily_avg >= 0
      end

      return 100.0 if daily_increments.empty?

      # Calcular coeficiente de variación (desviación estándar / media)
      mean = daily_increments.sum / daily_increments.size
      return 0.0 if mean == 0

      variance = daily_increments.map { |x| (x - mean)**2 }.sum / daily_increments.size
      std_dev = Math.sqrt(variance)

      ((std_dev / mean) * 100).round(2)
    end

    def determine_confidence_level(neighbors, variability)
      # Verificar mínimo de vecinos configurado
      min_neighbors = @company.min_neighbors_for_correction || 1

      # High confidence: muchos vecinos y baja variabilidad
      if neighbors[:before] >= 3 && neighbors[:after] >= 3 && variability < 20
        return "high"
      end

      # Medium confidence: algunos vecinos y variabilidad moderada
      if neighbors[:before] >= min_neighbors && neighbors[:after] >= min_neighbors && variability < 40
        return "medium"
      end

      # Low confidence: pocos vecinos o alta variabilidad
      "low"
    end
  end
end
