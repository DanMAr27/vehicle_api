# app/services/maintenances/update_service.rb
module Maintenances
  class UpdateService
    attr_reader :errors, :maintenance, :warnings

    def initialize(maintenance_id:, params:)
      @maintenance_id = maintenance_id
      @params = params
      @errors = []
      @warnings = []
    end

    def call
      validate_maintenance
      return failure unless @errors.empty?

      ActiveRecord::Base.transaction do
        update_maintenance
        update_km_record_if_requested
        success
      end
    rescue ActiveRecord::RecordInvalid => e
      @errors << e.message
      failure
    rescue StandardError => e
      @errors << e.message
      failure
    end

    private

    def validate_maintenance
      @maintenance = Maintenance.kept.find_by(id: @maintenance_id)
      @errors << "Mantenimiento no encontrado" unless @maintenance
    end

    def update_maintenance
      # Actualizar primero el maintenance para tener los nuevos valores
      update_params = @params.except(:update_km_record, :create_km_record)
      @maintenance.update!(update_params)
    end

    def update_km_record_if_requested
      # Permitir crear KM si no existe
      if @params[:create_km_record] && @maintenance.vehicle_km.nil?
        create_km_record
        return
      end

      # Actualizar KM existente
      return unless @params[:update_km_record]
      return unless @maintenance.vehicle_km.present?
      return unless @params[:register_km].present?

      km_result = VehicleKms::UpdateService.new(
        vehicle_km_id: @maintenance.vehicle_km.id,
        params: {
          km_reported: @params[:register_km],
          km_normalized: @params[:register_km]
        }
      ).call

      unless km_result[:success]
        @errors.concat(km_result[:errors])
        raise ActiveRecord::Rollback
      end

      if km_result[:vehicle_km]&.needs_review?
        @warnings << "El registro de KM actualizado está en conflicto"
      end
    end

    def create_km_record
      # Crear KM desde update si no existe
      km_result = VehicleKms::CreateService.new(
        vehicle_id: @maintenance.vehicle_id,
        params: {
          input_date: @maintenance.maintenance_date,
          km_reported: @maintenance.register_km,
          source_record_type: "Maintenance",
          source_record_id: @maintenance.id
        }
      ).call

      if km_result[:success]
        @maintenance.update!(vehicle_km_id: km_result[:vehicle_km].id)
        @warnings << "Registro de KM creado y vinculado"

        if km_result[:needs_review]
          @warnings << "El registro de KM fue marcado como conflictivo y requiere revisión"
        end
      else
        @errors.concat(km_result[:errors])
        raise ActiveRecord::Rollback
      end
    end

    def success
      {
        success: true,
        maintenance: @maintenance.reload,
        warnings: @warnings
      }
    end

    def failure
      {
        success: false,
        errors: @errors,
        maintenance: @maintenance
      }
    end
  end
end
