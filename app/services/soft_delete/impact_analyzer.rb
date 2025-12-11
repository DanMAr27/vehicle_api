# app/services/soft_delete/impact_analyzer.rb
module SoftDelete
  class ImpactAnalyzer
    attr_reader :record

    def initialize(record)
      @record = record
      @cache = {}
    end

    # Analiza el impacto completo del borrado
    def analyze
      {
        can_delete: can_delete?,
        blockers: find_blockers,
        will_cascade: find_cascade_impact,
        will_nullify: find_nullify_impact,
        warnings: generate_warnings,
        estimated_time: estimate_deletion_time,
        recommendation: generate_recommendation,
        total_affected: calculate_total_affected
      }
    end

    private

    # Verifica si el registro puede ser borrado
    # Solo retorna false si hay blockers críticos
    def can_delete?
      find_blockers.empty?
    end

    # Encuentra todas las relaciones que bloquean el borrado
    def find_blockers
      return @cache[:blockers] if @cache[:blockers]

      blockers = []

      # BLOQUEOS POR RELACIONES
      @record.soft_delete_blocking_relations.each do |relation_config|
        blocker = analyze_blocking_relation(relation_config)
        blockers << blocker if blocker
      end

      # BLOQUEOS POR VALIDACIONES DEL MODELO
      validation_blockers = extract_validation_blockers
      blockers.concat(validation_blockers)

      @cache[:blockers] = blockers
    end

    # Analiza una relación bloqueante específica
    def analyze_blocking_relation(relation_config)
      relation_name = relation_config[:name]
      custom_message = relation_config[:message]

      begin
        relation = @record.send(relation_name)
        count = count_active_records(relation)

        return nil if count.zero?

        {
          type: "relation",
          relation: relation_name.to_s.humanize,
          count: count,
          severity: "critical",
          message: build_blocking_message(relation_name, count, custom_message),
          can_force: false
        }
      rescue StandardError => e
        Rails.logger.error(
          "[IMPACT ANALYZER] Error analyzing blocking relation #{relation_name}: #{e.message}"
        )
        nil
      end
    end

    # Extrae blockers de las validaciones del modelo
    def extract_validation_blockers
      validations = @record.soft_delete_validations
      normalized = normalize_validations(validations)

      normalized.select { |v| v[:severity] == "blocker" }.map do |validation|
        {
          type: "validation",
          severity: "critical",
          message: validation[:message],
          can_force: false
        }
      end
    end

    # Construye mensaje de bloqueo para relaciones
    def build_blocking_message(relation_name, count, custom_message)
      if custom_message
        "Tiene #{count} #{custom_message}"
      else
        "Tiene #{count} #{relation_name.to_s.humanize.downcase} activos que impiden el borrado"
      end
    end

    # Encuentra todos los registros que se borrarán en cascada
    def find_cascade_impact
      return @cache[:cascade_impact] if @cache[:cascade_impact]

      cascade_items = []

      @record.soft_delete_cascade_relations.each do |relation_config|
        cascade_info = analyze_cascade_relation(relation_config)
        cascade_items << cascade_info if cascade_info
      end

      @cache[:cascade_impact] = cascade_items
    end

    # Analiza una relación de cascada específica
    def analyze_cascade_relation(relation_config)
      relation_name = relation_config[:name]
      is_optional = relation_config[:optional] || false

      # Verificar condición si existe
      if relation_config[:condition].is_a?(Proc)
        return nil unless @record.instance_exec(&relation_config[:condition])
      end

      begin
        relation = @record.send(relation_name)
        count = count_active_records(relation)

        return nil if count.zero?

        {
          relation: relation_name.to_s.humanize,
          count: count,
          model: extract_model_name(relation),
          optional: is_optional,
          action: is_optional ? "Opcional: puede borrar o mantener" : "Se borrarán automáticamente"
        }
      rescue StandardError => e
        Rails.logger.error(
          "[IMPACT ANALYZER] Error analyzing cascade relation #{relation_name}: #{e.message}"
        )
        nil
      end
    end

    # Encuentra todos los registros que se desvincularán
    def find_nullify_impact
      return @cache[:nullify_impact] if @cache[:nullify_impact]

      nullify_items = []

      @record.soft_delete_nullify_relations.each do |relation_config|
        nullify_info = analyze_nullify_relation(relation_config)
        nullify_items << nullify_info if nullify_info
      end

      @cache[:nullify_impact] = nullify_items
    end

    # Analiza una relación de nullify específica
    def analyze_nullify_relation(relation_config)
      model_class = relation_config[:model].constantize
      foreign_key = relation_config[:foreign_key]
      relation_name = relation_config[:name] || model_class.name.pluralize

      begin
        count = model_class.kept.where(foreign_key => @record.id).count

        return nil if count.zero?

        {
          relation: relation_name.to_s.humanize,
          count: count,
          model: model_class.name,
          action: "Se desvinculará (foreign key = NULL)",
          foreign_key: foreign_key
        }
      rescue StandardError => e
        Rails.logger.error(
          "[IMPACT ANALYZER] Error analyzing nullify relation for #{model_class}: #{e.message}"
        )
        nil
      end
    end

    # Genera todas las advertencias del borrado
    def generate_warnings
      warnings = []

      # ADVERTENCIAS DE VALIDACIONES DEL MODELO
      model_warnings = extract_model_warnings
      warnings.concat(model_warnings)

      # ADVERTENCIAS DE CASCADAS MASIVAS
      cascade_warnings = analyze_cascade_warnings
      warnings.concat(cascade_warnings)

      # ADVERTENCIAS ESPECÍFICAS DEL MODELO
      specific_warnings = generate_model_specific_warnings
      warnings.concat(specific_warnings)

      warnings
    end

    # Extrae warnings de las validaciones del modelo
    def extract_model_warnings
      validations = @record.soft_delete_validations
      normalized = normalize_validations(validations)

      normalized.select { |v| v[:severity] != "blocker" }.map do |validation|
        {
          type: "validation",
          message: validation[:message],
          severity: validation[:severity],
          can_force: validation[:severity] == "warning"
        }
      end
    end

    # Analiza advertencias relacionadas con cascadas
    def analyze_cascade_warnings
      warnings = []
      total_cascade = find_cascade_impact.sum { |i| i[:count] }

      if total_cascade > 100 && total_cascade <= 1000
        warnings << {
          type: "cascade",
          message: "Se borrarán más de 100 registros en cascada (#{total_cascade} total)",
          severity: "high",
          can_force: true
        }
      end

      if total_cascade > 1000
        warnings << {
          type: "cascade",
          message: "OPERACIÓN MASIVA: #{total_cascade} registros se borrarán. " \
                   "Esta operación puede tardar varios minutos.",
          severity: "critical",
          can_force: true
        }
      end

      warnings
    end

    # Genera advertencias específicas según el tipo de modelo
    def generate_model_specific_warnings
      warnings = []

      case @record.class.name
      when "VehicleKm"
        warnings.concat(vehicle_km_warnings)
      when "Maintenance"
        warnings.concat(maintenance_warnings)
      when "Vehicle"
        warnings.concat(vehicle_warnings)
      when "Company"
        warnings.concat(company_warnings)
      end

      warnings
    end

    # Advertencias específicas para VehicleKm
    def vehicle_km_warnings
      warnings = []

      if @record.respond_to?(:from_maintenance?) && @record.from_maintenance?
        warnings << {
          type: "model_specific",
          message: "Este registro fue creado desde un mantenimiento. El mantenimiento quedará desvinculado.",
          severity: "medium",
          can_force: true
        }
      end

      if @record.respond_to?(:status) && @record.status == "corregido"
        warnings << {
          type: "model_specific",
          message: "Este KM tiene correcciones automáticas que se perderán.",
          severity: "medium",
          can_force: true
        }
      end

      warnings
    end

    # Advertencias específicas para Maintenance
    def maintenance_warnings
      warnings = []

      if @record.respond_to?(:amount) && @record.amount.to_f > 1000
        warnings << {
          type: "model_specific",
          message: "Este mantenimiento tiene un costo alto (#{@record.amount}€).",
          severity: "medium",
          can_force: true
        }
      end

      warnings
    end

    # Advertencias específicas para Vehicle
    def vehicle_warnings
      warnings = []

      if @record.respond_to?(:vehicle_kms)
        km_count = @record.vehicle_kms.kept.count
        if km_count > 100
          warnings << {
            type: "model_specific",
            message: "Este vehículo tiene #{km_count} registros de KM que se borrarán.",
            severity: "high",
            can_force: true
          }
        end
      end

      warnings
    end

    # Advertencias específicas para Company
    def company_warnings
      warnings = []

      total_data = find_cascade_impact.sum { |i| i[:count] }

      if total_data > 500
        warnings << {
          type: "model_specific",
          message: "Esta compañía tiene #{total_data} registros asociados. " \
                   "La operación puede tardar varios minutos.",
          severity: "high",
          can_force: true
        }
      end

      warnings
    end

    # Estima el tiempo que tardará el borrado
    def estimate_deletion_time
      total = calculate_total_affected

      case total
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

    # Genera una recomendación basada en el análisis
    def generate_recommendation
      blockers = find_blockers
      return "BLOQUEADO: Resuelva los bloqueos antes de continuar" if blockers.any?

      warnings = generate_warnings
      critical_warnings = warnings.select { |w| w[:severity] == "critical" && !w[:can_force] }
      return "BLOQUEADO: #{critical_warnings.first[:message]}" if critical_warnings.any?

      high_warnings = warnings.select { |w| w[:severity] == "high" }
      return "PRECAUCIÓN: Revise las advertencias antes de proceder" if high_warnings.any?

      medium_warnings = warnings.select { |w| w[:severity] == "medium" }
      return "ATENCIÓN: Revise las advertencias" if medium_warnings.any?

      "OK: Seguro para borrar"
    end

    # Calcula el total de registros afectados
    def calculate_total_affected
      cascade_count = find_cascade_impact.sum { |i| i[:count] }
      nullify_count = find_nullify_impact.sum { |i| i[:count] }

      cascade_count + nullify_count
    end

    # Cuenta registros activos de una relación
    def count_active_records(relation)
      return 0 unless relation

      if relation.respond_to?(:kept)
        relation.kept.count
      elsif relation.respond_to?(:count)
        relation.count
      elsif relation.respond_to?(:size)
        relation.size
      else
        relation.present? ? 1 : 0
      end
    rescue StandardError
      0
    end

    # Extrae el nombre del modelo de una relación
    def extract_model_name(relation)
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

    # Normaliza validaciones a formato estándar
    def normalize_validations(validations)
      validations.map do |validation|
        if validation.is_a?(String)
          severity = detect_severity_from_message(validation)
          { severity: severity, message: validation }
        elsif validation.is_a?(Hash)
          validation[:severity] ||= "info"
          validation
        else
          { severity: "info", message: validation.to_s }
        end
      end
    end

    # Detecta la severidad desde el mensaje
    def detect_severity_from_message(message)
      return "warning" if message.include?("ADVERTENCIA")
      return "blocker" if message.include?("CRÍTICO") || message.include?("BLOQUEADO")
      return "high" if message.include?("IMPORTANTE")
      "info"
    end
  end
end
