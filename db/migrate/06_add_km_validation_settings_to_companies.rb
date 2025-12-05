# db/migrate/XXXXXX_add_km_validation_settings_to_companies.rb
class AddKmValidationSettingsToCompanies < ActiveRecord::Migration[7.0]
  def change
    add_column :companies, :max_daily_km_tolerance, :integer, default: nil
    add_column :companies, :auto_correction_enabled, :boolean, default: true
    add_column :companies, :min_neighbors_for_correction, :integer, default: 5
  end
end
