# config/routes.rb

Rails.application.routes.draw do
  # Monta el punto de entrada principal de Grape en '/api'
  mount Base => "/"

  # Si quieres Swagger UI
  mount GrapeSwaggerRails::Engine => "/swagger"
end
