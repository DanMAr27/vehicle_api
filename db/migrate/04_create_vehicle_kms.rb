# db/migrate/XXXXXX_create_vehicle_kms.rb
class CreateVehicleKms < ActiveRecord::Migration[7.0]
  def change
    create_table :vehicle_kms do |t|
      t.date :input_date, null: false
      t.string :source, null: false # telemetria/mantenimiento/itv/manual/otro
      t.bigint :source_record_id
      t.integer :km_reported, null: false
      t.integer :km_normalized
      t.string :status, default: 'original' # original/estimado/editado
      t.text :correction_notes
      t.references :vehicle, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.bigint :discarded_by_id
      t.datetime :discarded_at
      t.timestamps
    end

    add_index :vehicle_kms, [ :vehicle_id, :input_date ]
    add_index :vehicle_kms, [ :source, :source_record_id ]
    add_index :vehicle_kms, :status
    add_index :vehicle_kms, :discarded_at
  end
end
