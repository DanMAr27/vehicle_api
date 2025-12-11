# app/api/entities/success_entity.rb
module Entities
  class SuccessEntity < Grape::Entity
    expose :success, default: true
    expose :message
    expose :data
  end
end
