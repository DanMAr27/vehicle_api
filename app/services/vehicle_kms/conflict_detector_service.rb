# app/services/vehicle_kms/conflict_detector_service.rb
#
# Detección de conflictos basada en SUBSECUENCIA CRECIENTE MÁS LARGA
# PASO 1: Detecta SI hay conflicto (prev/new/next)
# PASO 2: Encuentra la secuencia creciente más larga y marca el resto como conflictivos
#
module VehicleKms
  class ConflictDetectorService
    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @vehicle = vehicle_km.vehicle
    end

    def call
      # PASO 1: Validación mínima con vecinos inmediatos
      prev_record = find_immediate_previous
      next_record = find_immediate_next

      has_immediate_conflict = detect_immediate_conflict(prev_record, next_record)

      if has_immediate_conflict
        # PASO 2: Encontrar subsecuencia creciente más larga
        diagnosis = find_longest_increasing_subsequence

        {
          has_conflict: true,
          current_is_conflictive: diagnosis[:conflictive_ids].include?(@vehicle_km.id),
          conflictive_records: diagnosis[:conflictive_records],
          valid_records: diagnosis[:valid_ids]
        }
      else
        # No hay conflicto inmediato, pero igual debemos verificar la ventana
        # por si el nuevo registro resuelve conflictos previos
        diagnosis = find_longest_increasing_subsequence

        {
          has_conflict: diagnosis[:conflictive_ids].any?,
          current_is_conflictive: diagnosis[:conflictive_ids].include?(@vehicle_km.id),
          conflictive_records: diagnosis[:conflictive_records],
          valid_records: diagnosis[:valid_ids]
        }
      end
    end

    private

    # ============================================================
    # PASO 1: VALIDACIÓN MÍNIMA (prev/new/next)
    # ============================================================

    def find_immediate_previous
      VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where("input_date < ? OR (input_date = ? AND id < ?)",
               @vehicle_km.input_date,
               @vehicle_km.input_date,
               @vehicle_km.id)
        .order(input_date: :desc, id: :desc)
        .first
    end

    def find_immediate_next
      VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where("input_date > ? OR (input_date = ? AND id > ?)",
               @vehicle_km.input_date,
               @vehicle_km.input_date,
               @vehicle_km.id)
        .order(input_date: :asc, id: :asc)
        .first
    end

    def detect_immediate_conflict(prev_record, next_record)
      current_km = @vehicle_km.km_reported

      # Solo existe prev
      if prev_record && !next_record
        return current_km < prev_record.km_reported
      end

      # Solo existe next
      if !prev_record && next_record
        return current_km > next_record.km_reported
      end

      # Existen ambos
      if prev_record && next_record
        prev_km = prev_record.km_reported
        next_km = next_record.km_reported

        # Debe estar entre ambos
        return !(prev_km <= current_km && current_km <= next_km)
      end

      # No hay vecinos, no puede haber conflicto
      false
    end

    # ============================================================
    # PASO 2: SUBSECUENCIA CRECIENTE MÁS LARGA (LIS)
    # Esta es la estrategia correcta para odómetros
    # ============================================================

    def find_longest_increasing_subsequence
      # Obtener ventana ampliada
      window = build_extended_window
      ordered_window = window.sort_by { |r| [ r.input_date, r.id ] }

      return empty_result if ordered_window.empty?

      # Encontrar la LIS (Longest Increasing Subsequence)
      valid_ids = calculate_lis(ordered_window)

      # Todos los que NO están en la LIS son conflictivos
      conflictive_ids = ordered_window.map(&:id) - valid_ids

      # Construir detalles
      conflictive_records = build_conflict_details(conflictive_ids, ordered_window)

      {
        conflictive_ids: conflictive_ids,
        valid_ids: valid_ids,
        conflictive_records: conflictive_records
      }
    end

    def build_extended_window
      # Hasta 5 registros antes
      previous_records = VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where("input_date < ? OR (input_date = ? AND id < ?)",
               @vehicle_km.input_date,
               @vehicle_km.input_date,
               @vehicle_km.id)
        .order(input_date: :desc, id: :desc)
        .limit(5)
        .to_a

      # Hasta 5 registros después
      next_records = VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where("input_date > ? OR (input_date = ? AND id > ?)",
               @vehicle_km.input_date,
               @vehicle_km.input_date,
               @vehicle_km.id)
        .order(input_date: :asc, id: :asc)
        .limit(5)
        .to_a

      (previous_records + [ @vehicle_km ] + next_records).uniq
    end

    def calculate_lis(ordered_records)
      # Algoritmo de programación dinámica para LIS
      # pero adaptado para odómetros (secuencia NO estrictamente creciente, permite iguales)

      n = ordered_records.size
      return [] if n == 0

      # dp[i] = longitud de la secuencia creciente más larga que termina en i
      dp = Array.new(n, 1)

      # parent[i] = índice del elemento anterior en la LIS que termina en i
      parent = Array.new(n, -1)

      # Llenar la tabla dp
      (1...n).each do |i|
        (0...i).each do |j|
          # El KM debe ser >= (permite iguales)
          if ordered_records[i].km_reported >= ordered_records[j].km_reported
            if dp[j] + 1 > dp[i]
              dp[i] = dp[j] + 1
              parent[i] = j
            end
          end
        end
      end

      # Encontrar el índice con la secuencia más larga
      max_length = dp.max

      # Si hay múltiples secuencias de igual longitud, usar criterio de desempate
      max_indices = dp.each_with_index.select { |len, _| len == max_length }.map(&:last)

      if max_indices.size > 1
        # CRITERIO DE DESEMPATE:
        # Preferir la secuencia que minimiza "saltos" en fechas consecutivas
        # Es decir, la que tiene más registros consecutivos por fecha
        max_index = choose_best_sequence(max_indices, ordered_records, parent)
      else
        max_index = max_indices.first
      end

      # Reconstruir la secuencia desde max_index hacia atrás
      sequence_indices = []
      current = max_index

      while current != -1
        sequence_indices.unshift(current)
        current = parent[current]
      end

      # Retornar los IDs de la secuencia válida
      sequence_indices.map { |idx| ordered_records[idx].id }
    end

    def choose_best_sequence(candidate_indices, ordered_records, parent)
      # Para cada candidato, reconstruir su secuencia y calcular "calidad"
      best_index = nil
      best_score = -Float::INFINITY

      candidate_indices.each do |end_index|
        sequence = reconstruct_sequence(end_index, parent)
        score = calculate_sequence_quality(sequence, ordered_records)

        if score > best_score
          best_score = score
          best_index = end_index
        end
      end

      best_index
    end

    def reconstruct_sequence(end_index, parent)
      sequence = []
      current = end_index

      while current != -1
        sequence.unshift(current)
        current = parent[current]
      end

      sequence
    end

    def calculate_sequence_quality(sequence_indices, ordered_records)
      # Criterios de calidad (en orden de importancia):
      # 1. Si incluye el registro NUEVO (máxima prioridad - queremos validarlo si es posible)
      # 2. Número de registros consecutivos por fecha (menos saltos = mejor)
      # 3. Uniformidad de incrementos

      score = 0

      # Criterio 1: PRIORIDAD MÁXIMA - incluir el nuevo registro
      # Si el nuevo registro puede formar parte de una secuencia válida, debe estarlo
      includes_new = sequence_indices.any? { |idx| ordered_records[idx].id == @vehicle_km.id }
      if includes_new
        score += 100  # Peso muy alto
      end

      # Criterio 2: Penalizar saltos en fechas
      date_gaps = 0
      sequence_indices.each_cons(2) do |i, j|
        # Contar cuántos registros saltamos entre i y j
        skipped = j - i - 1
        date_gaps += skipped
      end

      # Menos saltos = mejor
      score += (date_gaps * -10)

      # Criterio 3: Penalizar incrementos muy grandes (outliers históricos)
      sequence_indices.each_cons(2) do |i, j|
        km_diff = ordered_records[j].km_reported - ordered_records[i].km_reported
        days_diff = (ordered_records[j].input_date - ordered_records[i].input_date).to_i

        if days_diff > 0
          daily_rate = km_diff.to_f / days_diff

          # Penalizar incrementos > 300 km/día (probablemente errores)
          if daily_rate > 300
            score -= 3
          end
        end
      end

      score
    end

    def build_conflict_details(conflictive_ids, ordered_window)
      conflictive_ids.map do |record_id|
        record = ordered_window.find { |r| r.id == record_id }
        next unless record

        index = ordered_window.index(record)
        prev_rec = index > 0 ? ordered_window[index - 1] : nil
        next_rec = index < ordered_window.length - 1 ? ordered_window[index + 1] : nil

        reasons = []

        if prev_rec && record.km_reported < prev_rec.km_reported
          reasons << "KM inferior al registro anterior (#{prev_rec.km_reported} km el #{prev_rec.input_date.strftime('%d/%m/%Y')})"
        end

        if next_rec && record.km_reported > next_rec.km_reported
          reasons << "KM superior al registro posterior (#{next_rec.km_reported} km el #{next_rec.input_date.strftime('%d/%m/%Y')})"
        end

        if reasons.empty?
          reasons << "No forma parte de la secuencia creciente más coherente"
        end

        {
          record_id: record.id,
          date: record.input_date,
          km: record.km_reported,
          reasons: reasons
        }
      end.compact
    end

    def empty_result
      {
        conflictive_ids: [],
        valid_ids: [],
        conflictive_records: []
      }
    end
  end
end
