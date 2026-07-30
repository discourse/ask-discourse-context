# frozen_string_literal: true
# name: ask-discourse-context
# about: Adds customer context and hosted Admin Assistant chat ingestion
# version: 0.1
# authors: Sam
# url: https://github.com/discourse/ask-discourse-context

module ::AskDiscourseContext
  PLUGIN_NAME = "ask-discourse-context"
  # Source IDs make snapshot reconciliation idempotent without exposing metadata in PM bodies.
  MESSAGE_ID_CUSTOM_FIELD = "ask_discourse_context_admin_assistant_message_id"
  MESSAGE_ROLE_CUSTOM_FIELD = "ask_discourse_context_admin_assistant_message_role"
  MESSAGE_DELETED_CUSTOM_FIELD = "ask_discourse_context_admin_assistant_message_deleted"
  TOPIC_SYNC_CUSTOM_FIELD = "ask_discourse_context_admin_assistant_chat"
  TOPIC_START_MESSAGE_ID_CUSTOM_FIELD = "ask_discourse_context_admin_assistant_start_message_id"
  TOPIC_STARTED_AT_CUSTOM_FIELD = "ask_discourse_context_admin_assistant_started_at"
end

Discourse::Application.routes.append do
  scope "/admin/plugins/ask-discourse-context", constraints: AdminConstraint.new do
    put "/admin-assistant-chats/:external_id" =>
          "ask_discourse_context/admin_assistant_chats#update",
        :constraints => {
          external_id: /[\w-]+/,
        },
        :defaults => {
          format: :json,
        }
  end
end

add_api_key_scope(
  :ask_discourse_context,
  {
    sync_admin_assistant_chats: {
      actions: %w[ask_discourse_context/admin_assistant_chats#update],
    },
  },
)

after_initialize do
  register_post_custom_field_type(AskDiscourseContext::MESSAGE_ID_CUSTOM_FIELD, :string)
  register_post_custom_field_type(AskDiscourseContext::MESSAGE_ROLE_CUSTOM_FIELD, :string)
  register_post_custom_field_type(AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD, :boolean)
  register_topic_custom_field_type(AskDiscourseContext::TOPIC_SYNC_CUSTOM_FIELD, :boolean)
  register_topic_custom_field_type(
    AskDiscourseContext::TOPIC_START_MESSAGE_ID_CUSTOM_FIELD,
    :string,
  )
  register_topic_custom_field_type(AskDiscourseContext::TOPIC_STARTED_AT_CUSTOM_FIELD, :string)

  require_relative "lib/ask_discourse_context/admin_assistant_chat_snapshot"
  require_relative "lib/ask_discourse_context/admin_assistant_chat_synchronizer"
  require_relative "lib/ask_discourse_context/staged_user"
  require_relative "app/services/ask_discourse_context/admin_assistant_chat/sync"
  require_relative "app/controllers/ask_discourse_context/admin_assistant_chats_controller"

  # The ask theme can then use this information to render links to sites
  add_to_serializer(
    :user_card,
    :ai_stream_conversation_unique_id,
    include_condition: -> { scope&.user&.admin },
  ) { object.custom_fields["ai-stream-conversation-unique-id"] }
end
