# db/migrate/XXXXXX_create_soft_delete_audit_logs.rb
class CreateSoftDeleteAuditLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :soft_delete_audit_logs do |t|
      t.references :record, polymorphic: true, null: false, index: true
      t.string :action, null: false, limit: 20 # Valores: 'delete' o 'restore'

      # ========================================
      # USUARIO QUE REALIZÓ LA ACCIÓN (opcional)
      # ========================================
      # Polimórfico para soportar diferentes tipos de usuario
      # (User, AdminUser, SystemUser, etc.)
      # Puede ser NULL si es una acción automática del sistema
      t.references :performed_by, polymorphic: true, null: true

      # ========================================
      # CONTEXTO DE LA OPERACIÓN
      # ========================================
      # JSON con información detallada del borrado/restauración
      # Ejemplos de contenido:
      # - Borrado Company:
      #   {
      #     company_name: "Acme Corp",
      #     cif: "B12345678",
      #     vehicles_count: 50,
      #     kms_count: 2500,
      #     maintenances_count: 300
      #   }
      # - Borrado VehicleKm:
      #   {
      #     vehicle_matricula: "1234ABC",
      #     input_date: "2024-01-15",
      #     km_reported: 45000,
      #     status: "corregido",
      #     from_maintenance: true
      #   }
      t.jsonb :context, default: {}, null: false
      t.integer :cascade_count, default: 0, null: false # Número de registros borrados en cascada
      t.integer :nullify_count, default: 0, null: false # Número de registros desvinculados (FK = NULL)
      t.boolean :can_restore, default: true, null: false # ¿Se puede restaurar este registro?

      # Complejidad de restauración: 'simple', 'medium', 'complex'
      # - simple: solo el registro principal (cascade_count = 0)
      # - medium: 1-9 registros en cascada
      # - complex: 10+ registros en cascada
      t.string :restore_complexity, limit: 20
      t.datetime :performed_at, null: false
      t.timestamps
    end
    # Índice para filtrar por acción (delete/restore)
    add_index :soft_delete_audit_logs, :action
    # Índice para consultas cronológicas
    add_index :soft_delete_audit_logs, :performed_at
    # Índice para filtrar registros restaurables
    add_index :soft_delete_audit_logs, :can_restore
    # Índice compuesto para búsquedas por tipo de registro y acción
    add_index :soft_delete_audit_logs,
              [ :record_type, :action, :performed_at ],
              name: 'index_audit_logs_on_record_type_action_date'
    # Índice compuesto para búsquedas por usuario
    add_index :soft_delete_audit_logs,
              [ :performed_by_type, :performed_by_id, :performed_at ],
              name: 'index_audit_logs_on_user_date'
    # Índice para operaciones masivas (impacto alto)
    add_index :soft_delete_audit_logs,
              :cascade_count,
              where: 'cascade_count > 10',
              name: 'index_audit_logs_on_high_cascade'
  end
end
