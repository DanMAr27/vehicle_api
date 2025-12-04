# db/seeds.rb
# Limpiar datos existentes
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

# Crear registros de KM históricos para vehicle1
puts "Creando registros de KM para vehículo 1..."
base_date = 6.months.ago
base_km = 50000

# Registros normales cada semana
20.times do |i|
  date = base_date + (i * 7).days
  km = base_km + (i * 350) + rand(0..100) # Aproximadamente 50km/día

  VehicleKms::CreateService.new(
    vehicle_id: vehicle1.id,
    params: {
      input_date: date.to_date,
      source: [ 'telemetria', 'manual' ].sample,
      km_reported: km
    }
  ).call
end

# Añadir un registro conflictivo (regresión)
puts "Añadiendo registro conflictivo..."
VehicleKms::CreateService.new(
  vehicle_id: vehicle1.id,
  params: {
    input_date: 1.month.ago.to_date,
    source: 'manual',
    km_reported: 55000 # Menor que registros posteriores
  }
).call

# Añadir un registro con incremento muy alto
VehicleKms::CreateService.new(
  vehicle_id: vehicle1.id,
  params: {
    input_date: 2.weeks.ago.to_date,
    source: 'manual',
    km_reported: 80000 # Salto muy grande
  }
).call

# Crear registros para vehicle2
puts "Creando registros de KM para vehículo 2..."
base_km = 30000
10.times do |i|
  date = 3.months.ago + (i * 7).days
  km = base_km + (i * 400) + rand(0..100)

  VehicleKms::CreateService.new(
    vehicle_id: vehicle2.id,
    params: {
      input_date: date.to_date,
      source: 'telemetria',
      km_reported: km
    }
  ).call
end

# Crear mantenimientos
puts "Creando mantenimientos..."
Maintenance.create!(
  vehicle: vehicle1,
  company: company1,
  maintenance_date: 2.months.ago.to_date,
  register_km: 58000,
  amount: 250.50,
  description: "Cambio de aceite y filtros"
)

Maintenance.create!(
  vehicle: vehicle1,
  company: company1,
  maintenance_date: 1.month.ago.to_date,
  register_km: 61000,
  amount: 450.00,
  description: "Revisión completa"
)

Maintenance.create!(
  vehicle: vehicle2,
  company: company1,
  maintenance_date: 1.month.ago.to_date,
  register_km: 33000,
  amount: 180.00,
  description: "Cambio de neumáticos"
)

puts "\n✅ Seeds completados!"
puts "\nEstadísticas:"
puts "- Compañías: #{Company.count}"
puts "- Vehículos: #{Vehicle.count}"
puts "- Registros KM: #{VehicleKm.count}"
puts "  · Originales: #{VehicleKm.where(status: 'original').count}"
puts "  · Estimados: #{VehicleKm.where(status: 'estimado').count}"
puts "  · Editados: #{VehicleKm.where(status: 'editado').count}"
puts "- Mantenimientos: #{Maintenance.count}"

# Mostrar algunos registros conflictivos
conflicts = VehicleKm.where(status: 'estimado')
if conflicts.any?
  puts "\n⚠️  Registros con correcciones:"
  conflicts.each do |km|
    puts "  · ID #{km.id}: #{km.correction_notes}"
  end
end
