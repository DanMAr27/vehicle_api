# app/api/entities/conflictives_report_entity.rb
module Entities
  class ConflictivesReportEntity < Grape::Entity
    expose :vehicle_id
    expose :vehicle_info do |record, options|
      {
        matricula: record[:vehicle_matricula],
        vin: record[:vehicle_vin]
      }
    end
    expose :total_records
    expose :conflictive_count
    expose :conflictive_percentage do |record|
      total = record[:total_records].to_f
      total > 0 ? ((record[:conflictive_count].to_f / total) * 100).round(2) : 0
    end
    expose :oldest_conflict_date
    expose :newest_conflict_date

    # Lista de conflictos si se solicita detalle
    expose :conflicts, if: { include_details: true }, using: Entities::VehicleKmEntity
  end
end
