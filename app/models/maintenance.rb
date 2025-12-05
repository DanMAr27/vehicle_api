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
  scope :with_km_status, -> {
    left_joins(:vehicle_km)
      .select("maintenances.*, vehicle_kms.discarded_at as km_discarded_at")
  }

  # Estado del registro de KM asociado
  def km_status
    return "sin_registro" if vehicle_km_id.nil?
    return "eliminado" if vehicle_km&.discarded_at.present?
    "activo"
  end

  # ¿El KM fue informado manualmente en el mantenimiento?
  def km_manually_reported?
    vehicle_km_id.present? && vehicle_km&.source == "mantenimiento"
  end

  # ¿El KM está desincronizado con el registro actual?
  def km_desynchronized?
    return false if vehicle_km_id.nil?
    return false if vehicle_km.nil?

    register_km != vehicle_km.effective_km
  end
end
