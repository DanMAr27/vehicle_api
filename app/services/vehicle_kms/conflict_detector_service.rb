# app/services/vehicle_kms/conflict_detector_service.rb
#
# Servicio para detectar registros conflictivos en una ventana local
# Evalúa TODOS los registros en la ventana, no solo el actual
#
module VehicleKms
  class ConflictDetectorService
    WINDOW_SIZE = 3

    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @vehicle = vehicle_km.vehicle
    end

    def call
      # 1. Construir ventana local
      window = build_window

      # 2. Ordenar por fecha e ID
      ordered_window = sort_window(window)

      # 3. Encontrar secuencia válida (ascendente más larga)
      valid_ids = find_valid_ascending_sequence(ordered_window)

      # 4. Clasificar TODOS los registros de la ventana
      conflicts_by_id = classify_all_records(ordered_window, valid_ids)

      {
        current_is_conflictive: !valid_ids.include?(@vehicle_km.id),
        valid_sequence_ids: valid_ids,
        conflicts_by_id: conflicts_by_id,
        window_records: ordered_window
      }
    end

    private

    def build_window
      previous_records = VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where("input_date < ? OR (input_date = ? AND id < ?)",
               @vehicle_km.input_date,
               @vehicle_km.input_date,
               @vehicle_km.id)
        .order(input_date: :desc, id: :desc)
        .limit(WINDOW_SIZE)
        .to_a

      next_records = VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where("input_date > ? OR (input_date = ? AND id > ?)",
               @vehicle_km.input_date,
               @vehicle_km.input_date,
               @vehicle_km.id)
        .order(input_date: :asc, id: :asc)
        .limit(WINDOW_SIZE)
        .to_a

      (previous_records + [ @vehicle_km ] + next_records).uniq
    end

    def sort_window(window)
      window.sort_by { |record| [ record.input_date, record.id ] }
    end

    def find_valid_ascending_sequence(ordered_records)
      # Algoritmo de subsecuencia creciente más larga (LIS - Longest Increasing Subsequence)
      # pero adaptado para mantener coherencia temporal

      return [] if ordered_records.empty?

      # Usamos programación dinámica simple
      n = ordered_records.size
      dp = Array.new(n, 1)  # longitud de secuencia que termina en i
      parent = Array.new(n, -1)  # para reconstruir la secuencia

      ordered_records.each_with_index do |current, i|
        (0...i).each do |j|
          prev = ordered_records[j]

          # Solo consideramos si el KM es creciente
          if current.km_reported >= prev.km_reported && dp[j] + 1 > dp[i]
            dp[i] = dp[j] + 1
            parent[i] = j
          end
        end
      end

      # Encontrar el índice con la secuencia más larga
      max_length = dp.max
      max_index = dp.index(max_length)

      # Reconstruir la secuencia
      sequence_indices = []
      current_index = max_index

      while current_index != -1
        sequence_indices.unshift(current_index)
        current_index = parent[current_index]
      end

      sequence_indices.map { |i| ordered_records[i].id }
    end

    def classify_all_records(ordered_window, valid_ids)
      conflicts = {}

      ordered_window.each_with_index do |record, index|
        is_valid = valid_ids.include?(record.id)

        conflicts[record.id] = {
          is_conflictive: !is_valid,
          reasons: is_valid ? [] : build_conflict_reasons_for(record, index, ordered_window)
        }
      end

      conflicts
    end

    def build_conflict_reasons_for(record, index, ordered_window)
      reasons = []

      # Buscar registro anterior en la ventana
      prev_record = index > 0 ? ordered_window[index - 1] : nil

      # Buscar registro posterior en la ventana
      next_record = index < ordered_window.length - 1 ? ordered_window[index + 1] : nil

      if prev_record && record.km_reported < prev_record.km_reported
        reasons << "KM inferior al registro anterior (#{prev_record.km_reported} km el #{prev_record.input_date.strftime('%d/%m/%Y')})"
      end

      if next_record && record.km_reported > next_record.km_reported
        reasons << "KM superior al registro posterior (#{next_record.km_reported} km el #{next_record.input_date.strftime('%d/%m/%Y')})"
      end

      # Si no tiene razones específicas pero está fuera de la secuencia válida
      if reasons.empty?
        reasons << "Registro inconsistente con la secuencia general de kilometraje"
      end

      reasons
    end
  end
end
