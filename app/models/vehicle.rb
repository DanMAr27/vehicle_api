# app/models/vehicle.rb
class Vehicle < ApplicationRecord
  include Discard::Model

  belongs_to :company
  has_many :vehicle_kms, dependent: :destroy
  has_many :maintenances, dependent: :destroy

  has_paper_trail

  validates :matricula, presence: true, uniqueness: { scope: :company_id }
  validates :current_km, numericality: { greater_than_or_equal_to: 0 }
end
