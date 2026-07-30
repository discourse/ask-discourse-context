# frozen_string_literal: true

module AskDiscourseContext
  module AdminAssistantChat
    class Sync
      include Service::Base

      MAX_MESSAGES = 1_000
      MAX_TOTAL_RAW_BYTES = 10.megabytes
      EXTERNAL_ID_PATTERN = /\A[\w-]+\z/
      ROLES = %w[admin assistant].freeze

      params do
        attribute :external_id, :string
        attribute :user_unique_id, :string
        attribute :preferred_username, :string
        attribute :title, :string
        attribute :messages, :array

        validates :external_id,
                  presence: true,
                  length: {
                    maximum: Topic::EXTERNAL_ID_MAX_LENGTH,
                  },
                  format: {
                    with: EXTERNAL_ID_PATTERN,
                  }
        validates :user_unique_id, presence: true, length: { maximum: 500 }
        validates :preferred_username, presence: true, length: { maximum: User.username_length.max }
        validates :title,
                  presence: true,
                  length: {
                    in: SiteSetting.min_topic_title_length..SiteSetting.max_topic_title_length,
                  }
        validates :messages, length: { maximum: MAX_MESSAGES }
        validate :messages_are_valid

        private

        def messages_are_valid
          if !messages.is_a?(Array)
            errors.add(:messages, :invalid)
            return
          end

          normalized_messages =
            messages.filter_map do |message|
              attributes = message.respond_to?(:to_unsafe_h) ? message.to_unsafe_h : message.to_h
              attributes.stringify_keys
            end
          if normalized_messages.size != messages.size
            errors.add(:messages, :invalid)
            return
          end

          validate_message_ids(normalized_messages)
          validate_message_attributes(normalized_messages)
          validate_total_raw_size(normalized_messages)
        rescue NoMethodError, TypeError
          errors.add(:messages, :invalid)
        end

        def validate_message_ids(messages)
          ids = messages.map { |message| message["external_id"].to_s }
          if ids.any?(&:blank?) || ids.any? { |id| id.length > 100 } || ids.uniq.size != ids.size
            errors.add(:messages, :invalid)
          end
        end

        def validate_message_attributes(messages)
          previous_created_at = nil

          messages.each do |message|
            errors.add(:messages, :invalid) if !ROLES.include?(message["role"])

            raw = message["raw"]
            if !raw.is_a?(String) || raw.length > SiteSetting.max_post_length
              errors.add(:messages, :invalid)
            end

            created_at = parse_timestamp(message["created_at"])
            updated_at = parse_timestamp(message["updated_at"])
            deleted_at =
              message["deleted_at"].present? ? parse_timestamp(message["deleted_at"]) : nil

            errors.add(:messages, :invalid) if !created_at || !updated_at
            errors.add(:messages, :invalid) if created_at && updated_at && updated_at < created_at
            errors.add(:messages, :invalid) if created_at && deleted_at && deleted_at < created_at
            if previous_created_at && created_at && created_at < previous_created_at
              errors.add(:messages, :invalid)
            end

            previous_created_at = created_at if created_at
          end
        end

        def validate_total_raw_size(messages)
          total_raw_bytes = messages.sum { |message| message["raw"].to_s.bytesize }
          errors.add(:messages, :invalid) if total_raw_bytes > MAX_TOTAL_RAW_BYTES
        end

        def parse_timestamp(value)
          Time.iso8601(value.to_s)
        rescue ArgumentError
          nil
        end
      end

      policy :admin_can_sync_chat
      model :snapshot, :build_snapshot

      only_if :chat_should_sync do
        model :agent
        policy :agent_can_receive_chat

        lock :external_id do
          try(
            ActiveRecord::ActiveRecordError,
            Discourse::InvalidParameters,
            AdminAssistantChatSynchronizer::AuthorConflict,
            AdminAssistantChatSynchronizer::TopicConflict,
            StagedUser::InvalidUser,
          ) do
            model :staged_user, :create_staged_user
            step :synchronize_chat
          end
        end
      end

      private

      def admin_can_sync_chat(guardian:)
        guardian.is_admin?
      end

      def build_snapshot(params:)
        AdminAssistantChatSnapshot.new(params.messages)
      end

      def chat_should_sync(params:, snapshot:)
        snapshot.opening_message || Topic.with_deleted.exists?(external_id: params.external_id)
      end

      def fetch_agent
        AiAgent.find_by(id: SiteSetting.ask_discourse_context_admin_assistant_agent_id)
      end

      def agent_can_receive_chat(agent:)
        agent.user_id == SiteSetting.ask_discourse_context_admin_assistant_user_id &&
          agent.user&.active? && agent.user.bot?
      end

      def create_staged_user(params:)
        StagedUser.find_or_create!(
          unique_id: params.user_unique_id,
          preferred_username: params.preferred_username,
        )
      end

      def synchronize_chat(params:, guardian:, agent:, snapshot:, staged_user:)
        AdminAssistantChatSynchronizer.new(
          actor: guardian.user,
          agent_user: agent.user,
          external_id: params.external_id,
          snapshot: snapshot,
          staged_user: staged_user,
          title: params.title,
        ).sync
      end
    end
  end
end
