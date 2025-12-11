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
        revalidate_and_correct_window
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

      # Si se está resolviendo un conflicto manualmente
      if @params[:resolve_conflict] && @vehicle_km.status == "conflictivo"
        new_km = @params[:km_normalized] || @params[:km_reported] || @vehicle_km.km_reported

        @vehicle_km.update!(
          km_normalized: new_km,
          status: "editado",
          conflict_reasons_list: [],
          correction_notes: @params[:correction_notes] || "Resuelto manualmente. KM anterior: #{old_km}"
        )
      else
        # Actualización normal
        update_attrs = {}

        if @params[:km_normalized] || @params[:km_reported]
          new_km = @params[:km_normalized] || @params[:km_reported]
          update_attrs[:km_reported] = new_km
          update_attrs[:km_normalized] = new_km
          update_attrs[:status] = "editado"
          update_attrs[:correction_notes] = @params[:correction_notes] || "Editado manualmente. KM anterior: #{old_km}"
        end

        if @params[:status]
          update_attrs[:status] = @params[:status]
        end

        if @params[:correction_notes] && update_attrs[:correction_notes].nil?
          update_attrs[:correction_notes] = @params[:correction_notes]
        end

        @vehicle_km.update!(update_attrs) if update_attrs.any?
      end
    end

    def revalidate_and_correct_window
      # Solo revalidar si se cambió el kilometraje
      return unless @params[:km_normalized] || @params[:km_reported]

      detector = ConflictDetectorService.new(@vehicle_km)
      result = detector.call

      if result[:has_conflict]
        result[:conflictive_records].each do |conflict_info|
          record = VehicleKm.find(conflict_info[:record_id])

          if record.id == @vehicle_km.id
            # El registro editado sigue siendo conflictivo
            record.update!(
              status: "editado",
              conflict_reasons_list: conflict_info[:reasons],
              correction_notes: @vehicle_km.correction_notes + " | Conflictivo tras edición"
            )
          else
            corrector = KmCorrectionService.new(record)
            correction_result = corrector.call

            if correction_result[:success]
              record.update!(
                km_normalized: correction_result[:corrected_km],
                status: "corregido",
                conflict_reasons_list: conflict_info[:reasons],
                correction_notes: correction_result[:notes]
              )
            else
              record.update!(
                km_normalized: record.km_reported,
                status: "conflictivo",
                conflict_reasons_list: conflict_info[:reasons],
                correction_notes: correction_result[:notes]
              )
            end
          end
        end

        result[:valid_records].each do |valid_id|
          record = VehicleKm.find(valid_id)
          next if record.id == @vehicle_km.id

          if %w[conflictivo corregido].include?(record.status)
            record.update!(
              km_normalized: record.km_reported,
              status: "original",
              conflict_reasons_list: [],
              correction_notes: "Restaurado tras edición de registro vecino"
            )
          end
        end
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
