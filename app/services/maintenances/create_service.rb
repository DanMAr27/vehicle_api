# app/services/maintenances/create_service.rb
module Maintenances
  class CreateService
    attr_reader :errors, :maintenance, :vehicle_km, :warnings

    def initialize(vehicle_id:, params:)
      @vehicle_id = vehicle_id
      @params = params
      @errors = []
      @warnings = []
      @maintenance = nil
      @vehicle_km = nil
    end

    def call
      validate_vehicle
      return failure unless @errors.empty?

      ActiveRecord::Base.transaction do
        create_maintenance
        create_km_record_if_requested
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

    def validate_vehicle
      @vehicle = Vehicle.kept.find_by(id: @vehicle_id)
      @errors << "Vehículo no encontrado" unless @vehicle
    end

    def create_maintenance
      @maintenance = Maintenance.create!(
        vehicle: @vehicle,
        company: @vehicle.company,
        maintenance_date: @params[:maintenance_date],
        register_km: @params[:register_km],
        amount: @params[:amount],
        description: @params[:description]
      )
    end

    def create_km_record_if_requested
      return unless @params[:create_km_record]

      # Pasar los campos polimórficos correctamente
      km_result = VehicleKms::CreateService.new(
        vehicle_id: @vehicle_id,
        params: {
          input_date: @params[:maintenance_date],
          km_reported: @params[:register_km],
          source_record_type: "Maintenance",  # ✅ Tipo del modelo
          source_record_id: @maintenance.id   # ✅ ID del registro
        }
      ).call

      if km_result[:success]
        @vehicle_km = km_result[:vehicle_km]

        # Vincular el maintenance con el vehicle_km (relación fuerte)
        @maintenance.update!(vehicle_km_id: @vehicle_km.id)

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
        maintenance: @maintenance,
        vehicle_km: @vehicle_km,
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
