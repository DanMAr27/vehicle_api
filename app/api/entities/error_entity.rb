# app/api/entities/error_entity.rb
module Entities
  class ErrorEntity < Grape::Entity
    expose :success, default: false
    expose :errors
    expose :message
  end
end
