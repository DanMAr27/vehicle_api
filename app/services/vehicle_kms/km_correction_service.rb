# app/services/vehicle_kms/km_correction_service.rb
module VehicleKms
  class KmCorrectionService
    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @company = vehicle_km.company
    end

    def call
      # Verificar si la corrección está habilitada
      unless @company.auto_correction_enabled
        return no_correction_needed("Corrección automática deshabilitada")
      end

      prev_record = find_previous_record
      next_record = find_next_record

      # Verificar mínimo de vecinos
      min_neighbors = @company.min_neighbors_for_correction || 1
      neighbors_count = [ prev_record, next_record ].compact.count

      if neighbors_count < min_neighbors
        return no_correction_needed("Insuficientes registros vecinos (mínimo: #{min_neighbors})")
      end

      corrected_km = calculate_correction(prev_record, next_record)

      # Validar que la corrección tenga sentido
      if corrected_km.nil? || corrected_km < 0
        return no_correction_needed("No se pudo calcular corrección válida")
      end

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
        # Interpolación lineal
        interpolate(prev_record, next_record)
      elsif prev_record
        # Extrapolación forward
        extrapolate_forward(prev_record)
      elsif next_record
        # Extrapolación backward
        extrapolate_backward(next_record)
      else
        nil
      end
    end

    def interpolate(prev_record, next_record)
      days_total = (next_record.input_date - prev_record.input_date).to_i
      return nil if days_total <= 0

      days_from_prev = (@vehicle_km.input_date - prev_record.input_date).to_i
      return nil if days_from_prev < 0

      km_total = next_record.effective_km - prev_record.effective_km
      return nil if km_total < 0 # No tiene sentido interpolar si hay regresión

      km_per_day = km_total.to_f / days_total

      (prev_record.effective_km + (km_per_day * days_from_prev)).round
    end

    def extrapolate_forward(prev_record)
      avg_daily = calculate_historical_average
      return nil if avg_daily <= 0

      days_diff = (@vehicle_km.input_date - prev_record.input_date).to_i
      return nil if days_diff <= 0

      estimated_km = (prev_record.effective_km + (avg_daily * days_diff)).round

      # Validar que la estimación sea mayor que el anterior
      estimated_km > prev_record.effective_km ? estimated_km : nil
    end

    def extrapolate_backward(next_record)
      avg_daily = calculate_historical_average
      return nil if avg_daily <= 0

      days_diff = (next_record.input_date - @vehicle_km.input_date).to_i
      return nil if days_diff <= 0

      estimated_km = (next_record.effective_km - (avg_daily * days_diff)).round

      # Validar que la estimación sea menor que el siguiente
      estimated_km < next_record.effective_km && estimated_km >= 0 ? estimated_km : nil
    end

    def calculate_historical_average
      records = VehicleKm.kept
                        .where(vehicle_id: @vehicle_km.vehicle_id)
                        .where("input_date < ?", @vehicle_km.input_date)
                        .order(input_date: :desc)
                        .limit(10)

      return 50.0 if records.count < 3 # Default conservador si no hay suficientes datos

      # Ordenar cronológicamente para calcular
      records = records.sort_by(&:input_date)

      total_km = records.last.effective_km - records.first.effective_km
      total_days = (records.last.input_date - records.first.input_date).to_i

      return 50.0 if total_days <= 0 || total_km <= 0

      (total_km.to_f / total_days).round(2)
    end

    def build_notes(prev_record, next_record, corrected_km)
      method = if prev_record && next_record
                 "Interpolación lineal entre #{prev_record.input_date.strftime('%d/%m/%Y')} y #{next_record.input_date.strftime('%d/%m/%Y')}"
      elsif prev_record
                 "Extrapolación forward desde #{prev_record.input_date.strftime('%d/%m/%Y')}"
      else
                 "Extrapolación backward desde #{next_record.input_date.strftime('%d/%m/%Y')}"
      end

      "#{method}. KM original: #{@vehicle_km.km_reported}, KM estimado: #{corrected_km}"
    end

    def no_correction_needed(reason)
      {
        success: false,
        corrected_km: nil,
        notes: reason
      }
    end
  end
end
