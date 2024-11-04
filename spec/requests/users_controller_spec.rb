# frozen_string_literal: true

describe UsersController do
  fab!(:user) do
    user = Fabricate(:user)
    user.custom_fields["ai-stream-conversation-unique-id"] = "test"
    user.save
    user
  end
  fab!(:admin) { Fabricate(:admin) }

  describe "#index" do
    it "should not serialize data for regural users" do
      sign_in(user)
      get "/u/#{user.username_lower}/card.json"
      expect(response.parsed_body["user"]["ai_stream_conversation_unique_id"]).to eq(nil)
    end

    it "should serialize data for admin users" do
      sign_in(admin)
      get "/u/#{user.username_lower}/card.json"
      expect(response.parsed_body["user"]["ai_stream_conversation_unique_id"]).to eq("test")
    end
  end
end
