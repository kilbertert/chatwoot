require_dependency Rails.root.join('app/services/wecom/outbound/hmac_client.rb')

# 调 wecom-ai 发送文本消息
# wecom-ai 收到后,会调企业微信客服 send_kf_message API 把消息发到 WeCom
class Wecom::Outbound::SendTextService
  def initialize(message:, open_kfid:, external_userid:)
    @message = message
    @open_kfid = open_kfid
    @external_userid = external_userid
  end

  def perform
    payload = {
      open_kfid: @open_kfid,
      external_userid: @external_userid,
      msgtype: 'text',
      text: { content: @message.content.to_s }
    }

    Wecom::Outbound::HmacClient.new(@message.inbox.channel).post('/chatwoot/internal/send_message', payload)
  end
end
