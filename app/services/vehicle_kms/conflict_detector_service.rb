# app/services/vehicle_kms/conflict_detector_service.rb
#
# Servicio para detectar si un registro de KM es conflictivo
# basándose en una ventana local de registros vecinos
#
module VehicleKms
  class ConflictDetectorService
    # Tamaño de la ventana: cuántos registros mirar antes y después
    WINDOW_SIZE = 3

    def initialize(vehicle_km)
      @vehicle_km = vehicle_km
      @vehicle = vehicle_km.vehicle
    end

    def call
      # 1. Construir ventana local de registros vecinos
      window = build_window

      # 2. Ordenar por fecha (y por ID si es misma fecha)
      ordered_window = sort_window(window)

      # 3. Encontrar la secuencia válida (ascendente)
      valid_ids = find_valid_ascending_sequence(ordered_window)

      # 4. Determinar si el registro actual es conflictivo
      is_conflictive = !valid_ids.include?(@vehicle_km.id)

      # 5. Construir resultado detallado
      {
        is_conflictive: is_conflictive,
        valid_sequence_ids: valid_ids,
        window_records: ordered_window,
        conflict_reasons: is_conflictive ? build_conflict_reasons : []
      }
    end

    private

    def build_window
      # Registros anteriores al actual
      previous_records = VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where("input_date < ? OR (input_date = ? AND id < ?)",
               @vehicle_km.input_date,
               @vehicle_km.input_date,
               @vehicle_km.id)
        .order(input_date: :desc, id: :desc)
        .limit(WINDOW_SIZE)
        .to_a

      # Registros posteriores al actual
      next_records = VehicleKm.kept
        .where(vehicle_id: @vehicle.id)
        .where("input_date > ? OR (input_date = ? AND id > ?)",
               @vehicle_km.input_date,
               @vehicle_km.input_date,
               @vehicle_km.id)
        .order(input_date: :asc, id: :asc)
        .limit(WINDOW_SIZE)
        .to_a

      # Combinar: anteriores + actual + posteriores
      (previous_records + [ @vehicle_km ] + next_records).uniq
    end

    def sort_window(window)
      # Ordenar por fecha ascendente, y por ID si es misma fecha
      window.sort_by { |record| [ record.input_date, record.id ] }
    end

    def find_valid_ascending_sequence(ordered_records)
      # Lógica clave: mantener la secuencia ascendente más larga
      # Los registros que no encajan son conflictivos

      valid_sequence = []

      ordered_records.each do |record|
        if valid_sequence.empty?
          # Primer registro siempre se agrega
          valid_sequence << record
          next
        end

        last_valid = valid_sequence.last
        current_km = record.km_reported
        last_km = last_valid.km_reported

        if current_km >= last_km
          # El KM sube o se mantiene: registro válido
          valid_sequence << record
        else
          # El KM baja: hay un conflicto
          # Decidir si mantenemos el último válido o lo reemplazamos

          if should_replace_last_with_current?(valid_sequence, record)
            # El registro actual encaja mejor en la secuencia
            valid_sequence[-1] = record
          end
          # Si no se reemplaza, el registro actual queda fuera (conflictivo)
        end
      end

      valid_sequence.map(&:id)
    end

    def should_replace_last_with_current?(valid_sequence, current_record)
      # Si solo hay un registro en la secuencia válida, no reemplazamos
      return false if valid_sequence.length < 2

      # Comparar con el penúltimo registro
      penultimate = valid_sequence[-2]
      penultimate_km = penultimate.km_reported
      current_km = current_record.km_reported

      # El registro actual puede reemplazar al último si:
      # 1. Es mayor o igual que el penúltimo (mantiene progresión)
      # 2. Es menor que el último (por eso entramos aquí)
      current_km >= penultimate_km
    end

    def build_conflict_reasons
      reasons = []

      prev_record = find_immediate_previous
      next_record = find_immediate_next

      if prev_record && @vehicle_km.km_reported < prev_record.km_reported
        reasons << "KM inferior al registro anterior (#{prev_record.km_reported} km el #{prev_record.input_date.strftime('%d/%m/%Y')})"
      end

      if next_record && @vehicle_km.km_reported > next_record.km_reported
        reasons << "KM superior al registro posterior (#{next_record.km_reported} km el #{next_record.input_date.strftime('%d/%m/%Y')})"
      end

      reasons
    end

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
  end
end
