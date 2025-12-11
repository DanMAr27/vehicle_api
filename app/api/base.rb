  # app/api/base.rb

  class Base < Grape::API
    format :json
    mount V1::Base
  end
