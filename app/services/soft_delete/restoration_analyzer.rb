# app/services/soft_delete/restoration_analyzer.rb
module SoftDelete
  class RestorationAnalyzer
    attr_reader :record

    def initialize(record)
      @record = record
      @cache = {}

      unless @record.discarded?
        raise ArgumentError, "El registro no está eliminado (discarded_at es NULL)"
      end
    end

    # Analiza la viabilidad de restauración completa

    def analyze
      {
        can_restore: can_restore?,
        conflicts: find_conflicts,
        cascaded_records: find_cascaded_records,
        restore_options: generate_restore_options,
        estimated_time: estimate_restoration_time,
        recommendation: generate_recommendation,
        deletion_log: find_deletion_log
      }
    end

    private

    # Verifica si el registro puede ser restaurado
    # Solo retorna false si hay conflictos críticos
    def can_restore?
      find_conflicts.none? { |c| c[:type] == "blocker" }
    end

    # Encuentra todos los conflictos que impiden o dificultan la restauración
    def find_conflicts
      return @cache[:conflicts] if @cache[:conflicts]

      conflicts = []

      # CONFLICTOS DE UNICIDAD
      uniqueness_conflicts = check_uniqueness_conflicts
      conflicts.concat(uniqueness_conflicts)

      # CONFLICTOS CON PADRES ELIMINADOS
      parent_conflicts = check_parent_relations
      conflicts.concat(parent_conflicts)

      # CONFLICTOS POR VALIDACIONES DEL MODELO
      validation_conflicts = extract_validation_conflicts
      conflicts.concat(validation_conflicts)

      @cache[:conflicts] = conflicts
    end

    # Verifica conflictos de unicidad con registros activos
    def check_uniqueness_conflicts
      conflicts = []

      @record.uniqueness_validations.each do |validation|
        conflict = analyze_uniqueness_validation(validation)
        conflicts << conflict if conflict
      end

      conflicts
    end

    # Analiza una validación de unicidad específica
    def analyze_uniqueness_validation(validation)
      field = validation[:field]
      scope = validation[:scope]

      # Construir query para buscar registros activos con el mismo valor
      query = @record.class.kept.where(field => @record.send(field))
      query = query.where(scope => @record.send(scope)) if scope
      query = query.where.not(id: @record.id)

      return nil unless query.exists?

      existing = query.first
      field_name = field.to_s.humanize
      field_value = @record.send(field)

      {
        type: "blocker",
        category: "uniqueness",
        field: field_name,
        value: field_value,
        existing_record_id: existing.id,
        existing_record_type: existing.class.name,
        message: "Ya existe un registro activo con #{field_name}: '#{field_value}' (#{existing.class.name} ##{existing.id})",
        severity: "critical",
        suggestion: "Debe cambiar el #{field_name} del registro existente o fusionar ambos registros"
      }
    rescue StandardError => e
      Rails.logger.error(
        "[RESTORATION ANALYZER] Error checking uniqueness for #{field}: #{e.message}"
      )
      nil
    end

    # Verifica conflictos con relaciones padre eliminadas
    def check_parent_relations
      conflicts = []

      case @record.class.name
      when "Vehicle"
        conflicts.concat(check_vehicle_parent_relations)
      when "VehicleKm"
        conflicts.concat(check_vehicle_km_parent_relations)
      when "Maintenance"
        conflicts.concat(check_maintenance_parent_relations)
      end

      conflicts
    end

    # Conflictos de Vehicle (padre: Company)
    def check_vehicle_parent_relations
      return [] unless @record.respond_to?(:company)

      company = @record.company

      return [] unless company&.discarded?

      [ {
        type: "blocker",
        category: "parent_deleted",
        relation: "Company",
        parent_id: company.id,
        parent_name: company.name,
        message: "La compañía asociada '#{company.name}' (ID: #{company.id}) fue eliminada",
        severity: "critical",
        suggestion: "Debe restaurar primero la compañía o reasignar el vehículo a otra compañía"
      } ]
    end

    # Conflictos de VehicleKm (padre: Vehicle)
    def check_vehicle_km_parent_relations
      return [] unless @record.respond_to?(:vehicle)

      vehicle = @record.vehicle

      return [] unless vehicle&.discarded?

      [ {
        type: "blocker",
        category: "parent_deleted",
        relation: "Vehicle",
        parent_id: vehicle.id,
        parent_name: vehicle.matricula,
        message: "El vehículo asociado '#{vehicle.matricula}' (ID: #{vehicle.id}) fue eliminado",
        severity: "critical",
        suggestion: "Debe restaurar primero el vehículo"
      } ]
    end

    # Conflictos de Maintenance (padre: Vehicle)
    def check_maintenance_parent_relations
      return [] unless @record.respond_to?(:vehicle)

      vehicle = @record.vehicle

      return [] unless vehicle&.discarded?

      [ {
        type: "blocker",
        category: "parent_deleted",
        relation: "Vehicle",
        parent_id: vehicle.id,
        parent_name: vehicle.matricula,
        message: "El vehículo asociado '#{vehicle.matricula}' (ID: #{vehicle.id}) fue eliminado",
        severity: "critical",
        suggestion: "Debe restaurar primero el vehículo"
      } ]
    end

    # Extrae conflictos de las validaciones del modelo
    def extract_validation_conflicts
      validation_errors = @record.validate_soft_restore

      validation_errors.map do |error_message|
        {
          type: "blocker",
          category: "validation",
          message: error_message,
          severity: "high",
          suggestion: "Resuelva este problema antes de restaurar"
        }
      end
    end

    # Encuentra registros borrados en cascada que pueden restaurarse junto a este
    def find_cascaded_records
      return @cache[:cascaded_records] if @cache[:cascaded_records]

      cascaded = []
      deletion_log = find_deletion_log

      # Si no hay log o no hubo cascadas, retornar vacío
      return cascaded unless deletion_log
      return cascaded if deletion_log.cascade_count == 0

      # Analizar cada relación de cascada del modelo
      @record.soft_delete_cascade_relations.each do |relation_config|
        cascade_info = analyze_cascaded_relation(relation_config, deletion_log)
        cascaded << cascade_info if cascade_info
      end

      @cache[:cascaded_records] = cascaded
    end

    # Analiza una relación de cascada para restauración
    def analyze_cascaded_relation(relation_config, deletion_log)
      relation_name = relation_config[:name]

      begin
        relation = @record.send(relation_name)

        # Contar registros discarded en la relación
        discarded_count = if relation.respond_to?(:discarded)
                            relation.discarded.count
        else
                            0
        end

        return nil if discarded_count.zero?

        {
          relation: relation_name.to_s.humanize,
          count: discarded_count,
          model: extract_model_name_from_relation(relation),
          can_restore_cascade: true,
          deleted_at: deletion_log.performed_at,
          recommendation: build_cascade_recommendation(discarded_count)
        }
      rescue StandardError => e
        Rails.logger.error(
          "[RESTORATION ANALYZER] Error analyzing cascaded relation #{relation_name}: #{e.message}"
        )
        nil
      end
    end

    # Construye recomendación para cascadas
    def build_cascade_recommendation(count)
      if count <= 10
        "Recomendado: restaurar en cascada (#{count} registros)"
      elsif count <= 100
        "Opcional: restaurar en cascada (#{count} registros, puede tardar)"
      else
        "Precaución: restaurar en cascada (#{count} registros, operación pesada)"
      end
    end

    # Genera todas las opciones disponibles de restauración
    def generate_restore_options
      options = []
      cascaded = find_cascaded_records
      conflicts = find_conflicts

      # OPCIÓN 1: Restauración simple (solo el registro principal)
      options << build_simple_restore_option(cascaded)

      # OPCIÓN 2: Restauración en cascada (si hay cascadas)
      if cascaded.any?
        options << build_cascade_restore_option(cascaded)
      end

      # OPCIÓN 3: Fusión con registro existente (si hay conflictos de unicidad)
      uniqueness_conflicts = conflicts.select { |c| c[:category] == "uniqueness" }
      if uniqueness_conflicts.any?
        options << build_merge_option(uniqueness_conflicts)
      end

      # OPCIÓN 4: Restauración con reasignación (si hay conflictos de padre)
      parent_conflicts = conflicts.select { |c| c[:category] == "parent_deleted" }
      if parent_conflicts.any?
        options << build_reassign_option(parent_conflicts)
      end

      options
    end

    # Opción de restauración simple
    def build_simple_restore_option(cascaded)
      {
        type: "simple",
        name: "Restauración simple",
        description: "Restaurar solo este registro",
        will_restore_count: 1,
        leaves_orphaned: cascaded.any?,
        recommended: cascaded.empty?,
        complexity: "simple",
        estimated_time: "instant",
        warnings: cascaded.any? ? [ "Dejará #{cascaded.sum { |c| c[:count] }} registros relacionados sin restaurar" ] : []
      }
    end

    # Opción de restauración en cascada
    def build_cascade_restore_option(cascaded)
      total_cascade = cascaded.sum { |c| c[:count] }

      {
        type: "cascade",
        name: "Restauración en cascada",
        description: "Restaurar este registro y #{total_cascade} registros relacionados",
        will_restore_count: 1 + total_cascade,
        cascaded_details: cascaded,
        recommended: true,
        complexity: calculate_complexity(total_cascade),
        estimated_time: estimate_time(total_cascade),
        warnings: total_cascade > 100 ? [ "Esta operación puede tardar varios minutos" ] : []
      }
    end

    # Opción de fusión con registro existente
    #
    def build_merge_option(uniqueness_conflicts)
      {
        type: "merge",
        name: "Fusión con registro existente",
        description: "Fusionar datos con el registro activo que tiene los mismos valores únicos",
        will_restore_count: 0,
        requires_manual_action: true,
        recommended: false,
        complexity: "complex",
        estimated_time: "manual",
        conflicts: uniqueness_conflicts,
        warnings: [ "Requiere intervención manual para decidir qué datos conservar" ]
      }
    end

    # Opción de reasignación
    def build_reassign_option(parent_conflicts)
      {
        type: "reassign",
        name: "Restauración con reasignación",
        description: "Restaurar el registro asignándolo a otra relación padre activa",
        will_restore_count: 1,
        requires_manual_action: true,
        recommended: false,
        complexity: "medium",
        estimated_time: "manual",
        conflicts: parent_conflicts,
        warnings: [ "Debe seleccionar manualmente el nuevo padre antes de restaurar" ]
      }
    end

    # Estima el tiempo que tardará la restauración
    def estimate_restoration_time
      cascaded = find_cascaded_records
      total = cascaded.sum { |c| c[:count] }

      estimate_time(total)
    end

    # Genera una recomendación basada en el análisis
    def generate_recommendation
      conflicts = find_conflicts
      cascaded = find_cascaded_records

      # Blockers críticos
      blockers = conflicts.select { |c| c[:type] == "blocker" }

      parent_blockers = blockers.select { |c| c[:category] == "parent_deleted" }
      if parent_blockers.any?
        parent = parent_blockers.first
        return "BLOQUEADO: Debe restaurar primero #{parent[:relation]} ##{parent[:parent_id]}"
      end

      uniqueness_blockers = blockers.select { |c| c[:category] == "uniqueness" }
      if uniqueness_blockers.any?
        return "CONFLICTO: Ya existe un registro activo con los mismos datos únicos. " \
               "Debe cambiar el registro existente o fusionar ambos."
      end

      validation_blockers = blockers.select { |c| c[:category] == "validation" }
      if validation_blockers.any?
        return "PRECAUCIÓN: #{validation_blockers.first[:message]}"
      end

      # Sin blockers, evaluar cascadas
      if cascaded.any?
        total = cascaded.sum { |c| c[:count] }

        if total > 100
          return "RECOMENDADO: Restaurar en cascada con precaución (#{total} registros relacionados)"
        else
          return "SUGERIDO: Restaurar en cascada (#{total} registros relacionados)"
        end
      end

      "OK: Seguro para restaurar"
    end

    # Encuentra el log de borrado de este registro
    def find_deletion_log
      return @cache[:deletion_log] if @cache.key?(:deletion_log)

      @cache[:deletion_log] = SoftDeleteAuditLog
        .deletions
        .for_record(@record)
        .order(performed_at: :desc)
        .first
    end

    # Extrae el nombre del modelo de una relación
    def extract_model_name_from_relation(relation)
      return nil unless relation

      if relation.respond_to?(:klass)
        relation.klass.name
      elsif relation.respond_to?(:model_name)
        relation.model_name.to_s
      elsif relation.class.respond_to?(:model_name)
        relation.class.model_name.to_s
      else
        relation.class.name
      end
    rescue StandardError
      "Unknown"
    end

    # Calcula complejidad basada en cantidad
    def calculate_complexity(count)
      return "simple" if count == 0
      return "medium" if count < 10
      "complex"
    end

    # Estima tiempo basado en cantidad
    def estimate_time(count)
      case count
      when 0..10
        "instant"
      when 11..100
        "seconds"
      when 101..1000
        "minutes"
      else
        "background_job"
      end
    end
  end
end
