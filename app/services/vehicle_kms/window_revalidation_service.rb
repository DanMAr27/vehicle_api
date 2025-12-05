# app/services/vehicle_kms/window_revalidation_service.rb
module VehicleKms
  class WindowRevalidationService
    NEIGHBORS_COUNT = 5

    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
    end

    def call
      # Si el registro insertado es conflictivo por magnitud, NO revalidar vecinos
      # (el problema está en el nuevo registro, no en los vecinos)
      if @vehicle_km.status == "conflictivo" &&
         @vehicle_km.conflict_reasons_list.to_s.include?("magnitud")
        return {
          success: true,
          revalidated_count: 0,
          skipped_reason: "Conflicto de magnitud en registro nuevo - vecinos no afectados"
        }
      end

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
      # PASO 1: Verificar si el registro insertado que causó la revalidación es conflictivo
      # Si es así, NO marcar a este registro como conflictivo
      if @vehicle_km.status == "conflictivo"
        # El problema está en el registro nuevo, este registro probablemente está bien
        return
      end

      # PASO 2: Verificar si este registro ahora es un outlier
      outlier_detector = OutlierDetectionService.new(record)
      outlier_result = outlier_detector.call

      if outlier_result[:has_outlier] && outlier_result[:is_current_record]
        record.update!(
          status: "conflictivo",
          km_normalized: record.km_reported,
          conflict_reasons_list: [ "Detectado como outlier tras nueva inserción" ],
          correction_notes: "Outlier - patrón inconsistente con vecinos"
        )
        return
      end

      # PASO 3: Si había sido marcado como outlier pero ya no lo es
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

      # PASO 4: Validación normal de correlación
      checker = CorrelationCheckService.new(record)
      check_result = checker.call

      if !check_result[:has_conflict] && record.status == "conflictivo"
        record.update!(
          status: "original",
          km_normalized: record.km_reported,
          conflict_reasons_list: [],
          correction_notes: "Resuelto automáticamente tras inserción de nuevo registro"
        )
        return
      end

      if check_result[:has_conflict] && (record.status == "original" || record.status == "estimado")
        high_severity = check_result[:conflicts].any? { |c| c[:severity] == "high" }

        if high_severity
          record.update!(
            status: "conflictivo",
            km_normalized: record.km_reported,
            conflict_reasons_list: check_result[:conflicts].map { |c| c[:message] },
            correction_notes: "Conflicto detectado tras inserción de nuevo registro. No se puede corregir automáticamente."
          )
        else
          attempt_revalidation_correction(record, check_result)
        end
      end
    end

    def attempt_revalidation_correction(record, check_result)
      unless record.company.auto_correction_enabled
        record.update!(
          status: "conflictivo",
          km_normalized: record.km_reported,
          conflict_reasons_list: check_result[:conflicts].map { |c| c[:message] }
        )
        return
      end

      confidence_calculator = ConfidenceCalculatorService.new(record)
      confidence = confidence_calculator.call

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
