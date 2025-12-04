# app/api/entities/maintenance_entity.rb
module Entities
  class MaintenanceEntity < Grape::Entity
    expose :id
    expose :maintenance_date
    expose :register_km
    expose :amount
    expose :description
    expose :vehicle_id
    expose :company_id
    expose :vehicle_km_id
    expose :created_at
    expose :updated_at
    expose :discarded_at

    # Relaciones opcionales
    expose :vehicle, using: Entities::VehicleEntity, if: { include_vehicle: true }
    expose :vehicle_km, using: Entities::VehicleKmEntity, if: { include_vehicle_km: true }
  end
end
