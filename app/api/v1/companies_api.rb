# app/api/v1/companies_api.rb
module V1
  class CompaniesApi < Grape::API
    resource :companies do
      desc "Lista todas las compañías"
      params do
        optional :include_deleted, type: Boolean, default: false, desc: "Incluir compañías eliminadas"
        optional :only_deleted, type: Boolean, default: false, desc: "Solo compañías eliminadas"
        optional :with_stats, type: Boolean, default: false, desc: "Incluir estadísticas de cada compañía"
        optional :page, type: Integer, default: 1, desc: "Página"
        optional :per_page, type: Integer, default: 25, desc: "Registros por página"
      end
      get do
        # Base query según parámetros
        companies = if params[:only_deleted]
                      Company.discarded
        elsif params[:include_deleted]
                      Company.with_discarded
        else
                      Company.kept
        end

        companies = companies.page(params[:page]).per(params[:per_page])

        response = present companies, with: Entities::CompanyEntity

        # Agregar estadísticas si se solicita
        if params[:with_stats]
          response[:companies] = companies.map do |company|
            company_data = company.as_json
            company_data[:stats] = company.kept? ? company.km_stats : nil
            company_data
          end
        end

        response
      end

      desc "Obtener una compañía específica"
      params do
        requires :id, type: Integer, desc: "ID de la compañía"
        optional :include_deleted, type: Boolean, default: false
        optional :include_stats, type: Boolean, default: false, desc: "Incluir estadísticas completas"
      end
      route_param :id do
        get do
          company = if params[:include_deleted]
                      Company.with_discarded.find(params[:id])
          else
                      Company.kept.find(params[:id])
          end

          response = present(company, with: Entities::CompanyEntity)

          if params[:include_stats] && company.kept?
            response.merge!(
              stats: company.km_stats,
              vehicles_count: company.vehicles.kept.count,
              vehicle_kms_count: company.vehicle_kms.kept.count,
              maintenances_count: company.maintenances.kept.count
            )
          end

          response
        end
      end

      desc "Crear una nueva compañía"
      params do
        requires :name, type: String, desc: "Nombre de la compañía"
        optional :cif, type: String, desc: "CIF de la compañía"
        optional :max_daily_km_tolerance, type: Integer, desc: "Tolerancia máxima de KM diarios"
      end
      post do
        company = Company.create!(declared_params)
        present company, with: Entities::CompanyEntity
      end

      desc "Actualizar una compañía"
      params do
        requires :id, type: Integer, desc: "ID de la compañía"
        optional :name, type: String, desc: "Nombre de la compañía"
        optional :cif, type: String, desc: "CIF de la compañía"
      end
      route_param :id do
        put do
          company = Company.kept.find(params[:id])
          company.update!(declared_params.except(:id))
          present company, with: Entities::CompanyEntity
        end
      end

      desc "Eliminar una compañía (soft delete con cascada automática de TODOS los datos)"
      params do
        requires :id, type: Integer, desc: "ID de la compañía"
        optional :force, type: Boolean, default: false, desc: "Forzar eliminación ignorando advertencias"
        optional :preview, type: Boolean, default: false, desc: "Solo mostrar el impacto sin ejecutar"
        optional :confirm_massive, type: Boolean, default: false, desc: "Confirmar operación masiva (>1000 registros)"
      end
      route_param :id do
        delete do
          company = Company.kept.find(params[:id])

          # Crear coordinador
          coordinator = SoftDelete::DeletionCoordinator.new(company,
            force: params[:force]
          )

          # Si se pide preview, solo analizar
          if params[:preview]
            preview = coordinator.preview

            # Calcular datos adicionales
            total_vehicles = company.vehicles.kept.count
            total_kms = company.vehicle_kms.kept.count
            total_maintenances = company.maintenances.kept.count
            total_records = total_vehicles + total_kms + total_maintenances

            risk_level = company.deletion_risk_level

            return present({
              success: true,
              preview: preview,
              company_id: company.id,
              company_info: {
                name: company.name,
                cif: company.cif
              },
              impact_summary: {
                total_records_to_delete: total_records,
                vehicles_count: total_vehicles,
                vehicle_kms_count: total_kms,
                maintenances_count: total_maintenances,
                vehicles_with_conflicts: company.vehicles.kept.with_conflictive_kms.count,
                conflictive_kms_count: company.vehicle_kms.kept.conflictive.count,
                total_maintenance_cost: company.maintenances.kept.sum(:amount).to_f,
                estimated_time: preview.dig(:impact, :estimated_time),
                is_massive_operation: total_records > 100,
                requires_background_job: total_records > 1000
              },
              risk_level: risk_level
            })
          end

          # PROTECCIÓN: Verificar si es operación masiva crítica
          total_records = company.vehicles.kept.count +
                         company.vehicle_kms.kept.count +
                         company.maintenances.kept.count

          if total_records > 1000 && !params[:confirm_massive]
            error!({
              success: false,
              errors: [
                "Esta compañía tiene #{total_records} registros. Esta es una operación masiva crítica."
              ],
              message: "Operación masiva requiere confirmación adicional",
              requires_confirm_massive: true,
              total_records: total_records,
              recommendation: "Use confirm_massive=true para confirmar esta operación o considere usar un job en segundo plano"
            }, 422)
          end

          # Ejecutar borrado
          result = coordinator.call

          if result[:success]
            present({
              success: true,
              message: result[:message],
              company_id: company.id,
              impact: {
                cascade_count: result[:cascade_count] || 0,
                nullify_count: result[:nullify_count] || 0
              },
              warnings: result[:warnings] || [],
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

      desc "Restaurar una compañía eliminada"
      params do
        requires :id, type: Integer, desc: "ID de la compañía eliminada"
        optional :cascade_restore, type: Boolean, default: false, desc: "Restaurar también todos los vehículos, KMs y mantenimientos"
        optional :preview, type: Boolean, default: false, desc: "Solo mostrar viabilidad sin ejecutar"
        optional :confirm_massive, type: Boolean, default: false, desc: "Confirmar restauración masiva (>1000 registros)"
      end
      route_param :id do
        post :restore do
          company = Company.discarded.find(params[:id])

          # Preparar opciones
          options = {
            cascade_restore: params[:cascade_restore]
          }

          # Crear coordinador
          coordinator = SoftDelete::RestorationCoordinator.new(company, options)

          # Si se pide preview, solo analizar
          if params[:preview]
            preview = coordinator.preview

            # Calcular totales de cascadas
            cascaded = preview.dig(:restoration_info, :cascaded_records) || []
            total_cascaded = cascaded.sum { |c| c[:count] }

            vehicles_discarded = cascaded.find { |c| c[:relation] == "Vehicles" }&.dig(:count) || 0
            kms_discarded = cascaded.find { |c| c[:relation] == "Vehicle Kms" }&.dig(:count) || 0
            maintenances_discarded = cascaded.find { |c| c[:relation] == "Maintenances" }&.dig(:count) || 0

            return present({
              success: true,
              preview: preview,
              company_id: company.id,
              company_info: {
                name: company.name,
                cif: company.cif,
                deleted_at: company.discarded_at
              },
              restoration_summary: {
                total_cascaded_records: total_cascaded,
                vehicles_discarded: vehicles_discarded,
                vehicle_kms_discarded: kms_discarded,
                maintenances_discarded: maintenances_discarded,
                estimated_time: preview.dig(:restoration_info, :estimated_time),
                is_massive_restoration: total_cascaded > 100,
                requires_background_job: total_cascaded > 1000
              }
            })
          end

          # PROTECCIÓN: Verificar si es restauración masiva crítica
          if params[:cascade_restore]
            total_discarded = company.vehicles.discarded.count +
                            company.vehicle_kms.discarded.count +
                            company.maintenances.discarded.count

            if total_discarded > 1000 && !params[:confirm_massive]
              error!({
                success: false,
                errors: [
                  "Esta restauración en cascada involucra #{total_discarded} registros. Esta es una operación masiva crítica."
                ],
                message: "Restauración masiva requiere confirmación adicional",
                requires_confirm_massive: true,
                total_records: total_discarded,
                recommendation: "Use confirm_massive=true para confirmar o considere restaurar sin cascada primero"
              }, 422)
            end
          end

          # Ejecutar restauración
          result = coordinator.call

          if result[:success]
            present({
              success: true,
              message: result[:message],
              company: present(result[:record], with: Entities::CompanyEntity),
              restored_count: result[:restored_count] || 1,
              warnings: result[:warnings] || [],
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

      desc "Verificar si una compañía puede ser eliminada"
      params do
        requires :id, type: Integer, desc: "ID de la compañía"
      end
      route_param :id do
        get :can_delete do
          company = Company.kept.find(params[:id])
          impact = company.deletion_impact

          total_vehicles = company.vehicles.kept.count
          total_kms = company.vehicle_kms.kept.count
          total_maintenances = company.maintenances.kept.count
          total_records = total_vehicles + total_kms + total_maintenances

          present({
            success: true,
            can_delete: company.can_be_deleted?,
            requires_force: impact[:warnings].any?,
            impact: impact,
            summary: {
              total_records_to_delete: total_records,
              vehicles_count: total_vehicles,
              vehicle_kms_count: total_kms,
              maintenances_count: total_maintenances,
              vehicles_with_conflicts: company.vehicles.kept.with_conflictive_kms.count,
              conflictive_kms_count: company.vehicle_kms.kept.conflictive.count,
              total_maintenance_cost: company.maintenances.kept.sum(:amount).to_f,
              estimated_time: impact[:estimated_time],
              is_massive_operation: total_records > 100,
              requires_background_job: total_records > 1000
            },
            risk_level: company.deletion_risk_level
          })
        end
      end

      desc "Verificar si una compañía eliminada puede ser restaurada"
      params do
        requires :id, type: Integer, desc: "ID de la compañía eliminada"
      end
      route_param :id do
        get :can_restore do
          company = Company.discarded.find(params[:id])
          info = company.restoration_info

          cascaded = info[:cascaded_records] || []
          total_cascaded = cascaded.sum { |c| c[:count] }

          present({
            success: true,
            can_restore: company.can_be_restored?,
            restoration_info: info,
            summary: {
              total_cascaded_records: total_cascaded,
              is_massive_restoration: total_cascaded > 100,
              requires_background_job: total_cascaded > 1000,
              restore_options_count: info[:restore_options]&.count || 0
            }
          })
        end
      end

      desc "Obtener resumen completo del impacto de borrado"
      params do
        requires :id, type: Integer, desc: "ID de la compañía"
      end
      route_param :id do
        get :deletion_summary do
          company = Company.kept.find(params[:id])
          summary = company.deletion_impact_summary

          present({
            success: true,
            company_id: company.id,
            company_info: {
              name: company.name,
              cif: company.cif
            },
            summary: summary,
            risk_level: company.deletion_risk_level
          })
        end
      end

      desc "Obtener información de restauración de una compañía eliminada"
      params do
        requires :id, type: Integer, desc: "ID de la compañía eliminada"
      end
      route_param :id do
        get :restoration_viability do
          company = Company.discarded.find(params[:id])
          viability = company.restoration_viability

          present({
            success: true,
            company_id: company.id,
            company_info: {
              name: company.name,
              cif: company.cif,
              deleted_at: company.discarded_at
            },
            viability: viability
          })
        end
      end

      desc "Obtener estado de eliminación de una compañía"
      params do
        requires :id, type: Integer, desc: "ID de la compañía"
      end
      route_param :id do
        get :deletion_status do
          company = Company.with_discarded.find(params[:id])

          status_info = {
            company_id: company.id,
            name: company.name,
            is_deleted: company.discarded?,
            status_description: company.deletion_status_description
          }

          if company.discarded?
            # Información adicional para compañías eliminadas
            deletion_log = SoftDeleteAuditLog
              .deletions
              .for_record(company)
              .order(performed_at: :desc)
              .first

            status_info.merge!(
              deleted_at: company.discarded_at,
              can_be_restored: company.can_be_restored?,
              deletion_log_id: deletion_log&.id,
              cascade_count: deletion_log&.cascade_count || 0,
              restore_complexity: deletion_log&.restore_complexity,
              deletion_context: deletion_log&.context
            )
          else
            # Información adicional para compañías activas
            status_info.merge!(
              total_vehicles: company.vehicles.kept.count,
              total_vehicle_kms: company.vehicle_kms.kept.count,
              total_maintenances: company.maintenances.kept.count,
              vehicles_with_conflicts: company.vehicles.kept.with_conflictive_kms.count
            )
          end

          present(status_info)
        end
      end

      desc "Exportar datos de una compañía antes de eliminar (placeholder)"
      params do
        requires :id, type: Integer, desc: "ID de la compañía"
      end
      route_param :id do
        get :export_data do
          company = Company.kept.find(params[:id])
          export = company.export_data_before_deletion

          present({
            success: true,
            company_id: company.id,
            export: export,
            message: "Datos exportados correctamente. Considere guardar esta información antes de eliminar la compañía."
          })
        end
      end

      desc "Obtener estadísticas de soft delete de todas las compañías"
      get :deletion_stats do
        stats = {
          total_companies: Company.kept.count,
          deleted_companies: Company.discarded.count,
          companies_at_risk: Company.kept.select { |c|
            total = c.vehicles.kept.count + c.vehicle_kms.kept.count + c.maintenances.kept.count
            total > 500
          }.count,
          by_risk_level: {
            low: 0,
            medium: 0,
            high: 0,
            critical: 0
          }
        }

        Company.kept.each do |company|
          risk = company.deletion_risk_level
          stats[:by_risk_level][risk[:level]] += 1
        end

        present({
          success: true,
          stats: stats
        })
      end
    end
  end
end
