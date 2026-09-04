require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  test "preflight permits a local React client" do
    process :options, "/chat", headers: { "Origin" => "http://127.0.0.1:5173" }

    assert_response :no_content
    assert_equal "http://127.0.0.1:5173", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Access-Control-Allow-Methods"], "POST"
  end

  test "preflight does not reflect an unrelated origin" do
    process :options, "/chat", headers: { "Origin" => "https://attacker.example" }

    assert_response :no_content
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

end
