# app/api/v1/base.rb

module V1
  class Base < Grape::API
    version "v1", using: :path
    prefix :api
    format :json

    # Ejemplo de endpoint simple
    resource :users do
      desc "Retorna todos los usuarios"
      get do
        User.all
      end
    end

    mount V1::VehiclesApi
    mount V1::VehicleKmsApi
    mount V1::MaintenancesApi

    # Configuración mínima de Swagger
    add_swagger_documentation(
      api_version: "v1",
      mount_path: "/swagger_doc", # endpoint JSON de Swagger
      hide_documentation_path: false,
      info: {
        title: "My Grape API V1",
        description: "Documentación básica de la API"
      }
    )
  end
end
