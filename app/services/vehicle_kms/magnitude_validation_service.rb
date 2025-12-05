# app/services/vehicle_kms/magnitude_validation_service.rb
module VehicleKms
  class MagnitudeValidationService
    # Porcentaje máximo de desviación considerado aceptable
    MAX_DEVIATION_PERCENTAGE = 150 # 150% = 2.5x el valor esperado

    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @company = vehicle_km.company
    end

    def call
      prev_record = find_previous_record
      next_record = find_next_record

      # Necesitamos al menos un vecino para validar magnitud
      return { has_magnitude_issue: false, can_interpolate: false } unless prev_record || next_record

      issues = []

      # Validar contra anterior
      if prev_record
        prev_issue = check_magnitude_vs_previous(prev_record, next_record)
        issues << prev_issue if prev_issue
      end

      # Validar contra posterior
      if next_record
        next_issue = check_magnitude_vs_next(prev_record, next_record)
        issues << next_issue if next_issue
      end

      # CLAVE: puede interpolar si hay AMBOS vecinos (anterior Y posterior)
      can_interpolate = prev_record.present? && next_record.present?

      {
        has_magnitude_issue: issues.any?,
        issues: issues,
        can_interpolate: can_interpolate
      }
    end

    private

    def find_previous_record
      VehicleKm.kept
              .where(vehicle_id: @vehicle_km.vehicle_id)
              .where("input_date < ? OR (input_date = ? AND id < ?)",
                     @vehicle_km.input_date,
                     @vehicle_km.input_date,
                     @vehicle_km.id)
              .order(input_date: :desc, id: :desc)
              .first
    end

    def find_next_record
      VehicleKm.kept
              .where(vehicle_id: @vehicle_km.vehicle_id)
              .where("input_date > ? OR (input_date = ? AND id > ?)",
                     @vehicle_km.input_date,
                     @vehicle_km.input_date,
                     @vehicle_km.id)
              .order(input_date: :asc, id: :asc)
              .first
    end

    def check_magnitude_vs_previous(prev_record, next_record)
      days_diff = (@vehicle_km.input_date - prev_record.input_date).to_i
      return nil if days_diff <= 0

      # Calcular incremento esperado basado en el patrón histórico
      expected_increase = calculate_expected_increase(prev_record, days_diff)
      actual_increase = @vehicle_km.km_reported - prev_record.effective_km

      # Si el incremento real es negativo, ya lo maneja check_regression
      return nil if actual_increase < 0

      # Calcular desviación porcentual
      if expected_increase > 0
        deviation_percentage = ((actual_increase - expected_increase).abs / expected_increase.to_f * 100)

        if deviation_percentage > MAX_DEVIATION_PERCENTAGE
          return {
            type: "extreme_magnitude_deviation",
            message: "Incremento extremo: #{actual_increase} km en #{days_diff} días (esperado: ~#{expected_increase.round} km, desviación: #{deviation_percentage.round}%)",
            expected: expected_increase.round,
            actual: actual_increase,
            deviation_percentage: deviation_percentage.round
          }
        end
      end

      nil
    end

    def check_magnitude_vs_next(prev_record, next_record)
      # Si el KM actual es mayor que el siguiente, verificar la magnitud
      return nil unless @vehicle_km.km_reported > next_record.effective_km

      km_diff = @vehicle_km.km_reported - next_record.effective_km

      # Si la diferencia es muy grande (>20% del km del siguiente), es sospechoso
      percentage_diff = (km_diff.to_f / next_record.effective_km * 100)

      if percentage_diff > 20
        return {
          type: "extreme_future_deviation",
          message: "KM significativamente superior al futuro: #{@vehicle_km.km_reported} vs #{next_record.effective_km} (#{percentage_diff.round}% más alto)",
          percentage: percentage_diff.round
        }
      end

      nil
    end

    def calculate_expected_increase(prev_record, days_diff)
      # Calcular promedio histórico de los últimos registros
      historical_avg = calculate_historical_daily_average

      # Incremento esperado = promedio diario * días
      (historical_avg * days_diff).round
    end

    def calculate_historical_daily_average
      records = VehicleKm.kept
                        .where(vehicle_id: @vehicle_km.vehicle_id)
                        .where("input_date < ?", @vehicle_km.input_date)
                        .order(input_date: :desc)
                        .limit(10)

      return 50.0 if records.count < 3 # Default si no hay datos

      records = records.sort_by(&:input_date)

      total_km = records.last.effective_km - records.first.effective_km
      total_days = (records.last.input_date - records.first.input_date).to_i

      return 50.0 if total_days <= 0 || total_km <= 0

      (total_km.to_f / total_days)
    end
  end
end
