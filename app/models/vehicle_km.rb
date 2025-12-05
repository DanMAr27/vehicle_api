class VehicleKm < ApplicationRecord
  # Importante: Incluir la gema 'discard' para habilitar los scopes 'kept' y 'discarded'
  # Esto utiliza las columnas 'discarded_at' y 'discarded_by_id'
  include Discard::Model

  belongs_to :vehicle
  belongs_to :company

  # La columna 'discarded_by_id' necesita una asociación, si se requiere
  # Si 'discarded_by_id' es un ID de usuario/empleado, puedes añadir:
  # belongs_to :discarded_by, class_name: 'User', optional: true

  VALID_STATUSES = %w[original estimado conflictivo].freeze
  VALID_CONFIDENCE_LEVELS = %w[high medium low].freeze

  validates :status, inclusion: { in: VALID_STATUSES }
  # Se permite nil para 'confidence_level' si es un registro antiguo/original antes de ser analizado
  validates :confidence_level, inclusion: { in: VALID_CONFIDENCE_LEVELS }, allow_nil: true

  # Método para obtener el KM efectivo (normalizado si ha sido editado/estimado, o reportado si es original)
  def effective_km
    status == "original" ? km_reported : km_normalized
  end

  # Método para obtener las razones de conflicto como una lista de Ruby
  def conflict_reasons_list
    return [] if conflict_reasons.blank?
    # Intentamos parsear el JSON almacenado
    JSON.parse(conflict_reasons)
  rescue JSON::ParserError
    # En caso de que el contenido no sea JSON válido, devolvemos un array vacío
    []
  end

  # Setter para guardar las razones de conflicto como una cadena JSON
  # Acepta un array o cualquier objeto que pueda ser serializado
  def conflict_reasons_list=(reasons)
    self.conflict_reasons = reasons.to_json
  end
end
