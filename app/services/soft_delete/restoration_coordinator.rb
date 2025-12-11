# app/services/soft_delete/restoration_coordinator.rb
module SoftDelete
  class RestorationCoordinator
    attr_reader :record, :options, :restoration_info

    def initialize(record, options = {})
      @record = record
      @options = default_options.merge(options)
      @restoration_info = nil
      @result = nil

      # Validar que el registro esté borrado
      unless @record.discarded?
        raise ArgumentError,
              "El registro #{@record.class.name}##{@record.id} no está eliminado (discarded_at es NULL)"
      end
    end

    def call
      # FASE 1: Análisis previo
      return failure_from_analysis unless analyze_and_validate

      # FASE 2: Ejecución transaccional
      execute_restoration
    rescue StandardError => e
      Rails.logger.error(
        "[RESTORATION COORDINATOR] Error restoring #{@record.class.name}##{@record.id}: #{e.message}\n" \
        "#{e.backtrace.first(5).join("\n")}"
      )

      failure_response(
        errors: [ "Error interno: #{e.message}" ],
        message: "No se pudo completar la restauración"
      )
    end

    # Preview de la restauración sin ejecutarla
    def preview
      @restoration_info = analyze_restoration

      {
        success: true,
        can_proceed: @restoration_info[:can_restore],
        restoration_info: @restoration_info,
        record: @record,
        requires_decisions: requires_decisions?,
        restore_options: @restoration_info[:restore_options],
        message: preview_message
      }
    end

    private

    # FASE 1: ANÁLISIS Y VALIDACIÓN

    # Analiza y valida si se puede proceder con la restauración
    def analyze_and_validate
      # Saltar análisis si se especifica (uso interno)
      return true if @options[:skip_analysis]

      # Realizar análisis de restauración
      @restoration_info = analyze_restoration

      # Verificar conflictos críticos (blockers)
      blockers = extract_blockers
      if blockers.any?
        @result = failure_response(
          errors: blockers.map { |b| b[:message] },
          message: "La restauración está bloqueada",
          restoration_info: @restoration_info,
          conflicts: blockers
        )
        return false
      end

      # Verificar que se hayan tomado decisiones necesarias
      unless validate_required_decisions
        @result = failure_response(
          errors: [ "Faltan decisiones necesarias para restaurar" ],
          message: "Se requieren decisiones adicionales",
          restoration_info: @restoration_info,
          required_decisions: extract_required_decisions
        )
        return false
      end

      true
    end

    # Realiza el análisis de restauración
    def analyze_restoration
      return @restoration_info if @restoration_info

      analyzer = RestorationAnalyzer.new(@record)
      analyzer.analyze
    end

    # Extrae conflictos bloqueantes del análisis
    def extract_blockers
      return [] unless @restoration_info

      conflicts = @restoration_info[:conflicts] || []
      conflicts.select { |c| c[:type] == "blocker" }
    end

    # Verifica si se requieren decisiones del usuario
    def requires_decisions?
      return false unless @restoration_info

      # Decisiones de cascada
      has_cascades = @restoration_info[:cascaded_records]&.any?
      cascade_decision_needed = has_cascades && !@options[:cascade_restore].nil? == false

      # Decisiones de reasignación
      parent_conflicts = (@restoration_info[:conflicts] || []).select do |c|
        c[:category] == "parent_deleted"
      end
      reassign_needed = parent_conflicts.any? && @options[:reassign_to].blank?

      cascade_decision_needed || reassign_needed
    end

    # Valida que se hayan tomado las decisiones necesarias
    def validate_required_decisions
      # Si hay conflictos de padre borrado, debe especificar reasignación
      parent_conflicts = (@restoration_info[:conflicts] || []).select do |c|
        c[:category] == "parent_deleted"
      end

      if parent_conflicts.any? && @options[:reassign_to].blank?
        return false
      end

      # Si hay cascadas y se eligió restaurar solo algunas, validar
      if @options[:selected_cascades].present?
        cascaded = @restoration_info[:cascaded_records] || []
        valid_cascades = cascaded.map { |c| c[:relation].parameterize.underscore.to_sym }

        invalid = @options[:selected_cascades] - valid_cascades
        return false if invalid.any?
      end

      true
    end

    # Extrae decisiones requeridas
    def extract_required_decisions
      decisions = []

      # Decisión sobre cascadas
      cascaded = @restoration_info[:cascaded_records] || []
      if cascaded.any?
        decisions << {
          type: "cascade",
          description: "Decidir si restaurar registros en cascada",
          options: [ "cascade_restore: true/false", "selected_cascades: [:relation1, ...]" ],
          cascades_available: cascaded
        }
      end

      # Decisión sobre reasignación
      parent_conflicts = (@restoration_info[:conflicts] || []).select do |c|
        c[:category] == "parent_deleted"
      end

      if parent_conflicts.any?
        parent_conflicts.each do |conflict|
          decisions << {
            type: "reassign",
            description: "Reasignar #{conflict[:relation]}",
            options: "reassign_to: { #{conflict[:relation].underscore}_id: NEW_ID }",
            conflict: conflict
          }
        end
      end

      decisions
    end

    # FASE 2: EJECUCIÓN DE LA RESTAURACIÓN

    # Ejecuta la restauración dentro de una transacción
    def execute_restoration
      restored_count = 0

      ActiveRecord::Base.transaction do
        # 1. Resolver conflictos (reasignación si es necesario)
        resolve_conflicts

        # 2. Restaurar registros en cascada (ANTES del undiscard principal)
        restored_count += restore_cascaded_records if should_restore_cascades?

        # 3. Preparar contexto
        prepare_restoration_context

        # 4. Ejecutar undiscard (dispara callbacks del concern)
        @record.undiscard

        # 5. Verificar éxito
        unless @record.kept?
          raise ActiveRecord::Rollback, "El registro no fue restaurado"
        end

        restored_count += 1

        # 6. Obtener el log de auditoría creado
        audit_log = find_audit_log

        # 7. Construir respuesta de éxito
        @result = success_response(audit_log, restored_count)
      end

      @result
    end

    # Resuelve conflictos antes de restaurar
    def resolve_conflicts
      # Reasignar relaciones padre si se especificó
      if @options[:reassign_to].present?
        @options[:reassign_to].each do |attribute, new_value|
          if @record.respond_to?("#{attribute}=")
            @record.send("#{attribute}=", new_value)

            Rails.logger.info(
              "[RESTORATION] Reassigning #{attribute} to #{new_value} for #{@record.class.name}##{@record.id}"
            )
          end
        end
      end
    end

    # Verifica si debe restaurar cascadas
    def should_restore_cascades?
      @options[:cascade_restore] == true || @options[:selected_cascades].present?
    end

    # Restaura registros borrados en cascada
    def restore_cascaded_records
      restored_count = 0
      cascaded = @restoration_info[:cascaded_records] || []

      # Filtrar solo las cascadas seleccionadas si se especificó
      if @options[:selected_cascades].present?
        selected = @options[:selected_cascades].map(&:to_s).map(&:parameterize).map(&:underscore)
        cascaded = cascaded.select do |cascade|
          selected.include?(cascade[:relation].parameterize.underscore)
        end
      end

      cascaded.each do |cascade_info|
        relation_name = cascade_info[:relation].parameterize.underscore.to_sym

        begin
          # Obtener la configuración de la relación del modelo
          relation_config = @record.soft_delete_cascade_relations.find do |config|
            config[:name].to_s.parameterize.underscore == relation_name.to_s
          end

          next unless relation_config

          count = restore_cascade_relation(relation_config[:name])
          restored_count += count

          Rails.logger.info(
            "[RESTORATION CASCADE] Restored #{count} #{relation_name} for #{@record.class.name}##{@record.id}"
          )
        rescue StandardError => e
          Rails.logger.error(
            "[RESTORATION CASCADE ERROR] #{@record.class.name}##{@record.id} -> #{relation_name}: #{e.message}"
          )
        end
      end

      restored_count
    end

    # Restaura una relación en cascada específica
    def restore_cascade_relation(relation_name)
      count = 0

      begin
        relation = @record.send(relation_name)

        # Manejar has_many
        if relation.respond_to?(:discarded)
          records = relation.discarded
          records.each do |record|
            record.undiscard if record.respond_to?(:undiscard)
            count += 1
          end
        # Manejar has_one o belongs_to
        elsif relation&.discarded?
          relation.undiscard if relation.respond_to?(:undiscard)
          count += 1
        end
      rescue StandardError => e
        Rails.logger.error(
          "[RESTORE CASCADE] Error restoring #{relation_name}: #{e.message}"
        )
      end

      count
    end

    # Prepara el contexto que será usado por el concern
    def prepare_restoration_context
      # Agregar usuario si está disponible
      if @options[:user]
        @record.instance_variable_set(:@restoration_user, @options[:user])
      end

      # Agregar información de cascadas restauradas
      if @options[:cascade_restore] || @options[:selected_cascades].present?
        @record.instance_variable_set(:@cascades_restored, true)
      end

      # Agregar información de reasignación
      if @options[:reassign_to].present?
        @record.instance_variable_set(:@reassignments, @options[:reassign_to])
      end
    end

    # Construye respuesta de éxito
    def success_response(audit_log, restored_count)
      {
        success: true,
        record: @record,
        restoration_info: @restoration_info,
        audit_log: audit_log,
        message: build_success_message(restored_count),
        restored_count: restored_count,
        warnings: extract_applied_warnings
      }
    end

    # Construye respuesta de fallo
    def failure_response(errors: [], warnings: [], message: nil, **extra)
      {
        success: false,
        record: @record,
        errors: errors,
        warnings: warnings,
        message: message || "No se pudo completar la restauración",
        **extra
      }
    end

    # Construye respuesta de fallo desde el análisis
    def failure_from_analysis
      return @result if @result

      failure_response(
        errors: [ "Error en el análisis de restauración" ],
        message: "No se pudo analizar la viabilidad de restauración"
      )
    end

    # Opciones por defecto
    def default_options
      {
        cascade_restore: false,
        selected_cascades: nil,
        user: nil,
        reassign_to: {},
        skip_analysis: false,
        force_conflicts: false
      }
    end

    # Encuentra el log de auditoría recién creado
    def find_audit_log
      SoftDeleteAuditLog
        .restorations
        .for_record(@record)
        .order(performed_at: :desc)
        .first
    end

    # Construye mensaje de éxito descriptivo
    def build_success_message(restored_count)
      parts = [ "#{@record.class.name} restaurado correctamente" ]

      if restored_count > 1
        cascade_count = restored_count - 1
        parts << "#{cascade_count} registros restaurados en cascada"
      end

      if @options[:reassign_to].present?
        parts << "con reasignación de relaciones padre"
      end

      parts.join(". ")
    end

    # Extrae warnings aplicados
    def extract_applied_warnings
      warnings = []

      # Advertencias sobre cascadas no restauradas
      cascaded = @restoration_info[:cascaded_records] || []
      if cascaded.any? && !@options[:cascade_restore] && @options[:selected_cascades].blank?
        total = cascaded.sum { |c| c[:count] }
        warnings << "#{total} registros relacionados NO fueron restaurados"
      end

      # Advertencias sobre cascadas parciales
      if @options[:selected_cascades].present?
        all_cascades = cascaded.map { |c| c[:relation].parameterize.underscore.to_sym }
        not_restored = all_cascades - @options[:selected_cascades]

        if not_restored.any?
          warnings << "Algunas cascadas NO fueron restauradas: #{not_restored.join(', ')}"
        end
      end

      warnings
    end

    # Construye mensaje de preview
    def preview_message
      return @restoration_info[:recommendation] if @restoration_info

      "Análisis no disponible"
    end
  end
end
