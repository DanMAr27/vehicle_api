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
      # PASO 1: Detectar outlier en contexto (vecinos anómalos)
      outlier_detector = OutlierDetectionService.new(@vehicle_km)
      outlier_result = outlier_detector.call

      # Si hay outlier y NO es el registro actual → marcar ese vecino como conflictivo
      if outlier_result[:has_outlier] && !outlier_result[:is_current_record]
        handle_outlier_in_context(outlier_result[:outlier_record])

        @vehicle_km.update!(
          status: "original",
          confidence_level: nil,
          conflict_reasons_list: []
        )
        return
      end

      # PASO 2: Validar magnitud (errores extremos como 30k→80k)
      magnitude_validator = MagnitudeValidationService.new(@vehicle_km)
      magnitude_result = magnitude_validator.call

      # PASO 3: Validar correlación (regresión, futuro inconsistente)
      checker = CorrelationCheckService.new(@vehicle_km)
      check_result = checker.call

      # PASO 4: Determinar si hay conflictos
      has_conflicts = magnitude_result[:has_magnitude_issue] || check_result[:has_conflict]

      unless has_conflicts
        @vehicle_km.update!(
          status: "original",
          confidence_level: nil,
          conflict_reasons_list: []
        )
        return
      end

      # PASO 5: Hay conflictos - determinar si se pueden corregir
      # REGLA: Solo se puede corregir si hay registro anterior Y posterior (interpolación)
      can_correct = magnitude_result[:can_interpolate]

      if can_correct && @vehicle.company.auto_correction_enabled
        # Intentar corrección automática
        attempt_automatic_correction(magnitude_result, check_result)
      else
        # No se puede corregir o no está habilitado
        mark_as_conflictive_final(magnitude_result, check_result, can_correct)
      end
    end

    def attempt_automatic_correction(magnitude_result, check_result)
      # Calcular confianza
      confidence_calculator = ConfidenceCalculatorService.new(@vehicle_km)
      confidence = confidence_calculator.call

      # Intentar corrección por interpolación
      corrector = KmCorrectionService.new(@vehicle_km)
      correction_result = corrector.call

      if correction_result[:success] && correction_result[:corrected_km]
        # Construir notas
        notes = correction_result[:notes]

        if magnitude_result[:has_magnitude_issue]
          magnitude_info = magnitude_result[:issues].map { |i| i[:message] }.join(". ")
          notes += " | ERROR DE MAGNITUD CORREGIDO: #{magnitude_info}"
        end

        @vehicle_km.update!(
          km_normalized: correction_result[:corrected_km],
          status: "estimado",
          confidence_level: confidence[:level],
          conflict_reasons_list: [],
          correction_notes: notes
        )
      else
        # No se pudo calcular la corrección (no debería pasar si can_interpolate = true)
        mark_as_conflictive_final(magnitude_result, check_result, true)
      end
    end

    def mark_as_conflictive_final(magnitude_result, check_result, can_correct)
      all_messages = []

      if magnitude_result[:has_magnitude_issue]
        all_messages += magnitude_result[:issues].map { |i| i[:message] }
      end

      if check_result[:has_conflict]
        all_messages += check_result[:conflicts].map { |c| c[:message] }
      end

      notes = if !can_correct
                "No se puede corregir automáticamente: faltan registros vecinos para interpolar."
      elsif !@vehicle.company.auto_correction_enabled
                "Corrección automática deshabilitada para esta empresa."
      else
                "No se pudo calcular una corrección válida."
      end

      @vehicle_km.update!(
        status: "conflictivo",
        km_normalized: @vehicle_km.km_reported,
        confidence_level: nil,
        conflict_reasons_list: all_messages,
        correction_notes: notes
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
