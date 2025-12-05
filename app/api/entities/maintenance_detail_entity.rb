# app/api/entities/maintenance_detail_entity.rb
module Entities
  class MaintenanceDetailEntity < MaintenanceEntity
    expose :vehicle, using: Entities::VehicleEntity

    # Estado del registro de KM
    expose :km_info do |maintenance, options|
      vehicle_km = maintenance.vehicle_km

      base_info = {
        km_status: maintenance.km_status,
        manually_reported: maintenance.km_manually_reported?,
        desynchronized: maintenance.km_desynchronized?,
        registered_km: maintenance.register_km
      }

      if vehicle_km
        base_info.merge!(
          current_effective_km: vehicle_km.effective_km,
          difference: maintenance.register_km - vehicle_km.effective_km,
          vehicle_km_status: vehicle_km.status,
          vehicle_km_confidence: vehicle_km.confidence_level,
          is_estimated: vehicle_km.status == "estimado",
          is_conflictive: vehicle_km.status == "conflictivo"
        )
      end

      base_info
    end

    # Información del registro de KM asociado (si existe)
    expose :vehicle_km_detail, if: ->(maintenance, _) { maintenance.vehicle_km.present? } do
      expose :vehicle_km, using: Entities::VehicleKmDetailEntity

      # Historial de cambios del KM (si existe PaperTrail)
      expose :km_history, if: ->(maintenance, _) { maintenance.vehicle_km&.respond_to?(:versions) } do |maintenance|
        maintenance.vehicle_km.versions.map do |v|
          {
            event: v.event,
            created_at: v.created_at,
            changes: v.changeset
          }
        end
      end
    end

    # Historial de cambios del mantenimiento
    expose :maintenance_history, if: ->(maintenance, _) { maintenance.respond_to?(:versions) } do |maintenance|
      maintenance.versions.map do |v|
        {
          event: v.event,
          created_at: v.created_at,
          changes: v.changeset,
          whodunnit: v.whodunnit
        }
      end
    end

    # Alertas y advertencias (actualizado con nuevos estados)
    expose :alerts do |maintenance, options|
      alerts = []
      vehicle_km = maintenance.vehicle_km

      # Alerta: KM eliminado
      if maintenance.km_status == "eliminado"
        alerts << {
          type: "warning",
          severity: "high",
          message: "El registro de KM asociado ha sido eliminado",
          detail: "El kilometraje registrado en este mantenimiento ya no está vinculado al histórico del vehículo"
        }
      end

      # Alerta: Sin registro de KM
      if maintenance.km_status == "sin_registro"
        alerts << {
          type: "info",
          severity: "low",
          message: "Este mantenimiento no tiene registro de KM asociado",
          detail: "El kilometraje solo está registrado en el mantenimiento, no en el histórico general"
        }
      end

      # Alerta: KM desincronizado
      if maintenance.km_desynchronized? && vehicle_km
        km_diff = maintenance.register_km - vehicle_km.effective_km
        alerts << {
          type: "warning",
          severity: "medium",
          message: "Kilometraje desincronizado",
          detail: "El KM del mantenimiento (#{maintenance.register_km}) difiere del registro histórico (#{vehicle_km.effective_km}). Diferencia: #{km_diff} km"
        }
      end

      # Alerta: KM estimado por el sistema
      if vehicle_km&.status == "estimado"
        alerts << {
          type: "info",
          severity: "low",
          message: "Kilometraje estimado por el sistema",
          detail: vehicle_km.correction_notes,
          confidence_level: vehicle_km.confidence_level
        }
      end

      # Alerta NUEVA: KM conflictivo
      if vehicle_km&.status == "conflictivo"
        alerts << {
          type: "error",
          severity: "high",
          message: "Registro de kilometraje conflictivo",
          detail: "El registro de KM tiene conflictos que requieren revisión manual",
          conflict_reasons: vehicle_km.conflict_reasons_list
        }
      end

      # Alerta NUEVA: Confianza baja en estimación
      if vehicle_km&.status == "estimado" && vehicle_km.confidence_level == "low"
        alerts << {
          type: "warning",
          severity: "medium",
          message: "Estimación con baja confianza",
          detail: "La corrección automática se realizó con pocos datos históricos. Se recomienda verificar manualmente."
        }
      end

      alerts
    end
  end
end
