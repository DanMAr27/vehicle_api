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
  end
end
