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
        optional :page, type: Integer, default: 1
        optional :per_page, type: Integer, default: 25
      end
      get do
        maintenances = Maintenance.kept.includes(:vehicle, :company, :vehicle_km)
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
      end
      route_param :id do
        get do
          maintenance = Maintenance.kept.includes(:vehicle, :vehicle_km, :company).find(params[:id])
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
        vehicle = Vehicle.kept.find(params[:vehicle_id])
        vehicle_km = nil

        # Crear registro de KM automáticamente si se solicita
        if params[:create_km_record]
          km_result = VehicleKms::CreateService.new(
            vehicle_id: params[:vehicle_id],
            params: {
              input_date: params[:maintenance_date],
              source: "mantenimiento",
              km_reported: params[:register_km]
            }
          ).call

          error!({ success: false, errors: km_result[:errors] }, 422) unless km_result[:success]
          vehicle_km = km_result[:vehicle_km]
        end

        # Crear mantenimiento
        maintenance = Maintenance.create!(
          vehicle: vehicle,
          company: vehicle.company,
          vehicle_km: vehicle_km,
          maintenance_date: params[:maintenance_date],
          register_km: params[:register_km],
          amount: params[:amount],
          description: params[:description]
        )

        present maintenance, with: Entities::MaintenanceDetailEntity
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
          maintenance = Maintenance.kept.find(params[:id])
          update_params = declared_params.except(:id, :update_km_record)

          # Si hay que actualizar el KM y existe registro asociado
          if params[:update_km_record] && maintenance.vehicle_km_id.present? && params[:register_km].present?
            km_result = VehicleKms::UpdateService.new(
              vehicle_km_id: maintenance.vehicle_km_id,
              params: { km_normalized: params[:register_km] }
            ).call

            error!({ success: false, errors: km_result[:errors] }, 422) unless km_result[:success]
          end

          maintenance.update!(update_params)
          present maintenance, with: Entities::MaintenanceDetailEntity
        end
      end

      desc "Eliminar un mantenimiento (soft delete)"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
        optional :delete_km_record, type: Boolean, default: false, desc: "Eliminar también el registro de KM asociado"
      end
      route_param :id do
        delete do
          maintenance = Maintenance.kept.find(params[:id])
          notes = []

          # Si hay vehicle_km asociado y se solicita eliminarlo
          if params[:delete_km_record] && maintenance.vehicle_km_id.present?
            km_result = VehicleKms::DeleteService.new(
              vehicle_km_id: maintenance.vehicle_km_id,
              discarded_by_id: nil
            ).call

            if km_result[:success]
              notes << "Registro de KM #{maintenance.vehicle_km_id} eliminado"
            else
              notes << "No se pudo eliminar el registro de KM: #{km_result[:errors].join(', ')}"
            end
          elsif maintenance.vehicle_km_id.present?
            # Solo desvincular el mantenimiento del KM
            maintenance.update!(vehicle_km_id: nil)
            notes << "Mantenimiento desvinculado del registro de KM"
          end

          maintenance.discard
          notes << "Mantenimiento eliminado correctamente"

          {
            success: true,
            message: notes.first,
            details: notes
          }
        end
      end

      desc "Restaurar un mantenimiento eliminado"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
      end
      route_param :id do
        post :restore do
          maintenance = Maintenance.discarded.find(params[:id])
          maintenance.undiscard

          present maintenance, with: Entities::MaintenanceDetailEntity
        end
      end

      desc "Sincronizar KM del mantenimiento con el histórico"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
      end
      route_param :id do
        post :sync_km do
          maintenance = Maintenance.kept.find(params[:id])

          if maintenance.vehicle_km_id.nil?
            # Crear nuevo registro de KM
            km_result = VehicleKms::CreateService.new(
              vehicle_id: maintenance.vehicle_id,
              params: {
                input_date: maintenance.maintenance_date,
                source: "mantenimiento",
                km_reported: maintenance.register_km,
                source_record_id: maintenance.id
              }
            ).call

            error!({ success: false, errors: km_result[:errors] }, 422) unless km_result[:success]

            maintenance.update!(vehicle_km_id: km_result[:vehicle_km].id)
            message = "Registro de KM creado y vinculado"
          elsif maintenance.km_desynchronized?
            # Actualizar registro existente
            km_result = VehicleKms::UpdateService.new(
              vehicle_km_id: maintenance.vehicle_km_id,
              params: { km_normalized: maintenance.register_km }
            ).call

            error!({ success: false, errors: km_result[:errors] }, 422) unless km_result[:success]
            message = "Registro de KM actualizado"
          else
            message = "El KM ya está sincronizado"
          end

          {
            success: true,
            message: message,
            maintenance: present(maintenance.reload, with: Entities::MaintenanceDetailEntity)
          }
        end
      end

      desc "Obtener alertas de mantenimientos con problemas de KM"
      params do
        optional :vehicle_id, type: Integer, desc: "Filtrar por vehículo"
        optional :alert_type, type: String, values: %w[eliminado sin_registro desincronizado], desc: "Tipo de alerta"
      end
      get :alerts do
        maintenances = Maintenance.kept.includes(:vehicle_km)
        maintenances = maintenances.where(vehicle_id: params[:vehicle_id]) if params[:vehicle_id]

        results = maintenances.map do |m|
          {
            maintenance_id: m.id,
            vehicle_id: m.vehicle_id,
            maintenance_date: m.maintenance_date,
            km_status: m.km_status,
            has_issues: m.km_status != "activo" || m.km_desynchronized?
          }
        end

        # Filtrar por tipo de alerta si se especifica
        if params[:alert_type]
          results = results.select do |r|
            case params[:alert_type]
            when "eliminado"
              r[:km_status] == "eliminado"
            when "sin_registro"
              r[:km_status] == "sin_registro"
            when "desincronizado"
              maintenance = maintenances.find { |m| m.id == r[:maintenance_id] }
              maintenance.km_desynchronized?
            end
          end
        end

        {
          total: results.count,
          with_issues: results.count { |r| r[:has_issues] },
          maintenances: results
        }
      end
    end
  end
end
