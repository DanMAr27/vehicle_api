# app/api/entities/vehicle_entity.rb
module Entities
  class VehicleEntity < Grape::Entity
    expose :id
    expose :matricula
    expose :vin
    expose :current_km
    expose :company, using: Entities::CompanyEntity
    expose :created_at
    expose :updated_at
    expose :has_conflictive_kms do |vehicle|
      vehicle.has_conflictive_kms?
    end
    expose :km_stats, if: { include_stats: true } do |vehicle|
      vehicle.km_stats
    end
  end
end
