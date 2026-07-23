# frozen_string_literal: true

module AskDiscourseContext
  class AdminAssistantChatSynchronizer
    DELETED_FIRST_POST_RAW = "<!-- The imported source message was deleted. -->"
    EDIT_REASON = "Admin Assistant chat synchronization"

    class TopicConflict < StandardError
    end

    class AuthorConflict < StandardError
    end

    def initialize(actor:, agent_user:, external_id:, snapshot:, staged_user:, title:)
      @actor = actor
      @agent_user = agent_user
      @external_id = external_id
      @snapshot = snapshot
      @staged_user = staged_user
      @title = title
    end

    def sync
      topic = Topic.with_deleted.find_by(external_id: @external_id)
      ensure_topic_is_owned!(topic) if topic

      return if !topic && !@snapshot.opening_message

      topic ||= create_topic(@snapshot.opening_message)
      recover_topic(topic)
      reconcile_messages(topic)
    end

    private

    def ensure_topic_is_owned!(topic)
      if !topic.private_message? ||
           !topic.custom_fields[AskDiscourseContext::TOPIC_SYNC_CUSTOM_FIELD] ||
           topic.custom_fields[AskDiscourseContext::TOPIC_START_MESSAGE_ID_CUSTOM_FIELD].blank? ||
           topic.custom_fields[AskDiscourseContext::TOPIC_STARTED_AT_CUSTOM_FIELD].blank?
        raise TopicConflict
      end
    end

    def create_topic(opening_message)
      post =
        create_post(
          opening_message,
          title: @title,
          archetype: Archetype.private_message,
          target_user_ids: [@agent_user.id],
          external_id: @external_id,
          topic_opts: {
            custom_fields: {
              AskDiscourseContext::TOPIC_SYNC_CUSTOM_FIELD => true,
              AskDiscourseContext::TOPIC_START_MESSAGE_ID_CUSTOM_FIELD =>
                opening_message.external_id,
              AskDiscourseContext::TOPIC_STARTED_AT_CUSTOM_FIELD =>
                opening_message.created_at.iso8601(6),
            },
          },
        )
      post.topic
    end

    def recover_topic(topic)
      return if !topic.deleted_at

      PostDestroyer.new(@actor, topic.first_post, context: EDIT_REASON).recover
    end

    def reconcile_messages(topic)
      messages =
        @snapshot.from(
          message_id: topic.custom_fields[AskDiscourseContext::TOPIC_START_MESSAGE_ID_CUSTOM_FIELD],
          started_at:
            Time.iso8601(topic.custom_fields[AskDiscourseContext::TOPIC_STARTED_AT_CUSTOM_FIELD]),
        )
      posts = synchronized_posts(topic)

      messages.each { |message| reconcile_message(message, posts[message.external_id], topic) }

      missing_message_ids = posts.keys - messages.map(&:external_id)
      missing_message_ids.each { |message_id| delete_post(posts.fetch(message_id), topic) }
    end

    def synchronized_posts(topic)
      posts = topic.posts.with_deleted.to_a
      message_ids =
        PostCustomField
          .where(post_id: posts.map(&:id), name: AskDiscourseContext::MESSAGE_ID_CUSTOM_FIELD)
          .pluck(:post_id, :value)
          .to_h

      posts.filter_map { |post| [message_ids[post.id], post] if message_ids[post.id] }.to_h
    end

    def reconcile_message(message, post, topic)
      ensure_author_matches!(message, post) if post

      if message.active?
        post ||= create_post(message, topic_id: topic.id)
        recover_post(post) if post.deleted_at
        revise_post(post, message, topic)
        mark_source_deleted(post, false)
      elsif post
        delete_post(post, topic)
      else
        post = create_post(message, topic_id: topic.id)
        delete_post(post, topic)
      end
    end

    def ensure_author_matches!(message, post)
      expected_user_id = message.admin? ? @staged_user.id : @agent_user.id
      stored_role = post.custom_fields[AskDiscourseContext::MESSAGE_ROLE_CUSTOM_FIELD]

      raise AuthorConflict if post.user_id != expected_user_id || stored_role != message.role
    end

    def create_post(message, options = {})
      custom_fields = {
        AskDiscourseContext::MESSAGE_ID_CUSTOM_FIELD => message.external_id,
        AskDiscourseContext::MESSAGE_ROLE_CUSTOM_FIELD => message.role,
        AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD => false,
      }
      if message.admin?
        custom_fields[DiscourseAi::AiBot::Playground::BYPASS_AI_REPLY_CUSTOM_FIELD] = true
      end

      PostCreator.create!(
        message.admin? ? @staged_user : @agent_user,
        {
          raw: message.raw,
          acting_user: @actor,
          guardian: @actor.guardian,
          created_at: message.created_at,
          custom_fields: custom_fields,
          skip_validations: true,
          post_alert_options: {
            skip_send_email: true,
          },
        }.merge(options),
      )
    end

    def revise_post(post, message, topic)
      new_raw = message.raw
      new_title = post.is_first_post? ? @title : nil
      return if post.raw == new_raw && (!new_title || topic.title == new_title)

      changes = { raw: new_raw, edit_reason: EDIT_REASON }
      changes[:title] = new_title if new_title

      PostRevisor.new(post, topic).revise!(
        @actor,
        changes,
        bypass_bump: true,
        force_new_version: true,
        revised_at: message.updated_at,
        silent: true,
        skip_validations: true,
      )
    end

    def delete_post(post, topic)
      if post.is_first_post?
        revise_deleted_first_post(post, topic)
      elsif !post.deleted_at
        PostDestroyer.new(@actor, post, context: EDIT_REASON, skip_staff_log: true).destroy
        mark_source_deleted(post, true)
      end
    end

    def revise_deleted_first_post(post, topic)
      if post.raw != DELETED_FIRST_POST_RAW
        PostRevisor.new(post, topic).revise!(
          @actor,
          { raw: DELETED_FIRST_POST_RAW, edit_reason: EDIT_REASON },
          bypass_bump: true,
          force_new_version: true,
          silent: true,
          skip_validations: true,
        )
      end
      mark_source_deleted(post, true)
    end

    def recover_post(post)
      PostDestroyer.new(@actor, post, context: EDIT_REASON, skip_staff_log: true).recover
    end

    def mark_source_deleted(post, deleted)
      return if post.custom_fields[AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD] == deleted

      post.custom_fields[AskDiscourseContext::MESSAGE_DELETED_CUSTOM_FIELD] = deleted
      post.save_custom_fields
    end
  end
end
