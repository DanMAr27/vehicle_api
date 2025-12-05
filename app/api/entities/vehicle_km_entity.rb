# app/api/entities/vehicle_km_entity.rb
module Entities
  class VehicleKmEntity < Grape::Entity
    expose :id
    expose :input_date
    expose :source
    expose :source_record_id
    expose :km_reported, documentation: { desc: "KM reportado originalmente" }
    expose :km_normalized, documentation: { desc: "KM normalizado/corregido por el sistema" }
    expose :effective_km, documentation: { desc: "KM efectivo (normalizado si es estimado, reportado si es original)" }
    expose :status, documentation: {
      desc: "Estado del registro",
      values: [ "original", "estimado", "conflictivo" ]
    }
    expose :confidence_level, documentation: {
      desc: "Nivel de confianza de la estimación (solo para status=estimado)",
      values: [ "high", "medium", "low" ]
    }
    expose :correction_notes, documentation: { desc: "Notas sobre la corrección aplicada" }
    expose :conflict_reasons, documentation: { desc: "Razones del conflicto (JSON array)" }
    expose :vehicle_id
    expose :company_id
    expose :created_at
    expose :updated_at
    expose :discarded_at

    # Información del vehículo (opcional)
    expose :vehicle, using: Entities::VehicleEntity, if: { include_vehicle: true }

    # Helper para mostrar las razones de conflicto como array
    expose :conflict_reasons_list, if: ->(vehicle_km, _) { vehicle_km.status == "conflictivo" } do |vehicle_km|
      vehicle_km.conflict_reasons_list
    end

    # Indicador visual del estado
    expose :needs_review, documentation: { desc: "Indica si el registro requiere revisión manual" } do |vehicle_km|
      vehicle_km.status == "conflictivo"
    end
  end
end
