# app/models/soft_delete_audit_log.rb
class SoftDeleteAuditLog < ApplicationRecord
  # Registro que fue borrado/restaurado (polimórfico)
  belongs_to :record, polymorphic: true

  # Usuario que realizó la acción (polimórfico, opcional)
  belongs_to :performed_by, polymorphic: true, optional: true

  validates :action, presence: true, inclusion: { in: %w[delete restore] }
  validates :performed_at, presence: true
  validates :cascade_count, numericality: { greater_than_or_equal_to: 0 }
  validates :nullify_count, numericality: { greater_than_or_equal_to: 0 }
  validates :restore_complexity,
            inclusion: { in: %w[simple medium complex] },
            allow_nil: true

  # Validar que el contexto sea un hash válido
  before_validation :ensure_context_is_hash

  scope :deletions, -> { where(action: "delete") }
  scope :restorations, -> { where(action: "restore") }
  scope :recent, -> { order(performed_at: :desc) }
  scope :oldest, -> { order(performed_at: :asc) }
  scope :for_record, ->(record) { where(record: record) }
  scope :for_model, ->(model_class) { where(record_type: model_class.name) }
  scope :by_user, ->(user) { where(performed_by: user) }
  scope :restorable, -> { where(can_restore: true) }
  scope :non_restorable, -> { where(can_restore: false) }
  scope :simple_restores, -> { where(restore_complexity: "simple") }
  scope :medium_restores, -> { where(restore_complexity: "medium") }
  scope :complex_restores, -> { where(restore_complexity: "complex") }
  scope :massive_operations, -> { where("cascade_count > ? OR nullify_count > ?", 10, 10) }
  scope :with_cascades, -> { where("cascade_count > 0") }
  scope :with_nullify, -> { where("nullify_count > 0") }
  scope :between_dates, ->(from, to) { where(performed_at: from..to) }
  scope :last_days, ->(days) { where("performed_at >= ?", days.days.ago) }

  # MÉTODOS PÚBLICOS
  # ¿Es una operación de borrado?
  def deletion?
    action == "delete"
  end

  # ¿Es una operación de restauración?
  def restoration?
    action == "restore"
  end

  # ¿Tuvo impacto en cascada?
  def has_cascade_impact?
    cascade_count > 0
  end

  # ¿Tuvo impacto en nullify?
  def has_nullify_impact?
    nullify_count > 0
  end

  # Impacto total (cascadas + nullify)
  def total_impact
    cascade_count + nullify_count
  end

  # ¿Es una operación masiva?
  def massive_operation?
    total_impact > 10
  end

  # Etiqueta de complejidad con color (para UI)
  def complexity_badge
    case restore_complexity
    when "simple"
      { label: "Simple", color: "green" }
    when "medium"
      { label: "Media", color: "yellow" }
    when "complex"
      { label: "Compleja", color: "red" }
    else
      { label: "Desconocida", color: "gray" }
    end
  end

  # Descripción humana de la acción
  def action_description
    if deletion?
      "Eliminó #{record_type} ##{record_id}"
    else
      "Restauró #{record_type} ##{record_id}"
    end
  end

  # Descripción del impacto
  def impact_description
    parts = []
    parts << "#{cascade_count} en cascada" if cascade_count > 0
    parts << "#{nullify_count} desvinculados" if nullify_count > 0

    return "Sin impacto adicional" if parts.empty?
    parts.join(", ")
  end

  # Información del usuario que realizó la acción
  def performed_by_description
    return "Sistema automático" unless performed_by

    "#{performed_by.class.name} ##{performed_by.id}"
  end

  # Obtener el registro original (si aún existe)
  # Útil para restauraciones
  def original_record
    return nil unless record_type && record_id

    record_type.constantize.with_discarded.find_by(id: record_id)
  rescue NameError, ActiveRecord::RecordNotFound
    nil
  end

  # ¿El registro original todavía existe en BD?
  def record_exists?
    original_record.present?
  end

  # ¿El registro está actualmente eliminado?
  def record_discarded?
    rec = original_record
    rec.present? && rec.respond_to?(:discarded?) && rec.discarded?
  end

  # ¿El registro puede ser restaurado ahora?
  def currently_restorable?
    can_restore && record_exists? && record_discarded?
  end

  # Obtener el log de borrado correspondiente (desde una restauración)
  # o el log de restauración (desde un borrado)
  def paired_log
    if deletion?
      # Buscar la restauración posterior
      self.class.restorations
        .for_record(record)
        .where("performed_at > ?", performed_at)
        .order(performed_at: :asc)
        .first
    else
      # Buscar el borrado anterior
      self.class.deletions
        .for_record(record)
        .where("performed_at < ?", performed_at)
        .order(performed_at: :desc)
        .first
    end
  end

  # MÉTODOS DE CLASE - ESTADÍSTICAS
  class << self
    # Estadísticas generales de borrados
    def deletion_stats
      {
        total_deletions: deletions.count,
        total_restorations: restorations.count,
        by_model: deletions.group(:record_type).count,
        by_complexity: deletions.group(:restore_complexity).count,
        cascade_impact: deletions.sum(:cascade_count),
        nullify_impact: deletions.sum(:nullify_count),
        massive_operations: massive_operations.count,
        restorable_count: deletions.restorable.count
      }
    end

    # Estadísticas por modelo específico
    def stats_for_model(model_class)
      logs = for_model(model_class)

      {
        model: model_class.name,
        total_deletions: logs.deletions.count,
        total_restorations: logs.restorations.count,
        average_cascade: logs.deletions.average(:cascade_count).to_f.round(2),
        average_nullify: logs.deletions.average(:nullify_count).to_f.round(2),
        by_complexity: logs.deletions.group(:restore_complexity).count
      }
    end

    # Estadísticas por usuario
    def stats_for_user(user)
      logs = by_user(user)

      {
        user: user,
        total_deletions: logs.deletions.count,
        total_restorations: logs.restorations.count,
        models_affected: logs.select(:record_type).distinct.count,
        total_cascade_impact: logs.sum(:cascade_count),
        massive_operations: logs.massive_operations.count,
        first_action: logs.minimum(:performed_at),
        last_action: logs.maximum(:performed_at)
      }
    end

    # Top modelos más borrados
    def top_deleted_models(limit = 10)
      deletions
        .group(:record_type)
        .order("COUNT(*) DESC")
        .limit(limit)
        .count
        .map do |model, count|
          {
            model: model,
            deletion_count: count,
            restoration_count: restorations.for_model(model.constantize).count
          }
        end
    end

    # Operaciones recientes con impacto alto
    def recent_high_impact(days = 7, min_impact = 10)
      last_days(days)
        .where("cascade_count + nullify_count >= ?", min_impact)
        .order(performed_at: :desc)
    end

    # Registros pendientes de restauración
    def pending_restorations
      deletion_ids = deletions.pluck(:record_type, :record_id)
      restoration_ids = restorations.pluck(:record_type, :record_id)

      pending = deletion_ids - restoration_ids

      where(
        record_type: pending.map(&:first),
        record_id: pending.map(&:last)
      ).deletions.restorable
    end
  end

  private

  def ensure_context_is_hash
    self.context = {} unless context.is_a?(Hash)
  end
end
