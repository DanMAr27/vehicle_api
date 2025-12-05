# app/api/entities/maintenance_detail_entity.rb
module Entities
  class MaintenanceDetailEntity < MaintenanceEntity
    expose :vehicle, using: Entities::VehicleEntity

    # Estado del registro de KM
    expose :km_info do |maintenance, options|
      {
        km_status: maintenance.km_status,
        manually_reported: maintenance.km_manually_reported?,
        desynchronized: maintenance.km_desynchronized?,
        current_effective_km: maintenance.vehicle_km&.effective_km,
        registered_km: maintenance.register_km,
        difference: maintenance.vehicle_km ?
                     (maintenance.register_km - maintenance.vehicle_km.effective_km) :
                     nil
      }
    end

    # Información del registro de KM asociado (si existe)
    expose :vehicle_km_detail, if: ->(maintenance, _) { maintenance.vehicle_km.present? } do
      expose :vehicle_km, using: Entities::VehicleKmEntity
      expose :km_history do |maintenance, options|
        if maintenance.vehicle_km
          maintenance.vehicle_km.versions.map do |v|
            {
              event: v.event,
              created_at: v.created_at,
              changes: v.changeset
            }
          end
        else
          []
        end
      end
    end

    # Historial de cambios del mantenimiento
    expose :maintenance_history do |maintenance, options|
      maintenance.versions.map do |v|
        {
          event: v.event,
          created_at: v.created_at,
          changes: v.changeset,
          whodunnit: v.whodunnit
        }
      end
    end

    # Alertas y advertencias
    expose :alerts do |maintenance, options|
      alerts = []

      if maintenance.km_status == "eliminado"
        alerts << {
          type: "warning",
          severity: "high",
          message: "El registro de KM asociado ha sido eliminado",
          detail: "El kilometraje registrado en este mantenimiento ya no está vinculado al histórico del vehículo"
        }
      end

      if maintenance.km_status == "sin_registro"
        alerts << {
          type: "info",
          severity: "low",
          message: "Este mantenimiento no tiene registro de KM asociado",
          detail: "El kilometraje solo está registrado en el mantenimiento, no en el histórico general"
        }
      end

      if maintenance.km_desynchronized?
        km_diff = maintenance.register_km - maintenance.vehicle_km.effective_km
        alerts << {
          type: "warning",
          severity: "medium",
          message: "Kilometraje desincronizado",
          detail: "El KM del mantenimiento (#{maintenance.register_km}) difiere del registro histórico (#{maintenance.vehicle_km.effective_km}). Diferencia: #{km_diff} km"
        }
      end

      if maintenance.vehicle_km&.status == "estimado"
        alerts << {
          type: "info",
          severity: "low",
          message: "Kilometraje estimado por el sistema",
          detail: maintenance.vehicle_km.correction_notes
        }
      end

      alerts
    end
  end
end
