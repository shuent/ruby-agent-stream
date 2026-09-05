class AgentEventLog
  def self.dump(events)
    JSON.generate(events.reject { |event| event.type == :data && event.attributes[:name] == "run" }.map do |event|
      { type: event.type, attributes: event.attributes }
    end)
  end

  def self.load(json, run_event:)
    rows = JSON.parse(json, symbolize_names: true)
    events = rows.map { |row| AgentStream::UIMessage::V1::Event.new(row.fetch(:type), **row.fetch(:attributes)) }
    index = events.index { |event| event.type == :start_step }
    events.insert(index ? index + 1 : 0, run_event)
  end
end
