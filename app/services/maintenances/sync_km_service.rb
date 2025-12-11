# app/services/maintenances/sync_km_service.rb
module Maintenances
  class SyncKmService
    attr_reader :errors, :maintenance, :message

    def initialize(maintenance_id:)
      @maintenance_id = maintenance_id
      @errors = []
      @message = ""
    end

    def call
      validate_maintenance
      return failure unless @errors.empty?

      ActiveRecord::Base.transaction do
        if needs_km_creation_or_restoration?
          handle_km_record
        elsif needs_km_update?
          update_km_record
        else
          @message = "El KM ya está sincronizado"
        end

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

    def needs_km_creation_or_restoration?
      # Sin registro o registro descartado
      @maintenance.vehicle_km.nil? || @maintenance.vehicle_km.discarded?
    end

    def needs_km_update?
      @maintenance.vehicle_km.present? &&
        !@maintenance.vehicle_km.discarded? &&
        @maintenance.km_desynchronized?
    end

    def handle_km_record
      existing_discarded = find_existing_discarded_km

      if existing_discarded
        restore_km_record(existing_discarded)
      else
        create_new_km_record
      end
    end

    def find_existing_discarded_km
      # Buscar si existe un registro descartado con los mismos datos
      VehicleKm.discarded
        .where(
          vehicle_id: @maintenance.vehicle_id,
          source_record_type: "Maintenance",
          source_record_id: @maintenance.id
        )
        .order(discarded_at: :desc)
        .first
    end

    def restore_km_record(km_record)
      # Actualizar datos por si cambiaron
      km_record.update!(
        input_date: @maintenance.maintenance_date,
        km_reported: @maintenance.register_km,
        km_normalized: @maintenance.register_km,
        discarded_at: nil
      )

      # Vincular al mantenimiento
      @maintenance.update!(vehicle_km_id: km_record.id)

      # Re-validar conflictos después de restaurar
      revalidate_after_restoration(km_record)

      @message = "Registro de KM restaurado y actualizado"
    end

    def create_new_km_record
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
        @message = "Registro de KM creado y vinculado"
      else
        @errors.concat(km_result[:errors])
        raise ActiveRecord::Rollback
      end
    end

    def update_km_record
      km_result = VehicleKms::UpdateService.new(
        vehicle_km_id: @maintenance.vehicle_km.id,
        params: {
          input_date: @maintenance.maintenance_date,
          km_reported: @maintenance.register_km,
          km_normalized: @maintenance.register_km
        }
      ).call

      if km_result[:success]
        @message = "Registro de KM actualizado"
      else
        @errors.concat(km_result[:errors])
        raise ActiveRecord::Rollback
      end
    end

    def revalidate_after_restoration(km_record)
      # Ejecutar validación de conflictos
      detector = VehicleKms::ConflictDetectorService.new(km_record)
      result = detector.call

      return unless result[:has_conflict]

      # Procesar conflictos detectados
      result[:conflictive_records].each do |conflict_info|
        record = VehicleKm.find(conflict_info[:record_id])

        corrector = VehicleKms::KmCorrectionService.new(record)
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

    def success
      {
        success: true,
        maintenance: @maintenance.reload,
        message: @message
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
