# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 6) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "companies", force: :cascade do |t|
    t.string "name", null: false
    t.string "cif"
    t.datetime "discarded_at"
    t.integer "max_daily_km_tolerance"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["discarded_at"], name: "index_companies_on_discarded_at"
  end

  create_table "maintenances", force: :cascade do |t|
    t.date "maintenance_date", null: false
    t.integer "register_km", null: false
    t.decimal "amount", precision: 10, scale: 2
    t.text "description"
    t.bigint "vehicle_id", null: false
    t.bigint "company_id", null: false
    t.bigint "vehicle_km_id"
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_maintenances_on_company_id"
    t.index ["discarded_at"], name: "index_maintenances_on_discarded_at"
    t.index ["maintenance_date"], name: "index_maintenances_on_maintenance_date"
    t.index ["vehicle_id"], name: "index_maintenances_on_vehicle_id"
    t.index ["vehicle_km_id"], name: "index_maintenances_on_vehicle_km_id"
  end

  create_table "soft_delete_audit_logs", force: :cascade do |t|
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.string "action", limit: 20, null: false
    t.string "performed_by_type"
    t.bigint "performed_by_id"
    t.jsonb "context", default: {}, null: false
    t.integer "cascade_count", default: 0, null: false
    t.integer "nullify_count", default: 0, null: false
    t.boolean "can_restore", default: true, null: false
    t.string "restore_complexity", limit: 20
    t.datetime "performed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_soft_delete_audit_logs_on_action"
    t.index ["can_restore"], name: "index_soft_delete_audit_logs_on_can_restore"
    t.index ["cascade_count"], name: "index_audit_logs_on_high_cascade", where: "(cascade_count > 10)"
    t.index ["performed_at"], name: "index_soft_delete_audit_logs_on_performed_at"
    t.index ["performed_by_type", "performed_by_id", "performed_at"], name: "index_audit_logs_on_user_date"
    t.index ["performed_by_type", "performed_by_id"], name: "index_soft_delete_audit_logs_on_performed_by"
    t.index ["record_type", "action", "performed_at"], name: "index_audit_logs_on_record_type_action_date"
    t.index ["record_type", "record_id"], name: "index_soft_delete_audit_logs_on_record"
  end

  create_table "vehicle_kms", force: :cascade do |t|
    t.date "input_date", null: false
    t.string "source_record_type"
    t.bigint "source_record_id"
    t.integer "km_reported", null: false
    t.integer "km_normalized"
    t.string "status", default: "original", null: false
    t.text "correction_notes"
    t.text "conflict_reasons"
    t.bigint "vehicle_id", null: false
    t.bigint "company_id", null: false
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_vehicle_kms_on_company_id"
    t.index ["discarded_at"], name: "index_vehicle_kms_on_discarded_at"
    t.index ["source_record_type", "source_record_id"], name: "index_vehicle_kms_on_source_record"
    t.index ["source_record_type", "source_record_id"], name: "index_vehicle_kms_on_source_record_type_and_source_record_id"
    t.index ["status"], name: "index_vehicle_kms_on_status"
    t.index ["vehicle_id", "input_date"], name: "index_vehicle_kms_on_vehicle_id_and_input_date"
    t.index ["vehicle_id"], name: "index_vehicle_kms_on_vehicle_id"
  end

  create_table "vehicles", force: :cascade do |t|
    t.string "matricula", null: false
    t.string "vin"
    t.integer "current_km", default: 0
    t.bigint "company_id", null: false
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_vehicles_on_company_id"
    t.index ["discarded_at"], name: "index_vehicles_on_discarded_at"
    t.index ["matricula"], name: "index_vehicles_on_matricula"
    t.index ["vin"], name: "index_vehicles_on_vin"
  end

  create_table "versions", force: :cascade do |t|
    t.string "whodunnit"
    t.datetime "created_at"
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.string "event", null: false
    t.text "object"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  add_foreign_key "maintenances", "companies"
  add_foreign_key "maintenances", "vehicle_kms"
  add_foreign_key "maintenances", "vehicles"
  add_foreign_key "vehicle_kms", "companies"
  add_foreign_key "vehicle_kms", "vehicles"
  add_foreign_key "vehicles", "companies"
end
