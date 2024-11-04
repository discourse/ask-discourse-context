# frozen_string_literal: true
# name: ask-discourse-context
# about: Adds AI Stream conversation unique ID to user cards
# version: 0.1
# authors: Sam
# url: https://github.com/discourse/ask-discourse-context

# The ask theme can then use this information to render links to sites

after_initialize do
  add_to_serializer(
    :user_card,
    :ai_stream_conversation_unique_id,
    include_condition: -> { scope&.user&.admin },
  ) { object.custom_fields["ai-stream-conversation-unique-id"] }
end
