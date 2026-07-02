# 处理 wecom-ai 推送的入站事件
# 鉴权: HMAC-SHA256(post_body, channel.wecom_ai_secret) 头取自 X-WecomAI-Signature
class Webhooks::WecomEventsJob < ApplicationJob
  queue_as :low
  retry_on ActiveRecord::Deadlocked, wait: 3.seconds, attempts: 3

  def perform(params: {}, open_kfid: '', post_body: '', signature: '', trigger_bot_handoff: false)
    @params = params.with_indifferent_access
    @open_kfid = open_kfid
    @post_body = post_body
    @signature = signature
    @trigger_bot_handoff = trigger_bot_handoff

    return unless valid_channel?
    return unless valid_post_body?

    if @trigger_bot_handoff
      handle_bot_handoff!
    else
      Wecom::IncomingMessageService.new(inbox: @channel.inbox, params: @params.with_indifferent_access).perform
    end
  end

  def handle_bot_handoff!
    # 触发 Conversation#bot_handoff! - 不创建 message
    contact_inbox = @channel.inbox.contact_inboxes.find_by(source_id: @params[:external_userid])
    return unless contact_inbox

    conversation = contact_inbox.conversations.last
    return unless conversation

    conversation.bot_handoff!  # 触发 CONVERSATION_BOT_HANDOFF dispatcher 事件
  end

  private

  def valid_post_body?
    return false if @post_body.blank? || @signature.blank?
    return false if @channel.wecom_ai_secret.blank?

    expected = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('SHA256'), @channel.wecom_ai_secret, @post_body)
    ActiveSupport::SecurityUtils.secure_compare(expected, @signature.to_s)
  end

  def valid_channel?
    @channel = Channel::Wecom.find_by(open_kfid: @open_kfid)
    return false if @channel.nil?
    return false if @channel.account_id.nil?
    return false unless @channel.account&.active?

    true
  end
end
