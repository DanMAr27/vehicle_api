# config/initializers/swagger.rb

GrapeSwaggerRails.options.url      = "/api/v1/swagger_doc" 
GrapeSwaggerRails.options.app_url  = "http://localhost:3000"
GrapeSwaggerRails.options.doc_expansion = "list"           
GrapeSwaggerRails.options.headers  = { "Content-Type" => "application/json" }
