Rails.application.routes.draw do
  post "chat", to: "chats#create" # Original protocol fixture remains available.
  post "chat/no-llm-call", to: "chats#create"
  post "chat/openai", to: "chats#openai"
  post "chat/ruby_llm", to: "chats#ruby_llm"
  match "chat(/*path)", to: "chats#preflight", via: :options
  get "demo/dashboard", to: "demo#show"
  post "demo/reset", to: "demo#reset"
  post "demo/conversations", to: "demo#create_conversation"
  get "demo/conversations/:id", to: "demo#conversation"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

end
