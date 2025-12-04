# app/api/entities/company_entity.rb
module Entities
  class CompanyEntity < Grape::Entity
    expose :id
    expose :name
    expose :cif
    expose :created_at
    expose :updated_at
  end
end
