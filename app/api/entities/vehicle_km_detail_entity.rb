# app/api/entities/vehicle_km_detail_entity.rb

module Entities
  class VehicleKmDetailEntity < VehicleKmEntity
    # Información de conflictos detallada
    expose :conflict_analysis do |vehicle_km, options|
      detector = VehicleKms::ConflictDetectorService.new(vehicle_km)
      result = detector.call

      {
        has_conflict: result[:has_conflict],
        current_is_conflictive: result[:current_is_conflictive],
        conflictive_records: result[:conflictive_records].map do |conflict|
          {
            record_id: conflict[:record_id],
            date: conflict[:date],
            km: conflict[:km],
            reasons: conflict[:reasons]
          }
        end,
        valid_records_count: result[:valid_records].size
      }
    end

    # Información de corrección potencial
    expose :correction_info, if: ->(vehicle_km, _) {
      vehicle_km.status == "conflictivo"
    } do |vehicle_km|
      corrector = VehicleKms::KmCorrectionService.new(vehicle_km)
      result = corrector.call

      {
        can_be_corrected: result[:success],
        suggested_km: result[:corrected_km],
        correction_method: result[:method],
        notes: result[:notes]
      }
    end

    # Comparación entre KM reportado y normalizado
    expose :correction_summary, if: ->(vehicle_km, _) {
      vehicle_km.status == "corregido"
    } do |vehicle_km|
      {
        original_km: vehicle_km.km_reported,
        corrected_km: vehicle_km.km_normalized,
        difference: vehicle_km.correction_difference,
        difference_percentage: vehicle_km.correction_percentage,
        correction_notes: vehicle_km.correction_notes
      }
    end

    # Contexto de registros vecinos
    expose :neighbor_context do |vehicle_km|
      vehicle = vehicle_km.vehicle

      previous = VehicleKm.kept
        .where(vehicle_id: vehicle.id)
        .where("input_date < ? OR (input_date = ? AND id < ?)",
               vehicle_km.input_date, vehicle_km.input_date, vehicle_km.id)
        .order(input_date: :desc, id: :desc)
        .first

      next_record = VehicleKm.kept
        .where(vehicle_id: vehicle.id)
        .where("input_date > ? OR (input_date = ? AND id > ?)",
               vehicle_km.input_date, vehicle_km.input_date, vehicle_km.id)
        .order(input_date: :asc, id: :asc)
        .first

      {
        previous_record: previous ? {
          id: previous.id,
          input_date: previous.input_date,
          km: previous.effective_km,
          status: previous.status
        } : nil,
        next_record: next_record ? {
          id: next_record.id,
          input_date: next_record.input_date,
          km: next_record.effective_km,
          status: next_record.status
        } : nil
      }
    end

    # Historial de versiones
    expose :version_history, if: ->(vehicle_km, _) {
      vehicle_km.respond_to?(:versions)
    } do |vehicle_km|
      vehicle_km.versions.last(10).map do |v|
        {
          event: v.event,
          created_at: v.created_at,
          whodunnit: v.whodunnit,
          changes: v.changeset
        }
      end
    end
  end
end
