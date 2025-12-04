# app/api/v1/vehicle_kms_api.rb
module V1
  class VehicleKmsApi < Grape::API
    resource :vehicle_kms do
      desc "Lista registros de KM"
      params do
        optional :vehicle_id, type: Integer, desc: "Filtrar por vehículo"
        optional :status, type: String, values: VehicleKm::STATUSES, desc: "Filtrar por estado"
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
        kms = kms.between_dates(params[:from_date], params[:to_date]) if params[:from_date] && params[:to_date]

        kms = kms.ordered.page(params[:page]).per(params[:per_page])

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
        requires :source, type: String, values: VehicleKm::SOURCES, desc: "Fuente del registro"
        optional :source_record_id, type: Integer, desc: "ID del registro origen"
        requires :km_reported, type: Integer, desc: "Kilómetros reportados"
      end
      post do
        result = VehicleKms::CreateService.new(
          vehicle_id: params[:vehicle_id],
          params: declared_params
        ).call

        if result[:success]
          present result[:vehicle_km], with: Entities::VehicleKmDetailEntity
        else
          error!({ success: false, errors: result[:errors] }, 422)
        end
      end

      desc "Actualizar un registro de KM"
      params do
        requires :id, type: Integer, desc: "ID del registro"
        optional :km_normalized, type: Integer, desc: "Kilómetros normalizados"
        optional :km_reported, type: Integer, desc: "Kilómetros reportados"
      end
      route_param :id do
        put do
          result = VehicleKms::UpdateService.new(
            vehicle_km_id: params[:id],
            params: declared_params
          ).call

          if result[:success]
            present result[:vehicle_km], with: Entities::VehicleKmDetailEntity
          else
            error!({ success: false, errors: result[:errors] }, 422)
          end
        end
      end

      desc "Eliminar un registro de KM (soft delete)"
      params do
        requires :id, type: Integer, desc: "ID del registro"
      end
      route_param :id do
        delete do
          result = VehicleKms::DeleteService.new(
            vehicle_km_id: params[:id],
            discarded_by_id: nil # Aquí iría el ID del usuario cuando se implemente
          ).call

          if result[:success]
            { success: true, message: "Registro eliminado correctamente" }
          else
            error!({ success: false, errors: result[:errors] }, 422)
          end
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

          {
            vehicle_km_id: km.id,
            has_conflict: result[:has_conflict],
            conflicts: result[:conflicts],
            previous_record: result[:previous_record] ?
              present(result[:previous_record], with: Entities::VehicleKmEntity) : nil,
            next_record: result[:next_record] ?
              present(result[:next_record], with: Entities::VehicleKmEntity) : nil
          }
        end
      end

      desc "Recalcular correcciones para un vehículo"
      params do
        requires :vehicle_id, type: Integer, desc: "ID del vehículo"
      end
      post :recalculate do
        vehicle = Vehicle.kept.find(params[:vehicle_id])
        kms = VehicleKm.kept.where(vehicle_id: vehicle.id).ordered

        corrected = 0
        kms.each do |km|
          checker = VehicleKms::CorrelationCheckService.new(km)
          next unless checker.call[:has_conflict]

          corrector = VehicleKms::KmCorrectionService.new(km)
          result = corrector.call

          if result[:success]
            km.update!(
              km_normalized: result[:corrected_km],
              status: "estimado",
              correction_notes: result[:notes]
            )
            corrected += 1
          end
        end

        {
          success: true,
          message: "Se corrigieron #{corrected} registros",
          corrected_count: corrected
        }
      end
    end
  end
end
