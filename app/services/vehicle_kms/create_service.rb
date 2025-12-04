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
        check_and_correct_correlation
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
        km_normalized: @params[:km_reported], # Inicialmente igual
        status: "original"
      )
    end

    def check_and_correct_correlation
      checker = CorrelationCheckService.new(@vehicle_km)
      return unless checker.call[:has_conflict]

      corrector = KmCorrectionService.new(@vehicle_km)
      result = corrector.call

      if result[:success]
        @vehicle_km.update!(
          km_normalized: result[:corrected_km],
          status: "estimado",
          correction_notes: result[:notes]
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
      { success: true, vehicle_km: @vehicle_km }
    end

    def failure
      { success: false, errors: @errors }
    end
  end
end
