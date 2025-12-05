# db/migrate/XXXXXX_add_confidence_and_adjust_status_to_vehicle_kms.rb
class AddConfidenceAndAdjustStatusToVehicleKms < ActiveRecord::Migration[7.0]
  def change
    add_column :vehicle_kms, :confidence_level, :string
    add_column :vehicle_kms, :conflict_reasons, :text # JSON array de razones del conflicto

    add_index :vehicle_kms, :confidence_level
  end
end
