# app/services/soft_delete/deletion_coordinator.rb
module SoftDelete
  class DeletionCoordinator
    attr_reader :record, :options, :impact

    def initialize(record, options = {})
      @record = record
      @options = default_options.merge(options)
      @impact = nil
      @result = nil
    end

    # Ejecuta el borrado completo
    def call
      # FASE 1: Análisis previo
      return failure_from_analysis unless analyze_and_validate

      # FASE 2: Ejecución transaccional
      execute_deletion
    rescue StandardError => e
      Rails.logger.error(
        "[DELETION COORDINATOR] Error deleting #{@record.class.name}##{@record.id}: #{e.message}\n" \
        "#{e.backtrace.first(5).join("\n")}"
      )

      failure_response(
        errors: [ "Error interno: #{e.message}" ],
        message: "No se pudo completar el borrado"
      )
    end

    # Preview del impacto sin ejecutar el borrado
    # Útil para mostrar al usuario antes de confirmar
    def preview
      @impact = analyze_impact

      {
        success: true,
        can_proceed: @impact[:can_delete],
        impact: @impact,
        record: @record,
        requires_force: requires_force?,
        optional_cascades: extract_optional_cascades,
        message: preview_message
      }
    end

    private

    # FASE 1: ANÁLISIS Y VALIDACIÓN

    # Analiza y valida si se puede proceder con el borrado
    #
    def analyze_and_validate
      # Saltar análisis si se especifica (uso interno)
      return true if @options[:skip_analysis]

      # Realizar análisis de impacto
      @impact = analyze_impact

      # Verificar blockers críticos (no se pueden forzar)
      if @impact[:blockers].any?
        @result = failure_response(
          errors: @impact[:blockers].map { |b| b[:message] },
          message: "El borrado está bloqueado",
          impact: @impact
        )
        return false
      end

      # Verificar warnings (se pueden forzar con force: true)
      if requires_force? && !@options[:force]
        @result = failure_response(
          errors: [],
          warnings: @impact[:warnings].map { |w| w[:message] },
          message: "El borrado requiere confirmación (use force: true)",
          impact: @impact,
          requires_force: true
        )
        return false
      end

      # Validar cascadas opcionales
      unless validate_cascade_options
        @result = failure_response(
          errors: [ "Debe especificar qué hacer con las cascadas opcionales" ],
          message: "Faltan decisiones sobre cascadas opcionales",
          impact: @impact,
          optional_cascades: extract_optional_cascades
        )
        return false
      end

      true
    end

    # Realiza el análisis de impacto
    #
    def analyze_impact
      return @impact if @impact

      analyzer = ImpactAnalyzer.new(@record)
      analyzer.analyze
    end

    # Verifica si se requiere forzar el borrado
    #
    def requires_force?
      return false unless @impact

      warnings = @impact[:warnings] || []
      forceable_warnings = warnings.select { |w| w[:can_force] }

      forceable_warnings.any?
    end

    # Valida que se hayan especificado decisiones para cascadas opcionales
    #
    def validate_cascade_options
      optional_cascades = extract_optional_cascades
      return true if optional_cascades.empty?

      cascade_options = @options[:cascade_options] || {}

      optional_cascades.all? do |cascade|
        relation_key = cascade[:relation].parameterize.underscore.to_sym
        cascade_options.key?(relation_key)
      end
    end

    # Extrae información de cascadas opcionales del impacto
    #
    def extract_optional_cascades
      return [] unless @impact

      (@impact[:will_cascade] || []).select { |c| c[:optional] }
    end

    # FASE 2: EJECUCIÓN DEL BORRADO

    # Ejecuta el borrado dentro de una transacción
    #
    def execute_deletion
      ActiveRecord::Base.transaction do
        # Preparar contexto antes del borrado
        prepare_deletion_context

        # Procesar cascadas opcionales ANTES del discard
        process_optional_cascades

        # Ejecutar el discard (dispara los callbacks del concern)
        # Los callbacks ejecutarán:
        # - Validaciones del modelo
        # - Verificación de bloqueos
        # - before_soft_delete hook
        # - Cascadas automáticas
        # - Nullify
        # - after_soft_delete hook
        # - Auditoría
        @record.discard

        # Verificar si el discard fue exitoso
        unless @record.discarded?
          raise ActiveRecord::Rollback, "El registro no fue marcado como discarded"
        end

        # Obtener el log de auditoría creado por el concern
        audit_log = find_audit_log

        # Construir respuesta de éxito
        @result = success_response(audit_log)
      end

      @result
    end

    # Prepara el contexto que será usado por el concern
    #
    def prepare_deletion_context
      # El concern construye el contexto base, pero podemos agregar info adicional
      # mediante el options hash que luego se usa en before_soft_delete

      # Agregar usuario si está disponible
      if @options[:user]
        @record.instance_variable_set(:@deletion_user, @options[:user])
      end

      # Agregar información de cascadas opcionales procesadas
      if @options[:cascade_options].present?
        @record.instance_variable_set(:@cascade_decisions, @options[:cascade_options])
      end
    end

    # Procesa cascadas opcionales según las decisiones del usuario
    #
    def process_optional_cascades
      cascade_options = @options[:cascade_options] || {}
      optional_cascades = extract_optional_cascades

      optional_cascades.each do |cascade_info|
        relation_name = cascade_info[:relation].parameterize.underscore.to_sym
        decision = cascade_options[relation_name]

        next unless decision == "delete"

        # Obtener la configuración original de la relación
        relation_config = @record.soft_delete_cascade_relations.find do |config|
          config[:name].to_s.parameterize.underscore == relation_name.to_s
        end

        next unless relation_config

        # Verificar condición si existe
        if relation_config[:condition].is_a?(Proc)
          next unless @record.instance_exec(&relation_config[:condition])
        end

        # Borrar la relación
        delete_optional_cascade(relation_config[:name])
      end
    end

    # Borra una cascada opcional específica
    #
    def delete_optional_cascade(relation_name)
      begin
        relation = @record.send(relation_name)

        # Manejar has_many
        if relation.respond_to?(:each)
          records = relation.respond_to?(:kept) ? relation.kept : relation
          records.each do |record|
            record.discard if record.respond_to?(:discard)
          end
        # Manejar belongs_to o has_one
        elsif relation && relation.respond_to?(:discard)
          relation.discard
        end

        Rails.logger.info(
          "[OPTIONAL CASCADE] Deleted #{relation_name} for #{@record.class.name}##{@record.id}"
        )
      rescue StandardError => e
        Rails.logger.error(
          "[OPTIONAL CASCADE ERROR] #{@record.class.name}##{@record.id} -> #{relation_name}: #{e.message}"
        )
      end
    end

    # Construye respuesta de éxito
    #
    def success_response(audit_log)
      {
        success: true,
        record: @record,
        impact: @impact,
        audit_log: audit_log,
        message: build_success_message,
        warnings: extract_applied_warnings,
        cascade_count: audit_log&.cascade_count || 0,
        nullify_count: audit_log&.nullify_count || 0
      }
    end

    # Construye respuesta de fallo
    #
    def failure_response(errors: [], warnings: [], message: nil, **extra)
      {
        success: false,
        record: @record,
        errors: errors,
        warnings: warnings,
        message: message || "No se pudo completar el borrado",
        **extra
      }
    end

    # Construye respuesta de fallo desde el análisis
    #
    def failure_from_analysis
      return @result if @result

      failure_response(
        errors: [ "Error en el análisis de impacto" ],
        message: "No se pudo analizar el impacto del borrado"
      )
    end

    # HELPERS

    # Opciones por defecto
    #
    def default_options
      {
        force: false,
        user: nil,
        cascade_options: {},
        skip_analysis: false
      }
    end

    # Encuentra el log de auditoría recién creado
    #
    def find_audit_log
      SoftDeleteAuditLog
        .deletions
        .for_record(@record)
        .order(performed_at: :desc)
        .first
    end

    # Construye mensaje de éxito descriptivo
    #
    def build_success_message
      parts = [ "#{@record.class.name} eliminado correctamente" ]

      if @impact
        cascade_count = @impact[:will_cascade].sum { |c| c[:count] }
        nullify_count = @impact[:will_nullify].sum { |n| n[:count] }

        if cascade_count > 0
          parts << "#{cascade_count} registros eliminados en cascada"
        end

        if nullify_count > 0
          parts << "#{nullify_count} registros desvinculados"
        end
      end

      parts.join(". ")
    end

    # Extrae warnings que se aplicaron (si se usó force)
    #
    def extract_applied_warnings
      return [] unless @options[:force] && @impact

      (@impact[:warnings] || []).map { |w| w[:message] }
    end

    # Construye mensaje de preview
    #
    def preview_message
      return @impact[:recommendation] if @impact

      "Análisis no disponible"
    end
  end
end
