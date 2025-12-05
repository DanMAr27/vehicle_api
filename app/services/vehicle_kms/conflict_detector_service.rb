# app/services/vehicle_kms/conflict_detector_service.rb
#
# Detección de conflictos basada en MONOTONICIDAD ESTRICTA
# PASO 1: Detecta SI hay conflicto (prev/new/next)
# PASO 2: Determina QUIÉN está mal (ventana con reglas de monotonicidad)
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
        # PASO 2: Diagnóstico por monotonicidad en ventana
        diagnosis = diagnose_monotonicity_breaks(prev_record, next_record)

        {
          has_conflict: true,
          current_is_conflictive: diagnosis[:conflictive_ids].include?(@vehicle_km.id),
          conflictive_records: diagnosis[:conflictive_records],
          valid_records: diagnosis[:valid_ids]
        }
      else
        # No hay conflicto inmediato
        {
          has_conflict: false,
          current_is_conflictive: false,
          conflictive_records: [],
          valid_records: [ @vehicle_km.id ]
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
    # PASO 2: DIAGNÓSTICO POR MONOTONICIDAD
    # Basado en: "km SIEMPRE debe subir"
    # Solo marca conflictivos los que ROMPEN monotonicidad
    # ============================================================

    def diagnose_monotonicity_breaks(prev_record, next_record)
      # Obtener ventana ampliada
      window = build_extended_window
      ordered_window = window.sort_by { |r| [ r.input_date, r.id ] }

      # Encontrar todos los puntos donde se rompe la monotonicidad
      monotonicity_breaks = find_monotonicity_breaks(ordered_window)

      # Determinar quién es conflictivo en cada ruptura
      conflictive_ids = Set.new

      monotonicity_breaks.each do |break_info|
        culprit_id = determine_culprit(break_info, ordered_window)
        conflictive_ids.add(culprit_id)
      end

      # Todos los demás son válidos
      valid_ids = ordered_window.map(&:id) - conflictive_ids.to_a

      # Construir detalles de conflictos
      conflictive_records = build_conflict_details(conflictive_ids.to_a, ordered_window)

      {
        conflictive_ids: conflictive_ids.to_a,
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

    def find_monotonicity_breaks(ordered_window)
      breaks = []

      ordered_window.each_cons(2).with_index do |(r1, r2), index|
        # Si el KM baja, hay ruptura de monotonicidad
        if r2.km_reported < r1.km_reported
          breaks << {
            index: index,
            prev_record: r1,
            current_record: r2,
            prev_index: index,
            current_index: index + 1
          }
        end
      end

      breaks
    end

    def determine_culprit(break_info, ordered_window)
      prev_record = break_info[:prev_record]
      current_record = break_info[:current_record]
      prev_index = break_info[:prev_index]
      current_index = break_info[:current_index]

      # REGLA A: Distancia a vecinos
      # Si el salto es mucho más grande que el histórico, el nuevo es el culpable

      # Obtener el anterior al prev (si existe)
      prev_prev_record = prev_index > 0 ? ordered_window[prev_index - 1] : nil

      # Obtener el siguiente al current (si existe)
      next_record = current_index < ordered_window.length - 1 ? ordered_window[current_index + 1] : nil

      # Distancia del salto conflictivo
      conflict_distance = (prev_record.km_reported - current_record.km_reported).abs

      # Distancia histórica (prev_prev -> prev)
      historical_distance = if prev_prev_record
        (prev_record.km_reported - prev_prev_record.km_reported).abs
      else
        nil
      end

      # REGLA A: Comparar distancias
      if historical_distance && conflict_distance > historical_distance * 2
        # El salto es mucho más grande → el current es el conflictivo
        return current_record.id
      end

      # REGLA B: Consistencia del salto directo
      # Si hay un registro siguiente, verificar si el salto prev->next es coherente
      if next_record
        # Salto directo prev -> next (ignorando current)
        direct_jump = next_record.km_reported - prev_record.km_reported

        # Si el salto directo es positivo (creciente)
        if direct_jump > 0
          # Verificar cuál de los dos mantiene mejor la monotonicidad global

          # Opción 1: eliminar prev_record
          # ¿current -> next es creciente?
          option1_valid = current_record.km_reported <= next_record.km_reported

          # Opción 2: eliminar current_record
          # prev -> next ya sabemos que es creciente (direct_jump > 0)
          option2_valid = true

          # Si eliminar current mantiene monotonicidad pero eliminar prev no
          if option2_valid && !option1_valid
            return current_record.id
          end

          # Si ambas opciones son válidas o ambas inválidas,
          # preferir mantener el histórico (eliminar current)
          if option1_valid && option2_valid
            return current_record.id
          end

          # Si solo eliminar prev funciona
          if option1_valid && !option2_valid
            return prev_record.id
          end
        else
          # El salto directo también es negativo
          # Esto indica que hay más conflictos encadenados
          # En este caso, marcar el current como conflictivo
          return current_record.id
        end
      end

      # REGLA C: Default - si hay duda, el nuevo registro es el conflictivo
      # (principio de conservar datos históricos)
      if current_record.id == @vehicle_km.id
        return current_record.id
      end

      # Si el conflicto no involucra al nuevo registro,
      # necesitamos más información. Por defecto, marcar el que rompe hacia abajo
      current_record.id
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
          reasons << "Rompe la monotonicidad de la secuencia de kilometraje"
        end

        {
          record_id: record.id,
          date: record.input_date,
          km: record.km_reported,
          reasons: reasons
        }
      end.compact
    end
  end
end
