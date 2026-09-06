require "ai_stream"
require "ai_stream/adapters/ruby_llm"
require "openai"
require "ruby_llm"

# The example reads only the authorized server-side key and never exposes the
# root .env file through Rails, response metadata, or the Vite client.
root_env = Rails.root.join("..", "..", ".env")
if ENV["OPENAI_API_KEY"].to_s.empty? && root_env.file?
  line = root_env.each_line.find { |candidate| candidate.start_with?("OPENAI_APIKEY=") }
  value = line&.split("=", 2)&.last&.strip
  value = value[1..-2] if value&.start_with?(%q{"}) && value.end_with?(%q{"})
  ENV["OPENAI_API_KEY"] = value unless value.to_s.empty?
end

RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
end
