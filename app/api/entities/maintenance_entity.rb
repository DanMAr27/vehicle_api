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
    expose :created_at
    expose :updated_at
    expose :discarded_at
    expose :km_status do |maintenance|
      maintenance.km_status
    end
    expose :has_km_record do |maintenance|
      maintenance.vehicle_km.present?
    end
    expose :km_is_conflictive do |maintenance|
      maintenance.km_conflictive?
    end
    expose :km_is_desynchronized do |maintenance|
      maintenance.km_desynchronized?
    end
    expose :vehicle, using: Entities::VehicleEntity, if: { include_vehicle: true }
    expose :vehicle_km, using: Entities::VehicleKmEntity, if: { include_vehicle_km: true }
  end
end
