# db/migrate/XXXXXX_create_soft_delete_audit_logs.rb
class CreateSoftDeleteAuditLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :soft_delete_audit_logs do |t|
      t.references :record, polymorphic: true, null: false, index: true
      t.string :action, null: false, limit: 20 # Valores: 'delete' o 'restore'
      t.references :performed_by, polymorphic: true, null: true
      t.jsonb :context, default: {}, null: false
      t.integer :cascade_count, default: 0, null: false # Número de registros borrados en cascada
      t.integer :nullify_count, default: 0, null: false # Número de registros desvinculados (FK = NULL)
      t.boolean :can_restore, default: true, null: false # ¿Se puede restaurar este registro?
      t.string :restore_complexity, limit: 20       # Complejidad de restauración: 'simple', 'medium', 'complex'
      t.datetime :performed_at, null: false
      t.timestamps
    end
    add_index :soft_delete_audit_logs, :action
     add_index :soft_delete_audit_logs, :performed_at
    add_index :soft_delete_audit_logs, :can_restore
    add_index :soft_delete_audit_logs,
              [ :record_type, :action, :performed_at ],
              name: 'index_audit_logs_on_record_type_action_date'
    add_index :soft_delete_audit_logs,
              [ :performed_by_type, :performed_by_id, :performed_at ],
              name: 'index_audit_logs_on_user_date'
    add_index :soft_delete_audit_logs,
              :cascade_count,
              where: 'cascade_count > 10',
              name: 'index_audit_logs_on_high_cascade'
  end
end
