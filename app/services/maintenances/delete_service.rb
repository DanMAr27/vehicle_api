# app/services/maintenances/delete_service.rb
module Maintenances
  class DeleteService
    attr_reader :errors, :maintenance, :notes

    def initialize(maintenance_id:, delete_km_record: true) # ✅ Por defecto TRUE
      @maintenance_id = maintenance_id
      @delete_km_record = delete_km_record
      @errors = []
      @notes = []
    end

    def call
      validate_maintenance
      return failure unless @errors.empty?

      ActiveRecord::Base.transaction do
        delete_km_record_if_needed
        soft_delete_maintenance
        success
      end
    rescue StandardError => e
      @errors << e.message
      failure
    end

    private

    def validate_maintenance
      @maintenance = Maintenance.kept.find_by(id: @maintenance_id)
      @errors << "Mantenimiento no encontrado" unless @maintenance
    end

    def delete_km_record_if_needed
      return unless @maintenance.vehicle_km.present?
      return unless @maintenance.vehicle_km.kept? # Solo si no está ya descartado

      # Por defecto eliminamos el KM asociado (comportamiento en cascada)
      if @delete_km_record
        km_result = VehicleKms::DeleteService.new(
          vehicle_km_id: @maintenance.vehicle_km.id
        ).call

        if km_result[:success]
          @notes << "Registro de KM eliminado automáticamente (cascada)"
        else
          # Si falla, registramos pero no detenemos el proceso
          @notes << "Advertencia: No se pudo eliminar el KM: #{km_result[:errors].join(', ')}"
        end
      else
        # Desvincular sin eliminar
        @maintenance.update!(vehicle_km_id: nil)
        @notes << "Registro de KM desvinculado pero no eliminado"
      end
    end

    def soft_delete_maintenance
      @maintenance.discard
      @notes << "Mantenimiento eliminado correctamente"
    end

    def success
      {
        success: true,
        maintenance: @maintenance,
        message: @notes.first,
        notes: @notes
      }
    end

    def failure
      {
        success: false,
        errors: @errors
      }
    end
  end
end
