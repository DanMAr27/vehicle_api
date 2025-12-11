Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Permite solicitudes de CUALQUIER origen (*), lo cual es ideal para desarrollo
    # para que la interfaz de Swagger (que se carga como un origen separado) pueda acceder al JSON.
    origins "*"

    # Especifica los recursos (rutas) que se pueden compartir. '*' aplica a todas.
    resource "*",
      headers: :any,
      # DEBE incluir :options. La petición OPTIONS es la que usa el navegador
      # para verificar si el servidor permite la conexión (preflight check).
      methods: [ :get, :post, :put, :patch, :delete, :options, :head ]
  end
end
