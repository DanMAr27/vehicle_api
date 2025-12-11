# db/migrate/XXXXXX_create_maintenances.rb
class CreateMaintenances < ActiveRecord::Migration[7.0]
  def change
    create_table :maintenances do |t|
      t.date :maintenance_date, null: false
      t.integer :register_km, null: false
      t.decimal :amount, precision: 10, scale: 2
      t.text :description
      t.references :vehicle, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.references :vehicle_km, foreign_key: true # Relación con el registro KM
      t.datetime :discarded_at
      t.timestamps
    end

    add_index :maintenances, :maintenance_date
    add_index :maintenances, :discarded_at
  end
end
