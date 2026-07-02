# Channel::Wecom 的出站服务
# 实际工作交给 Wecom::Outbound::SendTextService 调用 wecom-ai HTTP API
class Wecom::SendOnWecomService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Wecom
  end

  def perform_reply
    contact_inbox_source_id = conversation.contact_inbox.source_id
    return if contact_inbox_source_id.blank?

    result = Wecom::Outbound::SendTextService.new(
      message: message,
      open_kfid: channel.open_kfid,
      external_userid: contact_inbox_source_id
    ).perform

    if result[:success]
      message.update!(source_id: result[:msgid]) if result[:msgid].present?
    else
      Messages::StatusUpdateService.new(message, 'failed', result[:error].to_s).perform
    end
  rescue StandardError => e
    Rails.logger.error("[Wecom::SendOnWecomService] #{e.class.name}: #{e.message}")
    Messages::StatusUpdateService.new(message, 'failed', e.message).perform
  end
end
