# app/models/vehicle_km.rb
class VehicleKm < ApplicationRecord
  belongs_to :vehicle
  belongs_to :company

  # Existing code...

  VALID_STATUSES = %w[original estimado conflictivo].freeze
  VALID_CONFIDENCE_LEVELS = %w[high medium low].freeze

  validates :status, inclusion: { in: VALID_STATUSES }
  validates :confidence_level, inclusion: { in: VALID_CONFIDENCE_LEVELS }, allow_nil: true

  # Método para obtener el KM efectivo
  def effective_km
    status == "original" ? km_reported : km_normalized
  end

  # Método para serializar razones de conflicto
  def conflict_reasons_list
    return [] if conflict_reasons.blank?
    JSON.parse(conflict_reasons)
  rescue JSON::ParserError
    []
  end

  def conflict_reasons_list=(reasons)
    self.conflict_reasons = reasons.to_json
  end
end
