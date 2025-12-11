# app/models/company.rb
class Company < ApplicationRecord
  include SoftDeletable
  has_paper_trail

  has_many :vehicles, dependent: :destroy
  has_many :vehicle_kms, dependent: :destroy
  has_many :maintenances, dependent: :destroy

  validates :name, presence: true

  scope :with_auto_correction, -> { where(auto_correction_enabled: true) }
  scope :without_auto_correction, -> { where(auto_correction_enabled: false) }

  # Relaciones que se borran automáticamente en cascada
  # Company borra TODO: vehículos, KMs y mantenimientos
  def soft_delete_cascade_relations
    [
      { name: :vehicles },
      { name: :vehicle_kms },
      { name: :maintenances }
    ]
  end

  # Relaciones que IMPIDEN el borrado
  # Company podría bloquearse por:
  # - Facturas pendientes de cobro
  # - Contratos vigentes
  # - Usuarios activos vinculados
  def soft_delete_blocking_relations
    []

    # Ejemplo futuro:
    # [
    #   {
    #     name: :pending_invoices,
    #     message: "facturas pendientes de cobro"
    #   },
    #   {
    #     name: :active_contracts,
    #     message: "contratos vigentes"
    #   },
    #   {
    #     name: :active_users,
    #     message: "usuarios activos vinculados"
    #   }
    # ]
  end

  # Relaciones que se desvinculan al borrar
  # Company no nullifica nada (todo se borra en cascada)
  def soft_delete_nullify_relations
    []
  end

  # Validaciones personalizadas antes de borrar
  def soft_delete_validations
    warnings = []

    # CONTEO TOTAL DE DATOS
    total_vehicles = vehicles.kept.count
    total_kms = vehicle_kms.kept.count
    total_maintenances = maintenances.kept.count
    total_records = total_vehicles + total_kms + total_maintenances

    # ADVERTENCIA/BLOCKER según cantidad de datos
    if total_records > 1000
      # BLOCKER: Demasiados datos, usar job en segundo plano
      warnings << {
        severity: "blocker",
        message: "BLOQUEADO: Esta compañía tiene #{total_records} registros. " \
                 "No se puede eliminar de forma síncrona. " \
                 "Use un job en segundo plano o contacte con el administrador."
      }
    elsif total_records > 500
      # HIGH: Operación muy pesada
      warnings << {
        severity: "high",
        message: "IMPORTANTE: Esta compañía tiene #{total_records} registros. " \
                 "La operación puede tardar varios minutos y afectar el rendimiento del sistema. " \
                 "#{total_vehicles} vehículos, #{total_kms} registros KM, #{total_maintenances} mantenimientos."
      }
    elsif total_records > 100
      # WARNING: Operación pesada
      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: Esta compañía tiene #{total_records} registros. " \
                 "#{total_vehicles} vehículos, #{total_kms} registros KM, #{total_maintenances} mantenimientos. " \
                 "La operación puede tardar algunos minutos."
      }
    elsif total_records > 0
      # INFO: Datos existentes
      warnings << {
        severity: "info",
        message: "INFO: Se eliminarán #{total_vehicles} vehículos, " \
                 "#{total_kms} registros KM y #{total_maintenances} mantenimientos."
      }
    end

    # ADVERTENCIA: Vehículos con actividad reciente
    recent_vehicles = vehicles.kept.joins(:vehicle_kms)
      .where("vehicle_kms.input_date > ?", 30.days.ago)
      .distinct
      .count

    if recent_vehicles > 0
      warnings << {
        severity: "warning",
        message: "ADVERTENCIA: #{recent_vehicles} vehículos tienen actividad reciente (últimos 30 días)."
      }
    end

    # ADVERTENCIA: Datos antiguos con valor histórico
    oldest_km_date = vehicle_kms.kept.minimum(:input_date)
    if oldest_km_date && oldest_km_date < 5.years.ago
      years = ((Date.today - oldest_km_date) / 365).to_i
      warnings << {
        severity: "info",
        message: "INFO: Esta compañía tiene datos históricos de #{years} años. " \
                 "Considere exportar antes de eliminar."
      }
    end

    # ADVERTENCIA: KMs conflictivos sin resolver
    conflictive_count = vehicle_kms.kept.conflictive.count
    if conflictive_count > 0
      warnings << {
        severity: "info",
        message: "INFO: Hay #{conflictive_count} registros de KM conflictivos sin resolver."
      }
    end

    # Ejemplo futuro de BLOCKER:
    # if has_pending_invoices?
    #   warnings << {
    #     severity: 'blocker',
    #     message: "BLOQUEADO: No se puede eliminar porque tiene facturas pendientes de cobro."
    #   }
    # end

    warnings
  end

  # Hook: guardar información antes de borrar
  def before_soft_delete(context)
    # Información básica de la compañía
    context[:company_name] = name
    context[:cif] = cif

    # Conteo completo de datos
    context[:vehicles_count] = vehicles.kept.count
    context[:vehicle_kms_count] = vehicle_kms.kept.count
    context[:maintenances_count] = maintenances.kept.count
    context[:total_records] = context[:vehicles_count] +
                              context[:vehicle_kms_count] +
                              context[:maintenances_count]

    # Estadísticas de vehículos
    context[:vehicles_with_conflicts] = vehicles.kept.with_conflictive_kms.count

    # Estadísticas de KMs
    context[:conflictive_kms_count] = vehicle_kms.kept.conflictive.count
    context[:corrected_kms_count] = vehicle_kms.kept.corrected.count
    context[:manual_kms_count] = vehicle_kms.kept.manual.count

    # Estadísticas de mantenimientos
    context[:total_maintenance_cost] = maintenances.kept.sum(:amount).to_f
    context[:maintenances_with_km] = maintenances.kept.with_km.count

    # Datos históricos
    context[:oldest_km_date] = vehicle_kms.kept.minimum(:input_date)
    context[:newest_km_date] = vehicle_kms.kept.maximum(:input_date)
    context[:oldest_maintenance_date] = maintenances.kept.minimum(:maintenance_date)
    context[:newest_maintenance_date] = maintenances.kept.maximum(:maintenance_date)

    # Configuración de la compañía (verificar si existen los campos)
    context[:auto_correction_enabled] = respond_to?(:auto_correction_enabled) ? auto_correction_enabled : nil
    context[:max_daily_km_tolerance] = respond_to?(:max_daily_km_tolerance) ? max_daily_km_tolerance : nil

    # Usuario (inyectado por el coordinador)
    user = instance_variable_get(:@deletion_user)
    context[:performed_by] = user if user
  end

  # Hook: acciones después de borrar
  def after_soft_delete(context)
    # Log principal
    Rails.logger.info(
      "[SOFT DELETE] Company ##{id} eliminada: " \
      "'#{context[:company_name]}' (CIF: #{context[:cif] || 'N/A'})"
    )

    # Log de impacto masivo
    Rails.logger.info(
      "[SOFT DELETE CASCADE] Eliminados en cascada: " \
      "#{context[:vehicles_count]} vehículos, " \
      "#{context[:vehicle_kms_count]} registros KM, " \
      "#{context[:maintenances_count]} mantenimientos " \
      "(#{context[:total_records]} total)"
    )

    # Log de estadísticas importantes
    if context[:conflictive_kms_count] > 0 || context[:corrected_kms_count] > 0
      Rails.logger.info(
        "[SOFT DELETE INFO] KMs: " \
        "#{context[:conflictive_kms_count]} conflictivos, " \
        "#{context[:corrected_kms_count]} corregidos, " \
        "#{context[:manual_kms_count]} manuales"
      )
    end

    # Log de mantenimientos
    if context[:total_maintenance_cost] > 0
      Rails.logger.info(
        "[SOFT DELETE INFO] Mantenimientos: " \
        "#{context[:maintenances_count]} registros, " \
        "costo total #{context[:total_maintenance_cost]}€"
      )
    end

    # Log de datos históricos
    if context[:oldest_km_date] && context[:newest_km_date]
      years = ((context[:newest_km_date] - context[:oldest_km_date]) / 365).to_i
      Rails.logger.info(
        "[SOFT DELETE INFO] Rango histórico: " \
        "#{context[:oldest_km_date].strftime('%d/%m/%Y')} - " \
        "#{context[:newest_km_date].strftime('%d/%m/%Y')} " \
        "(#{years} años de datos)"
      )
    end

    # IMPORTANTE: Notificar a administradores si es una operación grande
    if context[:total_records] > 100
      Rails.logger.warn(
        "[SOFT DELETE WARNING] Operación masiva: " \
        "Se eliminaron #{context[:total_records]} registros de la compañía '#{context[:company_name]}'"
      )

      # Futuro: Enviar email a administradores
      # AdminMailer.massive_company_deletion(self, context).deliver_later
    end
  end

  # Validaciones antes de restaurar
  def validate_soft_restore
    errors = []

    # Verificar conflicto de nombre con compañía activa
    existing = Company.kept.where(name: name).where.not(id: id).first
    if existing
      errors << "Ya existe una compañía activa con el nombre '#{name}' (ID: #{existing.id}). " \
                "Debe cambiar el nombre de la compañía existente o fusionar ambas compañías."
    end

    # Verificar conflicto de CIF si existe
    if cif.present?
      existing_cif = Company.kept.where(cif: cif).where.not(id: id).first
      if existing_cif
        errors << "Ya existe una compañía activa con el CIF '#{cif}' (ID: #{existing_cif.id}). " \
                  "Debe cambiar el CIF de la compañía existente."
      end
    end

    # Advertencia sobre datos huérfanos si hay mucho
    discarded_vehicles = vehicles.discarded.count
    if discarded_vehicles > 0
      errors << "INFO: Esta compañía tiene #{discarded_vehicles} vehículos eliminados que no se restaurarán automáticamente. " \
                "Considere restaurarlos también."
    end

    errors
  end

  # Campos únicos para verificación automática antes de restaurar
  def uniqueness_validations
    validations = [ { field: :name } ]
    validations << { field: :cif } if cif.present?
    validations
  end

  # Hook: acciones después de restaurar
  def after_soft_restore(context)
    # Usuario
    user = instance_variable_get(:@restoration_user)
    context[:performed_by] = user if user

    # Información de cascadas
    cascades_restored = instance_variable_get(:@cascades_restored)
    context[:cascades_restored] = cascades_restored if cascades_restored

    # Contar qué se restauró
    if cascades_restored
      context[:restored_vehicles_count] = vehicles.kept.count
      context[:restored_kms_count] = vehicle_kms.kept.count
      context[:restored_maintenances_count] = maintenances.kept.count
      context[:total_restored] = context[:restored_vehicles_count] +
                                 context[:restored_kms_count] +
                                 context[:restored_maintenances_count]
    end

    # Log
    Rails.logger.info(
      "[RESTORE] Company ##{id} restaurada: '#{name}'" +
      (cascades_restored ?
        " (#{context[:restored_vehicles_count]} vehículos, " \
        "#{context[:restored_kms_count]} KMs, " \
        "#{context[:restored_maintenances_count]} mantenimientos restaurados)" :
        "")
    )

    # Advertencia sobre operación masiva
    if cascades_restored && context[:total_restored] > 100
      Rails.logger.warn(
        "[RESTORE WARNING] Operación masiva: " \
        "Se restauraron #{context[:total_restored]} registros de la compañía '#{name}'"
      )
    end
  end

  # Verificar si la corrección automática está habilitada
  def auto_correction_enabled?
    auto_correction_enabled == true
  end

  # Obtener tolerancia de KM diarios (si existe)
  def daily_km_tolerance
    max_daily_km_tolerance || Float::INFINITY
  end

  # Verificar si un salto de KM excede la tolerancia
  def exceeds_daily_tolerance?(km_diff, days_diff)
    return false if max_daily_km_tolerance.nil?
    return false if days_diff.zero?

    daily_rate = km_diff.to_f / days_diff
    daily_rate > max_daily_km_tolerance
  end

  # Estadísticas de KM de todos los vehículos
  def km_stats
    {
      total_vehicles: vehicles.kept.count,
      total_km_records: vehicle_kms.kept.count,
      conflictive_records: vehicle_kms.kept.conflictive.count,
      corrected_records: vehicle_kms.kept.corrected.count,
      manual_records: vehicle_kms.kept.manual.count,
      maintenance_records: vehicle_kms.kept.from_maintenance.count,
      vehicles_with_conflicts: vehicles.kept.with_conflictive_kms.count,
      by_status: vehicle_kms.kept.group(:status).count
    }
  end

  # Resumen completo del impacto de borrar esta compañía
  def deletion_impact_summary
    coordinator = SoftDelete::DeletionCoordinator.new(self)
    preview = coordinator.preview

    total_vehicles = vehicles.kept.count
    total_kms = vehicle_kms.kept.count
    total_maintenances = maintenances.kept.count
    total_records = total_vehicles + total_kms + total_maintenances

    {
      can_proceed: preview[:can_proceed],
      requires_force: preview[:requires_force],
      is_massive_operation: total_records > 100,
      requires_background_job: total_records > 1000,
      total_records_to_delete: total_records,
      vehicles_count: total_vehicles,
      vehicle_kms_count: total_kms,
      maintenances_count: total_maintenances,
      vehicles_with_conflicts: vehicles.kept.with_conflictive_kms.count,
      conflictive_kms_count: vehicle_kms.kept.conflictive.count,
      total_maintenance_cost: maintenances.kept.sum(:amount).to_f,
      warnings_count: preview[:impact][:warnings].count,
      estimated_time: preview[:impact][:estimated_time],
      recommendation: preview[:message]
    }
  end

  # Verifica si la restauración es viable
  def restoration_viability
    analyzer = SoftDelete::RestorationAnalyzer.new(self)
    info = analyzer.analyze

    total_cascaded = (info[:cascaded_records] || []).sum { |c| c[:count] }

    {
      can_restore: info[:can_restore],
      conflicts: info[:conflicts],
      cascaded_records_count: total_cascaded,
      is_massive_restoration: total_cascaded > 100,
      restore_options: info[:restore_options]&.map { |opt| opt[:type] },
      recommendation: info[:recommendation]
    }
  end

  # Exportar datos antes de eliminar (futuro)
  def export_data_before_deletion
    # TODO: Implementar exportación de datos
    # Retornar archivo CSV/JSON con todos los datos
    {
      company: attributes,
      vehicles: vehicles.kept.map(&:attributes),
      vehicle_kms: vehicle_kms.kept.limit(1000).map(&:attributes), # Limitar para no explotar
      maintenances: maintenances.kept.map(&:attributes),
      exported_at: Time.current
    }
  end

  # Descripción del estado para UI
  def deletion_status_description
    if kept?
      active_vehicles = vehicles.kept.count
      "Activa (#{active_vehicles} vehículos)"
    else
      deleted_at = discarded_at&.strftime("%d/%m/%Y %H:%M")
      "Eliminada el #{deleted_at}"
    end
  end

  # Nivel de riesgo de la operación de borrado
  def deletion_risk_level
    total = vehicles.kept.count + vehicle_kms.kept.count + maintenances.kept.count

    case total
    when 0..10
      { level: :low, color: :green, description: "Bajo riesgo" }
    when 11..100
      { level: :medium, color: :yellow, description: "Riesgo medio" }
    when 101..500
      { level: :high, color: :orange, description: "Alto riesgo" }
    else
      { level: :critical, color: :red, description: "Riesgo crítico - Requiere job en segundo plano" }
    end
  end

  private

  # Métodos helper privados para futuras validaciones
  # def has_pending_invoices?
  #   invoices.pending.exists?
  # end

  # def has_active_contracts?
  #   contracts.active.exists?
  # end

  # def has_active_users?
  #   users.active.exists?
  # end
end
