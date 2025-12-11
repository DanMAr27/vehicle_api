# app/models/vehicle_km.rb
class VehicleKm < ApplicationRecord
  include SoftDeletable  # ← NUEVO: Incluye funcionalidad de soft delete
  has_paper_trail

  belongs_to :vehicle
  belongs_to :company
  belongs_to :source_record, polymorphic: true, optional: true

  VALID_STATUSES = %w[original corregido editado conflictivo].freeze

  validates :status, inclusion: { in: VALID_STATUSES }
  validates :input_date, presence: true
  validates :km_reported, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :km_normalized, numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :source_record_type, presence: true, if: -> { source_record_id.present? }
  validates :source_record_id, presence: true, if: -> { source_record_type.present? }

  scope :ordered, -> { order(input_date: :desc, created_at: :desc) }
  scope :by_status, ->(status) { where(status: status) }
  scope :conflictive, -> { where(status: "conflictivo") }
  scope :needs_review, -> { conflictive }
  scope :corrected, -> { where(status: "corregido") }
  scope :original, -> { where(status: "original") }
  scope :by_vehicle, ->(vehicle_id) { where(vehicle_id: vehicle_id) }
  scope :by_source_type, ->(type) { where(source_record_type: type) }
  scope :from_maintenance, -> { where(source_record_type: "Maintenance") }
  scope :manual, -> { where(source_record_type: nil) }
  scope :in_date_range, ->(from, to) { where(input_date: from..to) }

  after_commit :update_vehicle_stats, on: [ :create, :update, :destroy ]

  # CONFIGURACIÓN DE SOFT DELETE
  # Relaciones que se borran automáticamente en cascada
  # VehicleKm NO borra nada en cascada (es un registro hoja)
  def soft_delete_cascade_relations
    []
  end

  # Relaciones que IMPIDEN el borrado
  # VehicleKm NUNCA bloquea el borrado (siempre se puede borrar)
  def soft_delete_blocking_relations
    []
  end

  # Relaciones que se desvinculan al borrar este VehicleKm
  # Los Maintenances que apuntan a este VehicleKm quedarán sin referencia
  def soft_delete_nullify_relations
    [
      {
        name: :referencing_maintenances,
        model: "Maintenance",
        foreign_key: "vehicle_km_id",
        notify: true
      }
    ]
  end

  # Validaciones personalizadas antes de borrar
  # Genera advertencias según el contexto del registro
  def soft_delete_validations
    warnings = []

    # ADVERTENCIA: KM creado desde un mantenimiento
    if from_maintenance? && maintenance.present?
      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: Este KM fue creado desde el mantenimiento ##{maintenance.id} " \
                 "(#{maintenance.maintenance_date.strftime('%d/%m/%Y')}). " \
                 "El mantenimiento quedará desvinculado."
      }
    end

    # ADVERTENCIA: KM con correcciones automáticas
    if status == "corregido"
      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: Este KM tiene correcciones automáticas " \
                 "(KM reportado: #{km_reported}, corregido: #{km_normalized}). " \
                 "Se perderá el historial de corrección."
      }
    end

    # ADVERTENCIA: Único registro del vehículo
    if vehicle.vehicle_kms.kept.count == 1
      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: Este es el único registro de KM del vehículo #{vehicle.matricula}. " \
                 "El vehículo quedará sin historial de kilómetros."
      }
    end

    # ADVERTENCIA: KM conflictivo sin resolver
    if status == "conflictivo"
      reasons = conflict_reasons_list.join("; ")
      warnings << {
        severity: "info",
        message: "INFO: Este KM está marcado como conflictivo. Razones: #{reasons}"
      }
    end

    warnings
  end

  # Hook: guardar información antes de borrar
  def before_soft_delete(context)
    # Guardar información del registro para auditoría
    context[:vehicle_matricula] = vehicle.matricula
    context[:vehicle_id] = vehicle_id
    context[:input_date] = input_date
    context[:km_reported] = km_reported
    context[:km_normalized] = km_normalized
    context[:status] = status
    context[:from_maintenance] = from_maintenance?
    context[:maintenance_id] = maintenance&.id
    context[:has_corrections] = (status == "corregido")
    context[:is_conflictive] = (status == "conflictivo")

    # Agregar usuario si está disponible (inyectado por el coordinador)
    user = instance_variable_get(:@deletion_user)
    context[:performed_by] = user if user
  end

  # Hook: acciones después de borrar
  def after_soft_delete(context)
    # Recalcular ventana de KMs vecinos
    # Esto puede marcar otros KMs como válidos o conflictivos
    revalidate_km_window_after_deletion

    # Recalcular el current_km del vehículo
    update_vehicle_current_km

    # Log detallado
    Rails.logger.info(
      "[SOFT DELETE] VehicleKm ##{id} eliminado: " \
      "Vehículo #{context[:vehicle_matricula]} (ID: #{context[:vehicle_id]}), " \
      "Fecha #{context[:input_date]}, " \
      "KM reportado #{context[:km_reported]}, " \
      "Estado #{context[:status]}" +
      (context[:from_maintenance] ? ", Desde mantenimiento ##{context[:maintenance_id]}" : "")
    )

    # Si estaba vinculado a un mantenimiento, notificar
    if context[:from_maintenance] && context[:maintenance_id]
      Rails.logger.info(
        "[SOFT DELETE IMPACT] Mantenimiento ##{context[:maintenance_id]} quedó sin KM asociado"
      )
    end
  end

  # Validaciones antes de restaurar
  def validate_soft_restore
    errors = []

    # Verificar que el vehículo siga existiendo y esté activo
    if vehicle.discarded?
      errors << "El vehículo asociado (#{vehicle.matricula}, ID: #{vehicle_id}) fue eliminado. " \
                "Debe restaurar primero el vehículo o reasignar este KM a otro vehículo activo."
    end

    # Verificar que la compañía siga existiendo y esté activa
    if company.discarded?
      errors << "La compañía asociada (#{company.name}, ID: #{company_id}) fue eliminada. " \
                "Debe restaurar primero la compañía."
    end

    errors
  end

  # Campos únicos para verificación automática antes de restaurar
  # VehicleKm NO tiene restricciones de unicidad
  # (puede haber múltiples registros del mismo vehículo en la misma fecha)
  def uniqueness_validations
    []
  end

  # Hook: acciones después de restaurar
  def after_soft_restore(context)
    # Recalcular ventana de KMs vecinos
    # Esto puede afectar el estado de otros KMs
    revalidate_km_window_after_restoration

    # Recalcular el current_km del vehículo
    update_vehicle_current_km

    # Agregar usuario si está disponible
    user = instance_variable_get(:@restoration_user)
    context[:performed_by] = user if user

    # Log
    Rails.logger.info(
      "[RESTORE] VehicleKm ##{id} restaurado: " \
      "Vehículo #{vehicle.matricula}, " \
      "Fecha #{input_date}, " \
      "KM #{km_reported}"
    )
  end

  def effective_km
    km_normalized || km_reported
  end

  def conflict_reasons_list
    return [] if conflict_reasons.blank?
    JSON.parse(conflict_reasons)
  rescue JSON::ParserError
    []
  end

  def conflict_reasons_list=(reasons)
    self.conflict_reasons = reasons.to_json
  end

  # Método mejorado para obtener el mantenimiento asociado
  def maintenance
    return nil unless from_maintenance?
    return @maintenance if defined?(@maintenance)

    @maintenance = Maintenance.kept.find_by(vehicle_km_id: id)
    @maintenance ||= source_record if source_record.is_a?(Maintenance)
    @maintenance
  end

  def source_maintenance
    source_record if source_record_type == "Maintenance"
  end

  def from_maintenance?
    source_record_type == "Maintenance"
  end

  def manually_created?
    source_record.nil?
  end

  def needs_review?
    status == "conflictivo"
  end

  def auto_corrected?
    status == "corregido"
  end

  def manually_edited?
    status == "editado"
  end

  def correction_difference
    return 0 if km_normalized.nil?
    km_normalized - km_reported
  end

  def correction_percentage
    return 0 if km_reported.zero? || km_normalized.nil?
    ((correction_difference.to_f / km_reported) * 100).round(2)
  end

  def source_description
    if manually_created?
      "Manual"
    elsif from_maintenance?
      maint = maintenance
      if maint
        "Mantenimiento ##{maint.id} (#{maint.maintenance_date.strftime('%d/%m/%Y')})"
      else
        "Mantenimiento ##{source_record_id} (registro eliminado)"
      end
    else
      "Desconocido"
    end
  end

  def maintenance_exists?
    from_maintenance? && maintenance.present?
  end

  def maintenance_deleted?
    from_maintenance? && maintenance.nil?
  end

  private

  # Recalcula y corrige la ventana de KMs vecinos después de borrar
  def revalidate_km_window_after_deletion
    window = build_window_around_deleted

    window.each do |record|
      detector = VehicleKms::ConflictDetectorService.new(record)
      result = detector.call

      if result[:has_conflict]
        # Procesar registros conflictivos
        result[:conflictive_records].each do |conflict_info|
          rec = VehicleKm.find(conflict_info[:record_id])

          corrector = VehicleKms::KmCorrectionService.new(rec)
          correction_result = corrector.call

          if correction_result[:success]
            rec.update!(
              km_normalized: correction_result[:corrected_km],
              status: "corregido",
              conflict_reasons_list: conflict_info[:reasons],
              correction_notes: correction_result[:notes]
            )
          else
            rec.update!(
              km_normalized: rec.km_reported,
              status: "conflictivo",
              conflict_reasons_list: conflict_info[:reasons],
              correction_notes: correction_result[:notes]
            )
          end
        end

        # Restaurar registros que ahora son válidos
        result[:valid_records].each do |valid_id|
          rec = VehicleKm.find(valid_id)
          if %w[conflictivo corregido].include?(rec.status)
            rec.update!(
              km_normalized: rec.km_reported,
              status: "original",
              conflict_reasons_list: [],
              correction_notes: "Restaurado a secuencia válida tras eliminación de registro"
            )
          end
        end
      end
    end
  rescue StandardError => e
    Rails.logger.error(
      "[REVALIDATION ERROR] Error revalidating KM window after deletion: #{e.message}"
    )
  end

  # Recalcula la ventana de KMs después de restaurar
  def revalidate_km_window_after_restoration
    detector = VehicleKms::ConflictDetectorService.new(self)
    result = detector.call

    if result[:has_conflict]
      result[:conflictive_records].each do |conflict_info|
        record = VehicleKm.find(conflict_info[:record_id])

        corrector = VehicleKms::KmCorrectionService.new(record)
        correction_result = corrector.call

        if correction_result[:success]
          record.update!(
            km_normalized: correction_result[:corrected_km],
            status: "corregido",
            conflict_reasons_list: conflict_info[:reasons],
            correction_notes: correction_result[:notes]
          )
        else
          record.update!(
            km_normalized: record.km_reported,
            status: "conflictivo",
            conflict_reasons_list: conflict_info[:reasons],
            correction_notes: correction_result[:notes]
          )
        end
      end

      result[:valid_records].each do |valid_id|
        record = VehicleKm.find(valid_id)
        next if record.id == id

        if %w[conflictivo corregido].include?(record.status)
          record.update!(
            km_normalized: record.km_reported,
            status: "original",
            conflict_reasons_list: [],
            correction_notes: "Restaurado tras restauración de registro vecino"
          )
        end
      end
    end
  rescue StandardError => e
    Rails.logger.error(
      "[REVALIDATION ERROR] Error revalidating KM window after restoration: #{e.message}"
    )
  end

  # Construye ventana de registros vecinos
  def build_window_around_deleted
    previous_records = VehicleKm.kept
      .where(vehicle_id: vehicle_id)
      .where("input_date < ? OR (input_date = ? AND id < ?)",
             input_date, input_date, id)
      .order(input_date: :desc, id: :desc)
      .limit(5)
      .to_a

    next_records = VehicleKm.kept
      .where(vehicle_id: vehicle_id)
      .where("input_date > ? OR (input_date = ? AND id > ?)",
             input_date, input_date, id)
      .order(input_date: :asc, id: :asc)
      .limit(5)
      .to_a

    (previous_records + next_records).uniq
  end

  # Actualiza el current_km del vehículo
  def update_vehicle_current_km
    latest = VehicleKm.kept
      .where(vehicle_id: vehicle_id)
      .order(input_date: :desc, created_at: :desc)
      .first

    new_km = latest ? latest.effective_km : 0
    vehicle.update!(current_km: new_km)
  rescue StandardError => e
    Rails.logger.error(
      "[UPDATE VEHICLE KM ERROR] Error updating vehicle current_km: #{e.message}"
    )
  end

  def update_vehicle_stats
    return unless vehicle.respond_to?(:total_km_records)

    vehicle.update_columns(
      total_km_records: vehicle.vehicle_kms.kept.count,
      conflictive_km_records: vehicle.vehicle_kms.kept.conflictive.count,
      last_km_update_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error(
      "[UPDATE STATS ERROR] Error updating vehicle stats: #{e.message}"
    )
  end
end
