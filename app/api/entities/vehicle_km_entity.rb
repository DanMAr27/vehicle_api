# app/api/entities/vehicle_km_entity.rb
module Entities
  class VehicleKmEntity < Grape::Entity
    expose :id
    expose :input_date
    expose :source
    expose :source_record_id
    expose :km_reported
    expose :km_normalized
    expose :effective_km, documentation: { desc: "KM efectivo (normalizado o reportado)" }
    expose :status
    expose :correction_notes
    expose :vehicle_id
    expose :company_id
    expose :created_at
    expose :updated_at
    expose :discarded_at

    # Información del vehículo (opcional)
    expose :vehicle, using: Entities::VehicleEntity, if: { include_vehicle: true }
  end
end
