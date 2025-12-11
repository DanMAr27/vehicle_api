# db/migrate/XXXXXX_create_companies.rb
class CreateCompanies < ActiveRecord::Migration[7.0]
  def change
    create_table :companies do |t|
      t.string :name, null: false
      t.string :cif
      t.datetime :discarded_at
      t.integer :max_daily_km_tolerance
      t.timestamps
    end

    add_index :companies, :discarded_at
  end
end
