# app/api/v1/maintenances_api.rb
module V1
  class MaintenancesApi < Grape::API
    resource :maintenances do
      desc "Lista mantenimientos"
      params do
        optional :vehicle_id, type: Integer, desc: "Filtrar por vehículo"
        optional :from_date, type: Date, desc: "Fecha desde"
        optional :to_date, type: Date, desc: "Fecha hasta"
        optional :include_vehicle, type: Boolean, default: false
        optional :include_vehicle_km, type: Boolean, default: false
        optional :include_deleted, type: Boolean, default: false, desc: "Incluir mantenimientos eliminados"
        optional :page, type: Integer, default: 1
        optional :per_page, type: Integer, default: 25
      end
      get do
        # Base query: kept por defecto, o with_discarded si se pide
        maintenances = if params[:include_deleted]
                         Maintenance.with_discarded.includes(:vehicle, :company, :vehicle_km)
        else
                         Maintenance.kept.includes(:vehicle, :company, :vehicle_km)
        end

        maintenances = maintenances.where(vehicle_id: params[:vehicle_id]) if params[:vehicle_id]

        if params[:from_date] && params[:to_date]
          maintenances = maintenances.where(maintenance_date: params[:from_date]..params[:to_date])
        end

        maintenances = maintenances.ordered.page(params[:page]).per(params[:per_page])

        present maintenances, with: Entities::MaintenanceEntity,
                             include_vehicle: params[:include_vehicle],
                             include_vehicle_km: params[:include_vehicle_km]
      end

      desc "Obtener detalle completo de un mantenimiento"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
        optional :include_deleted, type: Boolean, default: false
      end
      route_param :id do
        get do
          maintenance = if params[:include_deleted]
                          Maintenance.with_discarded.includes(:vehicle, :vehicle_km, :company).find(params[:id])
          else
                          Maintenance.kept.includes(:vehicle, :vehicle_km, :company).find(params[:id])
          end

          present maintenance, with: Entities::MaintenanceDetailEntity
        end
      end

      desc "Crear un nuevo mantenimiento"
      params do
        requires :vehicle_id, type: Integer, desc: "ID del vehículo"
        requires :maintenance_date, type: Date, desc: "Fecha del mantenimiento"
        requires :register_km, type: Integer, desc: "Kilómetros registrados"
        optional :amount, type: BigDecimal, desc: "Importe"
        optional :description, type: String, desc: "Descripción"
        optional :create_km_record, type: Boolean, default: true, desc: "Crear registro de KM automáticamente"
      end
      post do
        result = Maintenances::CreateService.new(
          vehicle_id: params[:vehicle_id],
          params: declared_params.except(:vehicle_id)
        ).call

        if result[:success]
          response_data = {
            success: true,
            maintenance: present(result[:maintenance], with: Entities::MaintenanceDetailEntity)
          }

          response_data[:warnings] = result[:warnings] if result[:warnings].any?
          response_data
        else
          error!({ success: false, errors: result[:errors] }, 422)
        end
      end

      desc "Actualizar un mantenimiento"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
        optional :maintenance_date, type: Date, desc: "Fecha del mantenimiento"
        optional :register_km, type: Integer, desc: "Kilómetros registrados"
        optional :amount, type: BigDecimal, desc: "Importe"
        optional :description, type: String, desc: "Descripción"
        optional :update_km_record, type: Boolean, default: false, desc: "Actualizar también el registro de KM"
      end
      route_param :id do
        put do
          result = Maintenances::UpdateService.new(
            maintenance_id: params[:id],
            params: declared_params.except(:id)
          ).call

          if result[:success]
            response_data = {
              success: true,
              maintenance: present(result[:maintenance], with: Entities::MaintenanceDetailEntity)
            }

            response_data[:warnings] = result[:warnings] if result[:warnings].any?
            response_data
          else
            error!({ success: false, errors: result[:errors] }, 422)
          end
        end
      end

      desc "Eliminar un mantenimiento (soft delete con cascada opcional)"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
        optional :force, type: Boolean, default: false, desc: "Forzar eliminación ignorando advertencias"
        optional :preview, type: Boolean, default: false, desc: "Solo mostrar el impacto sin ejecutar"
        optional :delete_vehicle_km, type: String,
                 values: [ "delete", "keep" ],
                 desc: "Decisión sobre el VehicleKm asociado (si existe)"
      end
      route_param :id do
        delete do
          maintenance = Maintenance.kept.find(params[:id])

          # Preparar opciones de cascada si se especificaron
          cascade_options = {}
          if params[:delete_vehicle_km].present?
            cascade_options[:vehicle_km] = params[:delete_vehicle_km]
          end

          # Crear coordinador
          coordinator = SoftDelete::DeletionCoordinator.new(maintenance,
            force: params[:force],
            cascade_options: cascade_options
          )

          # Si se pide preview, solo analizar
          if params[:preview]
            preview = coordinator.preview
            return present({
              success: true,
              preview: preview,
              maintenance_id: maintenance.id,
              has_vehicle_km: maintenance.vehicle_km.present?,
              vehicle_km_info: maintenance.vehicle_km.present? ? {
                id: maintenance.vehicle_km.id,
                from_maintenance: maintenance.vehicle_km.from_maintenance?,
                can_delete_cascade: maintenance.can_delete_vehicle_km_cascade?
              } : nil
            })
          end

          # Ejecutar borrado
          result = coordinator.call

          if result[:success]
            present({
              success: true,
              message: result[:message],
              maintenance_id: maintenance.id,
              impact: {
                cascade_count: result[:cascade_count],
                nullify_count: result[:nullify_count]
              },
              warnings: result[:warnings],
              vehicle_km_deleted: result[:cascade_count] > 0
            })
          else
            error!({
              success: false,
              errors: result[:errors],
              warnings: result[:warnings],
              message: result[:message],
              requires_force: result[:requires_force],
              optional_cascades: result[:optional_cascades],
              impact: result[:impact]
            }, 422)
          end
        end
      end

      desc "Restaurar un mantenimiento eliminado"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento eliminado"
        optional :cascade_restore, type: Boolean, default: false, desc: "Restaurar también el VehicleKm en cascada"
        optional :reassign_to, type: Hash, desc: "Reasignar a otro vehículo si el original fue eliminado"
        optional :preview, type: Boolean, default: false, desc: "Solo mostrar viabilidad sin ejecutar"
      end
      route_param :id do
        post :restore do
          maintenance = Maintenance.discarded.find(params[:id])

          # Preparar opciones
          options = {
            cascade_restore: params[:cascade_restore]
          }

          if params[:reassign_to].present?
            options[:reassign_to] = params[:reassign_to].symbolize_keys
          end

          # Crear coordinador
          coordinator = SoftDelete::RestorationCoordinator.new(maintenance, options)

          # Si se pide preview, solo analizar
          if params[:preview]
            preview = coordinator.preview
            return present({
              success: true,
              preview: preview,
              maintenance_id: maintenance.id,
              has_cascaded_vehicle_km: preview.dig(:restoration_info, :cascaded_records)&.any?
            })
          end

          # Ejecutar restauración
          result = coordinator.call

          if result[:success]
            present({
              success: true,
              message: result[:message],
              maintenance: present(result[:record], with: Entities::MaintenanceDetailEntity),
              restored_count: result[:restored_count],
              warnings: result[:warnings]
            })
          else
            error!({
              success: false,
              errors: result[:errors],
              message: result[:message],
              conflicts: result[:conflicts],
              required_decisions: result[:required_decisions]
            }, 422)
          end
        end
      end

      desc "Verificar si un mantenimiento puede ser eliminado"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
      end
      route_param :id do
        get :can_delete do
          maintenance = Maintenance.kept.find(params[:id])
          impact = maintenance.deletion_impact

          present({
            success: true,
            can_delete: maintenance.can_be_deleted?,
            requires_force: impact[:warnings].any?,
            has_optional_cascades: impact[:will_cascade].any? { |c| c[:optional] },
            vehicle_km_info: maintenance.vehicle_km.present? ? {
              id: maintenance.vehicle_km.id,
              from_maintenance: maintenance.vehicle_km.from_maintenance?,
              can_delete_cascade: maintenance.can_delete_vehicle_km_cascade?,
              status_description: maintenance.vehicle_km_status_description
            } : nil,
            impact: impact
          })
        end
      end

      desc "Verificar si un mantenimiento eliminado puede ser restaurado"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento eliminado"
      end
      route_param :id do
        get :can_restore do
          maintenance = Maintenance.discarded.find(params[:id])
          info = maintenance.restoration_info

          present({
            success: true,
            can_restore: maintenance.can_be_restored?,
            has_cascaded_vehicle_km: info[:cascaded_records]&.any?,
            restoration_info: info
          })
        end
      end

      desc "Obtener resumen del impacto de borrado"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
      end
      route_param :id do
        get :deletion_summary do
          maintenance = Maintenance.kept.find(params[:id])
          summary = maintenance.deletion_impact_summary

          present({
            success: true,
            maintenance_id: maintenance.id,
            summary: summary,
            vehicle_km_info: maintenance.vehicle_km.present? ? {
              id: maintenance.vehicle_km.id,
              status: maintenance.vehicle_km.status,
              from_maintenance: maintenance.vehicle_km.from_maintenance?,
              status_description: maintenance.vehicle_km_status_description
            } : nil
          })
        end
      end

      desc "Sincronizar KM del mantenimiento con el histórico"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
      end
      route_param :id do
        post :sync_km do
          result = Maintenances::SyncKmService.new(
            maintenance_id: params[:id]
          ).call

          if result[:success]
            {
              success: true,
              message: result[:message],
              maintenance: present(result[:maintenance], with: Entities::MaintenanceDetailEntity)
            }
          else
            error!({ success: false, errors: result[:errors] }, 422)
          end
        end
      end

      desc "Obtener alertas de mantenimientos con problemas de KM"
      params do
        optional :vehicle_id, type: Integer, desc: "Filtrar por vehículo"
        optional :alert_type, type: String,
                 values: %w[eliminado sin_registro desincronizado conflictivo],
                 desc: "Tipo de alerta"
      end
      get :alerts do
        result = Maintenances::AlertsService.new(
          vehicle_id: params[:vehicle_id],
          alert_type: params[:alert_type]
        ).call

        result
      end
    end
  end
end
