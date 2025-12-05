# ============================================================
# app/services/vehicle_kms/create_service.rb
# ============================================================
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
        process_conflicts
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

    def process_conflicts
      detector = ConflictDetectorService.new(@vehicle_km)
      result = detector.call

      if result[:has_conflict]
        # Actualizar TODOS los registros conflictivos detectados
        result[:conflictive_records].each do |conflict_info|
          record = VehicleKm.find(conflict_info[:record_id])
          record.update!(
            status: "conflictivo",
            conflict_reasons_list: conflict_info[:reasons],
            correction_notes: "Rompe monotonicidad - detectado por análisis de ventana"
          )
        end

        # Restaurar registros que ahora son válidos
        result[:valid_records].each do |valid_id|
          record = VehicleKm.find(valid_id)
          if record.status == "conflictivo"
            record.update!(
              status: "original",
              conflict_reasons_list: [],
              correction_notes: "Monotonicidad restaurada tras nueva inserción"
            )
          end
        end
      else
        # No hay conflicto
        @vehicle_km.update!(
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

      @vehicle.update!(current_km: latest.km_reported) if latest
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
