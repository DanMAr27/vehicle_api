# app/services/vehicle_kms/create_service.rb
module VehicleKms
  class CreateService
    attr_reader :errors

    def initialize(vehicle_id:, params:)
      @vehicle_id = vehicle_id
      @params = params
      @errors = []
    end

    def call
      validate_vehicle
      return failure unless @errors.empty?

      ActiveRecord::Base.transaction do
        create_km_record
        process_validation_and_correction
        revalidate_affected_window if @params[:input_date]
        update_vehicle_current_km
        success
      end
    rescue StandardError => e
      @errors << e.message
      failure
    end

    private

    def validate_vehicle
      @vehicle = Vehicle.kept.find_by(id: @vehicle_id)
      @errors << "Vehículo no encontrado" unless @vehicle
    end

    def create_km_record
      @vehicle_km = VehicleKm.create!(
        vehicle: @vehicle,
        company: @vehicle.company,
        input_date: @params[:input_date],
        source: @params[:source],
        source_record_id: @params[:source_record_id],
        km_reported: @params[:km_reported],
        km_normalized: @params[:km_reported],
        status: "original"
      )
    end

    def process_validation_and_correction
      # PASO 1: Validación de magnitud (detecta errores EXTREMOS como 30k→80k)
      magnitude_validator = MagnitudeValidationService.new(@vehicle_km)
      magnitude_result = magnitude_validator.call

      # Si hay error de magnitud pero NO se puede interpolar → CONFLICTIVO directo
      if magnitude_result[:has_magnitude_issue] && !magnitude_result[:can_interpolate]
        mark_as_conflictive_magnitude(magnitude_result[:issues])
        return
      end

      # Si hay error de magnitud pero SÍ se puede interpolar → continuar para corregir
      # (se manejará en check_result más adelante)

      # PASO 2: Detectar outlier en contexto
      outlier_detector = OutlierDetectionService.new(@vehicle_km)
      outlier_result = outlier_detector.call

      # PASO 3: Si hay outlier y NO es el registro actual → marcar el outlier
      if outlier_result[:has_outlier] && !outlier_result[:is_current_record]
        handle_outlier_in_context(outlier_result[:outlier_record])

        @vehicle_km.update!(
          status: "original",
          confidence_level: nil,
          conflict_reasons_list: []
        )
        return
      end

      # PASO 4: Verificar correlación temporal (regresión, futuro inconsistente)
      checker = CorrelationCheckService.new(@vehicle_km)
      check_result = checker.call

      # PASO 5: Combinar conflictos de magnitud con conflictos de correlación
      all_conflicts = check_result[:conflicts].dup
      if magnitude_result[:has_magnitude_issue]
        # Agregar los conflictos de magnitud pero con severity MEDIUM (es corregible)
        magnitude_result[:issues].each do |issue|
          all_conflicts << {
            type: issue[:type],
            message: issue[:message],
            severity: "medium", # Es corregible por interpolación
            magnitude_issue: true
          }
        end
      end

      # PASO 6: Si no hay conflictos, dejar como original
      if all_conflicts.empty?
        @vehicle_km.update!(
          status: "original",
          confidence_level: nil,
          conflict_reasons_list: []
        )
        return
      end

      # PASO 7: Evaluar severidad y decidir acción
      high_severity_conflicts = all_conflicts.select { |c| c[:severity] == "high" }

      if high_severity_conflicts.any?
        # NO se puede corregir (faltan datos) → conflictivo
        mark_as_conflictive(all_conflicts)
      else
        # SÍ se puede corregir → intentar corrección
        attempt_correction_with_confidence(all_conflicts)
      end
    end

    def mark_as_conflictive_magnitude(issues)
      @vehicle_km.update!(
        status: "conflictivo",
        km_normalized: @vehicle_km.km_reported,
        confidence_level: nil,
        conflict_reasons_list: issues.map { |i| i[:message] },
        correction_notes: "Error de magnitud extrema detectado. Posible error de entrada de datos. Requiere revisión manual."
      )
    end

    def handle_outlier_in_context(outlier_record)
      outlier_record.update!(
        status: "conflictivo",
        km_normalized: outlier_record.km_reported,
        confidence_level: nil,
        conflict_reasons_list: [
          "Detectado como outlier tras inserción de nuevo registro consistente",
          "Patrón de incremento inconsistente con registros vecinos"
        ],
        correction_notes: "Outlier detectado automáticamente - requiere revisión manual"
      )
    end

    def mark_as_conflictive(conflicts)
      @vehicle_km.update!(
        status: "conflictivo",
        km_normalized: @vehicle_km.km_reported,
        confidence_level: nil,
        conflict_reasons_list: conflicts.map { |c| c[:message] },
        correction_notes: "Conflicto detectado: #{conflicts.map { |c| c[:type] }.join(', ')}. No se puede corregir automáticamente por falta de datos."
      )
    end

    def attempt_correction_with_confidence(conflicts)
      unless @vehicle.company.auto_correction_enabled
        mark_as_conflictive(conflicts)
        return
      end

      confidence_calculator = ConfidenceCalculatorService.new(@vehicle_km)
      confidence = confidence_calculator.call

      corrector = KmCorrectionService.new(@vehicle_km)
      correction_result = corrector.call

      if correction_result[:success] && correction_result[:corrected_km]
        # Agregar nota si había error de magnitud
        notes = correction_result[:notes]
        if conflicts.any? { |c| c[:magnitude_issue] }
          notes += " [CORREGIDO: Error de magnitud extrema detectado y corregido automáticamente]"
        end

        @vehicle_km.update!(
          km_normalized: correction_result[:corrected_km],
          status: "estimado",
          confidence_level: confidence[:level],
          conflict_reasons_list: [],
          correction_notes: notes
        )
      else
        mark_as_conflictive(conflicts)
      end
    end

    def revalidate_affected_window
      return if @params[:input_date] >= Date.today

      revalidator = WindowRevalidationService.new(@vehicle_km)
      revalidator.call
    end

    def update_vehicle_current_km
      latest = VehicleKm.kept
                       .where(vehicle_id: @vehicle_id)
                       .order(input_date: :desc, created_at: :desc)
                       .first

      @vehicle.update!(current_km: latest.effective_km) if latest
    end

    def success
      {
        success: true,
        vehicle_km: @vehicle_km,
        status: @vehicle_km.status,
        needs_review: @vehicle_km.status == "conflictivo"
      }
    end

    def failure
      { success: false, errors: @errors }
    end
  end
end
