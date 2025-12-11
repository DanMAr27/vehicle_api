# app/api/v1/vehicles_api.rb
module V1
  class VehiclesApi < Grape::API
    resource :vehicles do
      desc "Lista todos los vehículos"
      params do
        optional :company_id, type: Integer, desc: "Filtrar por compañía"
        optional :include_deleted, type: Boolean, default: false, desc: "Incluir vehículos eliminados"
        optional :only_deleted, type: Boolean, default: false, desc: "Solo vehículos eliminados"
        optional :page, type: Integer, default: 1, desc: "Página"
        optional :per_page, type: Integer, default: 25, desc: "Registros por página"
      end
      get do
        # Base query según parámetros
        vehicles = if params[:only_deleted]
                     Vehicle.discarded.includes(:company)
        elsif params[:include_deleted]
                     Vehicle.with_discarded.includes(:company)
        else
                     Vehicle.kept.includes(:company)
        end

        vehicles = vehicles.where(company_id: params[:company_id]) if params[:company_id]
        vehicles = vehicles.page(params[:page]).per(params[:per_page])

        present vehicles, with: Entities::VehicleEntity
      end

      desc "Obtener un vehículo específico"
      params do
        requires :id, type: Integer, desc: "ID del vehículo"
        optional :include_deleted, type: Boolean, default: false
        optional :include_stats, type: Boolean, default: false, desc: "Incluir estadísticas de KMs y mantenimientos"
      end
      route_param :id do
        get do
          vehicle = if params[:include_deleted]
                      Vehicle.with_discarded.find(params[:id])
          else
                      Vehicle.kept.find(params[:id])
          end

          response = present(vehicle, with: Entities::VehicleEntity)

          if params[:include_stats] && vehicle.kept?
            response.merge!(
              km_stats: vehicle.km_stats,
              maintenance_stats: vehicle.maintenance_stats
            )
          end

          response
        end
      end

      desc "Crear un nuevo vehículo"
      params do
        requires :matricula, type: String, desc: "Matrícula del vehículo"
        optional :vin, type: String, desc: "VIN del vehículo"
        optional :current_km, type: Integer, default: 0, desc: "Kilómetros actuales"
        requires :company_id, type: Integer, desc: "ID de la compañía"
      end
      post do
        vehicle = Vehicle.create!(declared_params)
        present vehicle, with: Entities::VehicleEntity
      end

      desc "Actualizar un vehículo"
      params do
        requires :id, type: Integer, desc: "ID del vehículo"
        optional :matricula, type: String, desc: "Matrícula del vehículo"
        optional :vin, type: String, desc: "VIN del vehículo"
      end
      route_param :id do
        put do
          vehicle = Vehicle.kept.find(params[:id])
          vehicle.update!(declared_params.except(:id))
          present vehicle, with: Entities::VehicleEntity
        end
      end

      desc "Eliminar un vehículo (soft delete con cascada automática de todos los datos)"
      params do
        requires :id, type: Integer, desc: "ID del vehículo"
        optional :force, type: Boolean, default: false, desc: "Forzar eliminación ignorando advertencias"
        optional :preview, type: Boolean, default: false, desc: "Solo mostrar el impacto sin ejecutar"
      end
      route_param :id do
        delete do
          vehicle = Vehicle.kept.find(params[:id])

          # Crear coordinador
          coordinator = SoftDelete::DeletionCoordinator.new(vehicle,
            force: params[:force]
          )

          # Si se pide preview, solo analizar
          if params[:preview]
            preview = coordinator.preview

            # Agregar información adicional útil
            return present({
              success: true,
              preview: preview,
              vehicle_id: vehicle.id,
              vehicle_info: {
                matricula: vehicle.matricula,
                current_km: vehicle.current_km,
                company_name: vehicle.company.name
              },
              impact_summary: {
                total_records_to_delete: preview.dig(:impact, :total_affected) || 0,
                vehicle_kms_count: vehicle.vehicle_kms.kept.count,
                maintenances_count: vehicle.maintenances.kept.count,
                conflictive_kms_count: vehicle.vehicle_kms.kept.conflictive.count,
                estimated_time: preview.dig(:impact, :estimated_time)
              }
            })
          end

          # Ejecutar borrado
          result = coordinator.call

          if result[:success]
            present({
              success: true,
              message: result[:message],
              vehicle_id: vehicle.id,
              impact: {
                cascade_count: result[:cascade_count],
                nullify_count: result[:nullify_count]
              },
              warnings: result[:warnings],
              audit_log_id: result[:audit_log]&.id
            })
          else
            error!({
              success: false,
              errors: result[:errors],
              warnings: result[:warnings],
              message: result[:message],
              requires_force: result[:requires_force],
              impact: result[:impact]
            }, 422)
          end
        end
      end

      desc "Restaurar un vehículo eliminado"
      params do
        requires :id, type: Integer, desc: "ID del vehículo eliminado"
        optional :cascade_restore, type: Boolean, default: false, desc: "Restaurar también KMs y mantenimientos en cascada"
        optional :reassign_to, type: Hash, desc: "Reasignar a otra compañía si la original fue eliminada"
        optional :preview, type: Boolean, default: false, desc: "Solo mostrar viabilidad sin ejecutar"
      end
      route_param :id do
        post :restore do
          vehicle = Vehicle.discarded.find(params[:id])

          # Preparar opciones
          options = {
            cascade_restore: params[:cascade_restore]
          }

          if params[:reassign_to].present?
            options[:reassign_to] = params[:reassign_to].symbolize_keys
          end

          # Crear coordinador
          coordinator = SoftDelete::RestorationCoordinator.new(vehicle, options)

          # Si se pide preview, solo analizar
          if params[:preview]
            preview = coordinator.preview

            # Agregar información adicional
            cascaded = preview.dig(:restoration_info, :cascaded_records) || []
            total_cascaded = cascaded.sum { |c| c[:count] }

            return present({
              success: true,
              preview: preview,
              vehicle_id: vehicle.id,
              vehicle_info: {
                matricula: vehicle.matricula,
                company_name: vehicle.company.name
              },
              restoration_summary: {
                total_cascaded_records: total_cascaded,
                vehicle_kms_discarded: cascaded.find { |c| c[:relation] == "Vehicle Kms" }&.dig(:count) || 0,
                maintenances_discarded: cascaded.find { |c| c[:relation] == "Maintenances" }&.dig(:count) || 0,
                estimated_time: preview.dig(:restoration_info, :estimated_time),
                is_massive_restoration: total_cascaded > 100
              }
            })
          end

          # Ejecutar restauración
          result = coordinator.call

          if result[:success]
            present({
              success: true,
              message: result[:message],
              vehicle: present(result[:record], with: Entities::VehicleEntity),
              restored_count: result[:restored_count],
              warnings: result[:warnings],
              audit_log_id: result[:audit_log]&.id
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

      desc "Verificar si un vehículo puede ser eliminado"
      params do
        requires :id, type: Integer, desc: "ID del vehículo"
      end
      route_param :id do
        get :can_delete do
          vehicle = Vehicle.kept.find(params[:id])
          impact = vehicle.deletion_impact

          present({
            success: true,
            can_delete: vehicle.can_be_deleted?,
            requires_force: impact[:warnings].any?,
            impact: impact,
            summary: {
              total_records_to_delete: impact[:total_affected],
              vehicle_kms_count: vehicle.vehicle_kms.kept.count,
              maintenances_count: vehicle.maintenances.kept.count,
              conflictive_kms_count: vehicle.vehicle_kms.kept.conflictive.count,
              estimated_time: impact[:estimated_time],
              is_massive_operation: impact[:total_affected] > 100
            }
          })
        end
      end

      desc "Verificar si un vehículo eliminado puede ser restaurado"
      params do
        requires :id, type: Integer, desc: "ID del vehículo eliminado"
      end
      route_param :id do
        get :can_restore do
          vehicle = Vehicle.discarded.find(params[:id])
          info = vehicle.restoration_info

          cascaded = info[:cascaded_records] || []
          total_cascaded = cascaded.sum { |c| c[:count] }

          present({
            success: true,
            can_restore: vehicle.can_be_restored?,
            restoration_info: info,
            summary: {
              total_cascaded_records: total_cascaded,
              is_massive_restoration: total_cascaded > 100,
              restore_options_count: info[:restore_options]&.count || 0
            }
          })
        end
      end

      desc "Obtener resumen completo del impacto de borrado"
      params do
        requires :id, type: Integer, desc: "ID del vehículo"
      end
      route_param :id do
        get :deletion_summary do
          vehicle = Vehicle.kept.find(params[:id])
          summary = vehicle.deletion_impact_summary

          present({
            success: true,
            vehicle_id: vehicle.id,
            vehicle_info: {
              matricula: vehicle.matricula,
              vin: vehicle.vin,
              current_km: vehicle.current_km,
              company_name: vehicle.company.name
            },
            summary: summary,
            risk_level: vehicle.deletion_risk_level
          })
        end
      end

      desc "Obtener información de restauración de un vehículo eliminado"
      params do
        requires :id, type: Integer, desc: "ID del vehículo eliminado"
      end
      route_param :id do
        get :restoration_viability do
          vehicle = Vehicle.discarded.find(params[:id])
          viability = vehicle.restoration_viability

          present({
            success: true,
            vehicle_id: vehicle.id,
            vehicle_info: {
              matricula: vehicle.matricula,
              company_name: vehicle.company.name,
              deleted_at: vehicle.discarded_at
            },
            viability: viability
          })
        end
      end

      desc "Obtener estado de eliminación de un vehículo"
      params do
        requires :id, type: Integer, desc: "ID del vehículo"
      end
      route_param :id do
        get :deletion_status do
          vehicle = Vehicle.with_discarded.find(params[:id])

          status_info = {
            vehicle_id: vehicle.id,
            matricula: vehicle.matricula,
            is_deleted: vehicle.discarded?,
            status_description: vehicle.deletion_status_description
          }

          if vehicle.discarded?
            # Información adicional para vehículos eliminados
            deletion_log = SoftDeleteAuditLog
              .deletions
              .for_record(vehicle)
              .order(performed_at: :desc)
              .first

            status_info.merge!(
              deleted_at: vehicle.discarded_at,
              can_be_restored: vehicle.can_be_restored?,
              deletion_log_id: deletion_log&.id,
              cascade_count: deletion_log&.cascade_count || 0,
              restore_complexity: deletion_log&.restore_complexity
            )
          else
            # Información adicional para vehículos activos
            status_info.merge!(
              total_km_records: vehicle.vehicle_kms.kept.count,
              total_maintenances: vehicle.maintenances.kept.count,
              conflictive_kms: vehicle.vehicle_kms.kept.conflictive.count
            )
          end

          present(status_info)
        end
      end
    end
  end
end
