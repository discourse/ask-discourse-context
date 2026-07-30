# frozen_string_literal: true

module AskDiscourseContext
  class AdminAssistantChatSnapshot
    Message =
      Data.define(:external_id, :role, :raw, :created_at, :updated_at, :deleted_at) do
        def active?
          deleted_at.nil?
        end

        def admin?
          role == "admin"
        end
      end

    attr_reader :messages

    def initialize(messages)
      @messages =
        messages.map do |message|
          attributes = message.respond_to?(:to_unsafe_h) ? message.to_unsafe_h : message.to_h
          attributes = attributes.stringify_keys

          Message.new(
            external_id: attributes.fetch("external_id").to_s,
            role: attributes.fetch("role"),
            raw: attributes.fetch("raw"),
            created_at: Time.iso8601(attributes.fetch("created_at").to_s),
            updated_at: Time.iso8601(attributes.fetch("updated_at").to_s),
            deleted_at:
              attributes["deleted_at"].present? ? Time.iso8601(attributes["deleted_at"].to_s) : nil,
          )
        end
    end

    def opening_message
      messages.find(&:admin?)
    end

    def from(message_id:, started_at:)
      if (index = messages.index { |message| message.external_id == message_id })
        messages.drop(index)
      else
        messages.select { |message| message.created_at >= started_at }
      end
    end
  end
end
