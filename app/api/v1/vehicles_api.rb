# app/api/v1/vehicles_api.rb
module V1
  class VehiclesApi < Grape::API
    resource :vehicles do
      desc "Lista todos los vehículos"
      params do
        optional :company_id, type: Integer, desc: "Filtrar por compañía"
        optional :page, type: Integer, default: 1, desc: "Página"
        optional :per_page, type: Integer, default: 25, desc: "Registros por página"
      end
      get do
        vehicles = Vehicle.kept.includes(:company)
        vehicles = vehicles.where(company_id: params[:company_id]) if params[:company_id]

        vehicles = vehicles.page(params[:page]).per(params[:per_page])

        present vehicles, with: Entities::VehicleEntity
      end

      desc "Obtener un vehículo específico"
      params do
        requires :id, type: Integer, desc: "ID del vehículo"
      end
      route_param :id do
        get do
          vehicle = Vehicle.kept.find(params[:id])
          present vehicle, with: Entities::VehicleEntity
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

      desc "Eliminar un vehículo (soft delete)"
      params do
        requires :id, type: Integer, desc: "ID del vehículo"
      end
      route_param :id do
        delete do
          vehicle = Vehicle.kept.find(params[:id])
          vehicle.discard
          { success: true, message: "Vehículo eliminado correctamente" }
        end
      end
    end
  end
end
