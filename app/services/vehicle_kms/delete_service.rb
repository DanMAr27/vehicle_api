# app/services/vehicle_kms/delete_service.rb
module VehicleKms
  class DeleteService
    attr_reader :errors

    def initialize(vehicle_km_id:, discarded_by_id: nil)
      @vehicle_km_id = vehicle_km_id
      @errors = []
    end

    def call
      validate_record
      return failure unless @errors.empty?

      ActiveRecord::Base.transaction do
        @vehicle_id = @vehicle_km.vehicle_id
        @input_date = @vehicle_km.input_date

        soft_delete_record
        handle_maintenance_relation
        revalidate_and_correct_after_deletion
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
      )
    end

    def handle_maintenance_relation
      # Buscar el mantenimiento correctamente
      return unless @vehicle_km.from_maintenance?

      # Buscar el mantenimiento que tiene este vehicle_km_id
      maintenance = Maintenance.kept.find_by(vehicle_km_id: @vehicle_km.id)

      return unless maintenance

      # Guardar versión con PaperTrail
      maintenance.paper_trail.save_with_version do
        maintenance.touch
      end

      @maintenance_affected = maintenance
    end

    def revalidate_and_correct_after_deletion
      window = build_window_around_deleted

      window.each do |record|
        detector = ConflictDetectorService.new(record)
        result = detector.call

        if result[:has_conflict]
          result[:conflictive_records].each do |conflict_info|
            rec = VehicleKm.find(conflict_info[:record_id])

            corrector = KmCorrectionService.new(rec)
            correction_result = corrector.call

            if correction_result[:success]
              rec.update!(
                km_normalized: correction_result[:corrected_km],
                status: "corregido",
                conflict_reasons_list: conflict_info[:reasons],
                correction_notes: correction_result[:notes]
              )
            else
              rec.update!(
                km_normalized: rec.km_reported,
                status: "conflictivo",
                conflict_reasons_list: conflict_info[:reasons],
                correction_notes: correction_result[:notes]
              )
            end
          end

          result[:valid_records].each do |valid_id|
            rec = VehicleKm.find(valid_id)
            if %w[conflictivo corregido].include?(rec.status)
              rec.update!(
                km_normalized: rec.km_reported,
                status: "original",
                conflict_reasons_list: [],
                correction_notes: "Restaurado tras eliminación de registro"
              )
            end
          end
        end
      end
    end

    def build_window_around_deleted
      previous_records = VehicleKm.kept
        .where(vehicle_id: @vehicle_id)
        .where("input_date < ?", @input_date)
        .order(input_date: :desc, id: :desc)
        .limit(5)
        .to_a

      next_records = VehicleKm.kept
        .where(vehicle_id: @vehicle_id)
        .where("input_date > ?", @input_date)
        .order(input_date: :asc, id: :asc)
        .limit(5)
        .to_a

      (previous_records + next_records).uniq
    end

    def recalculate_vehicle_km
      latest = VehicleKm.kept
        .where(vehicle_id: @vehicle_id)
        .order(input_date: :desc, created_at: :desc)
        .first

      new_km = latest ? latest.effective_km : 0
      Vehicle.find(@vehicle_id).update!(current_km: new_km)
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
          warning: "Este KM estaba asociado a un mantenimiento."
        }
      end

      result
    end

    def failure
      { success: false, errors: @errors }
    end
  end
end
