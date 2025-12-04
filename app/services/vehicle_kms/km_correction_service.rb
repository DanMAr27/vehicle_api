# app/services/vehicle_kms/km_correction_service.rb
module VehicleKms
  class KmCorrectionService
    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
    end

    def call
      prev_record = find_previous_record
      next_record = find_next_record

      return no_correction_needed unless prev_record || next_record

      corrected_km = calculate_correction(prev_record, next_record)
      notes = build_notes(prev_record, next_record, corrected_km)

      {
        success: true,
        corrected_km: corrected_km,
        notes: notes,
        original_km: @vehicle_km.km_reported
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

    def calculate_correction(prev_record, next_record)
      if prev_record && next_record
        # Interpolación lineal entre dos puntos
        interpolate(prev_record, next_record)
      elsif prev_record
        # Extrapolación basada en promedio histórico
        extrapolate_forward(prev_record)
      elsif next_record
        # Extrapolación hacia atrás
        extrapolate_backward(next_record)
      else
        @vehicle_km.km_reported
      end
    end

    def interpolate(prev_record, next_record)
      days_total = (next_record.input_date - prev_record.input_date).to_i
      days_from_prev = (@vehicle_km.input_date - prev_record.input_date).to_i

      km_total = next_record.effective_km - prev_record.effective_km
      km_per_day = km_total.to_f / days_total

      (prev_record.effective_km + (km_per_day * days_from_prev)).round
    end

    def extrapolate_forward(prev_record)
      # Calcular promedio diario basado en histórico
      avg_daily = calculate_historical_average
      days_diff = (@vehicle_km.input_date - prev_record.input_date).to_i

      (prev_record.effective_km + (avg_daily * days_diff)).round
    end

    def extrapolate_backward(next_record)
      avg_daily = calculate_historical_average
      days_diff = (next_record.input_date - @vehicle_km.input_date).to_i

      (next_record.effective_km - (avg_daily * days_diff)).round
    end

    def calculate_historical_average
      records = VehicleKm.kept
                        .where(vehicle_id: @vehicle_km.vehicle_id)
                        .order(input_date: :asc)
                        .limit(10)

      return 50 if records.count < 2 # Default conservador

      total_km = records.last.effective_km - records.first.effective_km
      total_days = (records.last.input_date - records.first.input_date).to_i

      return 50 if total_days <= 0

      (total_km.to_f / total_days).round(2)
    end

    def build_notes(prev_record, next_record, corrected_km)
      method = if prev_record && next_record
                 "Interpolación lineal"
      elsif prev_record
                 "Extrapolación forward"
      else
                 "Extrapolación backward"
      end

      "#{method}. KM original: #{@vehicle_km.km_reported}, KM estimado: #{corrected_km}"
    end

    def no_correction_needed
      {
        success: false,
        corrected_km: @vehicle_km.km_reported,
        notes: "No hay suficientes datos para corrección"
      }
    end
  end
end
