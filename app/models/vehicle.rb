# app/models/vehicle.rb
class Vehicle < ApplicationRecord
  include SoftDeletable
  has_paper_trail

  belongs_to :company
  has_many :vehicle_kms, dependent: :destroy
  has_many :maintenances, dependent: :destroy

  validates :matricula, presence: true, uniqueness: { scope: :company_id }
  validates :current_km, numericality: { greater_than_or_equal_to: 0 }

  scope :with_conflictive_kms, -> {
    joins(:vehicle_kms)
      .where(vehicle_kms: { status: "conflictivo", discarded_at: nil })
      .distinct
  }
  scope :ordered, -> { order(matricula: :asc) }

  # CONFIGURACIÓN DE SOFT DELETE
  # Relaciones que se borran automáticamente en cascada
  # Vehicle borra TODOS sus registros relacionados
  def soft_delete_cascade_relations
    [
      { name: :vehicle_kms },
      { name: :maintenances }
    ]
  end

  # Relaciones que IMPIDEN el borrado
  # Vehicle no tiene bloqueos por ahora
  # En el futuro podría bloquearse por:
  # - Contratos de leasing activos
  # - Documentación legal pendiente
  # - Vehículo asignado a conductor activo
  def soft_delete_blocking_relations
    []

    # Ejemplo futuro:
    # [
    #   {
    #     name: :active_leasing_contracts,
    #     message: "contratos de leasing activos"
    #   },
    #   {
    #     name: :active_driver_assignments,
    #     message: "asignaciones a conductores activos"
    #   }
    # ]
  end

  # Relaciones que se desvinculan al borrar
  # Vehicle no nullifica nada (todo se borra en cascada)
  def soft_delete_nullify_relations
    []
  end

  # Validaciones personalizadas antes de borrar
  def soft_delete_validations
    warnings = []

    # ADVERTENCIA: Cantidad de registros a borrar
    total_kms = vehicle_kms.kept.count
    total_maintenances = maintenances.kept.count
    total_records = total_kms + total_maintenances

    if total_records > 0
      parts = []
      parts << "#{total_kms} registros de KM" if total_kms > 0
      parts << "#{total_maintenances} mantenimientos" if total_maintenances > 0

      severity = if total_records > 100
                   "high"
      elsif total_records > 20
                   "warning"
      else
                   "info"
      end

      warnings << {
        severity: severity,
        message: "#{severity == 'high' ? 'IMPORTANTE' : 'ADVERTENCIA'}: " \
                 "Se eliminarán #{parts.join(' y ')} (#{total_records} registros en total)."
      }
    end

    # ADVERTENCIA: Vehículo con KMs conflictivos sin resolver
    conflictive_count = vehicle_kms.kept.conflictive.count
    if conflictive_count > 0
      warnings << {
        severity: "info",
        message: "INFO: Este vehículo tiene #{conflictive_count} registros de KM conflictivos sin resolver."
      }
    end

    # ADVERTENCIA: Vehículo con datos recientes
    recent_km = vehicle_kms.kept.where("input_date > ?", 30.days.ago).count
    recent_maintenance = maintenances.kept.where("maintenance_date > ?", 30.days.ago).count

    if recent_km > 0 || recent_maintenance > 0
      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: Este vehículo tiene actividad reciente " \
                 "(últimos 30 días: #{recent_km} KMs, #{recent_maintenance} mantenimientos)."
      }
    end

    # ADVERTENCIA: Vehículo con kilometraje alto
    if current_km > 200000
      warnings << {
        severity: "info",
        message: "INFO: Este vehículo tiene un kilometraje alto (#{current_km} km). " \
                 "Podría tener valor histórico."
      }
    end

    # Ejemplo futuro de BLOCKER:
    # if has_active_leasing?
    #   warnings << {
    #     severity: 'blocker',
    #     message: "BLOQUEADO: No se puede eliminar porque tiene un contrato de leasing activo."
    #   }
    # end

    warnings
  end

  # Hook: guardar información antes de borrar
  def before_soft_delete(context)
    # Información básica del vehículo
    context[:matricula] = matricula
    context[:vin] = vin
    context[:current_km] = current_km
    context[:company_name] = company.name
    context[:company_id] = company_id

    # Contar registros a eliminar (para auditoría)
    context[:vehicle_kms_count] = vehicle_kms.kept.count
    context[:maintenances_count] = maintenances.kept.count
    context[:total_records] = context[:vehicle_kms_count] + context[:maintenances_count]

    # Estadísticas de KMs
    context[:conflictive_kms_count] = vehicle_kms.kept.conflictive.count
    context[:last_km_date] = vehicle_kms.kept.maximum(:input_date)
    context[:last_maintenance_date] = maintenances.kept.maximum(:maintenance_date)

    # Usuario (inyectado por el coordinador)
    user = instance_variable_get(:@deletion_user)
    context[:performed_by] = user if user
  end

  # Hook: acciones después de borrar
  def after_soft_delete(context)
    # Log detallado
    Rails.logger.info(
      "[SOFT DELETE] Vehicle ##{id} eliminado: " \
      "Matrícula #{context[:matricula]}, " \
      "VIN #{context[:vin] || 'N/A'}, " \
      "KM actual #{context[:current_km]}, " \
      "Compañía #{context[:company_name]} (ID: #{context[:company_id]})"
    )

    # Log de impacto en cascada
    Rails.logger.info(
      "[SOFT DELETE CASCADE] Eliminados en cascada: " \
      "#{context[:vehicle_kms_count]} registros KM, " \
      "#{context[:maintenances_count]} mantenimientos " \
      "(#{context[:total_records]} total)"
    )

    # Log de KMs conflictivos si los había
    if context[:conflictive_kms_count] > 0
      Rails.logger.info(
        "[SOFT DELETE INFO] Se eliminaron #{context[:conflictive_kms_count]} KMs conflictivos sin resolver"
      )
    end

    # Log de última actividad
    if context[:last_km_date] || context[:last_maintenance_date]
      Rails.logger.info(
        "[SOFT DELETE INFO] Última actividad: " \
        "KM #{context[:last_km_date]&.strftime('%d/%m/%Y') || 'N/A'}, " \
        "Mantenimiento #{context[:last_maintenance_date]&.strftime('%d/%m/%Y') || 'N/A'}"
      )
    end

    # Aquí podrían agregarse notificaciones importantes
    # Ejemplo futuro:
    # if context[:total_records] > 100
    #   AdminMailer.massive_vehicle_deletion(self, context).deliver_later
    # end
  end

  # Validaciones antes de restaurar
  def validate_soft_restore
    errors = []

    # Verificar que la compañía siga existiendo y esté activa
    if company.discarded?
      errors << "La compañía asociada (#{company.name}, ID: #{company_id}) fue eliminada. " \
                "Debe restaurar primero la compañía o reasignar este vehículo a otra compañía."
    end

    # Verificar conflicto de matrícula con vehículo activo
    # (La validación de unicidad del concern lo maneja, pero agregamos contexto)
    existing = Vehicle.kept.where(matricula: matricula, company_id: company_id).where.not(id: id).first
    if existing
      errors << "Ya existe un vehículo activo con la matrícula '#{matricula}' " \
                "en la compañía #{company.name} (ID: #{existing.id}). " \
                "Debe cambiar la matrícula del vehículo existente o fusionar ambos registros."
    end

    errors
  end

  # Campos únicos para verificación automática antes de restaurar
  def uniqueness_validations
    [
      { field: :matricula, scope: :company_id }
    ]
  end

  # Hook: acciones después de restaurar
  def after_soft_restore(context)
    # Usuario
    user = instance_variable_get(:@restoration_user)
    context[:performed_by] = user if user

    # Información de cascadas
    cascades_restored = instance_variable_get(:@cascades_restored)
    context[:cascades_restored] = cascades_restored if cascades_restored

    # Contar qué se restauró en cascada
    if cascades_restored
      context[:restored_kms_count] = vehicle_kms.kept.count
      context[:restored_maintenances_count] = maintenances.kept.count
    end

    # Log
    Rails.logger.info(
      "[RESTORE] Vehicle ##{id} restaurado: " \
      "Matrícula #{matricula}, " \
      "Compañía #{company.name}" +
      (cascades_restored ?
        " (con #{context[:restored_kms_count]} KMs y #{context[:restored_maintenances_count]} mantenimientos restaurados)" :
        "")
    )

    # Recalcular current_km si se restauraron KMs
    if cascades_restored && vehicle_kms.kept.any?
      recalculate_current_km
    end
  end

  # MÉTODOS PÚBLICOS
  # Obtener último registro de KM válido
  def latest_km_record
    vehicle_kms.kept.ordered.first
  end

  # Obtener KM actual efectivo (del último registro)
  def effective_current_km
    latest_km_record&.effective_km || current_km
  end

  # Verificar si tiene registros conflictivos
  def has_conflictive_kms?
    if respond_to?(:conflictive_km_records)
      conflictive_km_records > 0
    else
      vehicle_kms.kept.conflictive.exists?
    end
  end

  # Estadísticas de KMs
  def km_stats
    {
      total_records: vehicle_kms.kept.count,
      conflictive: vehicle_kms.kept.conflictive.count,
      corrected: vehicle_kms.kept.corrected.count,
      original: vehicle_kms.kept.original.count,
      manual: vehicle_kms.kept.manual.count,
      from_maintenance: vehicle_kms.kept.from_maintenance.count,
      oldest_date: vehicle_kms.kept.minimum(:input_date),
      newest_date: vehicle_kms.kept.maximum(:input_date)
    }
  end

  # Estadísticas de mantenimientos
  def maintenance_stats
    {
      total: maintenances.kept.count,
      total_cost: maintenances.kept.sum(:amount),
      average_cost: maintenances.kept.average(:amount)&.to_f&.round(2),
      with_km: maintenances.kept.with_km.count,
      without_km: maintenances.kept.without_km.count,
      oldest_date: maintenances.kept.minimum(:maintenance_date),
      newest_date: maintenances.kept.maximum(:maintenance_date)
    }
  end

  # MÉTODOS PÚBLICOS - UTILIDADES DE SOFT DELETE
  # Resumen del impacto de borrar este vehículo
  # Wrapper conveniente sobre el coordinador
  def deletion_impact_summary
    coordinator = SoftDelete::DeletionCoordinator.new(self)
    preview = coordinator.preview

    total_kms = vehicle_kms.kept.count
    total_maintenances = maintenances.kept.count

    {
      can_proceed: preview[:can_proceed],
      requires_force: preview[:requires_force],
      total_records_to_delete: total_kms + total_maintenances,
      vehicle_kms_count: total_kms,
      maintenances_count: total_maintenances,
      conflictive_kms_count: vehicle_kms.kept.conflictive.count,
      warnings_count: preview[:impact][:warnings].count,
      estimated_time: preview[:impact][:estimated_time],
      recommendation: preview[:message]
    }
  end

  # Verifica si la restauración es viable
  def restoration_viability
    analyzer = SoftDelete::RestorationAnalyzer.new(self)
    info = analyzer.analyze

    {
      can_restore: info[:can_restore],
      conflicts: info[:conflicts],
      cascaded_records_count: (info[:cascaded_records] || []).sum { |c| c[:count] },
      restore_options: info[:restore_options]&.map { |opt| opt[:type] },
      recommendation: info[:recommendation]
    }
  end

  # Descripción del estado para UI
  def deletion_status_description
    if kept?
      "Activo"
    else
      deleted_at = discarded_at&.strftime("%d/%m/%Y %H:%M")
      "Eliminado el #{deleted_at}"
    end
  end

  private

  # Recalcula current_km basado en los KMs restaurados
  def recalculate_current_km
    latest = vehicle_kms.kept.order(input_date: :desc, created_at: :desc).first
    new_km = latest ? latest.effective_km : 0
    update_columns(current_km: new_km)

    Rails.logger.info(
      "[RECALCULATE] Vehicle ##{id} current_km actualizado a #{new_km} km"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[RECALCULATE ERROR] Error recalculating current_km for Vehicle ##{id}: #{e.message}"
    )
  end

  # Métodos helper privados para futuras validaciones
  # def has_active_leasing?
  #   leasing_contracts.active.exists?
  # end

  # def has_active_driver_assignment?
  #   driver_assignments.active.exists?
  # end
end
