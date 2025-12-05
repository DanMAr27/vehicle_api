# ============================================================
# app/services/vehicle_kms/create_service.rb
#
# Servicio para crear registros de KM y revalidar ventana
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
        detect_and_mark_conflicts_in_window
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

    def detect_and_mark_conflicts_in_window
      # Ejecutar detector
      detector = ConflictDetectorService.new(@vehicle_km)
      result = detector.call

      # Actualizar TODOS los registros en la ventana según el resultado
      result[:conflicts_by_id].each do |record_id, conflict_info|
        record = result[:window_records].find { |r| r.id == record_id }
        next unless record

        if conflict_info[:is_conflictive]
          # Marcar como conflictivo
          record.update!(
            status: "conflictivo",
            conflict_reasons_list: conflict_info[:reasons],
            correction_notes: "Detectado como conflictivo en validación de ventana"
          )
        else
          # Si estaba conflictivo y ahora es válido, restaurar
          if record.status == "conflictivo"
            record.update!(
              status: "original",
              conflict_reasons_list: [],
              correction_notes: "Conflicto resuelto tras inserción de nuevo registro"
            )
          end
        end
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
