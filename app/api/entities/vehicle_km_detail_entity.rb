# app/api/entities/vehicle_km_detail_entity.rb
module Entities
  class VehicleKmDetailEntity < VehicleKmEntity
    # Información de correlación detallada
    expose :correlation_info do |vehicle_km, options|
      checker = VehicleKms::CorrelationCheckService.new(vehicle_km)
      result = checker.call

      {
        has_conflict: result[:has_conflict],
        conflicts: result[:conflicts],
        previous_record: result[:previous_record] ? {
          id: result[:previous_record].id,
          input_date: result[:previous_record].input_date,
          effective_km: result[:previous_record].effective_km,
          status: result[:previous_record].status
        } : nil,
        next_record: result[:next_record] ? {
          id: result[:next_record].id,
          input_date: result[:next_record].input_date,
          effective_km: result[:next_record].effective_km,
          status: result[:next_record].status
        } : nil
      }
    end

    # Información de confianza (si es estimado)
    expose :confidence_info, if: ->(vehicle_km, _) { vehicle_km.status == "estimado" } do |vehicle_km|
      calculator = VehicleKms::ConfidenceCalculatorService.new(vehicle_km)
      calculator.call
    end

    # Comparación entre KM reportado y normalizado
    expose :correction_summary, if: ->(vehicle_km, _) { vehicle_km.status == "estimado" } do |vehicle_km|
      {
        original_km: vehicle_km.km_reported,
        corrected_km: vehicle_km.km_normalized,
        difference: vehicle_km.km_normalized - vehicle_km.km_reported,
        difference_percentage: vehicle_km.km_reported > 0 ?
          (((vehicle_km.km_normalized - vehicle_km.km_reported).to_f / vehicle_km.km_reported) * 100).round(2) :
          0
      }
    end

    # Historial de versiones (si existe PaperTrail)
    expose :version_history, if: ->(vehicle_km, _) { vehicle_km.respond_to?(:versions) } do |vehicle_km|
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
