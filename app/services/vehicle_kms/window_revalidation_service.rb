# app/services/vehicle_kms/window_revalidation_service.rb
module VehicleKms
  class WindowRevalidationService
    NEIGHBORS_COUNT = 5 # Número de registros antes/después a revisar

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
      # Buscar N registros antes y N registros después
      before = VehicleKm.kept
                       .where(vehicle_id: @vehicle_km.vehicle_id)
                       .where("input_date < ? OR (input_date = ? AND id < ?)",
                              @vehicle_km.input_date,
                              @vehicle_km.input_date,
                              @vehicle_km.id)
                       .order(input_date: :desc, id: :desc)
                       .limit(NEIGHBORS_COUNT)

      after = VehicleKm.kept
                      .where(vehicle_id: @vehicle_km.vehicle_id)
                      .where("input_date > ? OR (input_date = ? AND id > ?)",
                             @vehicle_km.input_date,
                             @vehicle_km.input_date,
                             @vehicle_km.id)
                      .order(input_date: :asc, id: :asc)
                      .limit(NEIGHBORS_COUNT)

      (before.to_a + after.to_a)
        .reject { |r| r.id == @vehicle_km.id }
        .sort_by { |r| [ r.input_date, r.id ] }
    end

    def revalidate_record(record)
      # PASO 1: Verificar si este registro ahora es un outlier
      outlier_detector = OutlierDetectionService.new(record)
      outlier_result = outlier_detector.call

      if outlier_result[:has_outlier] && outlier_result[:is_current_record]
        # Este registro es ahora un outlier → marcar como conflictivo
        record.update!(
          status: "conflictivo",
          km_normalized: record.km_reported,
          conflict_reasons_list: [ "Detectado como outlier tras nueva inserción" ],
          correction_notes: "Outlier - patrón inconsistente con vecinos"
        )
        return
      end

      # PASO 2: Si había sido marcado como outlier pero ya no lo es → resolver
      if !outlier_result[:has_outlier] &&
         record.status == "conflictivo" &&
         record.conflict_reasons_list.to_s.include?("outlier")

        record.update!(
          status: "original",
          km_normalized: record.km_reported,
          conflict_reasons_list: [],
          correction_notes: "Conflicto resuelto tras nueva inserción"
        )
        return
      end

      # PASO 3: Validación normal de correlación
      checker = CorrelationCheckService.new(record)
      check_result = checker.call

      # Si ya no hay conflictos y estaba marcado como conflictivo, actualizar
      if !check_result[:has_conflict] && record.status == "conflictivo"
        record.update!(
          status: "original",
          km_normalized: record.km_reported,
          conflict_reasons_list: [],
          correction_notes: "Resuelto automáticamente tras inserción de nuevo registro"
        )
        return
      end

      # Si ahora hay conflictos y estaba como original, re-evaluar
      if check_result[:has_conflict] && (record.status == "original" || record.status == "estimado")
        # Evaluar severidad
        high_severity = check_result[:conflicts].any? { |c| c[:severity] == "high" }

        if high_severity
          # No se puede corregir → conflictivo
          record.update!(
            status: "conflictivo",
            km_normalized: record.km_reported,
            conflict_reasons_list: check_result[:conflicts].map { |c| c[:message] },
            correction_notes: "Conflicto detectado tras inserción de nuevo registro. No se puede corregir automáticamente."
          )
        else
          # Se puede corregir → intentar corrección
          attempt_revalidation_correction(record, check_result)
        end
      end
    end

    def attempt_revalidation_correction(record, check_result)
      # Verificar si la corrección está habilitada
      unless record.company.auto_correction_enabled
        record.update!(
          status: "conflictivo",
          km_normalized: record.km_reported,
          conflict_reasons_list: check_result[:conflicts].map { |c| c[:message] }
        )
        return
      end

      # Calcular confianza
      confidence_calculator = ConfidenceCalculatorService.new(record)
      confidence = confidence_calculator.call

      # Intentar corrección
      corrector = KmCorrectionService.new(record)
      correction_result = corrector.call

      if correction_result[:success] && correction_result[:corrected_km]
        record.update!(
          km_normalized: correction_result[:corrected_km],
          status: "estimado",
          confidence_level: confidence[:level],
          conflict_reasons_list: [],
          correction_notes: correction_result[:notes]
        )
      else
        record.update!(
          status: "conflictivo",
          km_normalized: record.km_reported,
          conflict_reasons_list: check_result[:conflicts].map { |c| c[:message] }
        )
      end
    end
  end
end
