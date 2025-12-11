# app/models/maintenance.rb
class Maintenance < ApplicationRecord
  include SoftDeletable
  has_paper_trail

  belongs_to :vehicle
  belongs_to :company
  belongs_to :vehicle_km, optional: true

  validates :maintenance_date, presence: true
  validates :register_km, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :amount, numericality: { greater_than_or_equal_to: 0, allow_nil: true }

  scope :ordered, -> { order(maintenance_date: :desc) }
  scope :with_km, -> { joins(:vehicle_km) }
  scope :without_km, -> { left_joins(:vehicle_km).where(vehicle_kms: { id: nil }) }
  scope :with_km_issues, -> {
    left_joins(:vehicle_km)
      .where("vehicle_kms.status = ? OR vehicle_kms.id IS NULL", "conflictivo")
  }

  # CONFIGURACIÓN DE SOFT DELETE
  # Relaciones que se borran automáticamente en cascada
  # Maintenance puede borrar opcionalmente su VehicleKm asociado
  def soft_delete_cascade_relations
    [
      {
        name: :vehicle_km,
        optional: true,  # ← El usuario decide si borrar o mantener
        condition: -> {
          # Solo si:
          # 1. Tiene VehicleKm asociado
          # 2. El VehicleKm fue creado desde este mantenimiento
          vehicle_km.present? && vehicle_km.from_maintenance?
        }
      }
    ]
  end

  # Relaciones que IMPIDEN el borrado
  # Maintenance no tiene bloqueos por ahora
  # En el futuro podría bloquearse por:
  # - Facturas asociadas pendientes de pago
  # - Contratos de garantía vigentes
  def soft_delete_blocking_relations
    []

    # Ejemplo futuro:
    # [
    #   {
    #     name: :pending_invoices,
    #     message: "facturas pendientes de pago"
    #   }
    # ]
  end

  # Relaciones que se desvinculan al borrar
  # Maintenance no nullifica nada
  def soft_delete_nullify_relations
    []
  end

  # Validaciones personalizadas antes de borrar
  def soft_delete_validations
    warnings = []

    # ADVERTENCIA: Tiene VehicleKm asociado
    if vehicle_km.present?
      km_info = vehicle_km.from_maintenance? ?
                "creado desde este mantenimiento" :
                "vinculado manualmente"

      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: Este mantenimiento tiene un registro de KM asociado " \
                 "(#{km_info}, ID: #{vehicle_km.id}). " \
                 "Puede elegir borrar el KM en cascada o mantenerlo."
      }
    end

    # ADVERTENCIA: Mantenimiento con costo alto
    if amount.to_f > 1000
      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: Este mantenimiento tiene un costo alto (#{amount}€)."
      }
    end

    # ADVERTENCIA: Mantenimiento muy antiguo
    if maintenance_date < 5.years.ago
      warnings << {
        severity: "info",
        message: "INFO: Este mantenimiento es de hace más de 5 años (#{maintenance_date.strftime('%d/%m/%Y')})."
      }
    end

    # ADVERTENCIA: Único mantenimiento del vehículo
    if vehicle.maintenances.kept.count == 1
      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: Este es el único mantenimiento registrado del vehículo #{vehicle.matricula}."
      }
    end

    # Ejemplo futuro de BLOCKER:
    # if has_pending_invoice?
    #   warnings << {
    #     severity: 'blocker',
    #     message: "BLOQUEADO: No se puede eliminar porque tiene facturas pendientes de cobro."
    #   }
    # end

    warnings
  end

  # Hook: guardar información antes de borrar
  def before_soft_delete(context)
    # Información del mantenimiento
    context[:vehicle_matricula] = vehicle.matricula
    context[:vehicle_id] = vehicle_id
    context[:maintenance_date] = maintenance_date
    context[:register_km] = register_km
    context[:amount] = amount
    context[:description] = description

    # Información del VehicleKm
    context[:has_vehicle_km] = vehicle_km.present?
    context[:vehicle_km_id] = vehicle_km&.id
    context[:vehicle_km_from_maintenance] = vehicle_km&.from_maintenance?

    # Decisión del usuario sobre cascada opcional
    cascade_decisions = instance_variable_get(:@cascade_decisions)
    if cascade_decisions
      context[:cascade_decision_vehicle_km] = cascade_decisions[:vehicle_km]
    end

    # Usuario (inyectado por el coordinador)
    user = instance_variable_get(:@deletion_user)
    context[:performed_by] = user if user
  end

  # Hook: acciones después de borrar
  def after_soft_delete(context)
    # Log detallado
    Rails.logger.info(
      "[SOFT DELETE] Maintenance ##{id} eliminado: " \
      "Vehículo #{context[:vehicle_matricula]} (ID: #{context[:vehicle_id]}), " \
      "Fecha #{context[:maintenance_date]}, " \
      "KM #{context[:register_km]}, " \
      "Importe #{context[:amount] || 'N/A'}€" +
      (context[:has_vehicle_km] ? ", VehicleKm ID: #{context[:vehicle_km_id]}" : "")
    )

    # Log de decisión de cascada
    if context[:has_vehicle_km]
      decision = context[:cascade_decision_vehicle_km]
      if decision == "delete"
        Rails.logger.info(
          "[SOFT DELETE CASCADE] VehicleKm ##{context[:vehicle_km_id]} será eliminado en cascada"
        )
      elsif decision == "keep"
        Rails.logger.info(
          "[SOFT DELETE] VehicleKm ##{context[:vehicle_km_id]} se mantiene (no borrado en cascada)"
        )
      end
    end

    # Aquí podrían agregarse notificaciones, emails, etc.
    # Ejemplo futuro:
    # MaintenanceMailer.deletion_notification(self, context).deliver_later
  end

  # Validaciones antes de restaurar
  def validate_soft_restore
    errors = []

    # Verificar que el vehículo siga existiendo y esté activo
    if vehicle.discarded?
      errors << "El vehículo asociado (#{vehicle.matricula}, ID: #{vehicle_id}) fue eliminado. " \
                "Debe restaurar primero el vehículo o reasignar este mantenimiento a otro vehículo."
    end

    # Verificar que la compañía siga existiendo y esté activa
    if company.discarded?
      errors << "La compañía asociada (#{company.name}, ID: #{company_id}) fue eliminada. " \
                "Debe restaurar primero la compañía."
    end

    # Verificar VehicleKm si existe
    if vehicle_km_id.present?
      km = VehicleKm.with_discarded.find_by(id: vehicle_km_id)

      if km.nil?
        errors << "El registro de KM asociado (ID: #{vehicle_km_id}) fue eliminado permanentemente de la base de datos."
      elsif km.discarded?
        # No es error, solo informativo
        # El coordinador puede ofrecer restaurar en cascada
      end
    end

    errors
  end

  # Campos únicos para verificación automática antes de restaurar
  # Maintenance NO tiene restricciones de unicidad
  def uniqueness_validations
    []
  end

  # Hook: acciones después de restaurar
  def after_soft_restore(context)
    # Usuario (inyectado por el coordinador)
    user = instance_variable_get(:@restoration_user)
    context[:performed_by] = user if user

    # Información de cascadas
    cascades_restored = instance_variable_get(:@cascades_restored)
    context[:cascades_restored] = cascades_restored if cascades_restored

    # Log
    Rails.logger.info(
      "[RESTORE] Maintenance ##{id} restaurado: " \
      "Vehículo #{vehicle.matricula}, " \
      "Fecha #{maintenance_date}, " \
      "KM #{register_km}" +
      (cascades_restored ? " (con cascadas restauradas)" : "")
    )

    # Si se restauró pero el VehicleKm sigue borrado, advertir
    if vehicle_km_id.present?
      km = VehicleKm.with_discarded.find_by(id: vehicle_km_id)
      if km&.discarded?
        Rails.logger.warn(
          "[RESTORE WARNING] Maintenance ##{id} restaurado pero VehicleKm ##{vehicle_km_id} " \
          "sigue borrado. Considere restaurar el KM también."
        )
      end
    end
  end

  # MÉTODOS PÚBLICOS
  # Estado del registro de KM asociado
  def km_status
    return "sin_registro" if vehicle_km.nil?
    return "eliminado" if vehicle_km.discarded?
    "activo"
  end

  # ¿El KM fue informado manualmente en el mantenimiento?
  def km_manually_reported?
    vehicle_km.present? && vehicle_km.from_maintenance?
  end

  # ¿El KM está desincronizado con el registro actual?
  def km_desynchronized?
    return false if vehicle_km.nil?
    register_km != vehicle_km.effective_km
  end

  # Diferencia entre KM del mantenimiento y KM efectivo del registro
  def km_difference
    return 0 if vehicle_km.nil?
    register_km - vehicle_km.effective_km
  end

  # ¿El KM está en conflicto?
  def km_conflictive?
    vehicle_km.present? && vehicle_km.needs_review?
  end

  # ¿El KM fue corregido automáticamente?
  def km_auto_corrected?
    vehicle_km.present? && vehicle_km.auto_corrected?
  end

  # MÉTODOS PÚBLICOS - UTILIDADES DE SOFT DELETE
  # ¿Puede borrar su VehicleKm en cascada?
  def can_delete_vehicle_km_cascade?
    vehicle_km.present? && vehicle_km.from_maintenance?
  end

  # Descripción del estado del VehicleKm para mostrar al usuario
  def vehicle_km_status_description
    return "Sin registro de KM" if vehicle_km.nil?

    if vehicle_km.discarded?
      "KM eliminado (ID: #{vehicle_km.id})"
    elsif vehicle_km.from_maintenance?
      "KM creado desde este mantenimiento (ID: #{vehicle_km.id}, #{vehicle_km.status})"
    else
      "KM vinculado manualmente (ID: #{vehicle_km.id}, #{vehicle_km.status})"
    end
  end

  # Impacto estimado de borrar este mantenimiento
  # Wrapper conveniente sobre el coordinador
  def deletion_impact_summary
    coordinator = SoftDelete::DeletionCoordinator.new(self)
    preview = coordinator.preview

    {
      can_proceed: preview[:can_proceed],
      requires_force: preview[:requires_force],
      has_optional_cascades: preview[:optional_cascades].any?,
      optional_cascade_vehicle_km: can_delete_vehicle_km_cascade?,
      warnings_count: preview[:impact][:warnings].count,
      recommendation: preview[:message]
    }
  end

  private

  # Método helper privado para futuras validaciones
  # def has_pending_invoice?
  #   invoices.pending.exists?
  # end
end
