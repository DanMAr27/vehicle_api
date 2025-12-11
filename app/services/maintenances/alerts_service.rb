# app/services/maintenances/alerts_service.rb
module Maintenances
  class AlertsService
    attr_reader :maintenances, :results

    def initialize(vehicle_id: nil, alert_type: nil)
      @vehicle_id = vehicle_id
      @alert_type = alert_type
      @results = []
    end

    def call
      load_maintenances
      build_results
      filter_by_alert_type if @alert_type.present?

      {
        success: true,
        total: @maintenances.count,
        with_issues: @results.count { |r| r[:has_issues] },
        maintenances: @results
      }
    end

    private

    def load_maintenances
      @maintenances = Maintenance.kept.includes(:vehicle_km)
      @maintenances = @maintenances.where(vehicle_id: @vehicle_id) if @vehicle_id
    end

    def build_results
      @results = @maintenances.map do |maintenance|
        {
          maintenance_id: maintenance.id,
          vehicle_id: maintenance.vehicle_id,
          maintenance_date: maintenance.maintenance_date,
          km_status: maintenance.km_status,
          is_conflictive: maintenance.km_conflictive?,
          is_desynchronized: maintenance.km_desynchronized?,
          has_issues: has_issues?(maintenance)
        }
      end
    end

    def has_issues?(maintenance)
      maintenance.km_status != "activo" ||
        maintenance.km_desynchronized? ||
        maintenance.km_conflictive?
    end

    def filter_by_alert_type
      @results = @results.select do |result|
        case @alert_type
        when "eliminado"
          result[:km_status] == "eliminado"
        when "sin_registro"
          result[:km_status] == "sin_registro"
        when "desincronizado"
          result[:is_desynchronized]
        when "conflictivo"
          result[:is_conflictive]
        else
          true
        end
      end
    end
  end
end
