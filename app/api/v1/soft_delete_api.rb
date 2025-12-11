# app/api/v1/soft_delete_api.rb
module V1
  class SoftDeleteApi < Grape::API
    namespace :soft_delete do
      desc "Analizar el impacto de borrar un registro (preview)"
      params do
        requires :record_type, type: String, desc: "Tipo de modelo (Company, Vehicle, VehicleKm, Maintenance)"
        requires :record_id, type: Integer, desc: "ID del registro"
      end
      post :deletion_preview do
        # Validar y obtener registro
        record = find_record(params[:record_type], params[:record_id])
        error!({ error: "Registro no encontrado" }, 404) unless record

        # Crear coordinador y obtener preview
        coordinator = SoftDelete::DeletionCoordinator.new(record)
        preview = coordinator.preview

        # Respuesta estructurada
        present({
          success: true,
          record_type: params[:record_type],
          record_id: params[:record_id],
          preview: preview
        })
      end

      desc "Ejecutar el borrado de un registro"
      params do
        requires :record_type, type: String, desc: "Tipo de modelo"
        requires :record_id, type: Integer, desc: "ID del registro"
        optional :force, type: Boolean, default: false, desc: "Forzar borrado ignorando warnings"
        optional :cascade_options, type: Hash, desc: "Decisiones sobre cascadas opcionales"
        optional :user_id, type: Integer, desc: "ID del usuario que ejecuta la acción"
      end
      delete :execute do
        # Validar y obtener registro
        record = find_record(params[:record_type], params[:record_id])
        error!({ error: "Registro no encontrado" }, 404) unless record

        # Obtener usuario si se especificó
        user = params[:user_id] ? find_user(params[:user_id]) : nil

        # Crear coordinador con opciones
        coordinator = SoftDelete::DeletionCoordinator.new(record,
          force: params[:force],
          cascade_options: params[:cascade_options] || {},
          user: user
        )

        # Ejecutar borrado
        result = coordinator.call

        if result[:success]
          # Respuesta exitosa
          present({
            success: true,
            record_type: params[:record_type],
            record_id: params[:record_id],
            message: result[:message],
            audit_log_id: result[:audit_log]&.id,
            impact: {
              cascade_count: result[:cascade_count],
              nullify_count: result[:nullify_count]
            },
            warnings: result[:warnings]
          })
        else
          # Error estructurado
          error!({
            success: false,
            errors: result[:errors],
            warnings: result[:warnings],
            message: result[:message],
            requires_force: result[:requires_force],
            optional_cascades: result[:optional_cascades],
            impact: result[:impact]
          }, 422)
        end
      end

      desc "Analizar la viabilidad de restaurar un registro (preview)"
      params do
        requires :record_type, type: String, desc: "Tipo de modelo"
        requires :record_id, type: Integer, desc: "ID del registro eliminado"
      end
      post :restoration_preview do
        # Validar y obtener registro eliminado
        record = find_discarded_record(params[:record_type], params[:record_id])
        error!({ error: "Registro no encontrado o no está eliminado" }, 404) unless record

        # Crear coordinador y obtener preview
        coordinator = SoftDelete::RestorationCoordinator.new(record)
        preview = coordinator.preview

        # Respuesta estructurada
        present({
          success: true,
          record_type: params[:record_type],
          record_id: params[:record_id],
          preview: preview
        })
      end

      desc "Ejecutar la restauración de un registro eliminado"
      params do
        requires :record_type, type: String, desc: "Tipo de modelo"
        requires :record_id, type: Integer, desc: "ID del registro eliminado"
        optional :cascade_restore, type: Boolean, default: false, desc: "Restaurar en cascada"
        optional :selected_cascades, type: Array[String], desc: "Cascadas específicas a restaurar"
        optional :reassign_to, type: Hash, desc: "Reasignación de relaciones padre"
        optional :user_id, type: Integer, desc: "ID del usuario que ejecuta la acción"
      end
      post :restore do
        # Validar y obtener registro eliminado
        record = find_discarded_record(params[:record_type], params[:record_id])
        error!({ error: "Registro no encontrado o no está eliminado" }, 404) unless record

        # Obtener usuario si se especificó
        user = params[:user_id] ? find_user(params[:user_id]) : nil

        # Preparar opciones
        options = {
          cascade_restore: params[:cascade_restore],
          user: user
        }

        # Agregar selected_cascades si se especificó
        if params[:selected_cascades].present?
          options[:selected_cascades] = params[:selected_cascades].map(&:to_sym)
        end

        # Agregar reassign_to si se especificó
        if params[:reassign_to].present?
          options[:reassign_to] = symbolize_keys(params[:reassign_to])
        end

        # Crear coordinador con opciones
        coordinator = SoftDelete::RestorationCoordinator.new(record, options)

        # Ejecutar restauración
        result = coordinator.call

        if result[:success]
          # Respuesta exitosa
          present({
            success: true,
            record_type: params[:record_type],
            record_id: params[:record_id],
            message: result[:message],
            audit_log_id: result[:audit_log]&.id,
            restored_count: result[:restored_count],
            warnings: result[:warnings]
          })
        else
          # Error estructurado
          error!({
            success: false,
            errors: result[:errors],
            warnings: result[:warnings],
            message: result[:message],
            conflicts: result[:conflicts],
            required_decisions: result[:required_decisions],
            restoration_info: result[:restoration_info]
          }, 422)
        end
      end

      # ==========================================================================
      # LOGS DE AUDITORÍA
      # ==========================================================================

      desc "Obtener logs de auditoría"
      params do
        optional :record_type, type: String, desc: "Filtrar por tipo de modelo"
        optional :record_id, type: Integer, desc: "Filtrar por ID específico"
        optional :action, type: String, values: [ "delete", "restore" ], desc: "Filtrar por acción"
        optional :from_date, type: Date, desc: "Desde fecha"
        optional :to_date, type: Date, desc: "Hasta fecha"
        optional :page, type: Integer, default: 1, desc: "Página"
        optional :per_page, type: Integer, default: 25, desc: "Registros por página"
      end
      get :audit_logs do
        # Construir query base
        logs = SoftDeleteAuditLog.all

        # Filtrar por tipo de registro
        if params[:record_type].present?
          logs = logs.where(record_type: params[:record_type])
        end

        # Filtrar por ID específico
        if params[:record_id].present?
          logs = logs.where(record_id: params[:record_id])
        end

        # Filtrar por acción
        if params[:action].present?
          logs = if params[:action] == "delete"
                   logs.deletions
          else
                   logs.restorations
          end
        end

        # Filtrar por rango de fechas
        if params[:from_date] && params[:to_date]
          logs = logs.between_dates(params[:from_date], params[:to_date])
        end

        # Ordenar y paginar
        logs = logs.recent.page(params[:page]).per(params[:per_page])

        # Respuesta
        present({
          success: true,
          logs: logs.map { |log| format_audit_log(log) },
          pagination: {
            current_page: logs.current_page,
            total_pages: logs.total_pages,
            total_count: logs.total_count,
            per_page: params[:per_page]
          }
        })
      end

      desc "Obtener un log de auditoría específico"
      params do
        requires :id, type: Integer, desc: "ID del log"
      end
      route_param :id do
        get :audit_log do
          log = SoftDeleteAuditLog.find(params[:id])

          present({
            success: true,
            log: format_audit_log_detailed(log)
          })
        end
      end

      desc "Obtener estadísticas de soft delete"
      get :stats do
        stats = SoftDeleteAuditLog.deletion_stats

        present({
          success: true,
          stats: {
            total_deletions: stats[:total_deletions],
            total_restorations: stats[:total_restorations],
            by_model: stats[:by_model],
            cascade_impact: stats[:cascade_impact],
            nullify_impact: stats[:nullify_impact],
            massive_operations: stats[:massive_operations],
            restorable_count: stats[:restorable_count]
          }
        })
      end

      desc "Obtener estadísticas por modelo"
      params do
        requires :model, type: String, desc: "Nombre del modelo"
      end
      get :model_stats do
        model_class = constantize_model(params[:model])
        error!({ error: "Modelo no válido" }, 400) unless model_class

        stats = SoftDeleteAuditLog.stats_for_model(model_class)

        present({
          success: true,
          model: params[:model],
          stats: stats
        })
      end

      desc "Obtener registros pendientes de restauración"
      params do
        optional :model, type: String, desc: "Filtrar por modelo"
      end
      get :pending_restorations do
        logs = SoftDeleteAuditLog.pending_restorations

        # Filtrar por modelo si se especificó
        if params[:model].present?
          logs = logs.where(record_type: params[:model])
        end

        present({
          success: true,
          pending_count: logs.count,
          records: logs.limit(100).map { |log| format_pending_restoration(log) }
        })
      end

      # ==========================================================================
      # UTILIDADES
      # ==========================================================================

      desc "Verificar si un registro puede ser borrado"
      params do
        requires :record_type, type: String, desc: "Tipo de modelo"
        requires :record_id, type: Integer, desc: "ID del registro"
      end
      get :can_delete do
        record = find_record(params[:record_type], params[:record_id])
        error!({ error: "Registro no encontrado" }, 404) unless record

        can_delete = record.can_be_deleted?
        impact = record.deletion_impact

        present({
          success: true,
          can_delete: can_delete,
          requires_force: !can_delete && impact[:warnings].any?,
          blockers: impact[:blockers],
          recommendation: impact[:recommendation]
        })
      end

      desc "Verificar si un registro puede ser restaurado"
      params do
        requires :record_type, type: String, desc: "Tipo de modelo"
        requires :record_id, type: Integer, desc: "ID del registro eliminado"
      end
      get :can_restore do
        record = find_discarded_record(params[:record_type], params[:record_id])
        error!({ error: "Registro no encontrado o no está eliminado" }, 404) unless record

        can_restore = record.can_be_restored?
        info = record.restoration_info

        present({
          success: true,
          can_restore: can_restore,
          conflicts: info[:conflicts],
          recommendation: info[:recommendation]
        })
      end
    end

    helpers do
      # Encuentra un registro activo por tipo y ID
      def find_record(record_type, record_id)
        model_class = constantize_model(record_type)
        return nil unless model_class

        model_class.kept.find_by(id: record_id)
      end

      # Encuentra un registro eliminado por tipo y ID
      def find_discarded_record(record_type, record_id)
        model_class = constantize_model(record_type)
        return nil unless model_class

        model_class.discarded.find_by(id: record_id)
      end

      # Convierte string a clase de modelo
      def constantize_model(model_name)
        valid_models = %w[Company Vehicle VehicleKm Maintenance]
        return nil unless valid_models.include?(model_name)

        model_name.constantize
      rescue NameError
        nil
      end

      # Encuentra usuario (ajustar según tu sistema de autenticación)
      def find_user(user_id)
        # Ejemplo: User.find_by(id: user_id)
        # Por ahora retornamos un objeto genérico
        OpenStruct.new(id: user_id, class: OpenStruct.new(name: "User"))
      end

      # Convierte claves de hash a símbolos
      def symbolize_keys(hash)
        hash.transform_keys(&:to_sym)
      end

      # Formatea un log de auditoría (versión resumida)
      def format_audit_log(log)
        {
          id: log.id,
          record_type: log.record_type,
          record_id: log.record_id,
          action: log.action,
          performed_at: log.performed_at,
          cascade_count: log.cascade_count,
          nullify_count: log.nullify_count,
          can_restore: log.can_restore,
          restore_complexity: log.restore_complexity,
          performed_by: log.performed_by_description
        }
      end

      # Formatea un log de auditoría (versión detallada)
      def format_audit_log_detailed(log)
        {
          id: log.id,
          record_type: log.record_type,
          record_id: log.record_id,
          action: log.action,
          performed_at: log.performed_at,
          cascade_count: log.cascade_count,
          nullify_count: log.nullify_count,
          total_impact: log.total_impact,
          can_restore: log.can_restore,
          restore_complexity: log.restore_complexity,
          complexity_badge: log.complexity_badge,
          performed_by: log.performed_by_description,
          context: log.context,
          action_description: log.action_description,
          impact_description: log.impact_description,
          record_exists: log.record_exists?,
          record_discarded: log.record_discarded?,
          currently_restorable: log.currently_restorable?
        }
      end

      # Formatea registro pendiente de restauración
      def format_pending_restoration(log)
        {
          id: log.id,
          record_type: log.record_type,
          record_id: log.record_id,
          deleted_at: log.performed_at,
          cascade_count: log.cascade_count,
          restore_complexity: log.restore_complexity,
          context: log.context.slice("name", "matricula", "company_name") # Solo datos relevantes
        }
      end
    end
  end
end
