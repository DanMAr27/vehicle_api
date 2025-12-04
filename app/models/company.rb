# app/models/company.rb
class Company < ApplicationRecord
  include Discard::Model

  has_many :vehicles, dependent: :destroy
  has_many :vehicle_kms, dependent: :destroy
  has_many :maintenances, dependent: :destroy

  has_paper_trail

  validates :name, presence: true
end
