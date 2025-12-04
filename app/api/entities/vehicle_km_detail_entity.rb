# app/api/entities/vehicle_km_detail_entity.rb
module Entities
  class VehicleKmDetailEntity < VehicleKmEntity
    expose :correlation_info do |vehicle_km, options|
      checker = VehicleKms::CorrelationCheckService.new(vehicle_km)
      result = checker.call

      {
        has_conflict: result[:has_conflict],
        conflicts: result[:conflicts],
        previous_km: result[:previous_record]&.effective_km,
        next_km: result[:next_record]&.effective_km
      }
    end

    expose :version_history do |vehicle_km, options|
      vehicle_km.versions.map do |v|
        {
          event: v.event,
          created_at: v.created_at,
          changes: v.changeset
        }
      end
    end
  end
end
