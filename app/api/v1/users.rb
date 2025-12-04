# app/api/v1/users.rb

module V1
  class Users < Grape::API
    resource :users do
      desc "Returns a list of users"
      get do
        # Retorna un mensaje simple por ahora
        { users: [
          { id: 1, name: "Alice", status: "invited" },
          { id: 2, name: "Bob", status: "active" }
        ] }
      end

      desc "Returns a specific user"
      params do
        requires :id, type: Integer, desc: "User ID"
      end
      get ":id" do
        { id: params[:id], name: "User #{params[:id]}", status: "active" }
      end
    end
  end
end
