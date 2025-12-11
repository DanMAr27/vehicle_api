# config/initializers/swagger.rb

GrapeSwaggerRails.options.url     = "/api/v1/swagger_doc"
GrapeSwaggerRails.options.app_url = if Rails.env.production?
                                      "https://vehicle-api-nwq1.onrender.com"
else
                                      "http://localhost:3000"
end
GrapeSwaggerRails.options.doc_expansion = "list"
GrapeSwaggerRails.options.headers        = { "Content-Type" => "application/json" }
