# frozen_string_literal: true

RSpec.describe AskDiscourseContext::AdminAssistantChatsController do
  fab!(:admin)
  fab!(:regular_user, :user)
  fab!(:assistant_user) do
    Fabricate(
      :user,
      id: AskDiscourseContext::ADMIN_ASSISTANT_USER_ID,
      username: "ask_admin_assistant",
    )
  end
  fab!(:assistant_agent) do
    Fabricate(:ai_agent, id: AskDiscourseContext::ADMIN_ASSISTANT_AGENT_ID, user: assistant_user)
  end

  let(:external_id) { "admin-assistant-0123456789abcdef0123456789abcdef" }
  let(:user_unique_id) { "https://example.com/u/source-admin" }
  let(:title) { "Admin Assistant chat with source admin" }
  let(:started_at) { Time.utc(2026, 7, 23, 12) }

  def message(external_id:, role:, raw:, created_at:, updated_at: created_at, deleted_at: nil)
    {
      external_id: external_id.to_s,
      role: role,
      raw: raw,
      created_at: created_at.iso8601(6),
      updated_at: updated_at.iso8601(6),
      deleted_at: deleted_at&.iso8601(6),
    }
  end

  def payload(messages:, unique_id: user_unique_id, preferred_username: "source_admin")
    {
      user_unique_id: unique_id,
      preferred_username: preferred_username,
      title: title,
      messages: messages,
    }
  end

  def sync_chat(messages:, id: external_id, headers: nil, **payload_options)
    put "/admin/plugins/ask-discourse-context/admin-assistant-chats/#{id}.json",
        params: payload(messages: messages, **payload_options),
        headers: headers,
        as: :json
  end

  def source_post(topic, message_id)
    custom_field =
      PostCustomField.find_by(
        name: AskDiscourseContext::MESSAGE_ID_CUSTOM_FIELD,
        value: message_id.to_s,
        post_id: topic.posts.with_deleted.select(:id),
      )

    Post.with_deleted.find(custom_field.post_id) if custom_field
  end

  describe "#update" do
    it "requires an admin" do
      messages = [
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        ),
      ]

      sync_chat(messages: messages)
      expect(response).to have_http_status(:not_found)

      sign_in(regular_user)
      sync_chat(messages: messages)
      expect(response).to have_http_status(:not_found)

      expect(Topic.exists?(external_id: external_id)).to eq(false)
    end

    it "allows only the dedicated granular API-key scope" do
      messages = [
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        ),
      ]
      scope =
        Fabricate.build(
          :api_key_scope,
          resource: "ask_discourse_context",
          action: "sync_admin_assistant_chats",
        )
      api_key = Fabricate(:api_key, user: admin, scope_mode: :granular, api_key_scopes: [scope])
      headers = { "Api-Key" => api_key.key, "Api-Username" => admin.username }

      sync_chat(messages: messages, headers: headers)

      expect(response).to have_http_status(:no_content)
      expect(Topic.exists?(external_id: external_id)).to eq(true)

      scope.update!(action: "fake")
      rejected_external_id = "admin-assistant-fedcba9876543210fedcba9876543210"

      sync_chat(messages: messages, id: rejected_external_id, headers: headers)

      expect(response).to have_http_status(:not_found)
      expect(Topic.exists?(external_id: rejected_external_id)).to eq(false)
    end

    it "does nothing for an empty snapshot" do
      sign_in(admin)

      expect { sync_chat(messages: []) }.not_to change {
        UserCustomField.where(name: AskDiscourseContext::StagedUser::UNIQUE_ID_CUSTOM_FIELD).count
      }

      expect(response).to have_http_status(:no_content)
      expect(Topic.exists?(external_id: external_id)).to eq(false)
    end

    it "does nothing for an assistant welcome without an admin message" do
      sign_in(admin)
      messages = [
        message(
          external_id: 1,
          role: "assistant",
          raw: "Welcome! I am here to help.",
          created_at: started_at,
        ),
      ]

      expect { sync_chat(messages: messages) }.not_to change {
        UserCustomField.where(name: AskDiscourseContext::StagedUser::UNIQUE_ID_CUSTOM_FIELD).count
      }

      expect(response).to have_http_status(:no_content)
      expect(Topic.exists?(external_id: external_id)).to eq(false)
    end

    it "starts at the first admin message with the real authors and AI bypass field" do
      sign_in(admin)
      messages = [
        message(
          external_id: 1,
          role: "assistant",
          raw: "Welcome! I am here to help.",
          created_at: started_at,
        ),
        message(
          external_id: 2,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at + 1.minute,
        ),
        message(
          external_id: 3,
          role: "assistant",
          raw: "Open the settings page.",
          created_at: started_at + 2.minutes,
        ),
      ]

      sync_chat(messages: messages)

      expect(response).to have_http_status(:no_content)
      topic = Topic.find_by!(external_id: external_id)
      staged_user =
        UserCustomField.find_by!(
          name: AskDiscourseContext::StagedUser::UNIQUE_ID_CUSTOM_FIELD,
          value: user_unique_id,
        ).user
      admin_post = source_post(topic, 2)
      assistant_post = source_post(topic, 3)

      expect(source_post(topic, 1)).to be_nil
      expect(topic.topic_allowed_users.pluck(:user_id)).to contain_exactly(
        staged_user.id,
        assistant_user.id,
      )
      expect([admin_post.user, assistant_post.user]).to eq([staged_user, assistant_user])
      expect(
        admin_post.custom_fields[DiscourseAi::AiBot::Playground::BYPASS_AI_REPLY_CUSTOM_FIELD],
      ).to be_present
      expect(
        assistant_post.custom_fields[DiscourseAi::AiBot::Playground::BYPASS_AI_REPLY_CUSTOM_FIELD],
      ).to be_nil
    end

    it "is idempotent when the same snapshot is synchronized again" do
      sign_in(admin)
      messages = [
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        ),
        message(
          external_id: 2,
          role: "assistant",
          raw: "Open the settings page.",
          created_at: started_at + 1.minute,
        ),
      ]

      sync_chat(messages: messages)
      topic = Topic.find_by!(external_id: external_id)
      post_ids = topic.posts.order(:post_number).pluck(:id)
      revision_count = PostRevision.where(post_id: post_ids).count

      expect { sync_chat(messages: messages) }.not_to change { topic.posts.with_deleted.count }

      expect(response).to have_http_status(:no_content)
      expect(topic.posts.order(:post_number).pluck(:id)).to eq(post_ids)
      expect(PostRevision.where(post_id: post_ids).count).to eq(revision_count)
    end

    it "edits, soft-deletes, and restores synchronized replies" do
      sign_in(admin)
      initial_messages = [
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        ),
        message(
          external_id: 2,
          role: "assistant",
          raw: "Open the settings page.",
          created_at: started_at + 1.minute,
        ),
      ]
      sync_chat(messages: initial_messages)
      topic = Topic.find_by!(external_id: external_id)
      assistant_post = source_post(topic, 2)

      edited_messages = [
        initial_messages.first,
        message(
          external_id: 2,
          role: "assistant",
          raw: "Open the AI settings page.",
          created_at: started_at + 1.minute,
          updated_at: started_at + 2.minutes,
        ),
      ]
      sync_chat(messages: edited_messages)

      expect(response).to have_http_status(:no_content)
      expect(assistant_post.reload.raw).to eq("Open the AI settings page.")

      deleted_messages = [
        initial_messages.first,
        message(
          external_id: 2,
          role: "assistant",
          raw: "Open the AI settings page.",
          created_at: started_at + 1.minute,
          updated_at: started_at + 2.minutes,
          deleted_at: started_at + 3.minutes,
        ),
      ]
      sync_chat(messages: deleted_messages)

      expect(response).to have_http_status(:no_content)
      expect(assistant_post.reload.deleted_at).to be_present
      expect(assistant_post.custom_fields[AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD]).to eq(
        true,
      )

      sync_chat(messages: edited_messages)

      expect(response).to have_http_status(:no_content)
      expect(assistant_post.reload.deleted_at).to be_nil
      expect(assistant_post.custom_fields[AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD]).to eq(
        false,
      )
    end

    it "uses the invisible placeholder for a deleted first admin message and restores it" do
      sign_in(admin)
      active_message =
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        )
      sync_chat(messages: [active_message])
      topic = Topic.find_by!(external_id: external_id)
      first_post = topic.first_post

      deleted_message =
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
          updated_at: started_at + 1.minute,
          deleted_at: started_at + 1.minute,
        )
      sync_chat(messages: [deleted_message])

      expect(response).to have_http_status(:no_content)
      expect(first_post.reload.raw).to eq(
        AskDiscourseContext::AdminAssistantChatSynchronizer::DELETED_FIRST_POST_RAW,
      )
      expect(first_post.deleted_at).to be_nil
      expect(first_post.custom_fields[AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD]).to eq(
        true,
      )
      expect(topic.reload.deleted_at).to be_nil

      sync_chat(messages: [active_message])

      expect(response).to have_http_status(:no_content)
      expect(first_post.reload.raw).to eq("How do I configure this?")
      expect(first_post.custom_fields[AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD]).to eq(
        false,
      )
    end

    it "creates a traceable PM when its first observed admin message is already deleted" do
      sign_in(admin)
      deleted_message =
        message(
          external_id: 1,
          role: "admin",
          raw: "A message deleted between snapshots",
          created_at: started_at,
          updated_at: started_at + 1.minute,
          deleted_at: started_at + 1.minute,
        )

      sync_chat(messages: [deleted_message])

      expect(response).to have_http_status(:no_content)
      topic = Topic.find_by!(external_id: external_id)
      first_post = source_post(topic, 1)
      expect(first_post.raw).to eq(
        AskDiscourseContext::AdminAssistantChatSynchronizer::DELETED_FIRST_POST_RAW,
      )
      expect(first_post.custom_fields[AskDiscourseContext::MESSAGE_ID_CUSTOM_FIELD]).to eq("1")
      expect(first_post.custom_fields[AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD]).to eq(
        true,
      )
    end

    it "deletes omitted synchronized posts and preserves Ask-native posts" do
      sign_in(admin)
      initial_messages = [
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        ),
        message(
          external_id: 2,
          role: "assistant",
          raw: "Open the settings page.",
          created_at: started_at + 1.minute,
        ),
      ]
      sync_chat(messages: initial_messages)
      topic = Topic.find_by!(external_id: external_id)
      synchronized_reply = source_post(topic, 2)
      native_post =
        PostCreator.create!(
          admin,
          topic_id: topic.id,
          raw: "A reply written directly on Ask",
          skip_validations: true,
        )

      sync_chat(messages: [initial_messages.first])

      expect(response).to have_http_status(:no_content)
      expect(synchronized_reply.reload.deleted_at).to be_present
      expect(native_post.reload.deleted_at).to be_nil
    end

    it "reuses a staged user across conversations with the same unique ID" do
      sign_in(admin)
      messages = [
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        ),
      ]
      other_external_id = "admin-assistant-fedcba9876543210fedcba9876543210"

      sync_chat(messages: messages)
      sync_chat(messages: messages, id: other_external_id)

      expect(response).to have_http_status(:no_content)
      first_topic = Topic.find_by!(external_id: external_id)
      second_topic = Topic.find_by!(external_id: other_external_id)
      staged_fields =
        UserCustomField.where(
          name: AskDiscourseContext::StagedUser::UNIQUE_ID_CUSTOM_FIELD,
          value: user_unique_id,
        )

      expect(staged_fields.count).to eq(1)
      expect([first_topic.first_post.user_id, second_topic.first_post.user_id].uniq).to eq(
        [staged_fields.pick(:user_id)],
      )
    end

    it "rejects invalid roles, duplicate IDs, and out-of-order timestamps" do
      sign_in(admin)
      valid_admin =
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        )

      invalid_role = valid_admin.merge(role: "system")
      sync_chat(messages: [invalid_role])
      expect(response).to have_http_status(:bad_request)

      duplicate_id =
        message(
          external_id: 1,
          role: "assistant",
          raw: "Open the settings page.",
          created_at: started_at + 1.minute,
        )
      sync_chat(messages: [valid_admin, duplicate_id])
      expect(response).to have_http_status(:bad_request)

      earlier_reply =
        message(
          external_id: 2,
          role: "assistant",
          raw: "Open the settings page.",
          created_at: started_at - 1.minute,
        )
      sync_chat(messages: [valid_admin, earlier_reply])
      expect(response).to have_http_status(:bad_request)

      expect(Topic.exists?(external_id: external_id)).to eq(false)
    end

    it "rejects an external ID collision" do
      sign_in(admin)
      Fabricate(:topic, external_id: external_id)
      messages = [
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        ),
      ]

      sync_chat(messages: messages)

      expect(response).not_to have_http_status(:no_content)
      expect(Topic.find_by!(external_id: external_id).private_message?).to eq(false)
    end

    it "rejects a source message whose author role changes" do
      sign_in(admin)
      admin_message =
        message(
          external_id: 1,
          role: "admin",
          raw: "How do I configure this?",
          created_at: started_at,
        )
      sync_chat(messages: [admin_message])
      topic = Topic.find_by!(external_id: external_id)
      first_post = topic.first_post

      conflicting_message =
        message(
          external_id: 1,
          role: "assistant",
          raw: "How do I configure this?",
          created_at: started_at,
        )
      sync_chat(messages: [conflicting_message])

      expect(response).not_to have_http_status(:no_content)
      expect(first_post.reload.user.staged?).to eq(true)
      expect(first_post.custom_fields[AskDiscourseContext::MESSAGE_ROLE_CUSTOM_FIELD]).to eq(
        "admin",
      )
    end
  end
end
