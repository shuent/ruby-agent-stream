# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ai_stream"
require "json"
require "pathname"
require "stringio"

require "minitest/autorun"

def fixture(name)
  Pathname(__dir__).join("fixtures", name)
end
