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
        process_conflicts_and_corrections
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
      # Construir los atributos correctamente
      km_attributes = {
        vehicle: @vehicle,
        company: @vehicle.company,
        input_date: @params[:input_date],
        km_reported: @params[:km_reported],
        km_normalized: @params[:km_reported],
        status: "original"
      }

      # ✅ Agregar campos polimórficos si están presentes
      if @params[:source_record_type] && @params[:source_record_id]
        km_attributes[:source_record_type] = @params[:source_record_type]
        km_attributes[:source_record_id] = @params[:source_record_id]
      end

      @vehicle_km = VehicleKm.create!(km_attributes)
    end

    def process_conflicts_and_corrections
      detector = ConflictDetectorService.new(@vehicle_km)
      result = detector.call

      if result[:has_conflict]
        # Procesar registros conflictivos
        result[:conflictive_records].each do |conflict_info|
          record = VehicleKm.find(conflict_info[:record_id])

          corrector = KmCorrectionService.new(record)
          correction_result = corrector.call

          if correction_result[:success]
            record.update!(
              km_normalized: correction_result[:corrected_km],
              status: "corregido",
              conflict_reasons_list: conflict_info[:reasons],
              correction_notes: correction_result[:notes]
            )
          else
            record.update!(
              km_normalized: record.km_reported,
              status: "conflictivo",
              conflict_reasons_list: conflict_info[:reasons],
              correction_notes: correction_result[:notes]
            )
          end
        end

        # Restaurar registros que ahora son válidos
        result[:valid_records].each do |valid_id|
          record = VehicleKm.find(valid_id)

          if %w[conflictivo corregido].include?(record.status)
            record.update!(
              km_normalized: record.km_reported,
              status: "original",
              conflict_reasons_list: [],
              correction_notes: "Restaurado a secuencia válida tras nueva inserción"
            )
          end
        end
      else
        @vehicle_km.update!(
          km_normalized: @vehicle_km.km_reported,
          status: "original",
          conflict_reasons_list: []
        )
      end
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
        needs_review: @vehicle_km.needs_review?
      }
    end

    def failure
      { success: false, errors: @errors }
    end
  end
end
