# app/services/vehicle_kms/correlation_check_service.rb
module VehicleKms
  class CorrelationCheckService
    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @company = vehicle_km.company
    end

    def call
      prev_record = find_previous_record
      next_record = find_next_record

      conflicts = []

      # Validación 1: Regresión (siempre se valida)
      regression = check_regression(prev_record)
      conflicts << regression if regression

      # Validación 2: Inconsistencia futura (siempre se valida)
      future_inconsistency = check_future_consistency(next_record)
      conflicts << future_inconsistency if future_inconsistency

      # Validación 3: Incremento irrealista (solo si está configurado)
      if @company.max_daily_km_tolerance.present?
        unrealistic = check_unrealistic_increase(prev_record)
        conflicts << unrealistic if unrealistic
      end

      {
        has_conflict: conflicts.any?,
        conflicts: conflicts.compact,
        previous_record: prev_record,
        next_record: next_record
      }
    end

    private

    def find_previous_record
      VehicleKm.kept
              .where(vehicle_id: @vehicle_km.vehicle_id)
              .where("input_date < ?", @vehicle_km.input_date)
              .order(input_date: :desc)
              .first
    end

    def find_next_record
      VehicleKm.kept
              .where(vehicle_id: @vehicle_km.vehicle_id)
              .where("input_date > ?", @vehicle_km.input_date)
              .order(input_date: :asc)
              .first
    end

    def check_regression(prev_record)
      return unless prev_record
      return unless @vehicle_km.km_reported < prev_record.effective_km

      {
        type: "regression",
        message: "KM inferior al registro anterior (#{prev_record.effective_km} km en #{prev_record.input_date})",
        severity: "high"
      }
    end

    def check_unrealistic_increase(prev_record)
      return unless prev_record

      days_diff = (@vehicle_km.input_date - prev_record.input_date).to_i
      return if days_diff <= 0

      km_diff = @vehicle_km.km_reported - prev_record.effective_km
      return if km_diff <= 0 # No es incremento

      daily_avg = km_diff.to_f / days_diff
      max_daily = @company.max_daily_km_tolerance

      return unless daily_avg > max_daily

      {
        type: "unrealistic_increase",
        message: "Incremento diario promedio muy alto: #{daily_avg.round(2)} km/día (máximo configurado: #{max_daily} km/día)",
        severity: "medium"
      }
    end

    def check_future_consistency(next_record)
      return unless next_record
      return unless @vehicle_km.km_reported > next_record.effective_km

      {
        type: "future_inconsistency",
        message: "KM superior al registro posterior (#{next_record.effective_km} km en #{next_record.input_date})",
        severity: "high"
      }
    end
  end
end
