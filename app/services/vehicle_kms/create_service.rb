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
        revalidate_affected_window if @params[:input_date] # Si es fecha pasada
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
        status: "original" # Temporalmente, se ajustará en process_validation_and_correction
      )
    end

    def process_validation_and_correction
      # 1. Verificar conflictos
      checker = CorrelationCheckService.new(@vehicle_km)
      check_result = checker.call

      # 2. Si no hay conflictos, dejar como original
      unless check_result[:has_conflict]
        @vehicle_km.update!(
          status: "original",
          confidence_level: nil,
          conflict_reasons_list: []
        )
        return
      end

      # 3. Hay conflictos - evaluar severidad y decidir acción
      high_severity_conflicts = check_result[:conflicts].select { |c| c[:severity] == "high" }

      if high_severity_conflicts.any?
        # Conflictos severos: marcar como conflictivo sin intentar corrección
        mark_as_conflictive(check_result[:conflicts])
      else
        # Conflictos medios: intentar corrección si hay suficiente confianza
        attempt_correction(check_result)
      end
    end

    def mark_as_conflictive(conflicts)
      @vehicle_km.update!(
        status: "conflictivo",
        km_normalized: @vehicle_km.km_reported,
        confidence_level: nil,
        conflict_reasons_list: conflicts.map { |c| c[:message] },
        correction_notes: "Conflicto detectado: #{conflicts.map { |c| c[:type] }.join(', ')}"
      )
    end

    def attempt_correction(check_result)
      # Calcular nivel de confianza
      confidence_calculator = ConfidenceCalculatorService.new(@vehicle_km)
      confidence = confidence_calculator.call

      # Si la confianza es baja, marcar como conflictivo
      if confidence[:level] == "low" || !@vehicle.company.auto_correction_enabled
        mark_as_conflictive(check_result[:conflicts])
        return
      end

      # Intentar corrección
      corrector = KmCorrectionService.new(@vehicle_km)
      correction_result = corrector.call

      if correction_result[:success] && correction_result[:corrected_km]
        @vehicle_km.update!(
          km_normalized: correction_result[:corrected_km],
          status: "estimado",
          confidence_level: confidence[:level],
          conflict_reasons_list: [],
          correction_notes: correction_result[:notes]
        )
      else
        # No se pudo corregir con confianza
        mark_as_conflictive(check_result[:conflicts])
      end
    end

    def revalidate_affected_window
      # Solo si es inserción a pasado (fecha anterior a hoy)
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
