# app/services/vehicle_kms/outlier_detection_service.rb
module VehicleKms
  class OutlierDetectionService
    # Umbrales para detectar outliers
    HIGH_RATE_THRESHOLD = 300  # km/día considerado muy alto
    LOW_RATE_THRESHOLD = 50    # km/día considerado muy bajo

    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @company = vehicle_km.company
    end

    def call
      # Obtener contexto: 3-5 registros antes y después
      context = get_context_records(3)

      # Necesitamos al menos 3 registros para detectar outliers
      return { has_outlier: false } if context.size < 3

      # Incluir el registro actual en el análisis
      all_records = (context + [ @vehicle_km ]).sort_by { |r| [ r.input_date, r.id ] }

      outlier = detect_outlier_in_sequence(all_records)

      {
        has_outlier: outlier.present?,
        outlier_record: outlier,
        is_current_record: outlier&.id == @vehicle_km.id,
        context_size: context.size
      }
    end

    private

    def get_context_records(n)
      # Obtener registros válidos (no conflictivos si es posible)
      before = VehicleKm.kept
                       .where(vehicle_id: @vehicle_km.vehicle_id)
                       .where("input_date < ? OR (input_date = ? AND id < ?)",
                              @vehicle_km.input_date,
                              @vehicle_km.input_date,
                              @vehicle_km.id)
                       .order(input_date: :desc, id: :desc)
                       .limit(n)

      after = VehicleKm.kept
                      .where(vehicle_id: @vehicle_km.vehicle_id)
                      .where("input_date > ? OR (input_date = ? AND id > ?)",
                             @vehicle_km.input_date,
                             @vehicle_km.input_date,
                             @vehicle_km.id)
                      .order(input_date: :asc, id: :asc)
                      .limit(n)

      (before.to_a + after.to_a).sort_by { |r| [ r.input_date, r.id ] }
    end

    def detect_outlier_in_sequence(records)
      return nil if records.size < 4

      # Calcular incrementos diarios entre cada par consecutivo
      daily_rates = []
      records.each_cons(2) do |r1, r2|
        days = (r2.input_date - r1.input_date).to_i

        # Si es el mismo día, usar created_at para orden pero no calcular rate
        if days == 0
          daily_rates << {
            from: r1,
            to: r2,
            rate: nil,  # No calculable para mismo día
            km_diff: r2.km_reported - r1.effective_km,
            days: 0
          }
          next
        end

        km_diff = r2.km_reported - r1.effective_km
        daily_rate = km_diff.to_f / days

        daily_rates << {
          from: r1,
          to: r2,
          rate: daily_rate,
          km_diff: km_diff,
          days: days
        }
      end

      # Filtrar rates válidos (ignorar mismo día)
      valid_rates = daily_rates.select { |r| r[:rate].present? }
      return nil if valid_rates.empty?

      # Detectar outliers por patrón de incrementos anormales
      detect_outlier_pattern(valid_rates)
    end

    def detect_outlier_pattern(daily_rates)
      # Un outlier crea DOS incrementos anormales consecutivos:
      # OUTLIER ALTO: incremento muy alto HACIA él + incremento bajo/negativo DESDE él
      # OUTLIER BAJO: incremento bajo/negativo HACIA él + incremento muy alto DESDE él

      daily_rates.each_with_index do |rate_info, i|
        next if i == daily_rates.size - 1

        next_rate = daily_rates[i + 1]

        # Usar umbrales de la empresa si están configurados
        high_threshold = @company.max_daily_km_tolerance || HIGH_RATE_THRESHOLD
        low_threshold = LOW_RATE_THRESHOLD

        # Patrón 1: Outlier ALTO
        # Sube mucho hacia un registro, luego baja o crece muy poco desde él
        if rate_info[:rate] > high_threshold && next_rate[:rate] < low_threshold
          # El registro "to" del primer incremento es el outlier alto
          return rate_info[:to]
        end

        # Patrón 2: Outlier BAJO (o regresión)
        # Baja o crece poco hacia un registro, luego sube mucho desde él
        if rate_info[:rate] < low_threshold && next_rate[:rate] > high_threshold
          # El registro "to" del primer incremento es el outlier bajo
          return rate_info[:to]
        end

        # Patrón 3: Regresión severa seguida de recuperación
        # El km baja significativamente y luego vuelve a subir normalmente
        if rate_info[:km_diff] < 0 && next_rate[:rate] > 0 && next_rate[:rate] < high_threshold
          # El registro "to" del primer incremento (el que causó la regresión) es el outlier
          return rate_info[:to]
        end
      end

      nil
    end
  end
end
