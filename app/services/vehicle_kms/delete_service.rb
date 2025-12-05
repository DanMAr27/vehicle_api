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
      # Si hay un mantenimiento asociado, NO lo desvinculamos
      # El mantenimiento mantiene la referencia al vehicle_km_id eliminado
      # Esto permite rastrear que hubo un registro de KM y fue eliminado
      return unless @vehicle_km.maintenance

      # Registramos en las notas que el KM del mantenimiento fue eliminado
      @vehicle_km.maintenance.paper_trail.save_with_version do
        # PaperTrail registrará este cambio
        @vehicle_km.maintenance.touch # Forzar actualización de updated_at
      end

      @maintenance_affected = @vehicle_km.maintenance
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
      result = {
        success: true,
        vehicle_km: @vehicle_km,
        message: "Registro de KM eliminado correctamente"
      }

      if @maintenance_affected
        result[:maintenance_affected] = {
          id: @maintenance_affected.id,
          warning: "Este KM estaba asociado a un mantenimiento. El mantenimiento mantiene la referencia pero el registro KM está eliminado."
        }
      end

      result
    end

    def failure
      { success: false, errors: @errors }
    end
  end
end
