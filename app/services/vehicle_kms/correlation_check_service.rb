# app/services/vehicle_kms/correlation_check_service.rb
module VehicleKms
  class CorrelationCheckService
    TOLERANCE_PERCENTAGE = 0.15 # 15% de tolerancia
    MAX_DAILY_KM = 1000 # Máximo KM realista por día

    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
    end

    def call
      prev_record = find_previous_record
      next_record = find_next_record

      conflicts = []
      conflicts << check_regression(prev_record) if prev_record
      conflicts << check_unrealistic_increase(prev_record) if prev_record
      conflicts << check_future_consistency(next_record) if next_record

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
      return unless @vehicle_km.km_reported < prev_record.effective_km

      {
        type: "regression",
        message: "KM inferior al registro anterior (#{prev_record.effective_km} km)",
        severity: "high"
      }
    end

    def check_unrealistic_increase(prev_record)
      days_diff = (@vehicle_km.input_date - prev_record.input_date).to_i
      return if days_diff <= 0

      km_diff = @vehicle_km.km_reported - prev_record.effective_km
      daily_avg = km_diff.to_f / days_diff

      return unless daily_avg > MAX_DAILY_KM

      {
        type: "unrealistic_increase",
        message: "Incremento diario promedio muy alto: #{daily_avg.round(2)} km/día",
        severity: "medium"
      }
    end

    def check_future_consistency(next_record)
      return unless @vehicle_km.km_reported > next_record.effective_km

      {
        type: "future_inconsistency",
        message: "KM superior al registro posterior (#{next_record.effective_km} km)",
        severity: "high"
      }
    end
  end
end
