# db/migrate/XXXXXX_create_vehicles.rb
class CreateVehicles < ActiveRecord::Migration[7.0]
  def change
    create_table :vehicles do |t|
      t.string :matricula, null: false
      t.string :vin
      t.integer :current_km, default: 0
      t.references :company, null: false, foreign_key: true
      t.datetime :discarded_at
      t.timestamps
    end

    add_index :vehicles, :matricula
    add_index :vehicles, :vin
    add_index :vehicles, :discarded_at
  end
end
