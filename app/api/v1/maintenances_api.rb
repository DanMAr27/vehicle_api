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

      desc "Crear un nuevo mantenimiento"
      params do
        requires :vehicle_id, type: Integer, desc: "ID del vehículo"
        requires :maintenance_date, type: Date, desc: "Fecha del mantenimiento"
        requires :register_km, type: Integer, desc: "Kilómetros registrados"
        optional :amount, type: BigDecimal, desc: "Importe"
        optional :description, type: String, desc: "Descripción"
      end
      post do
        vehicle = Vehicle.kept.find(params[:vehicle_id])

        # Crear registro de KM automáticamente
        km_result = VehicleKms::CreateService.new(
          vehicle_id: params[:vehicle_id],
          params: {
            input_date: params[:maintenance_date],
            source: "mantenimiento",
            km_reported: params[:register_km]
          }
        ).call

        error!({ success: false, errors: km_result[:errors] }, 422) unless km_result[:success]

        # Crear mantenimiento
        maintenance = Maintenance.create!(
          vehicle: vehicle,
          company: vehicle.company,
          vehicle_km: km_result[:vehicle_km],
          maintenance_date: params[:maintenance_date],
          register_km: params[:register_km],
          amount: params[:amount],
          description: params[:description]
        )

        present maintenance, with: Entities::MaintenanceEntity
      end

      desc "Eliminar un mantenimiento (soft delete)"
      params do
        requires :id, type: Integer, desc: "ID del mantenimiento"
      end
      route_param :id do
        delete do
          maintenance = Maintenance.kept.find(params[:id])

          # Si tiene vehicle_km asociado, notamos que quedará huérfano
          vehicle_km_note = if maintenance.vehicle_km
            "Registro KM #{maintenance.vehicle_km_id} desvinculado"
          end

          maintenance.discard

          {
            success: true,
            message: "Mantenimiento eliminado",
            note: vehicle_km_note
          }
        end
      end
    end
  end
end
