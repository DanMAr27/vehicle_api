# app/api/entities/company_entity.rb
module Entities
  class CompanyEntity < Grape::Entity
    expose :id
    expose :name
    expose :cif
    expose :created_at
    expose :updated_at
    expose :max_daily_km_tolerance, documentation: {
      desc: "Máximo de km diarios permitido antes de marcar como conflicto (null = sin validación)"
    }
    expose :km_stats, if: { include_stats: true } do |company|
      company.km_stats
    end
  end
end
