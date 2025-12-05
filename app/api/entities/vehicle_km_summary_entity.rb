# app/api/entities/vehicle_km_summary_entity.rb
module Entities
  class VehicleKmSummaryEntity < Grape::Entity
    expose :id
    expose :input_date
    expose :km_reported
    expose :effective_km
    expose :status
    expose :confidence_level, if: ->(vehicle_km, _) { vehicle_km.status == "estimado" }
    expose :needs_review do |vehicle_km|
      vehicle_km.status == "conflictivo"
    end
    expose :source

    # Indicador visual simple
    expose :status_badge do |vehicle_km|
      case vehicle_km.status
      when "original"
        { color: "success", label: "Original", icon: "check" }
      when "estimado"
        confidence_color = case vehicle_km.confidence_level
        when "high" then "info"
        when "medium" then "warning"
        when "low" then "warning"
        else "info"
        end
        { color: confidence_color, label: "Estimado", icon: "calculator" }
      when "conflictivo"
        { color: "danger", label: "Conflictivo", icon: "alert-triangle" }
      else
        { color: "secondary", label: "Desconocido", icon: "question" }
      end
    end
  end
end
