# app/services/vehicle_kms/update_service.rb
module VehicleKms
  class UpdateService
    attr_reader :errors

    def initialize(vehicle_km_id:, params:)
      @vehicle_km_id = vehicle_km_id
      @params = params
      @errors = []
    end

    def call
      validate_record
      return failure unless @errors.empty?

      ActiveRecord::Base.transaction do
        update_km_record
        recalculate_correlations
        update_vehicle_current_km
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

    def update_km_record
      old_km = @vehicle_km.km_normalized || @vehicle_km.km_reported
      new_km = @params[:km_normalized] || @params[:km_reported]

      @vehicle_km.update!(
        km_normalized: new_km,
        status: "editado",
        correction_notes: "Editado manualmente. KM anterior: #{old_km}"
      )
    end

    def recalculate_correlations
      # Recalcular registros posteriores que puedan verse afectados
      affected = VehicleKm.kept
                         .where(vehicle_id: @vehicle_km.vehicle_id)
                         .where("input_date > ?", @vehicle_km.input_date)
                         .where(status: "estimado")

      affected.each do |record|
        corrector = KmCorrectionService.new(record)
        result = corrector.call

        record.update!(
          km_normalized: result[:corrected_km],
          correction_notes: result[:notes]
        ) if result[:success]
      end
    end

    def update_vehicle_current_km
      latest = VehicleKm.kept
                       .where(vehicle_id: @vehicle_km.vehicle_id)
                       .order(input_date: :desc, created_at: :desc)
                       .first

      @vehicle_km.vehicle.update!(current_km: latest.effective_km) if latest
    end

    def success
      { success: true, vehicle_km: @vehicle_km }
    end

    def failure
      { success: false, errors: @errors }
    end
  end
end
