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

ActiveRecord::Schema[8.0].define(version: 5) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "companies", force: :cascade do |t|
    t.string "name", null: false
    t.string "cif"
    t.datetime "discarded_at"
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

  create_table "vehicle_kms", force: :cascade do |t|
    t.date "input_date", null: false
    t.string "source", null: false
    t.bigint "source_record_id"
    t.integer "km_reported", null: false
    t.integer "km_normalized"
    t.string "status", default: "original"
    t.text "correction_notes"
    t.bigint "vehicle_id", null: false
    t.bigint "company_id", null: false
    t.bigint "discarded_by_id"
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_vehicle_kms_on_company_id"
    t.index ["discarded_at"], name: "index_vehicle_kms_on_discarded_at"
    t.index ["source", "source_record_id"], name: "index_vehicle_kms_on_source_and_source_record_id"
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
