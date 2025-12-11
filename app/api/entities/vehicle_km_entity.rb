# app/api/entities/vehicle_km_entity.rb
module Entities
  class VehicleKmEntity < Grape::Entity
    expose :id
    expose :input_date
    expose :km_reported, documentation: { desc: "KM reportado originalmente" }
    expose :km_normalized, documentation: { desc: "KM normalizado/corregido por el sistema" }
    expose :effective_km, documentation: {
      desc: "KM efectivo (normalizado si existe, reportado si no)"
    } do |vehicle_km|
      vehicle_km.effective_km
    end

    expose :status, documentation: {
      desc: "Estado del registro",
      values: [ "original", "corregido", "editado", "conflictivo" ]
    }

    expose :correction_notes, documentation: {
      desc: "Notas sobre la corrección/conflicto aplicada"
    }

    expose :conflict_reasons_list, as: :conflict_reasons, documentation: {
      desc: "Lista de razones del conflicto (array)"
    }
    expose :source_info do |vehicle_km|
      if vehicle_km.source_record.nil?
        { type: "manual", description: "Registro manual" }
      else
        {
          type: vehicle_km.source_record_type,
          id: vehicle_km.source_record_id,
          description: vehicle_km.source_description
        }
      end
    end
    expose :source_record, if: { include_source: true } do |vehicle_km|
      case vehicle_km.source_record_type
      when "Maintenance"
        Entities::MaintenanceEntity.represent(vehicle_km.source_record) if vehicle_km.source_record
      else
        nil
      end
    end
    expose :vehicle_id
    expose :company_id
    expose :created_at
    expose :updated_at
    expose :discarded_at
    expose :vehicle, using: Entities::VehicleEntity, if: { include_vehicle: true }
    expose :needs_review, documentation: {
      desc: "Indica si el registro requiere revisión manual"
    } do |vehicle_km|
      vehicle_km.needs_review?
    end
    expose :is_manual do |vehicle_km|
      vehicle_km.manually_created?
    end
    expose :is_from_maintenance do |vehicle_km|
      vehicle_km.from_maintenance?
    end
    expose :is_auto_corrected do |vehicle_km|
      vehicle_km.auto_corrected?
    end
    expose :is_manually_edited do |vehicle_km|
      vehicle_km.manually_edited?
    end
  end
end
