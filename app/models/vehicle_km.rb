# app/models/vehicle_km.rb
class VehicleKm < ApplicationRecord
  include Discard::Model

  belongs_to :vehicle
  belongs_to :company
  has_one :maintenance, dependent: :nullify

  has_paper_trail

  SOURCES = %w[telemetria mantenimiento itv manual otro].freeze
  STATUSES = %w[original estimado editado].freeze

  validates :input_date, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :km_reported, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :km_normalized, numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :kept, -> { where(discarded_at: nil) }
  scope :ordered, -> { order(input_date: :desc, created_at: :desc) }
  scope :for_vehicle, ->(vehicle_id) { where(vehicle_id: vehicle_id) }
  scope :original, -> { where(status: "original") }
  scope :corrected, -> { where(status: %w[estimado editado]) }
  scope :between_dates, ->(from, to) { where(input_date: from..to) }

  # Obtener el KM efectivo (normalizado si existe, reportado si no)
  def effective_km
    km_normalized || km_reported
  end
end
