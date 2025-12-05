# app/services/vehicle_kms/window_revalidation_service.rb
module VehicleKms
  class WindowRevalidationService
    WINDOW_DAYS = 30

    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
    end

    def call
      affected_records = find_affected_records

      affected_records.each do |record|
        revalidate_record(record)
      end

      {
        success: true,
        revalidated_count: affected_records.count
      }
    end

    private

    def find_affected_records
      # Buscar registros en ventana de 30 días antes y después
      start_date = @vehicle_km.input_date - WINDOW_DAYS.days
      end_date = @vehicle_km.input_date + WINDOW_DAYS.days

      VehicleKm.kept
              .where(vehicle_id: @vehicle_km.vehicle_id)
              .where("input_date BETWEEN ? AND ?", start_date, end_date)
              .where.not(id: @vehicle_km.id) # Excluir el registro que acabamos de insertar
              .order(input_date: :asc)
    end

    def revalidate_record(record)
      # Re-ejecutar validación
      checker = CorrelationCheckService.new(record)
      check_result = checker.call

      # Si ya no hay conflictos y estaba marcado como conflictivo, actualizar
      if !check_result[:has_conflict] && record.status == "conflictivo"
        record.update!(
          status: "original",
          conflict_reasons_list: [],
          correction_notes: "Resuelto automáticamente tras inserción de nuevo registro"
        )
        return
      end

      # Si ahora hay conflictos y estaba como original, re-evaluar
      if check_result[:has_conflict] && record.status == "original"
        # Calcular confianza
        confidence_calculator = ConfidenceCalculatorService.new(record)
        confidence = confidence_calculator.call

        high_severity = check_result[:conflicts].any? { |c| c[:severity] == "high" }

        if high_severity || confidence[:level] == "low"
          record.update!(
            status: "conflictivo",
            conflict_reasons_list: check_result[:conflicts].map { |c| c[:message] },
            correction_notes: "Conflicto detectado tras inserción de nuevo registro"
          )
        else
          # Intentar corrección
          corrector = KmCorrectionService.new(record)
          correction_result = corrector.call

          if correction_result[:success] && correction_result[:corrected_km]
            record.update!(
              km_normalized: correction_result[:corrected_km],
              status: "estimado",
              confidence_level: confidence[:level],
              correction_notes: correction_result[:notes]
            )
          else
            record.update!(
              status: "conflictivo",
              conflict_reasons_list: check_result[:conflicts].map { |c| c[:message] }
            )
          end
        end
      end
    end
  end
end
