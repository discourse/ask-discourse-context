# frozen_string_literal: true

module AskDiscourseContext
  class StagedUser
    UNIQUE_ID_CUSTOM_FIELD = "ai-stream-conversation-unique-id"
    MUTEX_VALIDITY = 30.seconds

    class InvalidUser < StandardError
    end

    def self.find_or_create!(unique_id:, preferred_username:)
      mutex_key = Digest::SHA256.hexdigest(unique_id)

      DistributedMutex.synchronize(
        "ask-discourse-context-staged-user-#{mutex_key}",
        validity: MUTEX_VALIDITY,
      ) do
        user = UserCustomField.find_by(name: UNIQUE_ID_CUSTOM_FIELD, value: unique_id)&.user
        raise InvalidUser if user && !user.staged?
        next user if user

        user =
          User.new(
            username: UserNameSuggester.suggest(preferred_username || unique_id),
            email: "#{SecureRandom.hex}@invalid.com",
            staged: true,
            active: false,
          )
        user.custom_fields[UNIQUE_ID_CUSTOM_FIELD] = unique_id
        user.save!
        user
      end
    end
  end
end
