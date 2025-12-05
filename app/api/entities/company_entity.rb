# app/api/entities/company_entity.rb
module Entities
  class CompanyEntity < Grape::Entity
    expose :id
    expose :name
    expose :cif
    expose :created_at
    expose :updated_at

    # Nuevos campos de configuración de KM
    expose :max_daily_km_tolerance, documentation: {
      desc: "Máximo de km diarios permitido antes de marcar como conflicto (null = sin validación)"
    }
    expose :auto_correction_enabled, documentation: {
      desc: "Si está habilitada la corrección automática de km conflictivos"
    }
    expose :min_neighbors_for_correction, documentation: {
      desc: "Mínimo de registros vecinos requeridos para aplicar corrección automática"
    }
  end
end
