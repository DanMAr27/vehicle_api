# app/api/v1/vehicle_kms_api.rb
module V1
  class VehicleKmsApi < Grape::API
    resource :vehicle_kms do
      desc "Lista registros de KM"
      params do
        optional :vehicle_id, type: Integer, desc: "Filtrar por vehículo"
        optional :status, type: String, values: %w[original estimado conflictivo], desc: "Filtrar por estado"
        optional :confidence_level, type: String, values: %w[high medium low], desc: "Filtrar por nivel de confianza"
        optional :needs_review, type: Boolean, desc: "Solo registros que requieren revisión (conflictivos)"
        optional :from_date, type: Date, desc: "Fecha desde"
        optional :to_date, type: Date, desc: "Fecha hasta"
        optional :include_vehicle, type: Boolean, default: false, desc: "Incluir datos del vehículo"
        optional :page, type: Integer, default: 1
        optional :per_page, type: Integer, default: 25
      end
      get do
        kms = VehicleKm.kept.includes(:vehicle, :company)
        kms = kms.where(vehicle_id: params[:vehicle_id]) if params[:vehicle_id]
        kms = kms.where(status: params[:status]) if params[:status]
        kms = kms.where(confidence_level: params[:confidence_level]) if params[:confidence_level]
        kms = kms.where(status: "conflictivo") if params[:needs_review]

        if params[:from_date] && params[:to_date]
          kms = kms.where(input_date: params[:from_date]..params[:to_date])
        end

        kms = kms.order(input_date: :desc, created_at: :desc)
                 .page(params[:page])
                 .per(params[:per_page])

        present kms, with: Entities::VehicleKmEntity, include_vehicle: params[:include_vehicle]
      end

      desc "Obtener un registro de KM específico con detalles"
      params do
        requires :id, type: Integer, desc: "ID del registro"
      end
      route_param :id do
        get do
          km = VehicleKm.kept.find(params[:id])
          present km, with: Entities::VehicleKmDetailEntity
        end
      end

      desc "Crear un nuevo registro de KM"
      params do
        requires :vehicle_id, type: Integer, desc: "ID del vehículo"
        requires :input_date, type: Date, desc: "Fecha del registro"
        requires :source, type: String, desc: "Fuente del registro (manual, mantenimiento, gps, etc.)"
        optional :source_record_id, type: Integer, desc: "ID del registro origen"
        requires :km_reported, type: Integer, desc: "Kilómetros reportados"
      end
      post do
        result = VehicleKms::CreateService.new(
          vehicle_id: params[:vehicle_id],
          params: {
            input_date: params[:input_date],
            source: params[:source],
            source_record_id: params[:source_record_id],
            km_reported: params[:km_reported]
          }
        ).call

        if result[:success]
          response_data = {
            success: true,
            vehicle_km: present(result[:vehicle_km], with: Entities::VehicleKmDetailEntity),
            status: result[:status],
            needs_review: result[:needs_review]
          }

          # Agregar advertencia si quedó conflictivo
          if result[:needs_review]
            response_data[:warning] = "El registro fue marcado como conflictivo y requiere revisión manual"
          end

          response_data
        else
          error!({ success: false, errors: result[:errors] }, 422)
        end
      end

      desc "Actualizar un registro de KM manualmente"
      params do
        requires :id, type: Integer, desc: "ID del registro"
        optional :km_normalized, type: Integer, desc: "Kilómetros normalizados (corrección manual)"
        optional :km_reported, type: Integer, desc: "Kilómetros reportados"
        optional :status, type: String, values: %w[original estimado conflictivo], desc: "Cambiar estado manualmente"
        optional :correction_notes, type: String, desc: "Notas de la corrección manual"
        optional :resolve_conflict, type: Boolean, default: false, desc: "Resolver conflicto y marcar como estimado"
      end
      route_param :id do
        put do
          km = VehicleKm.kept.find(params[:id])
          update_params = {}

          # Si se está resolviendo un conflicto manualmente
          if params[:resolve_conflict] && km.status == "conflictivo"
            update_params[:status] = "estimado"
            update_params[:confidence_level] = "medium"
            update_params[:conflict_reasons] = nil
            update_params[:correction_notes] = params[:correction_notes] || "Resuelto manualmente"
          end

          # Actualizar KM normalizado si se provee
          if params[:km_normalized]
            update_params[:km_normalized] = params[:km_normalized]
            update_params[:status] = "estimado" if km.status == "original"
          end

          # Actualizar KM reportado si se provee (raro, pero permitido)
          update_params[:km_reported] = params[:km_reported] if params[:km_reported]

          # Cambio de estado manual
          update_params[:status] = params[:status] if params[:status]

          # Notas adicionales
          if params[:correction_notes] && !update_params[:correction_notes]
            update_params[:correction_notes] = params[:correction_notes]
          end

          km.update!(update_params)

          # Re-validar ventana si cambió significativamente
          if params[:km_normalized] || params[:km_reported]
            revalidator = VehicleKms::WindowRevalidationService.new(km)
            revalidator.call
          end

          present km.reload, with: Entities::VehicleKmDetailEntity
        end
      end

      desc "Eliminar un registro de KM (soft delete)"
      params do
        requires :id, type: Integer, desc: "ID del registro"
      end
      route_param :id do
        delete do
          km = VehicleKm.kept.find(params[:id])
          km.discard

          # Re-validar ventana tras la eliminación
          revalidator = VehicleKms::WindowRevalidationService.new(km)
          revalidator.call

          { success: true, message: "Registro eliminado correctamente" }
        end
      end

      desc "Verificar correlación de un registro"
      params do
        requires :id, type: Integer, desc: "ID del registro"
      end
      route_param :id do
        get :check_correlation do
          km = VehicleKm.kept.find(params[:id])
          checker = VehicleKms::CorrelationCheckService.new(km)
          result = checker.call

          # Calcular confianza si hay vecinos
          confidence = nil
          if result[:previous_record] || result[:next_record]
            calculator = VehicleKms::ConfidenceCalculatorService.new(km)
            confidence = calculator.call
          end

          {
            vehicle_km_id: km.id,
            current_status: km.status,
            has_conflict: result[:has_conflict],
            conflicts: result[:conflicts],
            confidence: confidence,
            previous_record: result[:previous_record] ? {
              id: result[:previous_record].id,
              input_date: result[:previous_record].input_date,
              effective_km: result[:previous_record].effective_km,
              status: result[:previous_record].status
            } : nil,
            next_record: result[:next_record] ? {
              id: result[:next_record].id,
              input_date: result[:next_record].input_date,
              effective_km: result[:next_record].effective_km,
              status: result[:next_record].status
            } : nil
          }
        end
      end

      desc "Intentar corrección automática de un registro conflictivo"
      params do
        requires :id, type: Integer, desc: "ID del registro"
        optional :force, type: Boolean, default: false, desc: "Forzar corrección incluso con baja confianza"
      end
      route_param :id do
        post :attempt_correction do
          km = VehicleKm.kept.find(params[:id])

          unless km.status == "conflictivo"
            error!({ success: false, errors: [ "Solo se pueden corregir registros conflictivos" ] }, 422)
          end

          # Calcular confianza
          confidence_calculator = VehicleKms::ConfidenceCalculatorService.new(km)
          confidence = confidence_calculator.call

          # Si la confianza es baja y no se fuerza, rechazar
          if confidence[:level] == "low" && !params[:force]
            error!({
              success: false,
              errors: [ "Confianza insuficiente para corrección automática" ],
              confidence: confidence,
              suggestion: "Use force=true para forzar la corrección o corrija manualmente"
            }, 422)
          end

          # Intentar corrección
          corrector = VehicleKms::KmCorrectionService.new(km)
          result = corrector.call

          if result[:success] && result[:corrected_km]
            km.update!(
              km_normalized: result[:corrected_km],
              status: "estimado",
              confidence_level: confidence[:level],
              conflict_reasons: nil,
              correction_notes: result[:notes]
            )

            {
              success: true,
              message: "Corrección aplicada exitosamente",
              vehicle_km: present(km, with: Entities::VehicleKmDetailEntity),
              correction_summary: {
                original_km: result[:original_km],
                corrected_km: result[:corrected_km],
                difference: result[:corrected_km] - result[:original_km],
                confidence: confidence
              }
            }
          else
            error!({
              success: false,
              errors: [ "No se pudo calcular una corrección válida" ],
              details: result[:notes]
            }, 422)
          end
        end
      end

      desc "Recalcular correcciones para un vehículo completo"
      params do
        requires :vehicle_id, type: Integer, desc: "ID del vehículo"
        optional :only_conflictive, type: Boolean, default: true, desc: "Solo recalcular registros conflictivos"
      end
      post :recalculate do
        vehicle = Vehicle.kept.find(params[:vehicle_id])
        kms = VehicleKm.kept.where(vehicle_id: vehicle.id).order(input_date: :asc, created_at: :asc)

        # Filtrar solo conflictivos si se especifica
        kms = kms.where(status: "conflictivo") if params[:only_conflictive]

        results = {
          total_processed: 0,
          corrected: 0,
          still_conflictive: 0,
          errors: []
        }

        kms.each do |km|
          results[:total_processed] += 1

          begin
            # Calcular confianza
            confidence_calculator = VehicleKms::ConfidenceCalculatorService.new(km)
            confidence = confidence_calculator.call

            # Solo intentar si la confianza es media o alta
            next if confidence[:level] == "low"

            # Intentar corrección
            corrector = VehicleKms::KmCorrectionService.new(km)
            result = corrector.call

            if result[:success] && result[:corrected_km]
              km.update!(
                km_normalized: result[:corrected_km],
                status: "estimado",
                confidence_level: confidence[:level],
                conflict_reasons: nil,
                correction_notes: result[:notes]
              )
              results[:corrected] += 1
            else
              results[:still_conflictive] += 1
            end
          rescue StandardError => e
            results[:errors] << { km_id: km.id, error: e.message }
            results[:still_conflictive] += 1
          end
        end

        {
          success: true,
          message: "Procesados #{results[:total_processed]} registros, #{results[:corrected]} corregidos",
          details: results
        }
      end

      desc "Obtener estadísticas de KM por vehículo"
      params do
        requires :vehicle_id, type: Integer, desc: "ID del vehículo"
      end
      get :stats do
        vehicle = Vehicle.kept.find(params[:vehicle_id])
        kms = VehicleKm.kept.where(vehicle_id: vehicle.id)

        {
          vehicle_id: vehicle.id,
          vehicle_matricula: vehicle.matricula,
          total_records: kms.count,
          by_status: {
            original: kms.where(status: "original").count,
            estimado: kms.where(status: "estimado").count,
            conflictivo: kms.where(status: "conflictivo").count
          },
          by_confidence: {
            high: kms.where(confidence_level: "high").count,
            medium: kms.where(confidence_level: "medium").count,
            low: kms.where(confidence_level: "low").count
          },
          needs_review_count: kms.where(status: "conflictivo").count,
          date_range: {
            oldest: kms.minimum(:input_date),
            newest: kms.maximum(:input_date)
          },
          km_range: {
            min: kms.minimum(:km_reported),
            max: kms.maximum(:km_reported),
            current: vehicle.current_km
          }
        }
      end

      desc "Obtener lista de vehículos con registros conflictivos"
      params do
        optional :company_id, type: Integer, desc: "Filtrar por compañía"
        optional :min_conflictive, type: Integer, default: 1, desc: "Mínimo de registros conflictivos"
      end
      get :conflictives_summary do
        vehicles = Vehicle.kept
        vehicles = vehicles.where(company_id: params[:company_id]) if params[:company_id]

        results = vehicles.map do |vehicle|
          total = VehicleKm.kept.where(vehicle_id: vehicle.id).count
          conflictive = VehicleKm.kept.where(vehicle_id: vehicle.id, status: "conflictivo").count

          next if conflictive < params[:min_conflictive]

          {
            vehicle_id: vehicle.id,
            vehicle_matricula: vehicle.matricula,
            vehicle_vin: vehicle.vin,
            total_records: total,
            conflictive_count: conflictive,
            conflictive_percentage: total > 0 ? ((conflictive.to_f / total) * 100).round(2) : 0,
            oldest_conflict: VehicleKm.kept.where(vehicle_id: vehicle.id, status: "conflictivo")
                                           .minimum(:input_date),
            newest_conflict: VehicleKm.kept.where(vehicle_id: vehicle.id, status: "conflictivo")
                                           .maximum(:input_date)
          }
        end.compact.sort_by { |r| -r[:conflictive_count] }

        {
          total_vehicles: vehicles.count,
          vehicles_with_conflicts: results.count,
          total_conflictive_records: results.sum { |r| r[:conflictive_count] },
          vehicles: results
        }
      end
    end
  end
end
