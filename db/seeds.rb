# db/seeds.rb

puts "Limpiando base de datos..."
VehicleKm.delete_all
Maintenance.delete_all
Vehicle.delete_all
Company.delete_all

# Crear compañías
puts "Creando compañías..."
company1 = Company.create!(
  name: "Transportes García S.L.",
  cif: "B12345678"
)

company2 = Company.create!(
  name: "Logística del Norte S.A.",
  cif: "A87654321"
)

# Crear vehículos
puts "Creando vehículos..."
vehicle1 = Vehicle.create!(
  matricula: "1234ABC",
  vin: "WBADT43452G123456",
  current_km: 0,
  company: company1
)

vehicle2 = Vehicle.create!(
  matricula: "5678XYZ",
  vin: "WBAUE11070E123456",
  current_km: 0,
  company: company1
)

vehicle3 = Vehicle.create!(
  matricula: "9012DEF",
  vin: "WBA3B1C50DF123456",
  current_km: 0,
  company: company2
)

# ======================================
#       REGISTROS MANUALES (sin source_record)
# ======================================

puts "Creando registros manuales de KM para vehículo 1..."
base_date = 6.months.ago
base_km = 50000

20.times do |i|
  date = base_date + (i * 7).days
  km = base_km + (i * 350) + rand(0..100)

  VehicleKms::CreateService.new(
    vehicle_id: vehicle1.id,
    params: {
      input_date: date.to_date,
      km_reported: km
      # SIN source_record ⇒ registro manual
    }
  ).call
end

# Registro conflictivo (regresión)
puts "Añadiendo registro conflictivo manual..."
VehicleKms::CreateService.new(
  vehicle_id: vehicle1.id,
  params: {
    input_date: 1.month.ago.to_date,
    km_reported: 55000
  }
).call

# Registro con incremento exagerado
VehicleKms::CreateService.new(
  vehicle_id: vehicle1.id,
  params: {
    input_date: 2.weeks.ago.to_date,
    km_reported: 80000
  }
).call

# ======================================
#   REGISTROS MANUALES PARA VEHÍCULO 2
# ======================================

puts "Creando registros manuales de KM para vehículo 2..."
base_km = 30000

10.times do |i|
  date = 3.months.ago + (i * 7).days
  km = base_km + (i * 400) + rand(0..100)

  VehicleKms::CreateService.new(
    vehicle_id: vehicle2.id,
    params: {
      input_date: date.to_date,
      km_reported: km
    }
  ).call
end

# ======================================
#      REGISTROS DESDE MANTENIMIENTO
# ======================================

puts "Creando mantenimientos..."
m1 = Maintenance.create!(
  vehicle: vehicle1,
  company: company1,
  maintenance_date: 2.months.ago.to_date,
  register_km: 58000,
  amount: 250.50,
  description: "Cambio de aceite y filtros"
)

VehicleKms::CreateService.new(
  vehicle_id: vehicle1.id,
  params: {
    input_date: m1.maintenance_date,
    km_reported: m1.register_km,
    source_record: m1     # ⬅️ ORIGEN mantenimiento
  }
).call

m2 = Maintenance.create!(
  vehicle: vehicle1,
  company: company1,
  maintenance_date: 1.month.ago.to_date,
  register_km: 61000,
  amount: 450.00,
  description: "Revisión completa"
)

VehicleKms::CreateService.new(
  vehicle_id: vehicle1.id,
  params: {
    input_date: m2.maintenance_date,
    km_reported: m2.register_km,
    source_record: m2
  }
).call

m3 = Maintenance.create!(
  vehicle: vehicle2,
  company: company1,
  maintenance_date: 1.month.ago.to_date,
  register_km: 33000,
  amount: 180.00,
  description: "Cambio de neumáticos"
)

VehicleKms::CreateService.new(
  vehicle_id: vehicle2.id,
  params: {
    input_date: m3.maintenance_date,
    km_reported: m3.register_km,
    source_record: m3
  }
).call

# ======================================
#   ESTADÍSTICAS
# ======================================

puts "\n✅ Seeds completados!"
puts "\nEstadísticas:"
puts "- Compañías: #{Company.count}"
puts "- Vehículos: #{Vehicle.count}"
puts "- Registros KM: #{VehicleKm.count}"
puts "  · Originales: #{VehicleKm.where(status: 'original').count}"
puts "  · Estimados:  #{VehicleKm.where(status: 'estimado').count}"
puts "  · Editados:   #{VehicleKm.where(status: 'editado').count}"
puts "- Mantenimientos: #{Maintenance.count}"

conflicts = VehicleKm.where(status: 'estimado')
if conflicts.any?
  puts "\n⚠️  Registros con correcciones:"
  conflicts.each do |km|
    puts "  · ID #{km.id}: #{km.correction_notes}"
  end
end
