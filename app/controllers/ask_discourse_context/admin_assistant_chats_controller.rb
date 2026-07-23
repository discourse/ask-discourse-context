# frozen_string_literal: true

module AskDiscourseContext
  class AdminAssistantChatsController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    def update
      AdminAssistantChat::Sync.call(
        service_params.deep_merge(params: { external_id: params[:external_id] }),
      ) do
        on_success { head :no_content }
        on_failed_contract do |contract|
          render_json_error(contract.errors.full_messages, status: :bad_request)
        end
        on_model_not_found(:agent) { raise Discourse::NotFound }
        on_failed_policy(:agent_can_receive_chat) { raise Discourse::InvalidAccess }
        on_failed_policy(:admin_can_sync_chat) { raise Discourse::InvalidAccess }
        on_failure { render_json_error(I18n.t("ask_discourse_context.sync_failed")) }
      end
    end
  end
end
