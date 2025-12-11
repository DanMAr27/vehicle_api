# db/migrate/XXXXXX_create_vehicle_kms.rb
class CreateVehicleKms < ActiveRecord::Migration[7.0]
  def change
    create_table :vehicle_kms do |t|
      t.date :input_date, null: false
      t.references :source_record, polymorphic: true, null: true
      t.integer :km_reported, null: false
      t.integer :km_normalized
      t.string :status, default: 'original', null: false # original/estimado/editado
      t.text :correction_notes
      t.text :conflict_reasons # JSON array de razones del conflicto
      t.references :vehicle, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.datetime :discarded_at
      t.timestamps
    end

    add_index :vehicle_kms, [ :vehicle_id, :input_date ]
    add_index :vehicle_kms, [ :source_record_type, :source_record_id ]
    add_index :vehicle_kms, :status
    add_index :vehicle_kms, :discarded_at
  end
end
