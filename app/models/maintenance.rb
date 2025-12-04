# app/models/maintenance.rb
class Maintenance < ApplicationRecord
  include Discard::Model

  belongs_to :vehicle
  belongs_to :company
  belongs_to :vehicle_km, optional: true

  has_paper_trail

  validates :maintenance_date, presence: true
  validates :register_km, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :amount, numericality: { greater_than_or_equal_to: 0, allow_nil: true }

  scope :kept, -> { where(discarded_at: nil) }
  scope :ordered, -> { order(maintenance_date: :desc) }
end
