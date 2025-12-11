# app/services/vehicle_kms/km_correction_service.rb
#
# Servicio para corregir registros conflictivos mediante interpolación/extrapolación
# Usa solo los registros VÁLIDOS (no conflictivos) para calcular
#
module VehicleKms
  class KmCorrectionService
    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @vehicle = vehicle_km.vehicle
    end

    def call
      valid_neighbors = get_valid_neighbors
      prev_valid = find_previous_valid(valid_neighbors)
      next_valid = find_next_valid(valid_neighbors)

      corrected_km = calculate_correction(prev_valid, next_valid, valid_neighbors)

      if corrected_km
        {
          success: true,
          corrected_km: corrected_km,
          method: correction_method(prev_valid, next_valid),
          notes: build_correction_notes(prev_valid, next_valid, corrected_km)
        }
      else
        {
          success: false,
          corrected_km: nil,
          method: nil,
          notes: "No se pudo calcular corrección - faltan registros válidos"
        }
      end
    end

    private

    def get_valid_neighbors
      VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where.not(status: "conflictivo")
        .where.not(id: @vehicle_km.id)
        .order(input_date: :asc, id: :asc)
        .to_a
    end

    def find_previous_valid(valid_neighbors)
      valid_neighbors
        .select { |r| r.input_date < @vehicle_km.input_date ||
                      (r.input_date == @vehicle_km.input_date && r.id < @vehicle_km.id) }
        .last
    end

    def find_next_valid(valid_neighbors)
      valid_neighbors
        .select { |r| r.input_date > @vehicle_km.input_date ||
                      (r.input_date == @vehicle_km.input_date && r.id > @vehicle_km.id) }
        .first
    end

    def calculate_correction(prev_valid, next_valid, all_valid)
      if prev_valid && next_valid
        interpolate(prev_valid, next_valid)
      elsif prev_valid
        extrapolate_forward(prev_valid, all_valid)
      elsif next_valid
        extrapolate_backward(next_valid, all_valid)
      else
        nil
      end
    end

    def interpolate(prev_valid, next_valid)
      days_total = (next_valid.input_date - prev_valid.input_date).to_i
      return nil if days_total <= 0

      days_from_prev = (@vehicle_km.input_date - prev_valid.input_date).to_i
      return nil if days_from_prev < 0

      km_prev = prev_valid.km_normalized || prev_valid.km_reported
      km_next = next_valid.km_normalized || next_valid.km_reported

      km_total = km_next - km_prev
      return nil if km_total < 0

      km_per_day = km_total.to_f / days_total

      (km_prev + (km_per_day * days_from_prev)).round
    end

    def extrapolate_forward(prev_valid, all_valid)
      avg_daily_rate = calculate_historical_rate(all_valid, before: @vehicle_km.input_date)
      return nil if avg_daily_rate <= 0

      days_diff = (@vehicle_km.input_date - prev_valid.input_date).to_i
      return nil if days_diff <= 0

      km_prev = prev_valid.km_normalized || prev_valid.km_reported
      estimated_km = (km_prev + (avg_daily_rate * days_diff)).round

      estimated_km > km_prev ? estimated_km : nil
    end

    def extrapolate_backward(next_valid, all_valid)
      avg_daily_rate = calculate_historical_rate(all_valid, after: @vehicle_km.input_date)
      return nil if avg_daily_rate <= 0

      days_diff = (next_valid.input_date - @vehicle_km.input_date).to_i
      return nil if days_diff <= 0

      km_next = next_valid.km_normalized || next_valid.km_reported
      estimated_km = (km_next - (avg_daily_rate * days_diff)).round

      (estimated_km < km_next && estimated_km >= 0) ? estimated_km : nil
    end

    def calculate_historical_rate(valid_records, before: nil, after: nil)
      relevant_records = if before
        valid_records.select { |r| r.input_date < before }
      elsif after
        valid_records.select { |r| r.input_date > after }
      else
        valid_records
      end

      return 50.0 if relevant_records.count < 2

      sample = relevant_records.last(10)
      return 50.0 if sample.count < 2

      first_record = sample.first
      last_record = sample.last

      km_first = first_record.km_normalized || first_record.km_reported
      km_last = last_record.km_normalized || last_record.km_reported

      total_km = km_last - km_first
      total_days = (last_record.input_date - first_record.input_date).to_i

      return 50.0 if total_days <= 0 || total_km <= 0

      (total_km.to_f / total_days).round(2)
    end

    def correction_method(prev_valid, next_valid)
      if prev_valid && next_valid
        "interpolation"
      elsif prev_valid
        "extrapolation_forward"
      elsif next_valid
        "extrapolation_backward"
      else
        "none"
      end
    end

    def build_correction_notes(prev_valid, next_valid, corrected_km)
      notes = []

      if prev_valid && next_valid
        notes << "Interpolación lineal entre #{prev_valid.input_date.strftime('%d/%m/%Y')} (#{prev_valid.km_normalized || prev_valid.km_reported} km)"
        notes << "y #{next_valid.input_date.strftime('%d/%m/%Y')} (#{next_valid.km_normalized || next_valid.km_reported} km)"
      elsif prev_valid
        notes << "Extrapolación forward desde #{prev_valid.input_date.strftime('%d/%m/%Y')} (#{prev_valid.km_normalized || prev_valid.km_reported} km)"
        notes << "usando tendencia histórica"
      elsif next_valid
        notes << "Extrapolación backward desde #{next_valid.input_date.strftime('%d/%m/%Y')} (#{next_valid.km_normalized || next_valid.km_reported} km)"
        notes << "usando tendencia histórica"
      end

      notes << "KM reportado: #{@vehicle_km.km_reported}, KM corregido: #{corrected_km}"
      notes.join(". ")
    end
  end
end
