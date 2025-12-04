# app/services/vehicle_kms/delete_service.rb
module VehicleKms
  class DeleteService
    attr_reader :errors

    def initialize(vehicle_km_id:, discarded_by_id: nil)
      @vehicle_km_id = vehicle_km_id
      @discarded_by_id = discarded_by_id
      @errors = []
    end

    def call
      validate_record
      return failure unless @errors.empty?

      ActiveRecord::Base.transaction do
        soft_delete_record
        handle_maintenance_relation
        recalculate_vehicle_km
        success
      end
    rescue StandardError => e
      @errors << e.message
      failure
    end

    private

    def validate_record
      @vehicle_km = VehicleKm.kept.find_by(id: @vehicle_km_id)
      @errors << "Registro no encontrado" unless @vehicle_km
    end

    def soft_delete_record
      @vehicle_km.update!(
        discarded_at: Time.current,
        discarded_by_id: @discarded_by_id
      )
    end

    def handle_maintenance_relation
      # Si hay un mantenimiento asociado, desvincularlo
      return unless @vehicle_km.maintenance

      @vehicle_km.maintenance.update!(vehicle_km_id: nil)
    end

    def recalculate_vehicle_km
      # Recalcular el current_km del vehículo
      latest = VehicleKm.kept
                       .where(vehicle_id: @vehicle_km.vehicle_id)
                       .order(input_date: :desc, created_at: :desc)
                       .first

      new_km = latest ? latest.effective_km : 0
      @vehicle_km.vehicle.update!(current_km: new_km)
    end

    def success
      { success: true, vehicle_km: @vehicle_km }
    end

    def failure
      { success: false, errors: @errors }
    end
  end
end
