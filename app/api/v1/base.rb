# app/api/v1/base.rb

module V1
  class Base < Grape::API
    version "v1", using: :path
    prefix :api
    format :json

    helpers do
      def authenticate!
        # Por ahora sin autenticación para el POC
      end

      def current_company
        @current_company ||= Company.kept.first
      end

      def declared_params
        declared(params, include_missing: false)
      end

      # Helper para obtener configuración de KM de la empresa
      def km_validation_config(company)
        {
          max_daily_km_tolerance: company.max_daily_km_tolerance,
          auto_correction_enabled: company.auto_correction_enabled,
          min_neighbors_for_correction: company.min_neighbors_for_correction || 1
        }
      end
    end

    rescue_from ActiveRecord::RecordNotFound do |e|
      error!({ success: false, errors: [ "Recurso no encontrado" ] }, 404)
    end

    rescue_from ActiveRecord::RecordInvalid do |e|
      error!({ success: false, errors: e.record.errors.full_messages }, 422)
    end

    rescue_from Grape::Exceptions::ValidationErrors do |e|
      error!({ success: false, errors: e.full_messages }, 400)
    end

    mount V1::VehiclesApi
    mount V1::VehicleKmsApi
    mount V1::CompaniesApi
    mount V1::MaintenancesApi
    mount V1::SoftDeleteApi

    # Configuración mínima de Swagger
    add_swagger_documentation(
      api_version: "v1",
      mount_path: "/swagger_doc", # endpoint JSON de Swagger
      hide_documentation_path: false,
      entity_parse_strategy: :grape_entity,


      info: {
        title: "My Grape API V1",
        description: "Documentación básica de la API"
      },
        base_path: "/",
        host: Rails.env.production? ? "vehicle-api-nwq1.onrender.com" : "localhost:3000",
        schemes: Rails.env.production? ? [ "https" ] : [ "http" ]
    )
  end
end
